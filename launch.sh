#!/bin/bash
set -euo pipefail

###########################################
# InfraPilot v7 - Infrastructure Agent
# Production-grade single-file deployment
###########################################

# Configuration
readonly SCRIPT_NAME="infrapilot"
readonly SCRIPT_VERSION="7.0"
readonly LOG_FILE="/tmp/infrapilot.log"
readonly CACHE_FILE="/tmp/infrapilot_cache.json"
readonly API_TIMEOUT=30
readonly SSH_OPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new"

# State
declare -g MODE=""
declare -g NODES=()
declare -ag ACTIONS=()
declare -g API_KEY="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"
declare -g API_ENDPOINT="${NVIDIA_API_ENDPOINT:-https://integrate.api.nvidia.com/v1/chat/completions}"
declare -g SSH_KEY="${SSH_KEY:-}"

###########################################
# Logging & Output
###########################################

log() {
    local msg="$1"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] $msg" | tee -a "$LOG_FILE"
}

err() {
    local msg="$1"
    echo "[ERROR] $msg" >&2
    echo "[ERROR] $msg" >> "$LOG_FILE"
}

success() {
    local msg="$1"
    echo "[✓] $msg"
    log "[SUCCESS] $msg"
}

###########################################
# JSON Escaping Helper
###########################################

json_escape() {
    local str="$1"
    # Use jq to safely escape the string
    echo -n "$str" | jq -Rs .
}

###########################################
# Dependency Checks
###########################################

check_dependencies() {
    log "checking dependencies..."
    
    local missing=()
    
    for cmd in jq curl ssh; do
        if ! command -v "$cmd" &> /dev/null; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "missing dependencies: ${missing[*]}"
        err "install with: sudo apt-get update && sudo apt-get install -y curl jq openssh-client"
        return 1
    fi
    
    log "dependencies OK"
    return 0
}

###########################################
# Mode & Input Validation
###########################################

