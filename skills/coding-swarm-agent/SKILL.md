---
name: coding-swarm-agent
description: "Orchestrate multi-agent coding workflows using tmux-driven Claude Code and Codex agents. Use when: (1) user requests a feature/fix that should be delegated to coding agents, (2) managing parallel coding tasks across front-end and back-end, (3) monitoring active agent sessions and coordinating review, (4) user says 'start task', 'assign to agents', 'swarm mode', or references the coding-swarm-agent playbook. NOT for: simple one-liner edits (just edit directly), reading code (use read tool), or single quick questions about code."
---

# Agent Swarm Orchestrator

Coordinate multiple coding agents (Claude Code + Codex) via tmux sessions on a single machine. You are the orchestrator — you decompose tasks, write prompts, dispatch to agents, monitor progress, coordinate cross-review, and report results.

## Architecture

```
You (OpenClaw) = orchestrator
  ├→ cc-plan       (Claude Code)  — decompose requirements into atomic tasks
  ├→ codex-1       (Codex CLI)    — backend coding
  ├→ cc-frontend   (Claude Code)  — frontend coding (ALL frontend work)
  ├→ cc-review     (Claude Code)  — review Codex output
  └→ codex-review  (Codex CLI)    — review Claude Code output
```

5 base agents. Expand coding agents for complex projects (codex-2, cc-frontend-2, etc.). Review and plan agents stay fixed.

## Core Rules

1. **Main branch only.** No worktrees, no PRs. Atomic commits are the safety net.
2. **Conventional Commits.** `feat|fix|refactor|docs|test|chore(scope): description`
3. **Every commit pushes immediately.** `git add -A && git commit -m "..." && git push`
4. **You decompose tasks, not the agent.** Each prompt has explicit scope + file boundaries.
5. **Cross-review.** Codex output → cc-review. CC output → codex-review.
6. **File-isolation parallelism.** Different agents may run concurrently only if their file scopes don't overlap.
7. **⚠️ ALWAYS use dispatch.sh — never exec directly.** Any time you run Codex or Claude Code within a swarm project (active-tasks.json exists or task is swarm-related), dispatch via `dispatch.sh`. Never use the `exec` tool or `coding-agent` skill pattern directly. Reason: dispatch.sh is the only path that guarantees on-complete.sh fires → status updated → webhook triggered → you get notified. Direct exec = silent failure, no notification, no status tracking.
8. **⚠️ ORCHESTRATOR NEVER TOUCHES PROJECT FILES — NO EXCEPTIONS.**
   You are a pure orchestrator and auditor. Your role: understand requirements, write prompts, dispatch to agents, review agent output, coordinate next steps, notify human. Nothing else.
   
   NEVER use edit / write / exec tools to modify anything inside the project directory. This includes:
   - Source code (.ts, .tsx, .js, .py, etc.)
   - Config files (next.config.ts, package.json, tsconfig.json, .env*, nginx.conf, plist files)
   - Scripts, docs, or any other file inside the project repo
   
   The ONLY files you may write directly:
   - `~/.openclaw/workspace/swarm/*` (task registry, agent pool, config)
   - `~/.openclaw/workspace/docs/*` (playbook, design docs outside the project repo)
   - `~/.openclaw/workspace/skills/*` (skill definitions)
   - `~/.openclaw/workspace/memory/*` (your own memory files)
   
   **Task size is NOT a criterion.** Even a 1-line fix goes through cc-plan + codex. The question is always: "Does this touch the project directory?" → YES → dispatch to agent. Always.

## Role Definition

```
You (orchestrator) = auditor + dispatcher, independent from the codebase

✅ Your job:
  - Understand requirements, decompose into atomic tasks
  - Write precise prompts for cc-plan / codex / cc-frontend
  - Dispatch all work via dispatch.sh
  - Review agent output (read git diff, check scope, assess quality)
  - Coordinate reviews, unblock dependencies, dispatch next tasks
  - Notify human of progress, issues, completions
  - Maintain swarm config files (active-tasks.json, agent-pool.json)

❌ Never:
  - Edit, write, or create files inside the project directory
  - Run build / test / deploy commands on the project
  - "Save time" by doing small tasks yourself
  - Use exec tool to run code in the project repo
```

## New Module / Standalone Feature Flow

When a new module or standalone feature is requested (e.g., backtest, new microservice):

```
1. cc-plan → outputs plan document (written to docs/<feature>-plan.md in project repo)
             → outputs task list (registered in active-tasks.json)
2. codex   → creates new directory + implements per plan
3. You     → review plan document + code output (read-only)
             → never touch the new directory yourself
```

## Workflow

