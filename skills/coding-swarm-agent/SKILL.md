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
  - When plan is needed: write requirements (docs/requirements/), dispatch cc-plan for design (docs/design/), then decompose tasks yourself
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

## Documentation Rules — Plan 三层规范

### 三层分工

- **Requirements**: 永远由编排层整理和落地，用于明确需求边界、目标、非目标和验收标准
- **Design**: 需要代码探索时由 `cc-plan` 产出；不需要代码探索时由编排层直接写
- **Plan / 任务拆解**: 永远由编排层负责，因为编排层最了解 swarm 粒度、文件边界和 agent 分配

### 三档任务判断

| 档位 | 判断标准 | 需求文档 | 设计文档 | 负责方 |
| --- | --- | --- | --- | --- |
| A | 一句话任务，目标和实现路径都清楚 | 不写 | 不写；prompt / 分析文件放 `docs/swarm/` | 编排层 |
| B | 目标清楚，但实现方案仍需设计 | 不写 | 写到 `docs/design/` | 设计由 `cc-plan` 或编排层负责；任务拆解始终由编排层负责 |
| C | 复杂或模糊，需求本身仍不确定 | 先写到 `docs/requirements/` | 再写到 `docs/design/` | Requirements 和 Plan 由编排层负责；Design 由 `cc-plan` 或编排层负责 |

### 文档目录结构

```text
<project-or-skill-root>/
  docs/
    requirements/   ← 需求文档（编排层落，C 档复杂任务）
    design/         ← 技术设计文档（cc-plan 出 或 编排层写）
    swarm/          ← swarm dispatch prompt 文件、任务分析（编排层写，档位 A）
```

### 执行规则

- Requirements、Design、Plan 是三层，不要混写，也不要把任务拆解塞给 `cc-plan`
- 档位 A 不写 requirements/design 文档，直接把 prompt 和任务分析落到 `docs/swarm/`
- 档位 B 先完成 design，再由编排层拆任务；如果设计需要探索代码，再调用 `cc-plan`
- 档位 C 必须先收敛需求，先写 `docs/requirements/`，再进入 design 和任务拆解
- 任何进入 swarm 的任务，最终任务拆解都由编排层完成，不能外包给设计代理

### cc-plan 职责定位

- `cc-plan` 的核心价值是探索代码库后输出 Design 文档
- `cc-plan` 只负责 Design 层，不负责 Requirements，也不负责 Plan / 任务拆解
- `cc-plan` 的产出必须写到 `docs/design/<feature>-design.md`

## Workflow

### Starting a New Batch

When beginning a new swarm project or a new phase of work, archive the current batch first:

```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent
$SKILL_DIR/scripts/swarm-new-batch.sh --project "<project-name>" --repo "<github-url>"
```

This archives the current `active-tasks.json` to `swarm/history/` and creates a fresh one.
Then register new tasks and dispatch as usual.

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

**dispatch 前必须注册，没有例外，没有"太小可以跳过"。**
dispatch.sh 收到 `WARN: task not found` = 任务在黑洞里 = 状态不追踪 = deploy 不自动触发 = 你永远不知道完没完。

#### Hotfix 快速注册（1 行命令，比跳过更省力）

```bash
# 注册一个 hotfix/deploy 任务，直接粘贴修改 ID 和描述即可
TASK_FILE=~/.openclaw/workspace/swarm/active-tasks.json
TASK_ID="FIX-001"   # 改这里
TASK_DESC="修复 sports WS warmup 问题"  # 改这里
AGENT="cc-frontend"  # 改这里: codex-1 / cc-frontend / codex-deploy

python3 - << EOF
import json, datetime
with open('$TASK_FILE') as f:
    data = json.load(f)
data['tasks'].append({
    "id": "$TASK_ID",
    "name": "$TASK_DESC",
    "domain": "frontend",
    "status": "pending",
    "agent": "$AGENT",
    "review_level": "skip",
    "depends_on": [],
    "created_at": datetime.datetime.utcnow().isoformat() + "Z"
})
with open('$TASK_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print(f"✅ Registered $TASK_ID")
EOF
```

#### Hotfix + Deploy 链式注册（fix 完自动触发 deploy）

```bash
# 注册 FIX + 依赖它的 DEPLOY，形成自动链
python3 - << EOF
import json, datetime
with open('$TASK_FILE') as f:
    data = json.load(f)
now = datetime.datetime.utcnow().isoformat() + "Z"
data['tasks'].extend([
    {"id": "FIX-001", "name": "修复描述", "domain": "frontend",
     "status": "pending", "agent": "cc-frontend", "review_level": "skip",
     "depends_on": [], "created_at": now},
    {"id": "DEPLOY-001", "name": "部署 web-admin", "domain": "deploy",
     "status": "blocked", "agent": "codex-deploy", "review_level": "skip",
     "depends_on": ["FIX-001"], "created_at": now},
])
with open('$TASK_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("✅ Registered FIX-001 + DEPLOY-001 (chained)")
EOF
```