validate_inputs() {
    if [[ -z "$MODE" ]]; then
        err "MODE not set (use: single or swarm)"
        return 1
    fi
    
    if [[ "$MODE" != "single" && "$MODE" != "swarm" ]]; then
        err "invalid MODE: $MODE (must be 'single' or 'swarm')"
        return 1
    fi
    
    if [[ -z "$API_KEY" ]]; then
        err "NVIDIA_API_KEY not set"
        return 1
    fi
    
    if [[ "$MODE" == "swarm" ]]; then
        if [[ ${#NODES[@]} -eq 0 ]]; then
            err "swarm mode requires NODES array"
            return 1
        fi
        
        for node in "${NODES[@]}"; do
            if [[ -z "$node" ]]; then
                err "empty node in swarm mode"
                return 1
            fi
        done
        
        if [[ -z "$SSH_KEY" ]]; then
            err "SSH_KEY required for swarm mode"
            return 1
        fi
        
        if [[ ! -f "$SSH_KEY" ]]; then
            err "SSH key not found: $SSH_KEY"
            return 1
        fi
    fi
    
    log "input validation OK"
    return 0
}

###########################################
# State Collection
###########################################

collect_state_local() {
    local uptime mem_free disk_free load
    
    uptime=$(uptime -p 2>/dev/null || echo "unknown")
    load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1" "$2" "$3}' || echo "unknown")
    mem_free=$(free -m 2>/dev/null | awk 'NR==2 {print $7"MB"}' || echo "unknown")
    disk_free=$(df -h / 2>/dev/null | awk 'NR==2 {print $4}' || echo "unknown")
    
    local uptime_esc load_esc mem_esc disk_esc
    uptime_esc=$(json_escape "$uptime")
    load_esc=$(json_escape "$load")
    mem_esc=$(json_escape "$mem_free")
    disk_esc=$(json_escape "$disk_free")
    
    cat <<EOF
{
  "host": "localhost",
  "uptime": $uptime_esc,
  "load": $load_esc,
  "disk_free": $disk_esc,
  "mem_free": $mem_esc
}
EOF
}

collect_state_remote() {
    local node="$1"
    local uptime mem_free disk_free load
    
    local cmd="uptime -p 2>/dev/null || echo 'unknown'; cat /proc/loadavg 2>/dev/null | awk '{print \$1\" \"\$2\" \"\$3}' || echo 'unknown'; free -m 2>/dev/null | awk 'NR==2 {print \$7\"MB\"}' || echo 'unknown'; df -h / 2>/dev/null | awk 'NR==2 {print \$4}' || echo 'unknown'"
    
    local output
    if output=$(ssh $SSH_OPTS -i "$SSH_KEY" "$node" "$cmd" 2>/dev/null); then
        uptime=$(echo "$output" | sed -n '1p')
        load=$(echo "$output" | sed -n '2p')
        mem_free=$(echo "$output" | sed -n '3p')
        disk_free=$(echo "$output" | sed -n '4p')
    else
        uptime="unknown"
        load="unknown"
        mem_free="unknown"
        disk_free="unknown"
    fi
    
    local node_esc uptime_esc load_esc mem_esc disk_esc
    node_esc=$(json_escape "$node")
    uptime_esc=$(json_escape "$uptime")
    load_esc=$(json_escape "$load")
    mem_esc=$(json_escape "$mem_free")
    disk_esc=$(json_escape "$disk_free")
    
    cat <<EOF
{
  "host": $node_esc,
  "uptime": $uptime_esc,
  "load": $load_esc,
  "disk_free": $disk_esc,
  "mem_free": $mem_esc
}
EOF
}

collect_state() {
    log "collecting state..."
    
    local state_nodes=()
    
    if [[ "$MODE" == "single" ]]; then
        state_nodes+=("$(collect_state_local)")
    else
        for node in "${NODES[@]}"; do
            state_nodes+=("$(collect_state_remote "$node")")
        done
    fi
    
    local state
    state=$(printf '%s\n' "${state_nodes[@]}" | jq -s '{nodes: .}' 2>/dev/null)
    
    if ! echo "$state" | jq empty 2>/dev/null; then
        err "invalid state JSON generated"
        return 1
    fi
    
    echo "$state"
    log "state collected and normalized"
}

###########################################
# LLM Integration
###########################################

call_llm() {
    local state="$1"
    
    log "calling NVIDIA API..."
    
    local state_escaped
    state_escaped=$(echo "$state" | jq -Rs .)
    
    local prompt="You are an infrastructure automation agent. Analyze this system state and return ONLY a JSON array of actions. Do not include any other text.

System State:
$state

Return actions as JSON array with schema: [{\"node\": \"hostname/localhost\", \"type\": \"restart_service|cleanup|shell\", \"service\": \"optional\", \"command\": \"optional\"}]

Generate 0-3 safe, non-destructive actions based on the state. Return empty array if no actions needed. Return ONLY the JSON array."

    local payload
    payload=$(jq -n \
        --arg model "stepfun-ai/step-3.5-flash" \
        --arg prompt "$prompt" \
        '{
            model: $model,
            messages: [
                {
                    role: "user",
                    content: $prompt
                }
            ],
            temperature: 0.3,
            max_tokens: 500
        }')

    local response
    if ! response=$(curl -s -X POST \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json" \
        --max-time "$API_TIMEOUT" \
        -d "$payload" \
        "$API_ENDPOINT" 2>/dev/null); then
        err "LLM API call failed"
        return 1
    fi
    
    if ! echo "$response" | jq empty 2>/dev/null; then
        err "invalid LLM response: $response"
        return 1
    fi
    
    local content
    content=$(echo "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
    
    if [[ -z "$content" ]]; then
        err "no content in LLM response"
        return 1
    fi
    
    # Extract JSON array from response
    local actions
    actions=$(echo "$content" | grep -oP '^\[.*\]$' || echo "[]")
    
    if ! echo "$actions" | jq empty 2>/dev/null; then
        log "no valid actions in LLM response"
        echo "[]"
        return 0
    fi
    
    echo "$actions"
    log "LLM returned $(echo "$actions" | jq 'length') actions"
}

###########################################
# Action Validation
###########################################

validate_actions() {
    local actions="$1"
    
    log "validating actions..."
    
    if ! echo "$actions" | jq empty 2>/dev/null; then
        err "invalid JSON in actions"
        return 1
    fi
    
    local count
    count=$(echo "$actions" | jq 'length')
    
    for ((i=0; i<count; i++)); do
        local node type service command
        
        node=$(echo "$actions" | jq -r ".[$i].node // empty")
        type=$(echo "$actions" | jq -r ".[$i].type // empty")
        
        if [[ -z "$node" ]]; then
            err "action $i: empty node"
            return 1
        fi
        
        if [[ -z "$type" ]]; then
            err "action $i: empty type"
            return 1
        fi
        
        if [[ ! "$type" =~ ^(restart_service|cleanup|shell)$ ]]; then
            err "action $i: invalid type '$type'"
            return 1
        fi
        
        if [[ "$type" == "restart_service" ]]; then
            service=$(echo "$actions" | jq -r ".[$i].service // empty")
            if [[ -z "$service" ]]; then
                err "action $i: restart_service requires service field"
                return 1
            fi
        fi
        
        if [[ "$type" =~ ^(cleanup|shell)$ ]]; then
            command=$(echo "$actions" | jq -r ".[$i].command // empty")
            if [[ -z "$command" ]]; then
                err "action $i: $type requires command field"
                return 1
            fi
        fi
    done
    
    success "all actions valid"
    return 0
}

###########################################
# Approval System with Caching
###########################################

init_cache() {
    if [[ ! -f "$CACHE_FILE" ]]; then
        echo '{"decisions": {}}' > "$CACHE_FILE"
    fi
}

get_action_fingerprint() {
    local node="$1" type="$2" service="$3" command="$4"
    local input="${node}|${type}|${service}|${command}"
    echo -n "$input" | sha256sum | awk '{print $1}'
}

check_cached_decision() {
    local fingerprint="$1"
    
    local decision
    decision=$(jq -r ".decisions[\"$fingerprint\"] // empty" "$CACHE_FILE" 2>/dev/null)
    
    if [[ "$decision" == "approved" ]]; then
        return 0
    fi
    
    return 1
}

cache_decision() {
    local fingerprint="$1" decision="$2"
    
    jq ".decisions[\"$fingerprint\"] = \"$decision\"" "$CACHE_FILE" > "${CACHE_FILE}.tmp"
    mv "${CACHE_FILE}.tmp" "$CACHE_FILE"
}

approval_ui() {
    local actions="$1"
    
    log "entering approval UI..."
    
    init_cache
    
    local count
    count=$(echo "$actions" | jq 'length')
    
    if [[ $count -eq 0 ]]; then
        log "no actions to approve"
        return 0
    fi
    
    declare -ga ACTIONS=()
    
    for ((i=0; i<count; i++)); do
        local node type service command fingerprint
        
        node=$(echo "$actions" | jq -r ".[$i].node")
        type=$(echo "$actions" | jq -r ".[$i].type")
        service=$(echo "$actions" | jq -r ".[$i].service // \"\"")
        command=$(echo "$actions" | jq -r ".[$i].command // \"\"")
        
        fingerprint=$(get_action_fingerprint "$node" "$type" "$service" "$command")
        
        if check_cached_decision "$fingerprint"; then
            log "action $i: approved from cache"
            ACTIONS+=("$i")
            continue
        fi
        
        echo ""
        echo "════════════════════════════════════"
        echo "Action $((i+1))/$count"
        echo "════════════════════════════════════"
        echo "Node:    $node"
        echo "Type:    $type"
        if [[ -n "$service" ]]; then
            echo "Service: $service"
        fi
        if [[ -n "$command" ]]; then
            echo "Command: $command"
        fi
        echo ""
        
        while true; do
            read -p "Approve? (y/n/s for skip): " -r choice
            case "$choice" in
                y|Y)
                    cache_decision "$fingerprint" "approved"
                    ACTIONS+=("$i")
                    log "action $i: approved by user"
                    break
                    ;;
                n|N)
                    cache_decision "$fingerprint" "rejected"
                    log "action $i: rejected by user"
                    break
                    ;;
                s|S)
                    log "action $i: skipped by user"
                    break
                    ;;
                *)
                    echo "invalid choice"
                    ;;
            esac
        done
    done
    
    echo ""
    echo "════════════════════════════════════"
    echo "Summary: $(echo "${#ACTIONS[@]}") actions approved out of $count"
    echo "════════════════════════════════════"
    echo ""
}

###########################################
# Action Execution
###########################################

execute_action() {
    local node="$1" type="$2" service="$3" command="$4"
    
    local cmd_to_run=""
    
    case "$type" in
        restart_service)
            cmd_to_run="systemctl restart $service"
            ;;
        cleanup|shell)
            cmd_to_run="$command"
            ;;
        *)
            err "unknown action type: $type"
            return 1
            ;;
    esac
    
    log "executing: [$node] $type"
    
    if [[ "$node" == "localhost" ]]; then
        if ! eval "$cmd_to_run" 2>&1 | tee -a "$LOG_FILE"; then
            err "execution failed on localhost"
            return 1
        fi
    else
        if ! ssh $SSH_OPTS -i "$SSH_KEY" "$node" "$cmd_to_run" 2>&1 | tee -a "$LOG_FILE"; then
            err "execution failed on $node"
            return 1
        fi
    fi
    
    success "executed: [$node] $type"
    return 0
}

