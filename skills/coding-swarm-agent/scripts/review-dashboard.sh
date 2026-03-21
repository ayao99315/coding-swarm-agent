#!/bin/bash
# review-dashboard.sh — pre-deploy review readiness checklist
# Usage:
#   review-dashboard.sh [--task-file /path/to/active-tasks.json]

set -euo pipefail

TASK_FILE="$HOME/.openclaw/workspace/swarm/active-tasks.json"

usage() {
  echo "Usage: $0 [--task-file /path/to/active-tasks.json]" >&2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-file)
      TASK_FILE="${2:?--task-file requires a path}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 1
      ;;
  esac
done

if [[ ! -f "$TASK_FILE" ]]; then
  echo "⚠️  active-tasks.json not found"
  exit 0
fi

python3 - "$TASK_FILE" <<'PYEOF'
import json
import sys

task_file = sys.argv[1]

with open(task_file) as f:
    data = json.load(f)

project = data.get("project") or "unknown-project"
batch_id = data.get("batch_id") or "unknown-batch"
all_tasks = data.get("tasks", [])


def is_review_task(task):
    agent = (task.get("agent") or "").strip()
    task_id = (task.get("id") or "").upper()
    return agent in {"cc-review", "codex-review"} or "REVIEW" in task_id


done_tasks = [task for task in all_tasks if task.get("status") == "done"]
review_tasks = [task for task in done_tasks if is_review_task(task)]
target_tasks = [task for task in done_tasks if not is_review_task(task)]

rows = []
passed_count = 0

for task in target_tasks:
    task_id = task.get("id", "UNKNOWN")
    level = task.get("review_level", "scan")

    if level in {"scan", "skip"}:
        message = "passed"
        ok = True
    elif level == "full":
        matches = [
            review_task for review_task in review_tasks
            if task_id in (review_task.get("name") or "")
        ]
        if matches:
            review_task = matches[-1]
            review_id = review_task.get("id", "REVIEW")
            commits = review_task.get("commits") or []
            if commits:
                message = f"review done ({review_id}, commit {commits[-1][:7]})"
            else:
                message = f"review done ({review_id})"
            ok = True
        else:
            message = "NO REVIEW FOUND — 需要先完成 code review 再发版"
            ok = False
    else:
        message = f"UNKNOWN REVIEW LEVEL ({level})"
        ok = False

    if ok:
        passed_count += 1
    rows.append((task_id, level, message, ok))

separator = "─────────────────────────────────────"
id_width = max((len(row[0]) for row in rows), default=0)
level_width = max((len(row[1]) for row in rows), default=0)
missing_count = len(rows) - passed_count

print(f"📊 Review Readiness — {project} [batch: {batch_id}]")
print()

for task_id, level, message, ok in rows:
    prefix = "✅ " if ok else "⚠️  "
    print(f"{prefix}{task_id.ljust(id_width)}  {level.ljust(level_width)}  {message}")

print(separator)
print()

total = len(rows)
if missing_count == 0:
    print(f"📦 结论：{passed_count}/{total} 任务 review 完成，可以发版 ✅")
elif missing_count == 1:
    print(f"📦 结论：{passed_count}/{total} 任务完成，1 个任务缺少 review ❌")
else:
    print(f"📦 结论：{passed_count}/{total} 任务完成，{missing_count} 个任务缺少 review ❌")
PYEOF
