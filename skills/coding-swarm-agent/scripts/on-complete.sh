#!/bin/bash
# on-complete.sh — Called after an agent command finishes
# Usage: on-complete.sh <task_id> <session_name> <exit_code> [log_file]
#
# Writes a completion signal, updates task state synchronously, then wakes the
# main OpenClaw session so it can handle review and next-task dispatch.

set -Eeuo pipefail

TASK_ID="${1:?Usage: on-complete.sh <task_id> <session> <exit_code> [log_file]}"
SESSION="${2:?}"
EXIT_CODE="${3:-0}"
LOG_FILE="${4:-}"

SIGNAL_FILE="/tmp/agent-swarm-signals.jsonl"
SWARM_DIR="$HOME/.openclaw/workspace/swarm"
TASKS_FILE="$SWARM_DIR/active-tasks.json"
POOL_FILE="$SWARM_DIR/agent-pool.json"
POOL_LOCK="${POOL_FILE}.lock"
SWARM_COMPLETE_LOCK="/tmp/agent-swarm-manager.lock"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TS=$(date +%s)
ERROR_LOG="/tmp/on-complete-swarm-errors.log"

log_on_complete_error() {
  local detail="${1:-unknown error}"
  {
    printf '[%s] task=%s session=%s exit=%s %s\n' \
      "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
      "$TASK_ID" \
      "$SESSION" \
      "$EXIT_CODE" \
      "$detail"
  } >> "$ERROR_LOG"
}

trap 'log_on_complete_error "line=${LINENO} command=${BASH_COMMAND} ec=$?"' ERR

COMMIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo "none")
COMMIT_MSG=$(git log -1 --pretty=%s 2>/dev/null || echo "")
export PATH="/opt/homebrew/opt/util-linux/bin:$PATH"
CONTRIBUTOR_REPORT=""
if command -v git &>/dev/null && git rev-parse --git-dir &>/dev/null 2>&1; then
  if ! CONTRIBUTOR_REPORT=$(git log -1 --format="%b" 2>/dev/null | head -8 || echo ""); then
    log_on_complete_error "contributor-report capture failed"
    CONTRIBUTOR_REPORT=""
  fi
fi

# Parse token usage from agent output log (zero extra API calls — pure shell parsing)
TOKENS_JSON='{"input":0,"output":0,"cache_read":0,"cache_write":0}'
if [[ -n "$LOG_FILE" && -f "$LOG_FILE" ]]; then
  if ! TOKENS_JSON=$("$SCRIPT_DIR/parse-tokens.sh" "$LOG_FILE" 2>/dev/null || echo "$TOKENS_JSON"); then
    log_on_complete_error "token parse failed for $LOG_FILE"
    TOKENS_JSON='{"input":0,"output":0,"cache_read":0,"cache_write":0}'
  fi
fi

# Write structured signal (include tokens)
# Use python3 to build JSON — avoids broken JSONL when COMMIT_MSG contains " or \
if ! TASK_ID_ENV="$TASK_ID" \
SESSION_ENV="$SESSION" \
EXIT_CODE_ENV="$EXIT_CODE" \
COMMIT_HASH_ENV="$COMMIT_HASH" \
TS_ENV="$TS" \
python3 - "$COMMIT_MSG" "$TOKENS_JSON" >> "$SIGNAL_FILE" <<'PYEOF'
import json
import os
import sys

print(
    json.dumps(
        {
            "event": "task_done",
            "task": os.environ["TASK_ID_ENV"],
            "session": os.environ["SESSION_ENV"],
            "exit": int(os.environ["EXIT_CODE_ENV"]),
            "commit": os.environ["COMMIT_HASH_ENV"],
            "message": sys.argv[1],
            "tokens": json.loads(sys.argv[2]),
            "time": int(os.environ["TS_ENV"]),
        }
    )
)
PYEOF
then
  log_on_complete_error "signal write failed"
fi

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
if ! "$SCRIPT_DIR/update-agent-status.sh" "$SESSION" "idle" "" >/dev/null 2>>/tmp/update-agent-status-errors.log; then
  :
fi