### Phase 1: Plan

Send requirement to cc-plan. Read `references/prompt-cc-plan.md` for the template.

Output: structured task list with id, scope, files, dependencies.

### Phase 2: Register Tasks

Write tasks to `~/.openclaw/workspace/swarm/active-tasks.json`. See `references/task-schema.md`.

### Phase 3: Setup (once per project)

Install git hooks for event-driven automation:
```bash
~/.openclaw/workspace/skills/coding-swarm-agent/scripts/install-hooks.sh /path/to/project
```

This installs a `post-commit` hook that:
- Detects commits during active swarm operations
- Auto-pushes the commit
- Writes a signal to `/tmp/agent-swarm-signals.jsonl`
- Wakes the orchestrator via `openclaw system event --mode now`

### ⚠️ 任务注册铁律（所有任务，无例外）

**每次 dispatch 前，必须先把任务写入 `active-tasks.json`。** 包括：
- 临时 hotfix（FIX-xxx）
- 部署任务（DEPLOY-xxx）
- 一次性脚本任务

跳过注册 = dispatch.sh 警告 "task not found" = on-complete.sh 状态更新失效 = 丢失追踪。

哪怕是一行的 fix，也要先：
```bash
# 在 active-tasks.json 的 tasks 数组里加一条，再 dispatch
```

### Phase 4: Dispatch

For each ready task (status=pending, dependencies met):
- Pick agent based on domain (backend→codex, frontend→cc-frontend)
- Generate prompt from template (`references/prompt-codex.md` or `references/prompt-cc-frontend.md`)
  **Prompt quality rules:**
  - Reference actual code files (e.g. "参考 `src/persistence/db.ts` 的 getPool() 模式"), never describe tech stack in words
  - Pre-write the exact `git commit -m "..."` command, don't let agent choose
  - List specific file paths in scope, not directory names
  - In "Do NOT" section, list files likely to be accidentally modified
- Dispatch using the wrapper script (auto: marks running + attaches completion callback + force-commits if agent forgets):
  ```bash
  scripts/dispatch.sh <session> <task_id> "<agent_command>"
  ```
  dispatch.sh automatically:
  1. Updates active-tasks.json status to `running`
  2. Appends a force-commit check after agent finishes (catches forgotten commits)
  3. Calls on-complete.sh which updates status to `done`/`failed` + triggers webhook agent

**Parallel dispatch:** OK if file scopes don't overlap. Check before dispatching.

### Phase 5: Event-Driven Monitor

**Primary (instant — webhook-driven):**

1. **post-commit hook** — fires on every git commit. Writes signal + auto-pushes.
2. **on-complete.sh** — fires when agent command finishes. Does three things:
   a. `update-task-status.sh` — atomically updates active-tasks.json (status + commit + auto-unblock dependents)
   b. `POST /hooks/agent` — triggers an **isolated agent turn** via OpenClaw webhook. This agent reads fresh active-tasks.json, verifies scope, handles review_level, and dispatches next pending tasks.
   c. `openclaw message send` — backup Telegram notification to human.

The webhook agent runs on a lightweight model (sonnet) with `sessionKey: "hook:swarm:dispatch"` for multi-turn context.

**Fallback (heartbeat):** HEARTBEAT.md checks the signal file periodically as a safety net.

When checking manually, read the signal file:
```bash
tail -5 /tmp/agent-swarm-signals.jsonl
```

Then for the relevant agent:
```bash
tmux capture-pane -t <session> -p | tail -30
```

Assess status:
- **task_done + exit 0** → proceed to Verify Commit
- **task_done + exit != 0** → check output, adjust prompt, retry
- **waiting_input** → read context, answer or escalate to human
- **dead** → recreate session, redispatch

### Phase 6: Verify Commit

After agent finishes:
```bash
git diff HEAD~1 --stat  # check file scope matches task
git log --oneline -1     # check commit message format
```

If files outside scope were modified → `git revert HEAD` and redispatch with tighter prompt.

### Phase 7: Post-Completion Verification

Each task has a `review_level` field (see `references/task-schema.md`):

**`full` 🔴 (core logic / financial / security):**
1. Verify commit scope (`git diff HEAD~1 --stat`)
2. Dispatch cross-review agent using dispatch.sh. Read `references/prompt-cc-review.md` for template.
3. Pass criteria: No Critical or High issues.
   - Pass → mark task `done`
   - Fail → return review to original agent (max 3 rounds)
   - 3 rounds fail → switch to alternate agent (max 2 more attempts)
   - Still fail → escalate to human

