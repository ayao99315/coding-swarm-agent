#!/bin/bash
# dispatch.sh — Send a command to a tmux agent session with auto-completion notification
# Usage:
#   dispatch.sh <session> <task_id> <command...>
#   dispatch.sh <session> <task_id> "<legacy shell command string>"
#
# Wraps the agent command so that:
# 1. Task status is updated to "running" before execution
# 2. Agent stdout is captured to a log file for token parsing
# 3. on-complete.sh fires when command finishes (updates status + wakes main session)
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

# Support --prompt-file <file> as first argument after task_id.
# The prompt is copied to a temp file and streamed to the agent command via stdin
# so markdown/code blocks/newlines are preserved without shell-escaping issues.
# Recommended usage:
#   dispatch.sh <session> <task_id> --prompt-file /tmp/prompt.txt codex exec ...
PROMPT_FILE=""
PROMPT_TMP_FILE=""
DISPATCHED=false
cleanup_prompt_tmp() {
  if [[ "$DISPATCHED" != "true" ]] && [[ -n "${PROMPT_TMP_FILE:-}" ]] && [[ -f "$PROMPT_TMP_FILE" ]]; then
    rm -f "$PROMPT_TMP_FILE"
  fi
}
trap cleanup_prompt_tmp EXIT
if [[ "${1:-}" == "--prompt-file" ]]; then
  PROMPT_FILE="${2:?--prompt-file requires a path}"
  shift 2
fi

make_temp_file() {
  local prefix="$1"
  local tmp_base="${TMPDIR:-/tmp}"
  python3 -c '
import os
import sys
import tempfile

fd, path = tempfile.mkstemp(prefix=sys.argv[1] + ".", dir=sys.argv[2])
os.close(fd)
print(path)
' "$prefix" "${tmp_base%/}"
}

COMMAND_ARGS=()
if [[ "$#" == "1" ]]; then
  while IFS= read -r -d '' _arg; do
    COMMAND_ARGS+=("$_arg")
  done < <(
    python3 - "$1" <<'PY'
import shlex
import sys

try:
    parts = shlex.split(sys.argv[1], posix=True)
except ValueError as exc:
    print(f"dispatch.sh: failed to parse legacy command string: {exc}", file=sys.stderr)
    sys.exit(1)

for part in parts:
    sys.stdout.buffer.write(part.encode("utf-8"))
    sys.stdout.buffer.write(b"\0")
PY
  )
else
  COMMAND_ARGS=("$@")
fi

if [[ "${#COMMAND_ARGS[@]}" == "0" ]]; then
  echo "Usage: dispatch.sh <session> <task_id> [--prompt-file <file>] <command...>" >&2
  exit 1
fi

COMMAND_LITERAL="$(printf ' %q' "${COMMAND_ARGS[@]}")"
COMMAND_LITERAL="${COMMAND_LITERAL# }"

if [[ -n "$PROMPT_FILE" ]]; then
  PROMPT_TMP_FILE="$(make_temp_file "agent-swarm-prompt-${TASK_ID}-${SESSION}")"
  cat "$PROMPT_FILE" > "$PROMPT_TMP_FILE"
fi

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT_DIR="$SKILL_DIR/scripts"
ON_COMPLETE="$SCRIPT_DIR/on-complete.sh"
UPDATE_STATUS="$SCRIPT_DIR/update-task-status.sh"
VERBOSE_DISPATCH=$("$SCRIPT_DIR/swarm-config.sh" get notify.verbose_dispatch 2>/dev/null || echo "")

# Log file — human-readable agent output captured by tee
LOG_FILE="/tmp/agent-swarm-${TASK_ID}-${SESSION}.log"
# JSON sidecar — raw JSON from `claude --output-format json`, used for token parsing
CC_JSON_FILE="/tmp/agent-swarm-${TASK_ID}-${SESSION}-cc.json"
# Temp bash script executed in the tmux pane
SCRIPT_FILE="$(make_temp_file "agent-swarm-run-${TASK_ID}-${SESSION}")"

# ── Mark task as running ─────────────────────────────────────────────────────
# Use if-then-else to capture exit code without triggering set -e on non-zero return.
# update-task-status.sh exits 2 when task is already claimed by another agent.
if "$UPDATE_STATUS" "$TASK_ID" "running" "" "" "$SESSION" 2>&1; then
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