注册完 → dispatch FIX → FIX 完成后 on-complete.sh 自动解锁 DEPLOY 为 pending → orchestrator 被 event 唤醒后 dispatch。

## Hotfix Flow（快速修复链路）

当发现 bug 需要立刻修 → 立刻部署时，走这个流程：

```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent
TASK_FILE=~/.openclaw/workspace/swarm/active-tasks.json

# Step 1: 注册 FIX + DEPLOY 任务（链式依赖）
python3 - << EOF
import json, datetime
with open('$TASK_FILE') as f:
    data = json.load(f)
now = datetime.datetime.utcnow().isoformat() + "Z"
data['tasks'].extend([
    {"id": "FIX-XXX", "name": "一句话描述", "domain": "frontend",
     "status": "pending", "agent": "cc-frontend", "review_level": "skip",
     "depends_on": [], "created_at": now},
    {"id": "DEPLOY-XXX", "name": "部署", "domain": "deploy",
     "status": "blocked", "agent": "codex-deploy", "review_level": "skip",
     "depends_on": ["FIX-XXX"], "created_at": now},
])
with open('$TASK_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("✅ Registered FIX-XXX + DEPLOY-XXX")
EOF

# Step 2: 把 prompt 写到文件（避免 shell 转义地狱）
cat > /tmp/fix-xxx-prompt.txt << 'PROMPT'
## 你的任务
...
PROMPT

# Step 3: dispatch（用 --prompt-file，不用手动转义）
$SKILL_DIR/scripts/dispatch.sh cc-frontend FIX-XXX --prompt-file /tmp/fix-xxx-prompt.txt \
  claude --model claude-sonnet-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json

# DEPLOY-XXX 在 FIX-XXX on-complete 后自动解锁为 pending
# dispatch deploy 之前，先运行 review dashboard
$SKILL_DIR/scripts/review-dashboard.sh
# 确认输出"可以发版 ✅"后再 dispatch DEPLOY-XXX
```

**规则：hotfix 和 deploy 永远成对注册，deploy 永远依赖 fix。**

---

### Phase 4: Dispatch

For each ready task (status=pending, dependencies met):
- Pick agent based on domain (backend→codex, frontend→cc-frontend)
- Generate prompt from template (`references/prompt-codex.md` or `references/prompt-cc-frontend.md`)
  The current prompt templates include `## 认知模式`, `## Completeness Principle`, and `## Contributor Mode（任务完成后填写）`. Keep those sections intact when adapting a task prompt.
  **Prompt quality rules:**
  - Reference actual code files (e.g. "参考 `src/persistence/db.ts` 的 getPool() 模式"), never describe tech stack in words
  - Pre-write the exact `git commit -m "..."` command, don't let agent choose
  - List specific file paths in scope, not directory names
  - In "Do NOT" section, list files likely to be accidentally modified
  - Preserve the four cognitive checks in the prompt: `DRY Check`, `Boring by Default`, `Blast Radius Check`, `Two-Week Smell Test`
  - State the `Completeness Principle` explicitly when scope includes paired docs/files, so the agent finishes every in-scope artifact before stopping
  - Keep `## Contributor Mode（任务完成后填写）` at the end of the prompt and require the agent to include the field report in the commit message body: what was done, issues hit, and what was intentionally left out
- Dispatch using the wrapper script (auto: marks running + attaches completion callback + force-commits if agent forgets):
  ```bash
  scripts/dispatch.sh <session> <task_id> --prompt-file /tmp/task-prompt.txt <agent> <arg1> <arg2> ...
  ```
  Before dispatching any `deploy` task:
  ```bash
  # dispatch deploy 之前，先运行 review dashboard
  ~/.openclaw/workspace/skills/coding-swarm-agent/scripts/review-dashboard.sh
  # 确认输出"可以发版 ✅"后再 dispatch
  ```
  如需检查历史批次或其它任务文件，可追加 `--task-file /path/to/tasks.json`。
  Legacy single-string commands are still accepted for backward compatibility, but new docs should always use argv + `--prompt-file`.
  dispatch.sh automatically:
  1. Updates active-tasks.json status to `running`
  2. Appends a force-commit check after agent finishes (catches forgotten commits)
  3. Calls on-complete.sh which updates status to `done`/`failed` + fires `openclaw system event` to wake orchestrator (AI)
  4. Preserves the agent's Contributor Mode field report via the commit body, so the completion record explains what changed, what went wrong, and what was skipped

**Parallel dispatch:** OK if file scopes don't overlap. Check before dispatching.

### Phase 5: Event-Driven Monitor

