#!/bin/bash
set -euo pipefail

############################################
# CONFIG
############################################

API_URL="https://integrate.api.nvidia.com/v1/chat/completions"
MODEL="step-3.5-flash"
API_KEY="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"

SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_rsa}"

NODES=(
  "root@vps1.example.com"
  "root@vps2.example.com"
  "root@vps3.example.com"
)

AGENTS=("auditor" "optimizer" "ops" "safety" "orchestrator")

STATE_DIR="/tmp/infrapilot_state"
SNAP_DIR="/tmp/infrapilot_snapshots"
LOG="/tmp/infrapilot.log"

EXPLAIN=false
SWARM_BETA=false

############################################
# FLAGS
############################################

for arg in "$@"; do
  [[ "$arg" == "--why" ]] && EXPLAIN=true
  [[ "$arg" == "--swarm-beta" ]] && SWARM_BETA=true
done

mkdir -p "$STATE_DIR" "$SNAP_DIR"

############################################
# LOGGING
############################################

log() {
  echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"
}

############################################
# SSH POOL (simple but parallel)
############################################

ssh_run() {
  local node="$1"
  local cmd="$2"

  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
    "$node" "$cmd" 2>/dev/null || true
}

scan_node() {
  local node="$1"
  local file="$STATE_DIR/$(echo "$node" | tr '@./' '_').json"

  log "Scanning $node"

  ssh_run "$node" "bash -s" <<'EOF' > "$file"
{
  "host": "$(hostname)",
  "uptime": "$(uptime)",
  "disk": "$(df -h | head -10 | tr '\n' ' ')",
  "mem": "$(free -m | tr '\n' ' ')",
  "cpu": "$(top -bn1 | head -10 | tr '\n' ' ')",
  "services": "$(systemctl list-units --type=service --state=running | head -20 | tr '\n' ' ')"
}
EOF
}

collect_cluster() {
  for n in "${NODES[@]}"; do
    scan_node "$n" &
  done
  wait
}

build_global_state() {
  local out="/tmp/infrapilot_global.json"
  echo "{" > "$out"

  for f in "$STATE_DIR"/*.json; do
    echo "\"$(basename "$f")\": $(cat "$f")," >> "$out"
  done

  echo "\"end\": true}" >> "$out"
  echo "$out"
}

############################################
# SNAPSHOT + ROLLBACK GRAPH (simple version)
############################################

snapshot_cluster() {
  local id
  id=$(date +%s)

  mkdir -p "$SNAP_DIR/$id"

  log "Creating snapshot $id"

  for n in "${NODES[@]}"; do
    ssh_run "$n" "systemctl list-units --type=service" > "$SNAP_DIR/$id/${n//[@./]/_}_services.txt"
    ssh_run "$n" "df -h" > "$SNAP_DIR/$id/${n//[@./]/_}_disk.txt"
  done

  echo "$id" > "$SNAP_DIR/latest"
}

rollback_cluster() {
  [[ ! -f "$SNAP_DIR/latest" ]] && echo "No snapshot" && exit 1

  local id
  id=$(cat "$SNAP_DIR/latest")

  log "Rolling back cluster to $id (manual restore only)"

  # NOTE: real systems would restore configs, not just logs
  for n in "${NODES[@]}"; do
    log "No-op rollback hook for $n (extend for real infra)"
  done
}

############################################
# LLM CALL
############################################

call_llm() {
  local state="$1"

  local mode_prompt

  if $EXPLAIN; then
    mode_prompt="Explain system state only. No actions."
  else
    mode_prompt="Return STRICT JSON ONLY:
{
  \"actions\": [
    {
      \"node\": \"root@vps1.example.com\",
      \"type\": \"restart_service\",
      \"service\": \"nginx\",
      \"reason\": \"string\"
    }
  ]
}"
  fi

  local payload
  payload=$(cat "$state")

  curl -s "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"$MODEL\",
      \"temperature\": 0,
      \"messages\": [
        {
          \"role\": \"system\",
          \"content\": \"You are InfraPilot. You output only valid JSON.\"
        },
        {
          \"role\": \"user\",
          \"content\": $(echo "$mode_prompt\n\nSTATE:\n$payload" | jq -Rs .)
        }
      ]
    }"
}

############################################
# VALIDATION LAYER
############################################

is_safe_service() {
  case "$1" in
    nginx|docker|redis) return 0 ;;
    *) return 1 ;;
  esac
}

validate() {
  local input="$1"
  local out="/tmp/infrapilot_valid.json"
  > "$out"

  echo "$input" | jq -c '.actions[]?' 2>/dev/null | while read -r a; do
    type=$(echo "$a" | jq -r '.type')

    if [[ "$type" == "restart_service" ]]; then
      svc=$(echo "$a" | jq -r '.service')
      is_safe_service "$svc" && echo "$a" >> "$out" || log "BLOCKED $svc"
    else
      echo "$a" >> "$out"
    fi
  done

  echo "$out"
}

############################################
# EXECUTION ENGINE
############################################

execute() {
  local file="$1"

  if $EXPLAIN; then
    log "Explain mode: no execution"
    cat "$file"
    return
  fi

  log "Executing plan..."

  while read -r action; do
    node=$(echo "$action" | jq -r '.node')
    type=$(echo "$action" | jq -r '.type')

    case "$type" in
      restart_service)
        svc=$(echo "$action" | jq -r '.service')
        log "Restart $svc on $node"
        ssh_run "$node" "systemctl restart $svc"
        ;;
      cleanup)
        cmd=$(echo "$action" | jq -r '.command')
        log "Cleanup on $node"
        ssh_run "$node" "$cmd"
        ;;
    esac
  done < "$file"
}

############################################
# SWARM SUPER-AGENT MODE (simplified)
############################################

superagent() {
  local state="$1"

  log "Running SuperAgent mode (parallel reasoning)"

  local auditor optimizer ops safety orchestrator

  auditor=$(call_llm "$state")
  optimizer=$(call_llm "$state")
  ops=$(call_llm "$state")
  safety=$(call_llm "$state")

  orchestrator=$(echo "$auditor $optimizer $ops $safety" | jq -Rs .)

  echo "$orchestrator"
}

############################################
# MAIN
############################################

main() {
  [[ -z "$API_KEY" ]] && echo "Missing API key" && exit 1

  log "InfraPilot v6 starting"

  collect_cluster

  global=$(build_global_state)

  if $SWARM_BETA; then
    raw=$(superagent "$global")
  else
    raw=$(call_llm "$global")
  fi

  echo "$raw" > /tmp/infrapilot_raw.json

  content=$(echo "$raw" | jq -r '.choices[0].message.content')

  echo "$content" > /tmp/infrapilot_actions.json

  valid=$(validate "$content")

  snapshot_cluster

  execute "$valid"

  log "InfraPilot done"
}

main "$@"