execute_actions() {
    local actions="$1"
    
    if [[ ${#ACTIONS[@]} -eq 0 ]]; then
        log "no actions to execute"
        return 0
    fi
    
    log "executing ${#ACTIONS[@]} approved actions..."
    
    for idx in "${ACTIONS[@]}"; do
        local node type service command
        
        node=$(echo "$actions" | jq -r ".[$idx].node")
        type=$(echo "$actions" | jq -r ".[$idx].type")
        service=$(echo "$actions" | jq -r ".[$idx].service // \"\"")
        command=$(echo "$actions" | jq -r ".[$idx].command // \"\"")
        
        execute_action "$node" "$type" "$service" "$command" || true
    done
    
    success "execution phase complete"
}

###########################################
# Main Pipeline
###########################################

main() {
    log "InfraPilot v$SCRIPT_VERSION starting..."
    
    check_dependencies || exit 1
    validate_inputs || exit 1
    
    local state
    state=$(collect_state) || exit 1
    
    log "state: $state"
    
    local actions
    actions=$(call_llm "$state") || exit 1
    
    validate_actions "$actions" || exit 1
    
    approval_ui "$actions"
    
    execute_actions "$actions"
    
    success "InfraPilot run complete"
    log "see full log: $LOG_FILE"
}

###########################################
# CLI Entry Point
###########################################

usage() {
    cat <<EOF
Usage: $0 [options]

Options:
  -m, --mode MODE              single or swarm (required)
  -n, --nodes NODES            comma-separated nodes for swarm mode
  -k, --ssh-key PATH           path to SSH private key (required for swarm)
  -h, --help                   show this help

Environment Variables:
  NVIDIA_API_KEY               required
  NVIDIA_API_ENDPOINT          optional, defaults to NVIDIA integration endpoint
  SSH_KEY                      optional, path to SSH key

Example:
  $0 -m single

  $0 -m swarm -n "user@host1,user@host2" -k ~/.ssh/id_rsa

EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            MODE="$2"
            shift 2
            ;;
        -n|--nodes)
            IFS=',' read -ra NODES <<< "$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            err "unknown option: $1"
            usage
            ;;
    esac
done

main "$@"
