#!/bin/bash
# on-complete.sh — Called after an agent command finishes
# Usage: on-complete.sh <task_id> <session_name> <exit_code> [log_file]
#
# Writes a completion signal and triggers an isolated agent turn via webhook
# to handle review, status update, and next task dispatch automatically.

set -euo pipefail

TASK_ID="${1:?Usage: on-complete.sh <task_id> <session> <exit_code> [log_file]}"
SESSION="${2:?}"
EXIT_CODE="${3:-0}"
LOG_FILE="${4:-}"

SIGNAL_FILE="/tmp/agent-swarm-signals.jsonl"
SWARM_DIR="$HOME/.openclaw/workspace/swarm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TS=$(date +%s)
COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "none")
COMMIT_MSG=$(git log -1 --pretty=%s 2>/dev/null || echo "")

# Parse token usage from agent output log (zero extra API calls — pure shell parsing)
TOKENS_JSON='{"input":0,"output":0,"cache_read":0,"cache_write":0}'
if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
  TOKENS_JSON=$("$SCRIPT_DIR/parse-tokens.sh" "$LOG_FILE" 2>/dev/null || echo "$TOKENS_JSON")
fi

# Write structured signal (include tokens)
# Use python3 to build JSON — avoids broken JSONL when COMMIT_MSG contains " or \
python3 -c "
import json, sys
print(json.dumps({
  'event': 'task_done',
  'task': '$TASK_ID',
  'session': '$SESSION',
  'exit': $EXIT_CODE,
  'commit': '$COMMIT_HASH',
  'message': sys.argv[1],
  'tokens': json.loads(sys.argv[2]),
  'time': $TS
}))" "$COMMIT_MSG" "$TOKENS_JSON" >> "$SIGNAL_FILE"

# Update task status BEFORE webhook (so agent sees fresh state)
if [[ "$EXIT_CODE" == "0" ]]; then
  "$SCRIPT_DIR/update-task-status.sh" "$TASK_ID" "done" "$COMMIT_HASH" "$TOKENS_JSON" 2>&1 || true
else
  "$SCRIPT_DIR/update-task-status.sh" "$TASK_ID" "failed" "$COMMIT_HASH" "$TOKENS_JSON" 2>&1 || true
fi

# Kill dispatch heartbeat for this session (was keeping last_seen alive)
HEARTBEAT_PID_FILE="/tmp/agent-swarm-heartbeat-${SESSION}.pid"
if [[ -f "$HEARTBEAT_PID_FILE" ]]; then
  HB_PID=$(cat "$HEARTBEAT_PID_FILE" 2>/dev/null || true)
  [[ -n "$HB_PID" ]] && kill "$HB_PID" 2>/dev/null || true
  rm -f "$HEARTBEAT_PID_FILE"
fi

# Mark agent as idle in pool
"$SCRIPT_DIR/update-agent-status.sh" "$SESSION" "idle" "" 2>/dev/null &

# Dynamic agent management: scale up/down based on task queue
"$SCRIPT_DIR/agent-manager.sh" 2>/dev/null &

# Read config
HOOK_TOKEN=$(cat "$SWARM_DIR/hook-token" 2>/dev/null || echo "")
NOTIFY_TARGET=$(cat "$SWARM_DIR/notify-target" 2>/dev/null || echo "")
GATEWAY_URL="http://127.0.0.1:18789"

# ── Idempotency guard ──────────────────────────────────────────────────────
# Deduplicate webhook triggers within a 30-second window.
# Prevents double-dispatch from network retries or rapid re-invocations.
# Key = task_id + timestamp bucket (30s granularity).
IDEM_DIR="/tmp/agent-swarm-idem"
mkdir -p "$IDEM_DIR"
IDEM_BUCKET=$(( TS / 30 ))
IDEM_KEY="${TASK_ID}-${IDEM_BUCKET}"
IDEM_FILE="${IDEM_DIR}/${IDEM_KEY}"
if [[ -f "$IDEM_FILE" ]]; then
  echo "⚠️  Webhook already fired for $TASK_ID in this window (idem key: $IDEM_KEY) — skipping" >&2
  exit 0
fi
touch "$IDEM_FILE"
# Auto-clean keys older than 5 minutes to avoid stale file accumulation
find "$IDEM_DIR" -maxdepth 1 -name "T*" -mmin +5 -delete 2>/dev/null &

# Primary: trigger isolated agent turn via /hooks/agent
# This agent will: check scope, apply review_level, update tasks, dispatch next
if [[ -n "$HOOK_TOKEN" ]]; then
  AGENT_MSG="Swarm 任务完成信号：
- task: $TASK_ID
- agent: $SESSION
- exit_code: $EXIT_CODE
- commit: $COMMIT_HASH
- commit_msg: $COMMIT_MSG

active-tasks.json 已由脚本自动更新（状态已标记，依赖已解锁）。

请执行以下步骤：
1. 读取 ~/.openclaw/workspace/swarm/active-tasks.json 查看当前状态
2. 验证 commit scope（git diff $COMMIT_HASH~1 $COMMIT_HASH --stat）
3. 根据该任务的 review_level 处理：
   - skip/scan: 确认 scope 合理即可
   - full: 派 cross-review agent（cc-review 或 codex-review）到对应 tmux session
