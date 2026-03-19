#!/bin/bash
# dispatch.sh — Send a command to a tmux agent session with auto-completion notification
# Usage: dispatch.sh <session> <task_id> <command...>
#
# Wraps the agent command so that:
# 1. Task status is updated to "running" before execution
# 2. Agent stdout is captured to a log file for token parsing
# 3. on-complete.sh fires when command finishes (updates status + triggers webhook)
# 4. Post-commit force-commit fallback catches agents that forget to commit
#
# Shell compatibility:
#   tmux default-shell on macOS is /bin/zsh.  PIPESTATUS[0] is bash-only; zsh uses
#   pipestatus[1].  The agent command is written to a temp bash script that is
#   executed with `bash` — guarantees bash semantics, avoids send-keys quoting issues.

set -euo pipefail

SESSION="${1:?Usage: dispatch.sh <session> <task_id> <command...>}"
TASK_ID="${2:?}"
shift 2
COMMAND="$*"

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$SKILL_DIR/scripts"
ON_COMPLETE="$SCRIPT_DIR/on-complete.sh"
UPDATE_STATUS="$SCRIPT_DIR/update-task-status.sh"

# Log file — human-readable agent output captured by tee
LOG_FILE="/tmp/agent-swarm-${TASK_ID}-${SESSION}.log"
# JSON sidecar — raw JSON from `claude --output-format json`, used for token parsing
CC_JSON_FILE="/tmp/agent-swarm-${TASK_ID}-${SESSION}-cc.json"
# Temp bash script executed in the tmux pane
SCRIPT_FILE="/tmp/agent-swarm-run-${TASK_ID}-${SESSION}.sh"

# ── Mark task as running ─────────────────────────────────────────────────────
# Use if-then-else to capture exit code without triggering set -e on non-zero return.
# update-task-status.sh exits 2 when task is already claimed by another agent.
if "$UPDATE_STATUS" "$TASK_ID" "running" 2>&1; then
  CLAIM_EC=0
else
  CLAIM_EC=$?
fi
if [[ "$CLAIM_EC" == "2" ]]; then
  echo "⚠️  $TASK_ID already claimed by another agent — skipping dispatch" >&2
  exit 0
fi

# Mark agent as busy in pool
"$SCRIPT_DIR/update-agent-status.sh" "$SESSION" "busy" "$TASK_ID" 2>/dev/null || true

# ── Detect CC JSON mode ──────────────────────────────────────────────────────
# Only match when the actual binary is `claude` AND the flag appears outside quoted
# strings (strip single/double-quoted substrings before grepping).
# This prevents a prompt that merely mentions "--output-format json" from misfiring.
_CMD_BIN=$(echo "$COMMAND" | awk '{print $1}' | xargs basename 2>/dev/null || true)
_CMD_FLAGS=$(echo "$COMMAND" | sed "s/'[^']*'//g" | sed 's/"[^"]*"//g')
_CC_JSON_MODE=false
if [[ "$_CMD_BIN" == "claude" ]] && echo "$_CMD_FLAGS" | grep -q -- '--output-format[[:space:]]*json'; then
  _CC_JSON_MODE=true
fi

# ── Build agent runner script ────────────────────────────────────────────────
# Written to SCRIPT_FILE and executed as `bash SCRIPT_FILE` in the tmux pane.
# Variables expand at generation time (dispatch.sh context); runtime shell vars
# are escaped with \$ so they expand later inside the generated bash script.

if [[ "$_CC_JSON_MODE" == "true" ]]; then
  # Claude Code --output-format json mode:
  #   stdout  → python3 saves full JSON to CC_JSON_FILE, prints only .result → tee LOG_FILE
  #   stderr  → goes to /dev/stderr (NOT merged into JSON stream — avoids json.loads breakage)
  #   parse-tokens.sh receives CC_JSON_FILE (has full usage stats)
  cat > "$SCRIPT_FILE" << SCRIPT
#!/bin/bash
set -uo pipefail

