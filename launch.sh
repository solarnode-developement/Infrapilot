#!/bin/bash
set -euo pipefail

############################################
# CONFIG
############################################

API_URL="https://integrate.api.nvidia.com/v1/chat/completions"
MODEL="step-3.5-flash"
API_KEY="${NIM_API_KEY:-}"

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
  for cmd in jq ssh curl whiptail sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || {
      echo "[InfraPilot] installing $cmd..."
      apt update && apt install -y jq openssh-client curl whiptail coreutils || true
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
# LOGGING
############################################

log() {
  echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"
}

############################################
# NODE INPUT
############################################

tui() {
  MODE=$(whiptail --title "InfraPilot" --menu "Select Mode" 15 60 3 \
    "1" "Single VPS" \
    "2" "Swarm Mode" \
    "3" "Explain Mode" 3>&1 1>&2 2>&3)

  case "$MODE" in
    1)
      NODE=$(whiptail --inputbox "Enter VPS (user@ip)" 10 60 3>&1 1>&2 2>&3)
      export NODES_INPUT="$NODE"
      ;;
    2)
      NODE=$(whiptail --inputbox "Enter VPS list (comma separated)" 10 60 3>&1 1>&2 2>&3)
      export NODES_INPUT="$NODE"
      SWARM=true
      ;;
    3)
      NODE=$(whiptail --inputbox "Enter VPS list" 10 60 3>&1 1>&2 2>&3)
      export NODES_INPUT="$NODE"
      EXPLAIN=true
      ;;
  esac
}

load_nodes() {
  IFS=',' read -ra NODES <<< "$NODES_INPUT"
}

############################################
# SSH STATE
############################################

scan_node() {
  local node="$1"
  local out="$STATE_DIR/$(echo "$node" | tr '@./' '_').json"

  mkdir -p "$STATE_DIR"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$node" bash <<'EOF' > "$out"
{
  "host": "$(hostname)",
  "uptime": "$(uptime)",
  "disk": "$(df -h | head -10 | tr '\n' ' ')",
  "mem": "$(free -m | tr '\n' ' ')",
  "cpu": "$(top -bn1 | head -10 | tr '\n' ' ')"
}
EOF
}

collect() {
  for n in "${NODES[@]}"; do
    scan_node "$n" &
  done
  wait
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
# LLM
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
        {\"role\": \"system\", \"content\": \"InfraPilot JSON controller\"},
        {\"role\": \"user\", \"content\": \"$mode_text\n\nSTATE:\n$(cat "$state")\"}
      ]
    }"
}

############################################
# APPROVAL CACHE CORE
############################################

fingerprint() {
  echo "$1|$2|$3|$4" | sha256sum | awk '{print $1}'
}

cache_init() {
  [[ -f "$CACHE_FILE" ]] || echo "{}" > "$CACHE_FILE"
}

cache_check() {
  local fp="$1"
  jq -e --arg fp "$fp" '.[$fp]' "$CACHE_FILE" >/dev/null 2>&1
}

cache_get() {
  local fp="$1"
  jq -r --arg fp "$fp" '.[$fp].decision' "$CACHE_FILE"
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
# APPROVAL ENGINE (WITH CACHE)
############################################

approve_actions() {
  local file="$1"
  local approved="/tmp/infrapilot_approved.json"
  > "$approved"

  cache_init

  mapfile -t actions < "$file"

  for a in "${actions[@]}"; do

    node=$(echo "$a" | jq -r '.node')
    type=$(echo "$a" | jq -r '.type')
    svc=$(echo "$a" | jq -r '.service // "-"')
    cmd=$(echo "$a" | jq -r '.command // "-"')

    fp=$(fingerprint "$node" "$type" "$svc" "$cmd")

    # CACHE HIT
    if cache_check "$fp"; then
      decision=$(cache_get "$fp")

      log "[CACHE] $node $type → $decision"

      if [[ "$decision" == "approve" ]]; then
        echo "$a" >> "$approved"
      fi
      continue
    fi

    # HUMAN APPROVAL
    whiptail --yesno "Approve action?\n\nNode: $node\nType: $type\nService: $svc" 15 60

    if [[ $? -eq 0 ]]; then
      cache_save "$fp" "approve"
      echo "$a" >> "$approved"
      log "Approved $type on $node"
    else
      cache_save "$fp" "reject"
      log "Rejected $type on $node"
    fi

  done

  echo "$approved"
}

############################################
# EXECUTION
############################################

execute() {
  local file="$1"

  if $EXPLAIN; then
    log "Explain mode active"
    cat "$file"
    return
  fi

  while read -r action; do
    node=$(echo "$action" | jq -r '.node')
    type=$(echo "$action" | jq -r '.type')

    case "$type" in
      restart_service)
        svc=$(echo "$action" | jq -r '.service')
        log "Restart $svc on $node"
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

  mkdir -p "$STATE_DIR"

  collect

  STATE=$(build_state)

  raw=$(call_llm "$STATE")

  content=$(echo "$raw" | jq -r '.choices[0].message.content')
  echo "$content" > /tmp/infrapilot_actions.json

  filtered=$(filter_actions "/tmp/infrapilot_actions.json")

  approved=$(approve_actions "$filtered")

  execute "$approved"

  log "Done"
}

main "$@"
