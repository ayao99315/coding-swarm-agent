---
name: ayao-workflow-agent
description: "Multi-agent workflow orchestrator for coding, writing, analysis, and image tasks via tmux-driven Claude Code and Codex agents. Use when: (1) user requests a feature/fix that should be delegated to coding agents, (2) managing parallel coding tasks across front-end and back-end, (3) monitoring active agent sessions and coordinating review, (4) user says 'start task', 'assign to agents', 'swarm mode', or references the ayao-workflow-agent playbook. NOT for: simple one-liner edits (just edit directly), reading code (use read tool), or single quick questions about code."
---

# ayao-workflow-agent

Coordinate multiple coding agents (Claude Code + Codex) via tmux sessions on a single machine. You are the orchestrator — you decompose tasks, write prompts, dispatch to agents, monitor progress, coordinate cross-review, and report results.

## Architecture

```
You (OpenClaw) = orchestrator
  ├→ cc-plan       (Claude Code)  — decompose requirements into atomic tasks
  ├→ codex-1       (Codex CLI)    — backend coding
  ├→ cc-frontend   (Claude Code)  — frontend coding (external-facing UI only)
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
7. **⚠️ ALWAYS use dispatch.sh — never exec directly.** Any time you run Codex or Claude Code within a swarm project (active-tasks.json exists or task is swarm-related), dispatch via `dispatch.sh`. Never use the `exec` tool or `coding-agent` skill pattern directly. Reason: dispatch.sh is the only path that guarantees on-complete.sh fires → status updated → `openclaw system event` fired → orchestrator (AI) wakes and responds. Direct exec = silent failure, no notification, no status tracking.
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

## Documentation Rules — Three-Layer Planning

### Three-Layer Responsibilities

- **Requirements**: Always organized and finalized by the orchestrator layer, used to define requirement boundaries, goals, non-goals, and acceptance criteria
- **Design**: Produced by `cc-plan` when code exploration is needed; written directly by the orchestrator layer when no code exploration is required
- **Plan / Task decomposition**: Always owned by the orchestrator layer, because the orchestrator best understands swarm granularity, file boundaries, and agent assignments

### Three-Tier Task Classification

| Tier | Criteria | Requirements doc | Design doc | Owner |
| --- | --- | --- | --- | --- |
| A | One-liner task — goal and implementation path are both clear | Not needed | Not needed; prompt / analysis files go in `docs/swarm/` | Orchestrator layer |
| B | Goal is clear, but implementation approach still needs design | Not needed | Written to `docs/design/` | Design by `cc-plan` or orchestrator layer; task decomposition always by orchestrator layer |
| C | Complex or ambiguous — requirements themselves are uncertain | Written to `docs/requirements/` first | Then written to `docs/design/` | Requirements and Plan by orchestrator layer; Design by `cc-plan` or orchestrator layer |

### Document Directory Structure

```text
<project-or-skill-root>/
  docs/
    requirements/   ← Requirements docs (orchestrator writes, Tier C complex tasks)
    design/         ← Technical design docs (cc-plan produces or orchestrator writes)
    swarm/          ← Swarm dispatch prompt files, task analysis (orchestrator writes, Tier A)
