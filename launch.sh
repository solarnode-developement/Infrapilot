#!/bin/bash
set -euo pipefail

############################################
# CONFIG
############################################

API_URL="https://integrate.api.nvidia.com/v1/chat/completions"
MODEL="step-3.5-flash"
API_KEY="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"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

STATE_DIR="/tmp/infrapilot_state"
CACHE_FILE="/tmp/infrapilot_approval_cache.json"
LOG="/tmp/infrapilot.log"

EXPLAIN=false
SWARM=false

NODES=()

############################################
# DEPENDENCIES
############################################

require_deps() {
  for cmd in jq ssh curl sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "[InfraPilot] Installing missing: $cmd"
      apt update && apt install -y jq curl openssh-client coreutils || true
    }
  done
}

############################################
# FLAGS
############################################

for arg in "$@"; do
  [[ "$arg" == "--swarm" ]] && SWARM=true
  [[ "$arg" == "--why" ]] && EXPLAIN=true
done

############################################
# LOG
############################################

log() {
  echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"
}

############################################
# TERMINAL UI INPUT
############################################

tui() {
  echo "======================================"
  echo "         InfraPilot Launcher"
  echo "======================================"
  echo "1) Single VPS"
  echo "2) Swarm Mode"
  echo "3) Explain Mode"
  echo ""

  read -rp "Select mode: " mode

  case "$mode" in
    1)
      read -rp "Enter VPS (user@ip): " NODE
      export NODES_INPUT="$NODE"
      SWARM=false
      ;;
    2)
      read -rp "Enter VPS list (comma separated): " NODE
      export NODES_INPUT="$NODE"
      SWARM=true
      ;;
    3)
      read -rp "Enter VPS list (comma separated): " NODE
      export NODES_INPUT="$NODE"
      EXPLAIN=true
      ;;
  esac
}

############################################
# NODE LOADER
############################################

load_nodes() {
  IFS=',' read -ra NODES <<< "$NODES_INPUT"
}

############################################
# SINGLE / SWARM MODE EXECUTION FLOW
############################################

run_mode() {
  mkdir -p "$STATE_DIR"

  if [[ "$SWARM" == true ]]; then
    log "Swarm mode enabled"

    for n in "${NODES[@]}"; do
      scan_node "$n" &
    done
    wait

    STATE=$(build_state)

  else
    log "Single VPS mode (local host)"

    STATE_FILE="/tmp/infrapilot_single.json"

    {
      echo "{"
      echo "\"host\": \"$(hostname)\","
      echo "\"uptime\": \"$(uptime)\","
      echo "\"disk\": \"$(df -h | head -5)\","
      echo "\"mem\": \"$(free -m)\","
      echo "\"cpu\": \"$(top -bn1 | head -5)\"
      echo "}"
    } > "$STATE_FILE"

    STATE="$STATE_FILE"
  fi
}

############################################
# SSH SCAN
############################################

scan_node() {
  local node="$1"
  local out="$STATE_DIR/$(echo "$node" | tr '@./' '_').json"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$node" bash <<'EOF' > "$out"
{
  "host": "$(hostname)",
  "uptime": "$(uptime)",
  "disk": "$(df -h)",
  "mem": "$(free -m)",
  "cpu": "$(top -bn1 | head -5)"
}
EOF
}