**`scan` 🟡 (integration / persistence):**
1. Verify commit scope
2. Orchestrator reads `git diff HEAD~1` and checks key functions/types
3. Obvious bugs or scope violations → return to agent with feedback
4. Looks reasonable → mark `done`

**`skip` 🟢 (UI / scripts / low-risk):**
1. Verify commit scope only (`git diff HEAD~1 --stat`)
2. Files match expected scope → mark `done`
3. Scope violation → revert and redispatch

### Phase 8: Next Task (auto)

When a task is marked `done`:
1. Scan all `blocked` tasks — if all `depends_on` are `done`, flip to `pending`
2. Auto-dispatch the next `pending` task(s) using dispatch.sh
3. If parallel-safe (no file overlap), dispatch multiple simultaneously

When all tasks done → notify human via Telegram:
```bash
openclaw message send --channel telegram --target <chat_id> -m "✅ All swarm tasks complete!"
```

### Full Auto-Loop

The complete event-driven cycle:
```
Dispatch task → Agent works → Agent commits → post-commit hook fires
→ Orchestrator wakes → Verify commit scope → Dispatch cross-review
→ Review agent finishes → on-complete.sh fires → Orchestrator wakes
→ Check review result → Pass: mark done, unblock & dispatch next
                       → Fail: return to original agent with feedback
→ All tasks done → Notify human
```

No polling. No manual check-ins. Human only intervenes on escalations.

## Dispatch Notification Format

Every time an agent is dispatched (via dispatch.sh or coding-agent), report a **Dispatch Card** to the user.

### Verbose Mode (default: ON)

Check `~/.openclaw/workspace/swarm/config.json` → `"verbose_dispatch": true/false` (defaults to `true` if missing).

**Verbose Card (verbose_dispatch = true):**
```
🚀 已派发 [TASK_ID] → [SESSION]
┣ 📋 Session:  [tmux session 名 / background session id]
┣ ⏰ 启动时间: [HH:MM:SS]
┣ 🤖 模型:    [模型全名] ([级别/reasoning effort])
┗ 📝 任务:    [一句话任务描述]
```

示例：
```
🚀 已派发 T001 → codex-1
┣ 📋 Session:  tmux: codex-1
┣ ⏰ 启动时间: 10:35:42
┣ 🤖 模型:    gpt-5.4 (reasoning: high)
┗ 📝 任务:    修复 sports-ws ping heartbeat，使服务器正常推送比赛数据
```

**Compact Card (verbose_dispatch = false):**
```
🚀 [TASK_ID] → [SESSION] | [模型]/[级别] | [HH:MM]
```

示例：
```
🚀 T001 → codex-1 | gpt-5.4/high | 10:35
```

### 非 Swarm 场景（单 agent，coding-agent skill）

即使不经过 dispatch.sh，凡是 spawn coding agent 的操作，也必须汇报同格式的 Dispatch Card。字段：
- Session: exec sessionId（如 `calm-falcon`）
- 模型: 对应 Claude Code 为 `claude-sonnet-4-6` 或 opus；Codex 为 `gpt-5.4`

### 切换开关

```bash
# 开启详细模式（默认）
echo '{"verbose_dispatch": true}' > ~/.openclaw/workspace/swarm/config.json

# 关闭（精简模式）
echo '{"verbose_dispatch": false}' > ~/.openclaw/workspace/swarm/config.json
```

也可以直接告诉我「开启/关闭 dispatch 详情」，我来更新配置。

---

## tmux Session Management

### Create sessions
```bash
tmux new-session -d -s cc-plan -c /path/to/project
tmux new-session -d -s codex-1 -c /path/to/project
tmux new-session -d -s cc-frontend -c /path/to/project
tmux new-session -d -s cc-review -c /path/to/project
tmux new-session -d -s codex-review -c /path/to/project
```

### Model Selection Rules

### Model Selection Rules

#### Claude Code（`claude` CLI）

| Agent | Model | Rationale |
|---|---|---|
| `cc-plan` | `claude-opus-4-6` | Planning/architecture — always best model |
| `cc-review` | `claude-sonnet-4-6` | Execution task, sonnet sufficient, saves quota |
| `cc-frontend` | `claude-sonnet-4-6` | UI implementation, sonnet sufficient |

#### Codex（`codex` CLI）

Model is fixed as `gpt-5.4`. Reasoning effort is configurable via `-c model_reasoning_effort=<level>`:

| Effort | Flag | When to use |
|---|---|---|
| `medium` | `-c model_reasoning_effort=medium` | Simple/mechanical tasks (scripts, boilerplate) |
| `high` | `-c model_reasoning_effort=high` | Standard coding tasks (default) |
| `extra-high` | `-c model_reasoning_effort=extra-high` | Complex logic, financial code, retry after failure |