```

### Execution Rules

- Requirements, Design, and Plan are three separate layers — do not mix them, and do not push task decomposition onto `cc-plan`
- Tier A does not require requirements/design docs — put prompts and task analysis directly in `docs/swarm/`
- Tier B: complete design first, then orchestrator layer decomposes tasks; if design requires code exploration, invoke `cc-plan`
- Tier C: must converge requirements first — write `docs/requirements/`, then proceed to design and task decomposition
- For any task entering the swarm, final task decomposition is always done by the orchestrator layer — never delegated to the design agent

### cc-plan Role Definition

- `cc-plan`'s core value is exploring the codebase and producing Design documents
- `cc-plan` is only responsible for the Design layer — not Requirements, not Plan / task decomposition
- `cc-plan`'s output must be written to `docs/design/<feature>-design.md`

## Workflow

### Starting a New Batch

When beginning a new swarm project or a new phase of work, archive the current batch first:

```bash
SKILL_DIR=~/.openclaw/workspace/skills/ayao-workflow-agent
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
~/.openclaw/workspace/skills/ayao-workflow-agent/scripts/install-hooks.sh /path/to/project
```

This installs a `post-commit` hook that:
- Detects commits during active swarm operations
- Auto-pushes the commit
- Writes a signal to `/tmp/agent-swarm-signals.jsonl`
- Wakes the orchestrator via `openclaw system event --mode now`

### ⚠️ Task Registration Rule (No Exceptions)

**Every task must be registered before dispatch — no exceptions, no "too small to skip".**
If dispatch.sh returns `WARN: task not found`, the task is in a black hole — no status tracking, the orchestrator will never be woken to dispatch deploy — you'll never know if it finished.

#### Hotfix Quick Registration (one command — easier than skipping)

```bash
# Register a hotfix/deploy task — just modify the ID and description
TASK_FILE=~/.openclaw/workspace/swarm/active-tasks.json
TASK_ID="FIX-001"   # change this
TASK_DESC="Fix sports WS warmup issue"  # change this
AGENT="cc-frontend"  # change this: codex-1 / cc-frontend / codex-deploy

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

#### Hotfix + Deploy Chained Registration (orchestrator auto-dispatches deploy after fix completes)

```bash
# Register FIX + dependent DEPLOY, forming an event-driven chain
python3 - << EOF
import json, datetime
with open('$TASK_FILE') as f:
    data = json.load(f)
now = datetime.datetime.utcnow().isoformat() + "Z"
data['tasks'].extend([
    {"id": "FIX-001", "name": "Fix description", "domain": "frontend",
     "status": "pending", "agent": "cc-frontend", "review_level": "skip",
     "depends_on": [], "created_at": now},
    {"id": "DEPLOY-001", "name": "Deploy web-admin", "domain": "deploy",
     "status": "blocked", "agent": "codex-deploy", "review_level": "skip",
     "depends_on": ["FIX-001"], "created_at": now},
])
with open('$TASK_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("✅ Registered FIX-001 + DEPLOY-001 (chained)")
EOF
```

After registration → dispatch FIX → when FIX completes, on-complete.sh auto-unblocks DEPLOY to pending → orchestrator is woken by event and dispatches it.

## Hotfix Flow (Quick Fix Pipeline)

When a bug is found that needs an immediate fix → immediate deploy, follow this flow:

```bash
SKILL_DIR=~/.openclaw/workspace/skills/ayao-workflow-agent
TASK_FILE=~/.openclaw/workspace/swarm/active-tasks.json

# Step 1: Register FIX + DEPLOY tasks (chained dependency)
python3 - << EOF
import json, datetime
with open('$TASK_FILE') as f:
    data = json.load(f)
now = datetime.datetime.utcnow().isoformat() + "Z"
data['tasks'].extend([
    {"id": "FIX-XXX", "name": "One-line description", "domain": "frontend",
     "status": "pending", "agent": "cc-frontend", "review_level": "skip",
     "depends_on": [], "created_at": now},
    {"id": "DEPLOY-XXX", "name": "Deploy", "domain": "deploy",
     "status": "blocked", "agent": "codex-deploy", "review_level": "skip",
     "depends_on": ["FIX-XXX"], "created_at": now},
])
with open('$TASK_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("✅ Registered FIX-XXX + DEPLOY-XXX")
EOF

# Step 2: Write prompt to file (avoids shell escaping hell)
cat > /tmp/fix-xxx-prompt.txt << 'PROMPT'
## Your Task
...
PROMPT

# Step 3: Dispatch (use --prompt-file, no manual escaping needed)
$SKILL_DIR/scripts/dispatch.sh cc-frontend FIX-XXX --prompt-file /tmp/fix-xxx-prompt.txt \
  claude --model claude-sonnet-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json

# DEPLOY-XXX auto-unblocks to pending after FIX-XXX completes; orchestrator is woken by event and dispatches DEPLOY-XXX
# Before dispatching deploy, run the review dashboard first
$SKILL_DIR/scripts/review-dashboard.sh
# Confirm output shows "Ready to release ✅" before dispatching
```

**Rule: hotfix and deploy are always registered as a pair — deploy always depends on fix.**

---

### Phase 4: Dispatch

