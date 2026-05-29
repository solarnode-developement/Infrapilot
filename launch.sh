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
RAW_FILE="/tmp/infrapilot_raw.json"
ACTION_FILE="/tmp/infrapilot_actions.json"
LOG="/tmp/infrapilot.log"

SWARM=false
EXPLAIN=false
NODES=()

mkdir -p "$STATE_DIR"

############################################
# LOGGING
############################################

log() {
  echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"
}

############################################
# DEPENDENCIES
############################################

require_deps() {
  for c in jq curl ssh sha256sum; do
    command -v "$c" >/dev/null 2>&1 || {
      apt update && apt install -y jq curl openssh-client coreutils
    }
  done
}

############################################
# TUI INPUT
############################################

tui() {
  echo "================================"
  echo "       InfraPilot v7"
  echo "================================"
  echo "1) Single VPS"
  echo "2) Swarm Mode"
  echo "3) Explain Mode"
  echo

  read -rp "Select mode: " m

  case "$m" in
    1)
      read -rp "VPS (user@ip): " NODE
      NODES=("$NODE")
      SWARM=false
      ;;
    2)
      read -rp "VPS list (comma separated): " NODE
      IFS=',' read -ra NODES <<< "$NODE"
      SWARM=true
      ;;
    3)
      read -rp "VPS list (comma separated): " NODE
      IFS=',' read -ra NODES <<< "$NODE"
      EXPLAIN=true
      ;;
  esac
}

############################################
# STATE COLLECTION (SAFE JSON ONLY)
############################################

collect_node() {
  local node="$1"
  local out="$STATE_DIR/$(echo "$node" | tr '@./' '_').json"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$node" bash <<'EOF' > "$out"
{
  "host": "$(hostname)",
  "uptime": "$(uptime -p)",
  "load": "$(cat /proc/loadavg | awk '{print $1,$2,$3}')",
  "disk_free": "$(df -h / | tail -1 | awk '{print $4}')",
  "mem_free": "$(free -m | awk '/Mem:/ {print $4}')"
}
EOF
}

build_state() {
  jq -s '{nodes: .}' "$STATE_DIR"/*.json
}

############################################
# LLM CALL (SAFE PAYLOAD)
############################################

call_llm() {
  local state="$1"
  local payload

  payload=$(jq -Rs . < "$state")

  curl -s "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL\",
      \"temperature\": 0.2,
      \"messages\": [
        {
          \"role\": \"system\",
          \"content\": \"Return ONLY JSON array: [{node,type,service?,command?}]\"
        },
        {
          \"role\": \"user\",
          \"content\": $payload
        }
      ]
    }" | tee "$RAW_FILE"
}

############################################
# PARSE OUTPUT
############################################

parse_actions() {
  jq -r '.choices[0].message.content // "[]"' "$RAW_FILE" > "$ACTION_FILE"
}

############################################
# VALIDATION LAYER
############################################

validate() {
  jq -c '.[]?' "$ACTION_FILE" 2>/dev/null | while read -r a; do

    node=$(echo "$a" | jq -r '.node')
    type=$(echo "$a" | jq -r '.type')

    [[ -z "$node" || -z "$type" ]] && continue

    case "$type" in
      restart_service|cleanup|shell)
        echo "$a"
        ;;
      *)
        log "Rejected invalid action type: $type"
        ;;
    esac
  done
}

############################################
# EXECUTION ENGINE
############################################

execute() {
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
        log "Cleanup on $node"
        ssh -i "$SSH_KEY" "$node" "$cmd" || true
        ;;

      shell)
        cmd=$(echo "$action" | jq -r '.command')
        log "Shell on $node"
        ssh -i "$SSH_KEY" "$node" "$cmd" || true
        ;;
    esac

  done
}

############################################
# MAIN FLOW
############################################

main() {
  require_deps
  tui

  log "Collecting state..."

  if $SWARM; then
    for n in "${NODES[@]}"; do
      collect_node "$n"
    done
    STATE=$(build_state)
  else
    collect_node "${NODES[0]}"
    STATE=$(build_state)
  fi

  log "Calling LLM..."
  call_llm "$STATE"

  log "Parsing output..."
  parse_actions

  if $EXPLAIN; then
    cat "$ACTION_FILE"
    exit 0
  fi

  log "Validating actions..."
  VALID=$(validate)

  log "Executing..."
  echo "$VALID" | execute

  log "Done"
}

main "$@"