# Refresh pool liveness and trigger cleanup once the swarm is complete.
(
  exec 9>"$SWARM_COMPLETE_LOCK"
  flock -n 9 || exit 0

  ALL_DONE=$(
    (
      flock -x 8
      TASKS_FILE="$TASKS_FILE" \
      POOL_FILE="$POOL_FILE" \
      python3 - <<'PYEOF'
import json
import os
import subprocess
from datetime import datetime, timezone

tasks_file = os.environ["TASKS_FILE"]
pool_file = os.environ["POOL_FILE"]

if os.path.exists(pool_file):
    with open(pool_file, encoding="utf-8") as f:
        pool = json.load(f)

    now = datetime.now(timezone.utc).isoformat()
    for agent in pool.get("agents", []):
        tmux_session = agent.get("tmux")
        if not tmux_session:
            continue
        alive = subprocess.run(
            ["tmux", "has-session", "-t", tmux_session], capture_output=True
        ).returncode == 0
        if alive:
            agent["last_seen"] = now
            if agent.get("status") == "dead":
                agent["status"] = "idle"
        else:
            agent["status"] = "dead"
            agent["last_seen"] = now

    pool["updated_at"] = now
    tmp = pool_file + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(pool, f, indent=2, ensure_ascii=False)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, pool_file)

if not os.path.exists(tasks_file):
    print("no")
    raise SystemExit(0)

with open(tasks_file, encoding="utf-8") as f:
    tasks = json.load(f).get("tasks", [])

print("yes" if tasks and all(t.get("status") in ("done", "failed", "escalated") for t in tasks) else "no")
PYEOF
    ) 8>"$POOL_LOCK" 2>>/tmp/on-complete-swarm-errors.log || echo "no"
  )

  if [[ "$ALL_DONE" == "yes" ]]; then
    "$SCRIPT_DIR/cleanup-agents.sh" 2>>/tmp/cleanup-agents-errors.log || true
  fi
) &

# Read config
NOTIFY_TARGET=$("$SCRIPT_DIR/swarm-config.sh" resolve notify.target 2>/dev/null || cat "$SWARM_DIR/notify-target" 2>/dev/null || echo "")

if [[ "$STATUS_UPDATE_EC" == "2" && -n "$NOTIFY_TARGET" ]]; then
  STATUS_ALERT_MSG=$(cat <<EOF
⚠️ update-task-status 未找到任务
task: $TASK_ID
session: $SESSION
exit: $EXIT_CODE

$STATUS_UPDATE_OUTPUT
EOF
)
  openclaw message send --channel telegram --target "$NOTIFY_TARGET" \
    -m "$STATUS_ALERT_MSG" --silent 2>/dev/null || true
fi

TASK_NAME="$TASK_ID"
if [[ -f "$TASKS_FILE" ]]; then
  if ! TASK_NAME=$(python3 - "$TASKS_FILE" "$TASK_ID" <<'PYEOF'
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
); then
    log_on_complete_error "task name lookup failed"
    TASK_NAME="$TASK_ID"
  fi
fi

openclaw system event --text "Done: $TASK_ID $TASK_NAME" --mode now 2>/dev/null || true

# Best-effort project retro write. Failures must never block the main flow.
if [[ "$EXIT_CODE" == "0" ]]; then
  PROJECT_SLUG=""
  if [[ -f "$TASKS_FILE" ]]; then
    PROJECT_SLUG=$(
      TASKS_FILE_ENV="$TASKS_FILE" \
      python3 - <<'PYEOF' 2>/dev/null || echo ""
import json
import os

try:
    with open(os.environ["TASKS_FILE_ENV"], encoding="utf-8") as f:
        data = json.load(f)
    repo = data.get("repo", "")
    slug = data.get("project") or (os.path.basename(repo.rstrip("/")) if repo else "")
    print(slug)
except Exception:
    pass
PYEOF
    )
  fi

  if [[ -n "$PROJECT_SLUG" ]]; then
    RETRO_DIR="$SKILL_DIR/projects/$PROJECT_SLUG"
    RETRO_FILE="$RETRO_DIR/retro.jsonl"
    CONTRIBUTOR_BODY=$(printf '%s' "$CONTRIBUTOR_REPORT" | head -5 | tr '\n' ' ' | cut -c1-200 2>/dev/null || echo "")
    DURATION_SEC=$(python3 - "$TASKS_FILE" "$TASK_ID" <<'PYEOF' 2>/dev/null || echo ""
import json
import sys
from datetime import datetime

tasks_file, task_id = sys.argv[1], sys.argv[2]

def parse_time(value):
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except Exception:
        return None

try:
    with open(tasks_file) as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)