LOG_FILE="${LOG_FILE}"
CC_JSON_FILE="${CC_JSON_FILE}"
ON_COMPLETE="${ON_COMPLETE}"
TASK_ID="${TASK_ID}"
SESSION="${SESSION}"
WORKDIR="\$(pwd)"

# Run agent: stdout only → python intercept → tee to LOG_FILE
# stderr is NOT merged (2>&1 omitted) so CC's JSON stdout stays clean
${COMMAND} 2>/dev/null | python3 -c "
import sys, json
sidecar = sys.argv[1]
raw = sys.stdin.read()
open(sidecar, 'w').write(raw)
try:
    obj = json.loads(raw)
    print(obj.get('result') or raw)
except Exception:
    sys.stdout.write(raw)
" "\${CC_JSON_FILE}" | tee "\${LOG_FILE}"
EC=\${PIPESTATUS[0]}

# Force-commit any uncommitted changes (catches agents that forget)
FC_EC=0
if [ -n "\$(git -C "\${WORKDIR}" status --porcelain 2>/dev/null)" ]; then
  git -C "\${WORKDIR}" add -A \
    && git -C "\${WORKDIR}" commit -m "feat: ${TASK_ID} auto-commit (agent forgot)" \
    && git -C "\${WORKDIR}" push \
    || FC_EC=\$?
fi
[ "\${FC_EC}" -ne 0 ] && EC="\${FC_EC}"

"\${ON_COMPLETE}" "${TASK_ID}" "${SESSION}" "\${EC}" "\${CC_JSON_FILE}"
SCRIPT

else
  # Standard mode (Codex or CC without --output-format json):
  #   stdout + stderr piped through tee to LOG_FILE
  #   parse-tokens.sh receives LOG_FILE (scans for token patterns)
  cat > "$SCRIPT_FILE" << SCRIPT
#!/bin/bash
set -uo pipefail

LOG_FILE="${LOG_FILE}"
ON_COMPLETE="${ON_COMPLETE}"
TASK_ID="${TASK_ID}"
SESSION="${SESSION}"
WORKDIR="\$(pwd)"

# Run agent, tee output to log
${COMMAND} 2>&1 | tee "\${LOG_FILE}"
EC=\${PIPESTATUS[0]}

# Force-commit any uncommitted changes
FC_EC=0
if [ -n "\$(git -C "\${WORKDIR}" status --porcelain 2>/dev/null)" ]; then
  git -C "\${WORKDIR}" add -A \
    && git -C "\${WORKDIR}" commit -m "feat: ${TASK_ID} auto-commit (agent forgot)" \
    && git -C "\${WORKDIR}" push \
    || FC_EC=\$?
fi
[ "\${FC_EC}" -ne 0 ] && EC="\${FC_EC}"

"\${ON_COMPLETE}" "${TASK_ID}" "${SESSION}" "\${EC}" "\${LOG_FILE}"
SCRIPT

fi

chmod +x "$SCRIPT_FILE"

# ── Dispatch to tmux ─────────────────────────────────────────────────────────
# tmux pane only sees `bash /tmp/script.sh` — no quoting issues, no shell compat issues
WRAPPED="bash ${SCRIPT_FILE}"

tmux send-keys -t "$SESSION" -l -- "$WRAPPED"
tmux send-keys -t "$SESSION" Enter

# ── Background heartbeat ─────────────────────────────────────────────────────
# Keeps last_seen fresh every 5 min so health-check.sh doesn't flag us as stuck
HEARTBEAT_PID_FILE="/tmp/agent-swarm-heartbeat-${SESSION}.pid"
(
  while true; do
    sleep 300
    tmux has-session -t "$SESSION" 2>/dev/null || break
    "$SCRIPT_DIR/update-agent-status.sh" "$SESSION" "busy" "$TASK_ID" 2>/dev/null || true
  done
) >/dev/null 2>&1 &
HEARTBEAT_PID=$!
echo "$HEARTBEAT_PID" > "$HEARTBEAT_PID_FILE"
disown "$HEARTBEAT_PID"

echo "✅ Dispatched $TASK_ID to $SESSION (script: $SCRIPT_FILE, log: $LOG_FILE)"