For each ready task (status=pending, dependencies met):
- Pick agent based on domain and `ui_quality`:
  - `domain=backend` → `codex-1`
  - `domain=frontend, ui_quality=external` → `cc-frontend` (Claude Code sonnet)
  - `domain=frontend, ui_quality=internal` (or omitted) → `codex-1` (save tokens)
  - `domain=docs/writing/analysis/design` → `cc-plan` (Claude Code opus)
  - `domain=test` → `codex-test`
  - `domain=deploy` → `codex-deploy`
- Generate prompt from template (`references/prompt-codex.md` or `references/prompt-cc-frontend.md`)
  The current prompt templates include `## Cognitive Mode`, `## Completeness Principle`, and `## Contributor Mode (fill in after task completion)`. Keep those sections intact when adapting a task prompt.
  **Prompt quality rules:**
  - Reference actual code files (e.g. "refer to `src/persistence/db.ts` getPool() pattern"), never describe tech stack in words
  - Pre-write the exact `git commit -m "..."` command, don't let agent choose
  - List specific file paths in scope, not directory names
  - In "Do NOT" section, list files likely to be accidentally modified
  - Preserve the four cognitive checks in the prompt: `DRY Check`, `Boring by Default`, `Blast Radius Check`, `Two-Week Smell Test`
  - State the `Completeness Principle` explicitly when scope includes paired docs/files, so the agent finishes every in-scope artifact before stopping
  - Keep `## Contributor Mode (fill in after task completion)` at the end of the prompt and require the agent to include the field report in the commit message body: what was done, issues hit, and what was intentionally left out
- For `cc-plan` tasks: if a project memory file exists at `projects/<slug>/context.md`, dispatch.sh automatically injects it into the prompt so the planning agent has project-specific background context.
- Dispatch using the wrapper script (auto: marks running + attaches completion callback + force-commits if agent forgets):
  ```bash
  scripts/dispatch.sh <session> <task_id> --prompt-file /tmp/task-prompt.txt <agent> <arg1> <arg2> ...
  ```
  Before dispatching any `deploy` task:
  ```bash
  # Before dispatching deploy, run the review dashboard first
  ~/.openclaw/workspace/skills/ayao-workflow-agent/scripts/review-dashboard.sh
  # Confirm output shows "Ready to release ✅" before dispatching
  ```
  To check historical batches or other task files, append `--task-file /path/to/tasks.json`.
  Legacy single-string commands are still accepted for backward compatibility, but new docs should always use argv + `--prompt-file`.
  dispatch.sh automatically:
  1. Validates TASK_ID against a whitelist regex (rejects injection payloads)
  2. Updates active-tasks.json status to `running` (with tmux session written to `task.tmux` field); verifies tmux session exists **before** mark-running to avoid orphan states
  3. Executes agent via quoted heredoc (`<<'SCRIPT'`, no shell interpolation) with variables passed as env vars — eliminates code injection surface
  4. Appends a force-commit check after agent finishes (catches forgotten commits); cleanup trap rolls back status to `failed` on unexpected exit
  5. Calls on-complete.sh which updates status to `done`/`failed` + fires `openclaw system event` to wake orchestrator (AI)
  6. Preserves the agent's Contributor Mode field report via the commit body, so the completion record explains what changed, what went wrong, and what was skipped

**Parallel dispatch:** OK if file scopes don't overlap. Check before dispatching.

### Phase 5: Event-Driven Monitor

**Primary (instant — event-driven):**

1. **post-commit hook** — fires on every git commit. Writes signal + auto-pushes.
2. **on-complete.sh** — fires when agent command finishes. Does three things:
   a. `update-task-status.sh` — atomically updates active-tasks.json (status + commit + auto-unblock dependents)
   b. `openclaw system event --text "Done: $TASK_ID" --mode now` — wakes the main session orchestrator (AI)
   c. `openclaw message send` — Telegram notification to human.

Current notification format uses the upgraded compact style: task name, token usage (`Xk`), elapsed time, and a suggested next step. When the whole swarm completes, the final notification also includes total duration.

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
2. Orchestrator (AI) dispatches the next `pending` task(s) using dispatch.sh
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

Read via the config system: `swarm-config.sh resolve notify.verbose_dispatch` (falls back to `true` if unset). dispatch.sh uses this to choose compact vs verbose format automatically.