for task in data.get("tasks", []):
    if task.get("id") != task_id:
        continue
    created_at = parse_time(task.get("created_at"))
    updated_at = parse_time(task.get("updated_at"))
    if created_at and updated_at:
        seconds = int(round((updated_at - created_at).total_seconds()))
        if seconds >= 0:
            print(seconds)
    raise SystemExit(0)
PYEOF
)

    {
      mkdir -p "$RETRO_DIR" 2>/dev/null || true
      python3 - "$RETRO_FILE" "$TASK_ID" "$TASK_NAME" "$COMMIT_HASH" "$DURATION_SEC" "$CONTRIBUTOR_BODY" <<'PYEOF'
import datetime
import json
import sys

retro_file, task_id, task_name, commit_hash, duration_sec, contributor_body = sys.argv[1:7]

entry = {
    "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
    "task_id": task_id,
    "task_name": task_name,
    "commit": commit_hash,
    "result": "done",
    "contributor_report": contributor_body,
}

if duration_sec.strip():
    try:
        entry["duration_sec"] = int(duration_sec)
    except Exception:
        pass

with open(retro_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(entry, ensure_ascii=False) + "\n")
PYEOF
    } >/dev/null 2>&1 || true
  fi
fi

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
if ! mkdir -p "$COMPLETE_SENT_DIR"; then
  log_on_complete_error "mkdir failed for $COMPLETE_SENT_DIR"
fi