# ── Detect command mode ──────────────────────────────────────────────────────
_CMD_BIN="$(basename "${COMMAND_ARGS[0]}" 2>/dev/null || true)"
_CC_JSON_MODE=false
if [[ "$_CMD_BIN" == "claude" ]]; then
  for ((i = 1; i < ${#COMMAND_ARGS[@]}; i++)); do
    if [[ "${COMMAND_ARGS[i]}" == "--output-format=json" ]]; then
      _CC_JSON_MODE=true
      break
    fi
    if [[ "${COMMAND_ARGS[i]}" == "--output-format" ]] && (( i + 1 < ${#COMMAND_ARGS[@]} )) && [[ "${COMMAND_ARGS[i + 1]}" == "json" ]]; then
      _CC_JSON_MODE=true
      break
    fi
  done
fi

PROMPT_MODE="none"
if [[ -n "$PROMPT_TMP_FILE" ]]; then
  PROMPT_MODE="stdin"
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
PROMPT_TMP_FILE="${PROMPT_TMP_FILE}"
PROMPT_MODE="${PROMPT_MODE}"
COMMAND=( ${COMMAND_LITERAL} )

cleanup() {
  if [[ -n "\${PROMPT_TMP_FILE}" ]] && [[ -f "\${PROMPT_TMP_FILE}" ]]; then
    rm -f "\${PROMPT_TMP_FILE}"
  fi
}
trap cleanup EXIT

run_agent() {
  case "\${PROMPT_MODE}" in
    stdin)
      cat "\${PROMPT_TMP_FILE}" | "\${COMMAND[@]}"
      ;;
    *)
      "\${COMMAND[@]}"
      ;;
  esac
}

# Run agent: stdout only → python intercept → tee to LOG_FILE
# stderr is NOT merged (2>&1 omitted) so CC's JSON stdout stays clean
run_agent 2>/dev/null | python3 -c "
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
# Use git add with pathspec to exclude workspace swarm/ files (active-tasks.json etc.)
FC_EC=0
if [ -n "\$(git -C "\${WORKDIR}" status --porcelain 2>/dev/null)" ]; then
  git -C "\${WORKDIR}" add -- . ':!../../swarm/' ':!../../reports/' ':!../../memory/' \
    2>/dev/null || git -C "\${WORKDIR}" add -A
  if [ -n "\$(git -C "\${WORKDIR}" diff --cached --name-only 2>/dev/null)" ]; then
    git -C "\${WORKDIR}" commit -m "feat: ${TASK_ID} auto-commit (agent forgot)" \
      && git -C "\${WORKDIR}" push \
      || FC_EC=\$?
  fi
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
PROMPT_TMP_FILE="${PROMPT_TMP_FILE}"
PROMPT_MODE="${PROMPT_MODE}"
COMMAND=( ${COMMAND_LITERAL} )

cleanup() {
  if [[ -n "\${PROMPT_TMP_FILE}" ]] && [[ -f "\${PROMPT_TMP_FILE}" ]]; then
    rm -f "\${PROMPT_TMP_FILE}"
  fi
}
trap cleanup EXIT

run_agent() {
  case "\${PROMPT_MODE}" in
    stdin)
      cat "\${PROMPT_TMP_FILE}" | "\${COMMAND[@]}"
      ;;
    *)
      "\${COMMAND[@]}"
      ;;
  esac
}

# Run agent, tee output to log
run_agent 2>&1 | tee "\${LOG_FILE}"
EC=\${PIPESTATUS[0]}

# Force-commit any uncommitted changes (catches agents that forget)
# Use pathspec to exclude workspace swarm/ files (active-tasks.json etc.)
FC_EC=0
if [ -n "\$(git -C "\${WORKDIR}" status --porcelain 2>/dev/null)" ]; then
  git -C "\${WORKDIR}" add -- . ':!../../swarm/' ':!../../reports/' ':!../../memory/' \
    2>/dev/null || git -C "\${WORKDIR}" add -A
  if [ -n "\$(git -C "\${WORKDIR}" diff --cached --name-only 2>/dev/null)" ]; then
    git -C "\${WORKDIR}" commit -m "feat: ${TASK_ID} auto-commit (agent forgot)" \
      && git -C "\${WORKDIR}" push \
      || FC_EC=\$?
  fi
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
DISPATCHED=true

# ── Background heartbeat ─────────────────────────────────────────────────────
# Keeps task.updated_at and agent last_seen fresh every 5 min so health-check.sh doesn't flag us as stuck
HEARTBEAT_PID_FILE="/tmp/agent-swarm-heartbeat-${SESSION}.pid"
(
  while true; do
    sleep 300
    tmux has-session -t "$SESSION" 2>/dev/null || break
    "$SCRIPT_DIR/update-task-status.sh" "$TASK_ID" "running" 2>/dev/null || true
    "$SCRIPT_DIR/update-agent-status.sh" "$SESSION" "busy" "$TASK_ID" 2>/dev/null || true
  done
) >/dev/null 2>&1 &
HEARTBEAT_PID=$!
echo "$HEARTBEAT_PID" > "$HEARTBEAT_PID_FILE"
disown "$HEARTBEAT_PID"

if [[ "$VERBOSE_DISPATCH" == "false" ]]; then
  echo "🚀 $TASK_ID → $SESSION | $(date +%H:%M)"
else
  echo "✅ Dispatched $TASK_ID to $SESSION (script: $SCRIPT_FILE, log: $LOG_FILE)"
fi