**Verbose Card (verbose_dispatch = true):**
```
🚀 Dispatched [TASK_ID] → [SESSION]
┣ 📋 Session:  [tmux session name / background session id]
┣ ⏰ Started:  [HH:MM:SS]
┣ 🤖 Model:   [full model name] ([tier/reasoning effort])
┗ 📝 Task:    [one-line task description]
```

Example:
```
🚀 Dispatched T001 → codex-1
┣ 📋 Session:  tmux: codex-1
┣ ⏰ Started:  10:35:42
┣ 🤖 Model:   gpt-5.4 (reasoning: high)
┗ 📝 Task:    Fix sports-ws ping heartbeat so server properly pushes match data
```

**Compact Card (verbose_dispatch = false):**
```
🚀 [TASK_ID] → [SESSION] | [model]/[tier] | [HH:MM]
```

Example:
```
🚀 T001 → codex-1 | gpt-5.4/high | 10:35
```

### Non-Swarm Scenarios (single agent, coding-agent skill)

Even outside dispatch.sh, any operation that spawns a coding agent must report a Dispatch Card in the same format. Fields:
- Session: exec sessionId (e.g. `calm-falcon`)
- Model: for Claude Code use `claude-sonnet-4-6` or opus; for Codex use `gpt-5.4`

### Toggle Switch

```bash
SKILL_DIR=~/.openclaw/workspace/skills/ayao-workflow-agent

# Enable verbose mode (default)
$SKILL_DIR/scripts/swarm-config.sh set notify.verbose_dispatch true

# Disable (compact mode)
$SKILL_DIR/scripts/swarm-config.sh set notify.verbose_dispatch false
```

You can also just tell me "enable/disable dispatch details" and I'll update the config.

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

#### Claude Code (`claude` CLI)

| Agent | Model | Rationale |
|---|---|---|
| `cc-plan` | `claude-opus-4-6` | Planning/architecture/docs/writing/analysis |
| `cc-review` | `claude-sonnet-4-6` | Code review |
| `cc-frontend` | `claude-sonnet-4-6` | External-facing UI only (`ui_quality=external`) |

> **Documentation task routing rule**: Tasks with `domain: docs` (updating playbook, SKILL.md, README, etc.) are always dispatched to `cc-plan` (claude-opus-4-6), using the same dispatch command format as cc-plan. Reason: documentation tasks require understanding global context and design intent — opus delivers better quality, and doc tasks typically follow a batch of coding tasks when the cc-plan session is already idle.

> **Frontend routing criteria**: Based on "whether real users see it." `internal` frontends (admin panels, internal tools, ops dashboards) go to `codex-1`; `external` frontends (user-facing product UI, public interfaces) go to `cc-frontend`.

#### Codex (`codex` CLI)

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
SKILL_DIR=~/.openclaw/workspace/skills/ayao-workflow-agent
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

## Project Memory Store

Each swarm project can have its own memory directory at `projects/<slug>/`, containing:

```
projects/
  <slug>/
    context.md      ← Project background (manually maintained), auto-injected into cc-plan tasks
    retro.jsonl     ← Task retrospective records (auto-appended by on-complete.sh)
```

- **context.md**: Records the project's tech stack, key decisions, known pitfalls, and other background information. dispatch.sh automatically injects this file's content when dispatching cc-plan tasks, giving the planning agent project-specific context. Manually maintained — recommended to update after each major batch completes.
- **retro.jsonl**: Each record corresponds to a completed task, in JSON Lines format. on-complete.sh auto-appends on task completion, including task_id, status, elapsed time, tokens, commit hash, field report summary, and other fields. Used for retrospectives and trend analysis.

## Known Limitations

The following WARN-level issues were identified during the v1.6.0 security review and left as-is:

1. **task-not-found vs race-protection share exit 2** — `update-task-status.sh` uses exit 2 for both "task not found in JSON" and "race-condition rollback". Could be split into exit 2 / exit 3 for finer-grained caller handling. Low impact: callers currently treat both as non-success.
2. **generate-image.sh `--output` path not validated** — The output path is used as-is without directory-traversal checks. An agent could write to an arbitrary path via `--output ../../etc/foo`. Low risk in practice (agents run sandboxed and output is ephemeral).
3. **`/tmp/agent-swarm-token-warned.json` not batch-isolated** — The token milestone de-dup file is global across batches. A warning suppressed in batch N stays suppressed in batch N+1. Workaround: manually delete the file between batches if milestone alerts are desired.