if [[ -f "$TASKS_FILE" && -n "$NOTIFY_TARGET" ]]; then
  export COMPLETE_SENT_DIR
  COMPLETE_MSG_ERR=$(mktemp /tmp/on-complete-msg.XXXXXX)
  if ! COMPLETE_MSG=$(python3 - <<'PYEOF' 2>"$COMPLETE_MSG_ERR"
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from datetime import datetime

tasks_file = Path(os.path.expanduser("~/.openclaw/workspace/swarm/active-tasks.json"))
sent_dir = Path(os.environ["COMPLETE_SENT_DIR"])


def parse_time(value):
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except Exception:
        return None


def format_k(value):
    value = int(value or 0)
    if value < 1000:
        return str(value)
    if value < 100000:
        short = f"{value / 1000:.1f}k"
        return short.replace(".0k", "k")
    return f"{int(round(value / 1000.0))}k"


def format_batch_duration(seconds):
    if seconds is None or seconds < 0:
        return ""
    seconds = int(round(seconds))
    if seconds < 60:
        return "<1 分钟"
    minutes = max(1, round(seconds / 60))
    return f"约 {minutes} 分钟"


def format_task_duration(seconds):
    if seconds is None or seconds < 0:
        return ""
    seconds = int(round(seconds))
    if seconds < 60:
        return "<1 分钟"
    minutes, _ = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        if minutes:
            return f"{hours}h {minutes}m"
        return f"{hours}h"
    return f"{minutes} 分钟"


def shorten_text(text, limit):
    text = " ".join((text or "").split())
    if len(text) <= limit:
        return text
    return text[: max(0, limit - 3)].rstrip() + "..."


def task_status_emoji(status):
    if status == "done":
        return "✅"
    if status == "failed":
        return "❌"
    return "⏳"


commit_subject_cache = {}


def resolve_commit_summary(commit):
    commit_hash = ""
    commit_subject = ""

    if isinstance(commit, dict):
        commit_hash = str(commit.get("hash") or commit.get("id") or "").strip()
        commit_subject = str(commit.get("message") or commit.get("name") or "").strip()
    elif isinstance(commit, str):
        commit_hash = commit.strip()

    if not commit_hash:
        return "", ""

    short_hash = commit_hash[:7]
    if commit_subject:
        return short_hash, shorten_text(commit_subject, 60)

    cached = commit_subject_cache.get(commit_hash)
    if cached is None:
        try:
            result = subprocess.run(
                ["git", "log", "-1", "--format=%s", commit_hash],
                capture_output=True,
                check=True,
                text=True,
            )
            cached = (result.stdout or "").strip()
        except Exception:
            cached = ""
        commit_subject_cache[commit_hash] = cached

    return short_hash, shorten_text(cached, 60)

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

total_input = sum(t.get("tokens", {}).get("input", 0) for t in batch_tasks)
total_output = sum(t.get("tokens", {}).get("output", 0) for t in batch_tasks)
total_cache_r = sum(t.get("tokens", {}).get("cache_read", 0) for t in batch_tasks)
project = batch_project
done_count = len(batch_tasks)
commits = []
for task in batch_tasks:
    for commit in task.get("commits", []):
        if commit and commit not in commits:
            commits.append(commit)

created_times = [parse_time(t.get("created_at")) for t in batch_tasks]
updated_times = [parse_time(t.get("updated_at")) for t in batch_tasks]
created_times = [t for t in created_times if t is not None]
updated_times = [t for t in updated_times if t is not None]

lines = [
    f"🎉 Swarm 完成 — {project}",
    f"✅ {done_count}/{done_count} 任务全部 done",
    f"📦 共 {len(commits)} commits",
]

if total_input or total_output or total_cache_r:
    token_line = f"📊 总 tokens: {format_k(total_input)} in / {format_k(total_output)} out"
    if total_cache_r:
        token_line += f" (+{format_k(total_cache_r)} cache)"
    lines.append(token_line)

duration_sec = None
if len(updated_times) >= 2:
    duration_sec = (max(updated_times) - min(updated_times)).total_seconds()
elif len(updated_times) == 1 and len(created_times) == 1:
    duration_sec = (updated_times[0] - created_times[0]).total_seconds()
    if duration_sec > 6 * 3600:
        duration_sec = None

if duration_sec is not None:
    duration_text = format_batch_duration(duration_sec)
    if duration_text:
        lines.append(f"⏱️ 批次用时: {duration_text}")

try:
    task_lines = []
    for task in batch_tasks:
        task_id = (task.get("id") or "?").strip() or "?"
        task_name = (task.get("name") or "").strip() or task_id
        detail_parts = []

        tokens = task.get("tokens", {}) or {}
        input_tokens = int(tokens.get("input", 0) or 0)
        output_tokens = int(tokens.get("output", 0) or 0)
        if input_tokens > 0:
            detail_parts.append(f"{format_k(input_tokens + output_tokens)} tokens")

        task_created_at = parse_time(task.get("created_at"))
        task_updated_at = parse_time(task.get("updated_at"))
        if task_created_at and task_updated_at:
            task_duration_sec = (task_updated_at - task_created_at).total_seconds()
            if 0 <= task_duration_sec < 6 * 3600:
                task_duration_text = format_task_duration(task_duration_sec)
                if task_duration_text:
                    detail_parts.append(task_duration_text)

        task_line = f"{task_id} {task_status_emoji(task.get('status'))} {task_name}"
        if detail_parts:
            task_line += f" ({', '.join(detail_parts)})"
        task_lines.append(task_line)

        task_commits = task.get("commits") or []
        if task_commits:
            short_hash, commit_subject = resolve_commit_summary(task_commits[0])
            if short_hash and commit_subject:
                task_lines.append(f"  └ commit: {short_hash} {commit_subject}")
            elif short_hash:
                task_lines.append(f"  └ commit: {short_hash}")
            else:
                task_lines.append("  └ No commit recorded")
        else:
            task_lines.append("  └ No commit recorded")

    if task_lines:
        lines.append("─────────────────────")
        lines.extend(task_lines)
except Exception as exc:
    print(f"per-task summary build failed: {exc}", file=sys.stderr)

sent_file.write_text(data.get("updated_at", "done"), encoding="utf-8")
print("\n".join(lines))
PYEOF
); then
    log_on_complete_error "swarm complete message build failed"
    COMPLETE_MSG=""
  elif [[ -s "$COMPLETE_MSG_ERR" ]]; then
    log_on_complete_error "$(head -n 1 "$COMPLETE_MSG_ERR")"
  fi
  rm -f "$COMPLETE_MSG_ERR"
  if [[ -n "$COMPLETE_MSG" ]]; then
    openclaw message send --channel telegram --target "$NOTIFY_TARGET" \
      -m "$COMPLETE_MSG" --silent 2>/dev/null &
  fi
fi

# ── Per-task notification (with token breakdown) ───────────────────────────
if [[ -n "$NOTIFY_TARGET" ]]; then
  STATUS_EMOJI="✅"
  STATUS_WORD="完成"
  if [[ "$EXIT_CODE" != "0" ]]; then
    STATUS_EMOJI="❌"
    STATUS_WORD="失败"
  fi

  TASK_NOTIFY_MSG=""
  if [[ -f "$TASKS_FILE" ]]; then
    if ! TASK_NOTIFY_MSG=$(python3 - "$TASKS_FILE" "$TASK_ID" "$EXIT_CODE" "$SESSION" <<'PYEOF'
import json
import sys
from datetime import datetime

tasks_file, task_id, exit_code, session = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]