4. 找到所有 status=pending 的任务，按依赖顺序 dispatch 到空闲 agent
5. 如果全部任务 done，发送汇总通知"

  # Escape for JSON
  AGENT_MSG_JSON=$(echo "$AGENT_MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

  curl -s -X POST "$GATEWAY_URL/hooks/agent" \
    -H "Authorization: Bearer $HOOK_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{
      \"message\": $AGENT_MSG_JSON,
      \"name\": \"swarm-dispatch\",
      \"sessionKey\": \"hook:swarm:dispatch\",
      \"deliver\": true,
      \"channel\": \"telegram\",
      \"to\": \"$NOTIFY_TARGET\",
      \"model\": \"anthropic/claude-sonnet-4-20250514\",
      \"thinking\": \"low\",
      \"timeoutSeconds\": 120
    }" >/dev/null 2>&1 &
fi

# ── Token milestone check ──────────────────────────────────────────────────
# Read active-tasks.json and compute cumulative swarm tokens.
# Send a warning if we just crossed a threshold (50k / 100k input tokens).
TASKS_FILE="$HOME/.openclaw/workspace/swarm/active-tasks.json"
TOKEN_WARNING_FILE="/tmp/agent-swarm-token-warned.json"

if [[ -f "$TASKS_FILE" && -n "$NOTIFY_TARGET" ]]; then
  export NOTIFY_TARGET
  if python3 - <<'PYEOF'
import json, os, sys

tasks_file = os.path.expanduser("~/.openclaw/workspace/swarm/active-tasks.json")
warned_file = "/tmp/agent-swarm-token-warned.json"
notify_target = os.environ.get("NOTIFY_TARGET", "")

thresholds = [50000, 100000, 200000]  # input token milestones

with open(tasks_file) as f:
    data = json.load(f)

total_input  = sum(t.get("tokens", {}).get("input",  0) for t in data.get("tasks", []))
total_output = sum(t.get("tokens", {}).get("output", 0) for t in data.get("tasks", []))
total_cache_r = sum(t.get("tokens", {}).get("cache_read",  0) for t in data.get("tasks", []))

# Load already-warned thresholds
warned = set()
if os.path.exists(warned_file):
    try:
        warned = set(json.load(open(warned_file)))
    except Exception:
        pass

# Check which thresholds we just crossed
new_warnings = []
for th in thresholds:
    if total_input >= th and th not in warned:
        new_warnings.append(th)
        warned.add(th)

if new_warnings:
    with open(warned_file, "w") as f:
        json.dump(list(warned), f)
    th_str = "/".join(str(t) for t in new_warnings)
    msg = (
        f"⚠️ Token 里程碑 {th_str} 达到！\n"
        f"本次 swarm 累计：\n"
        f"  input:      {total_input:,}\n"
        f"  output:     {total_output:,}\n"
        f"  cache_read: {total_cache_r:,}"
    )
    print(msg)
    sys.exit(1)  # signal: send warning

sys.exit(0)
PYEOF
  then
    MILESTONE_EXIT=0
  else
    MILESTONE_EXIT=$?
  fi
  if [[ "$MILESTONE_EXIT" == "1" ]]; then
    MILESTONE_MSG=$(python3 - <<'PYEOF'
import json, os

tasks_file = os.path.expanduser("~/.openclaw/workspace/swarm/active-tasks.json")
warned_file = "/tmp/agent-swarm-token-warned.json"
thresholds = [50000, 100000, 200000]

with open(tasks_file) as f:
    data = json.load(f)

total_input   = sum(t.get("tokens", {}).get("input",  0) for t in data.get("tasks", []))
total_output  = sum(t.get("tokens", {}).get("output", 0) for t in data.get("tasks", []))
total_cache_r = sum(t.get("tokens", {}).get("cache_read",  0) for t in data.get("tasks", []))

warned = set()
if os.path.exists(warned_file):
    try:
        warned = set(json.load(open(warned_file)))
    except Exception:
        pass

crossed = [th for th in thresholds if total_input >= th]
th_str = f"{max(crossed):,}" if crossed else "?"

print(
    f"⚠️ Swarm token 里程碑 {th_str} input tokens！\n"
    f"累计消耗：\n"
    f"  📥 input:      {total_input:,}\n"
    f"  📤 output:     {total_output:,}\n"
    f"  💾 cache_read: {total_cache_r:,}"
)
PYEOF
)
    openclaw message send --channel telegram --target "$NOTIFY_TARGET" \
      -m "$MILESTONE_MSG" --silent 2>/dev/null &
  fi
fi

# ── Per-task notification (with token breakdown) ───────────────────────────
if [[ -n "$NOTIFY_TARGET" ]]; then
  # Extract token numbers from TOKENS_JSON for the message
  TOKEN_DISPLAY=$(python3 -c "
import json, sys
try:
    t = json.loads('$TOKENS_JSON')
    inp = t.get('input', 0)
    out = t.get('output', 0)
    cr  = t.get('cache_read', 0)
    if inp or out:
        parts = [f'in={inp:,}', f'out={out:,}']
        if cr:
            parts.append(f'cache_r={cr:,}')
        print(' | tokens: ' + ', '.join(parts))
    else:
        print('')
except Exception:
    print('')
" 2>/dev/null)

  STATUS_EMOJI="✅"
  [[ "$EXIT_CODE" != "0" ]] && STATUS_EMOJI="❌"

  openclaw message send --channel telegram --target "$NOTIFY_TARGET" \
    -m "${STATUS_EMOJI} ${TASK_ID} 完成 (exit=${EXIT_CODE}) — ${COMMIT_HASH}${TOKEN_DISPLAY}" \
    --silent 2>/dev/null &
fi

exit 0