**Retry escalation rule:**
- Attempt 1: `high` (default)
- Attempt 2+: automatically escalate to `extra-high`
- Never downgrade on retry

### Send commands to agents (with auto-completion notification)
```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent

# cc-plan — always opus
# Use --output-format json so parse-tokens.sh can extract usage stats from the log.
# dispatch.sh wraps the command with `tee LOG_FILE`, so LOG_FILE contains the JSON blob.
$SKILL_DIR/scripts/dispatch.sh cc-plan T000 "claude --model claude-opus-4-6 --permission-mode bypassPermissions --no-session-persistence --print --output-format json 'PROMPT_HERE'"

# cc-review / cc-frontend — sonnet
$SKILL_DIR/scripts/dispatch.sh cc-review T005 "claude --model claude-sonnet-4-6 --permission-mode bypassPermissions --no-session-persistence --print --output-format json 'PROMPT_HERE'"
$SKILL_DIR/scripts/dispatch.sh cc-frontend T010 "claude --model claude-sonnet-4-6 --permission-mode bypassPermissions --no-session-persistence --print --output-format json 'PROMPT_HERE'"

# Codex — standard task (high effort, default)
$SKILL_DIR/scripts/dispatch.sh codex-1 T001 "codex exec -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox 'PROMPT_HERE'"

# Codex — retry / complex task (extra-high effort)
$SKILL_DIR/scripts/dispatch.sh codex-1 T001 "codex exec -c model_reasoning_effort=extra-high --dangerously-bypass-approvals-and-sandbox 'PROMPT_HERE'"

# Codex — simple/boilerplate task (medium effort, faster)
$SKILL_DIR/scripts/dispatch.sh codex-1 T001 "codex exec -c model_reasoning_effort=medium --dangerously-bypass-approvals-and-sandbox 'PROMPT_HERE'"
```

### Read agent output
```bash
tmux capture-pane -t <session> -p | tail -40
```

### Interactive follow-up (if agent is in conversation mode)
```bash
tmux send-keys -t <session> -l -- "follow-up message"
tmux send-keys -t <session> Enter
```

## Permission Boundaries

**Act autonomously:**
- Answer agent technical questions
- Retry failed tasks (adjust prompt)
- Revert bad commits
- Minor refactoring decisions
- Choose which agent for a task

**Escalate to human:**
- Unclear requirements / ambiguous design
- Anything involving secrets, .env, API keys
- Stuck after 5 total attempts (3 original + 2 alternate)
- Architecture-level changes
- Deleting important files or data

## Notification Strategy

- **Immediate:** secrets involved, design decisions needed, 5 retries exhausted
- **Batch:** all tasks complete, milestone progress
- **Silent:** routine retries, answering agent questions, minor fixes

## References

- `references/prompt-codex.md` — Codex backend coding prompt template
- `references/prompt-cc-plan.md` — CC planning prompt template
- `references/prompt-cc-frontend.md` — CC frontend coding prompt template
- `references/prompt-cc-review.md` — CC/Codex review prompt template
- `references/task-schema.md` — active-tasks.json schema and status definitions
- `scripts/dispatch.sh` — Dispatch wrapper: mark running + mark agent busy + tee output + force-commit + on-complete callback
- `scripts/on-complete.sh` — Completion callback: parse tokens + update status + mark agent idle + agent-manager + webhook + milestone alert + notify
- `scripts/update-task-status.sh` — Atomically update task status in active-tasks.json (status + tokens + auto-unblock)
- `scripts/update-agent-status.sh` — Update a single agent's status in agent-pool.json (idle/busy/dead)
- `scripts/parse-tokens.sh` — Parse token usage from agent output log (Claude Code + Codex formats)
- `scripts/install-hooks.sh` — Install git post-commit hook (tsc + ESLint gates + auto-push)
- `scripts/agent-manager.sh` — Evaluate task queue → scale agents up (spawn) or trigger cleanup when all done
- `scripts/spawn-agent.sh` — Spawn a new tmux session + register in agent-pool.json (with memory check)
- `scripts/check-memory.sh` — Check available RAM; ok/warn/block thresholds for safe agent spawning
- `scripts/health-check.sh` — Inspect all running agent sessions; detect stuck/dead agents and notify
- `scripts/cleanup-agents.sh` — Kill all dynamic agent sessions after swarm completes; preserve fixed sessions
- `scripts/monitor.sh` — Fallback cron monitor (safety net, optional)
- Full design doc: `~/.openclaw/workspace/docs/coding-swarm-agent-playbook.md`