def parse_time(value):
    if not value:
        return None
    try:
        if value.endswith("Z"):
            value = value[:-1] + "+00:00"
        return datetime.fromisoformat(value)
    except Exception:
        return None


def format_k(value):
    value = int(value or 0)
    if value < 1000:
        return str(value)
    if value < 100000:
        short = f"{value / 1000:.1f}k"
        return short.replace(".0k", "k")
    return f"{int(round(value / 1000.0))}k"


def format_duration(seconds):
    if seconds is None or seconds < 0:
        return ""
    seconds = int(round(seconds))
    minutes, secs = divmod(seconds, 60)
    hours, minutes = divmod(minutes, 60)
    if hours:
        return f"{hours}h {minutes}m {secs:02d}s"
    if minutes:
        return f"{minutes}m {secs:02d}s"
    return f"{secs}s"


try:
    with open(tasks_file) as f:
        data = json.load(f)
except Exception:
    print("")
    raise SystemExit(0)

tasks = data.get("tasks", [])
task = next((item for item in tasks if item.get("id") == task_id), None)
if not task:
    print("")
    raise SystemExit(0)

project = data.get("project") or "swarm"
status_emoji = "✅" if exit_code == 0 else "❌"
status_word = "完成" if exit_code == 0 else "失败"
lines = [f"{status_emoji} {task_id} {status_word} — {project}"]

name = (task.get("name") or "").strip()
if name:
    lines.append(f"📝 {name}")

tokens = task.get("tokens", {}) or {}
input_tokens = int(tokens.get("input", 0) or 0)
output_tokens = int(tokens.get("output", 0) or 0)
cache_read = int(tokens.get("cache_read", 0) or 0)

created_at = parse_time(task.get("created_at"))
updated_at = parse_time(task.get("updated_at"))
duration_text = ""
if created_at and updated_at:
    duration_text = format_duration((updated_at - created_at).total_seconds())

if input_tokens or output_tokens or cache_read:
    token_line = f"📊 Tokens: {format_k(input_tokens)} in / {format_k(output_tokens)} out"
    if cache_read:
        token_line += f" (+{format_k(cache_read)} cache)"
    if duration_text:
        token_line += f"  ⏱️ 用时: {duration_text}"
    lines.append(token_line)
elif duration_text:
    lines.append(f"⏱️ 用时: {duration_text}")

if exit_code == 0:
    next_tasks = [
        item.get("id")
        for item in tasks
        if task_id in (item.get("depends_on") or []) and item.get("id")
    ]
    if next_tasks:
        lines.append(f"⬇️ 下一步：{'、'.join(next_tasks)} 条件满足后将解锁")
else:
    attempts = task.get("attempts")
    max_attempts = task.get("max_attempts")
    tmux_name = (task.get("tmux") or session or "").strip()

    if attempts is not None and max_attempts is not None:
        retry_text = f"attempt {attempts}/{max_attempts}"
    elif attempts is not None:
        retry_text = f"attempt {attempts}"
    else:
        retry_text = ""

    if tmux_name and retry_text:
        lines.append(f"🔄 {retry_text}，请检查 tmux capture-pane -t {tmux_name} -p")
    elif tmux_name:
        lines.append(f"🔄 请检查 tmux capture-pane -t {tmux_name} -p")
    elif retry_text:
        lines.append(f"🔄 {retry_text}")

print("\n".join(lines))
PYEOF
); then
      log_on_complete_error "task notification message build failed"
      TASK_NOTIFY_MSG=""
    fi
  fi

  if [[ -z "$TASK_NOTIFY_MSG" ]]; then
    TASK_NOTIFY_MSG="${STATUS_EMOJI} ${TASK_ID} ${STATUS_WORD}"
  fi

  if [[ -n "$CONTRIBUTOR_REPORT" ]]; then
    TASK_NOTIFY_MSG="${TASK_NOTIFY_MSG}

📝 Field Report:
${CONTRIBUTOR_REPORT:0:300}"
  fi

  openclaw message send --channel telegram --target "$NOTIFY_TARGET" \
    -m "$TASK_NOTIFY_MSG" \
    --silent 2>/dev/null &
fi

exit 0