**Primary (instant — event-driven):**

1. **post-commit hook** — fires on every git commit. Writes signal + auto-pushes.
2. **on-complete.sh** — fires when agent command finishes. Does three things:
   a. `update-task-status.sh` — atomically updates active-tasks.json (status + commit + auto-unblock dependents)
   b. `openclaw system event --text "Done: $TASK_ID" --mode now` — wakes the main session orchestrator (AI)
   c. `openclaw message send` — Telegram notification to human.

Current notification format is the upgraded "20 分钟前通知" style: task name, token usage (`Xk`), elapsed time, and a suggested next step. When the whole swarm completes, the final notification also includes total duration.

The orchestrator (AI main session), once woken by the event, is responsible for:
- Verifying commit scope (reading `git diff`)
- Dispatching cross-review (full level)
- Dispatching the next pending task

> "Event-driven" here means AI orchestrator responds to events — not unattended script automation.

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
→ on-complete.sh: update status + openclaw system event → Orchestrator wakes (AI)
→ Orchestrator: verify commit scope → dispatch cross-review
→ Review agent finishes → on-complete.sh: update status + openclaw system event → Orchestrator wakes (AI)
→ Orchestrator: check review result → Pass: mark done, unblock & dispatch next
                                     → Fail: return to original agent with feedback
→ All tasks done → Notify human
```

No polling. No manual check-ins. "Automatic" means AI orchestrator responds to `openclaw system event` — not unattended script automation. Human only intervenes on escalations.

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
PROMPT_FILE=/tmp/swarm-task-prompt.txt

cat > "$PROMPT_FILE" << 'PROMPT'
PROMPT_HERE
PROMPT

# cc-plan — always opus
# Use --output-format json so parse-tokens.sh can extract usage stats from the log.
# dispatch.sh wraps the command with `tee LOG_FILE`, so LOG_FILE contains the JSON blob.
$SKILL_DIR/scripts/dispatch.sh cc-plan T000 --prompt-file "$PROMPT_FILE" \
  claude --model claude-opus-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json

# cc-review / cc-frontend — sonnet
$SKILL_DIR/scripts/dispatch.sh cc-review T005 --prompt-file "$PROMPT_FILE" \
  claude --model claude-sonnet-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json
$SKILL_DIR/scripts/dispatch.sh cc-frontend T010 --prompt-file "$PROMPT_FILE" \
  claude --model claude-sonnet-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json

# Codex — standard task (high effort, default)
$SKILL_DIR/scripts/dispatch.sh codex-1 T001 --prompt-file "$PROMPT_FILE" \
  codex exec -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox

# Codex — retry / complex task (extra-high effort)
$SKILL_DIR/scripts/dispatch.sh codex-1 T001 --prompt-file "$PROMPT_FILE" \
  codex exec -c model_reasoning_effort=extra-high --dangerously-bypass-approvals-and-sandbox

# Codex — simple/boilerplate task (medium effort, faster)
$SKILL_DIR/scripts/dispatch.sh codex-1 T001 --prompt-file "$PROMPT_FILE" \
  codex exec -c model_reasoning_effort=medium --dangerously-bypass-approvals-and-sandbox
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
- `scripts/on-complete.sh` — Completion callback: parse tokens + update status + mark agent idle + agent-manager + webhook + milestone alert + upgraded "20 分钟前通知" style notify
- `scripts/update-task-status.sh` — Atomically update task status in active-tasks.json (status + tokens + auto-unblock)
- `scripts/update-agent-status.sh` — Update a single agent's status in agent-pool.json (idle/busy/dead)
- `scripts/parse-tokens.sh` — Parse token usage from agent output log (Claude Code + Codex formats)
- `scripts/install-hooks.sh` — Install git post-commit hook (tsc + ESLint gates + auto-push)
- `scripts/agent-manager.sh` — Evaluate task queue → scale agents up (spawn) or trigger cleanup when all done
- `scripts/spawn-agent.sh` — Spawn a new tmux session + register in agent-pool.json (with memory check)
- `scripts/check-memory.sh` — Check available RAM; ok/warn/block thresholds for safe agent spawning
- `scripts/review-dashboard.sh` — Pre-deploy readiness dashboard; review task detection is more precise and ordering is stable by time
- `scripts/health-check.sh` — Inspect all running agent sessions; detect stuck/dead agents, notify, and run prompt-reference validation at the end
- `scripts/validate-prompts.sh` — Scan prompt templates under `references/` and verify every referenced `scripts/*.sh` path exists
- `scripts/cleanup-agents.sh` — Kill all dynamic agent sessions after swarm completes; preserve fixed sessions
- `scripts/monitor.sh` — Fallback cron monitor (safety net, optional)
- Full design doc: `~/.openclaw/workspace/docs/coding-swarm-agent-playbook.md`