build_state() {
  local out="/tmp/infrapilot_global.json"
  echo "{" > "$out"

  for f in "$STATE_DIR"/*.json; do
    echo "\"$(basename "$f")\": $(cat "$f")," >> "$out"
  done

  echo "\"end\": true}" >> "$out"
  echo "$out"
}

############################################
# LLM CALL
############################################

call_llm() {
  local state="$1"
  local mode_text="Return ONLY JSON actions."

  $EXPLAIN && mode_text="Explain only. No actions."

  curl -s "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL\",
      \"temperature\": 0,
      \"messages\": [
        {
          \"role\": \"system\",
          \"content\": \"InfraPilot JSON controller\"
        },
        {
          \"role\": \"user\",
          \"content\": \"$mode_text\n\nSTATE:\n$(cat "$state")\"
        }
      ]
    }"
}

############################################
# APPROVAL CACHE
############################################

cache_init() {
  [[ -f "$CACHE_FILE" ]] || echo "{}" > "$CACHE_FILE"
}

fingerprint() {
  echo "$1|$2|$3|$4" | sha256sum | awk '{print $1}'
}

cache_check() {
  jq -e --arg fp "$1" '.[$fp]' "$CACHE_FILE" >/dev/null 2>&1
}

cache_get() {
  jq -r --arg fp "$1" '.[$fp].decision' "$CACHE_FILE"
}

cache_save() {
  local fp="$1"
  local decision="$2"

  tmp=$(mktemp)

  jq --arg fp "$fp" --arg d "$decision" \
    '.[$fp] = {"decision": $d, "ts": (now|floor)}' \
    "$CACHE_FILE" > "$tmp"

  mv "$tmp" "$CACHE_FILE"
}

############################################
# SAFETY FILTER
############################################

safe_service() {
  case "$1" in
    nginx|docker|redis) return 0 ;;
    *) return 1 ;;
  esac
}

filter_actions() {
  local input="$1"
  local out="/tmp/infrapilot_filtered.json"
  > "$out"

  echo "$input" | jq -c '.actions[]?' 2>/dev/null | while read -r a; do
    type=$(echo "$a" | jq -r '.type')

    if [[ "$type" == "restart_service" ]]; then
      svc=$(echo "$a" | jq -r '.service')
      safe_service "$svc" && echo "$a" >> "$out"
    else
      echo "$a" >> "$out"
    fi
  done

  echo "$out"
}

############################################
# APPROVAL UI (NO POPUPS, FULL TERMINAL)
############################################

approve_actions() {
  local file="$1"
  local approved="/tmp/infrapilot_approved.json"
  > "$approved"

  cache_init

  mapfile -t actions < "$file"

  echo ""
  echo "======================================"
  echo "        InfraPilot Approval UI"
  echo "======================================"
  echo ""

  i=1
  for a in "${actions[@]}"; do
    node=$(echo "$a" | jq -r '.node')
    type=$(echo "$a" | jq -r '.type')
    svc=$(echo "$a" | jq -r '.service // "-"')

    echo "[$i] $node | $type | $svc"
    ((i++))
  done

  echo ""
  echo "Commands:"
  echo "  a <n>   approve"
  echo "  r <n>   reject"
  echo "  all     approve cached-safe"
  echo "  q       continue"
  echo ""

  while true; do
    read -rp "InfraPilot> " cmd idx

    case "$cmd" in

      a)
        a="${actions[$((idx-1))]}"

        node=$(echo "$a" | jq -r '.node')
        type=$(echo "$a" | jq -r '.type')
        svc=$(echo "$a" | jq -r '.service // "-"')
        cmdx=$(echo "$a" | jq -r '.command // "-"')

        fp=$(fingerprint "$node" "$type" "$svc" "$cmdx")

        cache_save "$fp" "approve"
        echo "$a" >> "$approved"

        log "Approved $node $type"
        ;;

      r)
        a="${actions[$((idx-1))]}"

        node=$(echo "$a" | jq -r '.node')
        type=$(echo "$a" | jq -r '.type')
        svc=$(echo "$a" | jq -r '.service // "-"')
        cmdx=$(echo "$a" | jq -r '.command // "-"')

        fp=$(fingerprint "$node" "$type" "$svc" "$cmdx")

        cache_save "$fp" "reject"

        log "Rejected $node $type"
        ;;

      all)
        for a in "${actions[@]}"; do
          node=$(echo "$a" | jq -r '.node')
          type=$(echo "$a" | jq -r '.type')
          svc=$(echo "$a" | jq -r '.service // "-"')
          cmdx=$(echo "$a" | jq -r '.command // "-"')

          fp=$(fingerprint "$node" "$type" "$svc" "$cmdx")

          if cache_check "$fp" && [[ "$(cache_get "$fp")" == "approve" ]]; then
            echo "$a" >> "$approved"
          fi
        done
        ;;

      q)
        break
        ;;
    esac
  done

  echo "$approved"
}

############################################
# EXECUTION
############################################

execute() {
  local file="$1"

  if $EXPLAIN; then
    log "Explain mode"
    cat "$file"
    return
  fi

  while read -r action; do
    node=$(echo "$action" | jq -r '.node')
    type=$(echo "$action" | jq -r '.type')

    case "$type" in
      restart_service)
        svc=$(echo "$action" | jq -r '.service')
        ssh -i "$SSH_KEY" "$node" "systemctl restart $svc" || true
        ;;
      cleanup)
        cmd=$(echo "$action" | jq -r '.command')
        ssh -i "$SSH_KEY" "$node" "$cmd" || true
        ;;
    esac
  done < "$file"
}

############################################
# MAIN
############################################

main() {
  require_deps
  tui
  load_nodes

  log "Starting InfraPilot"

  run_mode

  raw=$(call_llm "$STATE")

  content=$(echo "$raw" | jq -r '.choices[0].message.content')
  echo "$content" > /tmp/infrapilot_actions.json

  filtered=$(filter_actions "/tmp/infrapilot_actions.json")

  approved=$(approve_actions "$filtered")

  execute "$approved"

  log "Done"
}

main "$@"
