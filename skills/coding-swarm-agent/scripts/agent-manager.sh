#!/bin/bash
# agent-manager.sh — Evaluate task queue and dynamically scale agents up/down
# Usage: agent-manager.sh [--dry-run]
#
# Called automatically by on-complete.sh after each task finishes.
# Also safe to call manually at any time.
#
# What it does:
#   1. Count pending backend tasks vs idle backend agents → spawn if needed
#   2. Count pending frontend tasks vs idle frontend agents → spawn if needed
#   3. Mark dead/finished sessions in agent pool
#   4. If all tasks done → trigger cleanup

set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

TASKS_FILE="$HOME/.openclaw/workspace/swarm/active-tasks.json"
POOL_FILE="$HOME/.openclaw/workspace/swarm/agent-pool.json"
PROJECT_DIR=$(cat "$HOME/.openclaw/workspace/swarm/project-dir" 2>/dev/null || echo "")
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NOTIFY_TARGET=$(cat "$HOME/.openclaw/workspace/swarm/notify-target" 2>/dev/null || echo "")
MANAGER_LOCK="/tmp/agent-swarm-manager.lock"
export PATH="/opt/homebrew/opt/util-linux/bin:$PATH"

exec 9>"$MANAGER_LOCK"
if ! flock -n 9; then
  echo "agent-manager: another instance running, skipping" >&2
  exit 0
fi

if [[ ! -f "$TASKS_FILE" || ! -f "$POOL_FILE" ]]; then
  echo "No active swarm. Exiting."
  exit 0
fi

next_available_session() {
  local type="$1"
  local max_count="$2"
  local name=""

  if [[ "$type" == "codex" ]]; then
    for i in $(seq 1 "$max_count"); do
      name="codex-$i"
      if ! tmux has-session -t "$name" 2>/dev/null; then
        echo "$name"
        return 0
      fi
    done
  elif [[ "$type" == "claude" ]]; then
    for i in $(seq 1 "$max_count"); do
      name="cc-frontend-$i"
      if ! tmux has-session -t "$name" 2>/dev/null; then
        echo "$name"
        return 0
      fi
    done
  fi

  return 1
}

# ── Read current state ─────────────────────────────────────────────────────
eval "$(python3 -c "
import json

tasks = json.load(open('$TASKS_FILE'))['tasks']
pool  = json.load(open('$POOL_FILE'))

pending_backend  = sum(1 for t in tasks if t['status'] == 'pending'  and t.get('domain') == 'backend')
pending_frontend = sum(1 for t in tasks if t['status'] == 'pending'  and t.get('domain') == 'frontend')
running_backend  = sum(1 for t in tasks if t['status'] == 'running'  and t.get('domain') == 'backend')
running_frontend = sum(1 for t in tasks if t['status'] == 'running'  and t.get('domain') == 'frontend')
all_done = all(t['status'] in ('done', 'failed', 'escalated') for t in tasks)

idle_backend  = sum(1 for a in pool['agents'] if a['domain'] == 'backend'  and a['status'] == 'idle')
idle_frontend = sum(1 for a in pool['agents'] if a['domain'] == 'frontend' and a['status'] == 'idle')
max_codex = pool.get('limits', {}).get('max_codex', 4)
max_cc = pool.get('limits', {}).get('max_cc_frontend', 2)

print(f'PENDING_BACKEND={pending_backend}')
print(f'PENDING_FRONTEND={pending_frontend}')
print(f'RUNNING_BACKEND={running_backend}')
print(f'RUNNING_FRONTEND={running_frontend}')
print(f'IDLE_BACKEND={idle_backend}')
print(f'IDLE_FRONTEND={idle_frontend}')
print(f'ALL_DONE={all_done}')
print(f'MAX_CODEX={max_codex}')
print(f'MAX_CC={max_cc}')
")"

echo "📊 State: backend pending=$PENDING_BACKEND running=$RUNNING_BACKEND idle=$IDLE_BACKEND | frontend pending=$PENDING_FRONTEND running=$RUNNING_FRONTEND idle=$IDLE_FRONTEND"

# ── All done → cleanup ─────────────────────────────────────────────────────
if [[ "$ALL_DONE" == "True" ]]; then
  echo "🎉 All tasks done. Triggering cleanup..."
  if [[ "$DRY_RUN" == "false" ]]; then
    "$SCRIPT_DIR/cleanup-agents.sh"
  else
    echo "[dry-run] Would run cleanup-agents.sh"
  fi
  exit 0
fi

# ── Scale up backend (Codex) ───────────────────────────────────────────────
# Spawn if: more pending tasks than idle agents AND tasks are actually queued
if [[ $PENDING_BACKEND -gt $IDLE_BACKEND && $PENDING_BACKEND -gt 0 ]]; then
  NEED=$(( PENDING_BACKEND - IDLE_BACKEND ))
  echo "⚡ Need $NEED more backend agent(s) (pending=$PENDING_BACKEND, idle=$IDLE_BACKEND)"

  for i in $(seq 1 $NEED); do
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] Would spawn codex agent ($i/$NEED)"
    else
      NEXT_SESSION=$(next_available_session codex "$MAX_CODEX" || true)
      if [[ -z "$NEXT_SESSION" ]]; then
        echo "⚠️ No available backend session slot before spawn."
        break
      fi
      if tmux has-session -t "$NEXT_SESSION" 2>/dev/null; then
        echo "⚠️ Skip backend spawn: tmux session $NEXT_SESSION already exists."
        continue
      fi
      NEW_SESSION=$("$SCRIPT_DIR/spawn-agent.sh" codex "$PROJECT_DIR" 2>&1) || {
        echo "⚠️ Could not spawn backend agent $i/$NEED: $NEW_SESSION"
        break
      }
      echo "✅ Spawned backend agent: $NEW_SESSION"
    fi
  done
fi

# ── Scale up frontend (Claude Code) ───────────────────────────────────────
if [[ $PENDING_FRONTEND -gt $IDLE_FRONTEND && $PENDING_FRONTEND -gt 0 ]]; then
  NEED=$(( PENDING_FRONTEND - IDLE_FRONTEND ))
  echo "⚡ Need $NEED more frontend agent(s) (pending=$PENDING_FRONTEND, idle=$IDLE_FRONTEND)"

  for i in $(seq 1 $NEED); do
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "[dry-run] Would spawn claude agent ($i/$NEED)"
    else
      NEXT_SESSION=$(next_available_session claude "$MAX_CC" || true)
      if [[ -z "$NEXT_SESSION" ]]; then
        echo "⚠️ No available frontend session slot before spawn."
        break
      fi
      if tmux has-session -t "$NEXT_SESSION" 2>/dev/null; then
        echo "⚠️ Skip frontend spawn: tmux session $NEXT_SESSION already exists."
        continue
      fi
      NEW_SESSION=$("$SCRIPT_DIR/spawn-agent.sh" claude "$PROJECT_DIR" 2>&1) || {
        echo "⚠️ Could not spawn frontend agent $i/$NEED: $NEW_SESSION"
        break
      }
      echo "✅ Spawned frontend agent: $NEW_SESSION"
    fi
  done
fi

echo "✅ agent-manager done."
exit 0
