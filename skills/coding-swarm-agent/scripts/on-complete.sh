#!/bin/bash
# on-complete.sh — Called after an agent command finishes
# Usage: on-complete.sh <task_id> <session_name> <exit_code> [log_file]
#
# Writes a completion signal, updates task state synchronously, then wakes the
# main OpenClaw session so it can handle review and next-task dispatch.

set -euo pipefail

TASK_ID="${1:?Usage: on-complete.sh <task_id> <session> <exit_code> [log_file]}"
SESSION="${2:?}"
EXIT_CODE="${3:-0}"
LOG_FILE="${4:-}"

SIGNAL_FILE="/tmp/agent-swarm-signals.jsonl"
SWARM_DIR="$HOME/.openclaw/workspace/swarm"
TASKS_FILE="$SWARM_DIR/active-tasks.json"
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

# Update task status immediately so any follow-up sees fresh state.
if [[ "$EXIT_CODE" == "0" ]]; then
  if STATUS_UPDATE_OUTPUT=$("$SCRIPT_DIR/update-task-status.sh" "$TASK_ID" "done" "$COMMIT_HASH" "$TOKENS_JSON" 2>&1); then
    STATUS_UPDATE_EC=0
  else
    STATUS_UPDATE_EC=$?
  fi
else
  if STATUS_UPDATE_OUTPUT=$("$SCRIPT_DIR/update-task-status.sh" "$TASK_ID" "failed" "$COMMIT_HASH" "$TOKENS_JSON" 2>&1); then
    STATUS_UPDATE_EC=0
  else
    STATUS_UPDATE_EC=$?
  fi
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
NOTIFY_TARGET=$(cat "$SWARM_DIR/notify-target" 2>/dev/null || echo "")

TASK_NAME="$TASK_ID"
if [[ -f "$TASKS_FILE" ]]; then
  TASK_NAME=$(python3 - "$TASKS_FILE" "$TASK_ID" <<'PYEOF'
import json
import sys

tasks_file, task_id = sys.argv[1], sys.argv[2]

try:
    with open(tasks_file) as f:
        data = json.load(f)
except Exception:
    print(task_id)
    raise SystemExit(0)

for task in data.get("tasks", []):
    if task.get("id") == task_id:
        print(task.get("name") or task_id)
        raise SystemExit(0)

print(task_id)
PYEOF
)
fi

openclaw system event --text "Done: $TASK_ID $TASK_NAME" --mode now 2>/dev/null || true

# ── Token milestone check ──────────────────────────────────────────────────
# Read active-tasks.json and compute cumulative swarm tokens.
# Send a warning if we just crossed a threshold (50k / 100k input tokens).
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

# ── Swarm complete check ──────────────────────────────────────────────────
# If all tasks are now done, emit one full summary for this swarm.
COMPLETE_SENT_DIR="/tmp/agent-swarm-complete"
mkdir -p "$COMPLETE_SENT_DIR"

if [[ -f "$TASKS_FILE" && -n "$NOTIFY_TARGET" ]]; then
  export COMPLETE_SENT_DIR
  COMPLETE_MSG=$(python3 - <<'PYEOF'
import hashlib
import json
import os
from pathlib import Path

tasks_file = Path(os.path.expanduser("~/.openclaw/workspace/swarm/active-tasks.json"))
sent_dir = Path(os.environ["COMPLETE_SENT_DIR"])

try:
    data = json.loads(tasks_file.read_text())
except Exception:
    print("")
    raise SystemExit(0)

tasks = data.get("tasks", [])

# Current batch = all tasks in the active file (new architecture: one file per batch)
batch_project = data.get("project") or "swarm"
batch_tasks = tasks

# Only fire swarm-complete when ALL batch tasks are done (not all tasks in file)
if not batch_tasks or any(t.get("status") != "done" for t in batch_tasks):
    print("")
    raise SystemExit(0)

fingerprint = hashlib.sha1(
    json.dumps(
        {
            "project": batch_project,
            "tasks": [
                {"id": t.get("id"), "created_at": t.get("created_at")}
                for t in batch_tasks
            ],
        },
        sort_keys=True,
        ensure_ascii=False,
    ).encode("utf-8")
).hexdigest()
sent_file = sent_dir / f"{fingerprint}.sent"
if sent_file.exists():
    print("")
    raise SystemExit(0)

sent_file.write_text(data.get("updated_at", "done"), encoding="utf-8")

total_input = sum(t.get("tokens", {}).get("input", 0) for t in batch_tasks)
total_output = sum(t.get("tokens", {}).get("output", 0) for t in batch_tasks)
total_cache_r = sum(t.get("tokens", {}).get("cache_read", 0) for t in batch_tasks)
total_cache_w = sum(t.get("tokens", {}).get("cache_write", 0) for t in batch_tasks)
project = batch_project
done_count = len(batch_tasks)
commits = []
for task in batch_tasks:
    for commit in task.get("commits", []):
        if commit and commit not in commits:
            commits.append(commit)

message = (
    f"✅ Swarm 全部完成！\n"
    f"项目: {project}\n"
    f"任务: {done_count}/{done_count} done\n"
    f"commits: {len(commits)}\n"
    f"累计 tokens:\n"
    f"  📥 input:      {total_input:,}\n"
    f"  📤 output:     {total_output:,}\n"
    f"  💾 cache_read: {total_cache_r:,}\n"
    f"  📝 cache_write:{total_cache_w:,}"
)
print(message)
PYEOF
)
  if [[ -n "$COMPLETE_MSG" ]]; then
    openclaw message send --channel telegram --target "$NOTIFY_TARGET" \
      -m "$COMPLETE_MSG" --silent 2>/dev/null &
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