## References

- `references/prompt-codex.md` — Codex backend coding prompt template
- `references/prompt-cc-plan.md` — CC planning prompt template
- `references/prompt-cc-frontend.md` — CC frontend coding prompt template
- `references/prompt-cc-review.md` — CC/Codex review prompt template
- `references/prompt-cc-writing.md` — Non-code writing tasks (docs, emails, analysis reports, etc.)
- `references/prompt-cc-analysis.md` — Code/data analysis tasks
- `references/task-schema.md` — active-tasks.json schema and status definitions
- `scripts/swarm-config.sh` — Unified config reader/writer for `swarm/config.json`. Commands: `get <dot.path>`, `set <dot.path> <value>`, `resolve <dot.path>` (expands `${ENV_VAR}` templates), `project get <dot.path>`. Write path uses flock + tmpfile + fsync + os.replace; fail-fast on write error (never clears config)
- `scripts/generate-image.sh` — Generic image generation interface. Backends: `nano-banana` (Gemini), `openai` (DALL-E 3), `stub` (testing). Configured via `swarm/config.json` `image_generation.*`. Backend whitelist validation + subprocess execution (no `source`); parameter validation with exit 1 on failure
- `scripts/dispatch.sh` — Dispatch wrapper: TASK_ID whitelist validation + mark running (with tmux pre-check + cleanup trap rollback) + mark agent busy + tee output + quoted heredoc runner (no shell interpolation, env-var injection) + force-commit + on-complete callback. Reads `notify.verbose_dispatch` via swarm-config.sh; auto-injects `projects/<slug>/context.md` for cc-plan tasks
- `scripts/swarm-new-batch.sh` — Archive current batch and create fresh active-tasks.json. Refuses to archive when running tasks exist (prevents late completions landing in new batch)
- `scripts/on-complete.sh` — Completion callback: parse tokens + update status + mark agent idle + sync `agent-pool.json` liveness + trigger `cleanup-agents.sh` when all tasks finish + `openclaw system event` (wake orchestrator) + milestone alert + upgraded compact-style notification. Reads `notify.target` via `swarm-config.sh resolve` (fallback: legacy notify-target file). Includes first 300 chars of commit body as Field Report in Telegram notification. Auto-appends retro record to `projects/<slug>/retro.jsonl`
- `scripts/update-task-status.sh` — Atomically update task status in active-tasks.json (flock + tmpfile + fsync + os.replace). Features: auto-unblock dependents, task-not-found returns exit 2, heartbeat support (running→running updates `task.updated_at`)
- `scripts/update-agent-status.sh` — Update a single agent's status in agent-pool.json (idle/busy/dead). Uses flock + tmpfile + fsync + os.replace for atomic writes
- `scripts/parse-tokens.sh` — Parse token usage from agent output log (Claude Code + Codex formats)
- `scripts/install-hooks.sh` — Install git post-commit hook (tsc + ESLint gates + auto-push)
- `scripts/check-memory.sh` — Check available RAM; ok/warn/block thresholds for manual capacity checks before adding more agent load
- `scripts/review-dashboard.sh` — Pre-deploy readiness dashboard; precise `depends_on` reverse-lookup (no T1/T10 false matches). Exits 1 when unfinished full-reviews exist (release gate)
- `scripts/health-check.sh` — Inspect all running agent sessions; detect stuck/dead agents, mark their tasks as `failed` via update-task-status.sh, notify, and run prompt-reference validation. Uses flock + atomic write for agent-pool.json
- `scripts/validate-prompts.sh` — Scan prompt templates under `references/` and verify every referenced `scripts/*.sh` path exists
- `scripts/cleanup-agents.sh` — Kill all dynamic agent sessions after swarm completes; preserve fixed sessions. Uses flock + atomic write for agent-pool.json
- Full design doc: `~/.openclaw/workspace/docs/ayao-workflow-agent-playbook.md`
