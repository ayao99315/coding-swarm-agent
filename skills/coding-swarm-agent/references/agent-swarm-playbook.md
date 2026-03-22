# Agent Swarm Playbook

多 Agent 编排系统操作手册。编排层（OpenClaw）分解任务、生成 prompt、调度 agent、监控进度、协调 review；执行层（Claude Code / Codex）只看代码、只做实现。

---

## 目录

1. [系统概览](#1-系统概览)
2. [架构总览](#2-架构总览)
3. [Agent 角色与模型选择](#3-agent-角色与模型选择)
4. [任务生命周期](#4-任务生命周期)
5. [工作流程（Phase 1-8）](#5-工作流程phase-1-8)
6. [dispatch 系统](#6-dispatch-系统)
7. [事件驱动监控](#7-事件驱动监控)
8. [Review 分级制度](#8-review-分级制度)
9. [任务注册规范](#9-任务注册规范)
10. [批次管理](#10-批次管理)
11. [配置系统](#11-配置系统)
12. [项目记忆库](#12-项目记忆库)
13. [文档三层规范](#13-文档三层规范)
14. [权限边界](#14-权限边界)
15. [脚本参考](#15-脚本参考)
16. [已知限制](#16-已知限制)

---

## 1. 系统概览

ayao-workflow-agent 是一个基于 tmux 的多 Agent 编排系统，运行在单机（Mac Mini 16GB）上。编排层（OpenClaw 主 session）持有业务上下文，将任务分解为原子单元后派发给 Claude Code 或 Codex agent；agent 完成后通过 git hook + 完成回调自动通知编排层，编排层进行 review、解锁依赖、派发下一个任务，形成全自动事件驱动闭环。

**核心理念：**

- **编排层与执行层分离**：编排层持有需求和架构上下文，执行层只看代码。两层各自最大化利用 context window。
- **原子化一切**：一个任务 = 一个原子 commit。任何一次提交出问题都能快速 `git revert`。
- **事件驱动，不轮询**：agent 完成后通过 hook 和回调立即通知编排层，零延迟自动运转。
- **主干开发**：所有 agent 在 main 分支工作，不用 worktree 和 PR，原子 commit 作为安全网。

---

## 2. 架构总览

```
┌─────────────────────────────────────────────────┐
│  人类（Telegram / SSH）                          │
│  • 提需求                                       │
│  • 收进度通知（自动推送）                         │
│  • 处理升级问题                                  │
└──────────────────┬──────────────────────────────┘
                   │
┌──────────────────▼──────────────────────────────┐
│  OpenClaw 编排层（Mac Mini）                     │
│                                                  │
│  职责：                                          │
│  • 理解需求，拆解为原子任务                       │
│  • 生成精确 prompt，派发给对应 agent              │
│  • 事件驱动监控：hook 触发 → 即时响应             │
│  • 按 review_level 分级验证                      │
│  • 自动解锁依赖，派发下游任务                     │
│  • Telegram 通知人类关键节点                      │
└──┬───────┬───────┬───────┬──────────┬───────────┘
   │       │       │       │          │
   ▼       ▼       ▼       ▼          ▼
┌──────┐┌──────┐┌──────┐┌───────┐┌──────────┐
│cc-   ││codex ││cc-   ││cc-    ││codex-    │
│plan  ││-1/-2 ││front ││review ││review    │
│      ││      ││end   ││       ││          │
│规划  ││后端  ││前端  ││审查CC ││审查Codex │
└──────┘└──────┘└──────┘└───────┘└──────────┘
```

### 事件驱动信息流

```
需求输入 → cc-plan 规划 → 任务列表 → active-tasks.json
  ↓
dispatch.sh 派发 → Agent 编码 → git commit
  ↓
post-commit hook 触发 → 编译门禁 → 通过则 push + 写信号
  ↓
Agent 命令结束 → on-complete.sh
  → update-task-status.sh（原子更新状态 + 自动解锁下游 blocked→pending）
  → openclaw system event（唤醒主 session）
  → Telegram 通知人类
  ↓
编排层被唤醒 → 验证 scope → 按 review_level 处理：
  full  → 派 review agent → 通过才标 done
  scan  → 编排层自己看 diff
  skip  → 直接 done
  ↓
标记 done → 自动解锁下游任务 → dispatch 下一个
  ↓
全部完成 → swarm 总汇报（项目/任务数/commits/tokens）
```

---

## 3. Agent 角色与模型选择

### 5 个 base agent

| Agent | tmux 会话 | 工具 | 模型 | 职责 |
|-------|----------|------|------|------|
| **cc-plan** | `cc-plan` | Claude Code | `claude-opus-4-6` | 需求分析、架构设计、文档写作、代码分析 |
| **codex-1~4** | `codex-1` ~ `codex-4` | Codex | `gpt-5.4` | 后端逻辑、API、DB、内部工具前端 |
| **cc-frontend** | `cc-frontend-1/2` | Claude Code | `claude-sonnet-4-6` | 对外产品 UI（`ui_quality=external`） |
| **cc-review** | `cc-review` | Claude Code | `claude-sonnet-4-6` | 审查 Codex 写的代码（full review） |
| **codex-review** | `codex-review` | Codex | `gpt-5.4` | 审查前端代码 |

**固定 session**（跨 swarm 保留）：`cc-plan`、`cc-review`、`codex-review`

**动态 session**（按 swarm 生命周期创建/销毁）：`codex-1~4`、`cc-frontend-1/2`、`codex-test`、`codex-deploy`

### 任务路由规则

```
后端逻辑 / API / 策略引擎 / DB / WebSocket  → codex-1 或 codex-2
内部管理后台 / 数据看板（ui_quality=internal）→ codex-1
对外产品页 / 高 UI 质量页面（ui_quality=external）→ cc-frontend
规划 / 分析 / 方案设计 / 文档 / 写作        → cc-plan（claude-opus-4-6）
Codex 代码审查                               → cc-review（claude-sonnet-4-6）
前端代码审查                                  → codex-review
里程碑测试                                    → codex-test
构建 + 部署                                   → codex-deploy
```

**前端路由判断标准**：看"是否有真实用户看到"。`internal`（管理后台、自用界面）→ codex-1；`external`（对外产品 UI）→ cc-frontend。

### Codex reasoning effort

| Effort | Flag | 适用场景 |
|--------|------|---------|
| `medium` | `-c model_reasoning_effort=medium` | 简单/机械性任务（脚本、样板） |
| `high` | `-c model_reasoning_effort=high` | 标准编码任务（默认） |
| `extra-high` | `-c model_reasoning_effort=extra-high` | 复杂逻辑、金融代码、重试 |

**重试升级规则**：第 1 次用 `high`，第 2 次及之后自动升级到 `extra-high`，不降级。

### 交叉 Review 规则

```
Codex 写的代码（后端）  → cc-review（Claude Code 审查）
前端代码               → codex-review（Codex 审查）
```

---

## 4. 任务生命周期

### 状态流转

```
pending → running → (按 review_level)
                   ├→ [skip/scan] → done
                   └→ [full] → reviewing → done
                                        ↘ running（修改）
              ↘ failed → retrying → running
                       ↘ escalated（通知人类）
blocked → pending（前置 done 后自动解锁）
```

### 状态定义

| 状态 | 含义 | 触发条件 |
|------|------|---------|
| `pending` | 依赖已满足，待派发 | 初始状态或 blocked 解锁后 |
| `blocked` | 等待前置任务完成 | `depends_on` 中有未完成任务 |
| `running` | agent 正在执行 | dispatch.sh 标记 |
| `reviewing` | 交叉 review 中 | 仅 `review_level=full` |
| `done` | 完成 | on-complete.sh 或编排层标记 |
| `failed` | 失败 | agent 退出码非零或超时 |
| `escalated` | 升级给人类 | 5 次重试仍失败 |

### 自动解锁规则

当任务标记 `done` 时，`update-task-status.sh` 自动扫描所有 `blocked` 任务。若其 `depends_on` 列表中的任务全部为 `done`，立即翻转为 `pending`。

---

## 5. 工作流程（Phase 1-8）

### Phase 1: Plan

将需求发送给 cc-plan。使用 `references/prompt-cc-plan.md` 模板。

cc-plan 探索代码库后输出设计文档（写入 `docs/design/<feature>-design.md`），并提供建议任务列表供编排层参考。

**cc-plan 只负责 Design 层**，不负责 Requirements 和最终任务拆解。

### Phase 2: Register Tasks

将任务写入 `~/.openclaw/workspace/swarm/active-tasks.json`。格式见 `references/task-schema.md`。

**dispatch 前必须注册，没有例外。** dispatch.sh 收到 `WARN: task not found` = 任务在黑洞里 = 状态不追踪 = orchestrator 不会被唤醒。

### Phase 3: Setup（首次）

安装 git hooks：

```bash
~/.openclaw/workspace/skills/coding-swarm-agent/scripts/install-hooks.sh /path/to/project
```

安装 `post-commit` hook，功能：
- tsc --noEmit 编译门禁（只检查改动文件的新错误，失败自动 `git reset --soft`）
- ESLint 门禁（对 web-admin 改动文件，`--max-warnings=0`，失败自动回退）
- 编译和 lint 通过后 auto-push
- 写信号到 `/tmp/agent-swarm-signals.jsonl`

### Phase 4: Dispatch

对每个 ready 任务（`status=pending`，依赖已满足）：

1. 根据 domain 和 `ui_quality` 选择 agent（见第 3 章路由规则）
2. 从 prompt 模板生成 prompt（见 `references/prompt-*.md`）
3. 通过 dispatch.sh 派发：

```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent
PROMPT_FILE=/tmp/swarm-task-prompt.txt

cat > "$PROMPT_FILE" << 'PROMPT'
PROMPT_HERE
PROMPT

# cc-plan — opus
$SKILL_DIR/scripts/dispatch.sh cc-plan T000 --prompt-file "$PROMPT_FILE" \
  claude --model claude-opus-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json

# cc-frontend / cc-review — sonnet
$SKILL_DIR/scripts/dispatch.sh cc-frontend T010 --prompt-file "$PROMPT_FILE" \
  claude --model claude-sonnet-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json

# Codex — standard (high effort)
$SKILL_DIR/scripts/dispatch.sh codex-1 T001 --prompt-file "$PROMPT_FILE" \
  codex exec -c model_reasoning_effort=high --dangerously-bypass-approvals-and-sandbox
```

**deploy 任务 dispatch 前**：先运行 `review-dashboard.sh`，确认输出"可以发版 ✅"后再 dispatch。

**并行 dispatch**：文件 scope 不重叠的任务可同时进行。

### Phase 5: Event-Driven Monitor

**主路径（秒级响应）：**

1. **post-commit hook** — agent commit 时触发。编译门禁 → 通过则 push + 写信号 + Telegram 通知。
2. **on-complete.sh** — agent 命令结束时触发：
   - `update-task-status.sh` 原子更新状态 + 自动解锁依赖
   - `openclaw system event --mode now` 唤醒主 session
   - `openclaw message send` Telegram 通知
   - token 里程碑预警（5 万 / 10 万 / 20 万 input tokens）
   - 全部任务完成时发 swarm 总汇报

**兜底路径**：`health-check.sh` 检测卡住（>15min 无更新）/死亡/静默退出的 agent。

编排层被唤醒后负责：
- 验证 commit scope（`git diff`）
- 按 review_level 处理（full → 派 cross-review / scan → 看 diff / skip → 直接 done）
- 派发下一个 pending 任务

### Phase 6: Verify Commit

```bash
git diff HEAD~1 --stat  # 检查文件 scope 是否匹配任务
git log --oneline -1     # 检查 commit message 格式
```

文件超出 scope → `git revert HEAD` + 重新 dispatch 更精确的 prompt。

### Phase 7: Post-Completion Verification

按 `review_level` 分级处理（详见第 8 章）。

### Phase 8: Next Task（auto）

任务标记 `done` 时：
1. `update-task-status.sh` 自动解锁所有满足条件的 `blocked` → `pending`
2. 编排层 dispatch 下一个 `pending` 任务
3. 并行安全（无文件重叠）则同时 dispatch 多个
4. 全部完成 → Telegram 汇总通知

---

## 6. dispatch 系统

### dispatch.sh 工作原理

`~/.openclaw/workspace/skills/coding-swarm-agent/scripts/dispatch.sh` 是唯一合法的 agent 派发入口。

**⚠️ ALWAYS use dispatch.sh — never exec directly.** 直接 exec = 无 on-complete 回调 = 无状态更新 = orchestrator 不会被唤醒。

**执行流程：**

1. **TASK_ID 白名单校验**：正则 `^[A-Za-z0-9._-]+$`，拒绝注入 payload
2. **tmux session 存在性检查**：session 不存在直接报错退出
3. **标记 running**：调用 `update-task-status.sh` 设置 `running`，带 check-and-set 防重复 dispatch。若任务已被其他 agent claim（exit code 2），跳过
4. **标记 agent busy**：调用 `update-agent-status.sh`
5. **构建 runner 脚本**：生成一个 bash 临时脚本写入 `/tmp/`，通过环境变量注入所有参数（不在脚本内做 shell 插值），消除代码注入面
6. **tmux 执行**：通过 `tmux send-keys` 派发，pane 只看到 `bash /tmp/script.sh`
7. **agent 执行 + tee 捕获输出**到 log 文件
8. **Claude Code JSON 模式**：若检测到 `--output-format json`，stdout 通过 python intercept 将 JSON 写入 sidecar 文件供 token 解析，同时将 `result` 字段打印到 log
9. **Force-commit 兜底**：agent 命令结束后检查 `git status --porcelain`，有未提交变更则自动 `git add + commit + push`
10. **on-complete.sh 回调**：传入 TASK_ID、SESSION、EXIT_CODE、LOG_FILE
11. **cleanup trap**：若 dispatch 失败（标记 running 后但未完成派发），自动回滚状态为 `failed`
12. **背景 heartbeat**：每 5 分钟刷新 `task.updated_at` 和 `agent.last_seen`，防止 health-check 误报卡住

### --prompt-file 机制

推荐用法：将 prompt 写入文件，通过 `--prompt-file` 传递。dispatch.sh 将文件内容复制到唯一临时文件，agent 通过 stdin 管道读取。**彻底绕开 shell 转义问题**——markdown、代码块、引号都能正确传递。

```bash
$SKILL_DIR/scripts/dispatch.sh cc-frontend T010 --prompt-file /tmp/fix-prompt.txt \
  claude --model claude-sonnet-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json
```

### cc-plan 项目上下文自动注入

当 dispatch cc-plan 任务时，dispatch.sh 自动检查 `projects/<slug>/context.md` 是否存在。若存在，将其内容注入到 prompt 文件开头（`## 项目背景（自动注入）`），让规划 agent 拥有项目背景。

### Dispatch 卡片格式

每次 dispatch 时向用户汇报 Dispatch Card。

**Verbose 模式**（默认，`swarm-config.sh get notify.verbose_dispatch` = `true`）：
```
🚀 已派发 T001 → codex-1
┣ 📋 Session:  tmux: codex-1
┣ ⏰ 启动时间: 10:35:42
┣ 🤖 模型:    gpt-5.4 (reasoning: high)
┗ 📝 任务:    修复 sports-ws ping heartbeat
```

**Compact 模式**（`notify.verbose_dispatch` = `false`）：
```
🚀 T001 → codex-1 | gpt-5.4/high | 10:35
```

切换命令：
```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent

# 开启详细模式（默认）
$SKILL_DIR/scripts/swarm-config.sh set notify.verbose_dispatch true

# 精简模式
$SKILL_DIR/scripts/swarm-config.sh set notify.verbose_dispatch false
```

---

## 7. 事件驱动监控

### 完整链路

```
Agent commit → post-commit hook
  → tsc --noEmit 编译检查（只检查改动文件的新错误）
  ├→ 编译失败 → git reset --soft HEAD~1（保留代码让 agent 继续修）
  │            → Telegram 通知 "❌ 编译失败"
  └→ 编译通过 → ESLint 检查（web-admin 改动文件，--max-warnings=0）
      ├→ ESLint 失败 → git reset --soft HEAD~1 → Telegram 通知
      └→ ESLint 通过 → git push（自动）
                      → 写 commit 信号到 /tmp/agent-swarm-signals.jsonl
                      → Telegram 通知 "✅ Commit: ..."

Agent 命令结束 → on-complete.sh
  → parse-tokens.sh 解析 token 用量
  → update-task-status.sh 原子更新（flock + tmpfile + fsync + os.replace）
    → 自动解锁 blocked→pending
  → 停止 dispatch heartbeat
  → update-agent-status.sh 标 agent idle
  → 同步 agent-pool.json 活性（检测 tmux session 存活状态）
  → 全部任务完成时触发 cleanup-agents.sh
  → openclaw system event --mode now（唤醒主 session）
  → 项目 retro.jsonl 追加回顾记录
  → Token 里程碑预警（5万/10万/20万 input tokens）
  → 全部完成时发 swarm 总汇报（幂等去重）
  → Telegram 任务完成通知（含 token、用时、下一步建议、Field Report 前 300 字符）
```

### 编译门禁设计要点

- **soft reset** 而不是 hard reset — 保留工作区让 agent 继续修复
- **只查新错误** — 不被项目预存在的类型问题干扰
- **按子项目检查** — monorepo 中只编译受影响的部分
- **ESLint 只检查改动文件** — 秒级完成，`--max-warnings=0` 强制干净代码
- **顺序：tsc → ESLint → push** — 两道门禁都过才推送

### 信号文件格式

`/tmp/agent-swarm-signals.jsonl`，每行一个 JSON：

```jsonl
{"event":"commit","hash":"eb332f6","message":"feat(clob-auth): ...","files":"clob-auth.ts","time":1773746092}
{"event":"task_done","task":"T004","session":"codex-1","exit":0,"commit":"eb332f6","tokens":{"input":8432,"output":1205,"cache_read":3100,"cache_write":0},"time":1773745951}
{"event":"compile_fail","hash":"abc1234","message":"feat(engine): ...","errors":"tsc failed in polygo-daemon","time":1773746100}
{"event":"eslint_fail","hash":"def5678","message":"feat(accounts): ...","time":1773746200}
{"event":"milestone_done","milestone":"M1","milestone_name":"市场数据层","task_ids":["T001","T002"],"time":1773746300}
```

### 手动检查

```bash
# 查看最近信号
tail -5 /tmp/agent-swarm-signals.jsonl

# 查看 agent 输出
tmux capture-pane -t <session> -p | tail -30
```

---

## 8. Review 分级制度

每个任务在规划阶段标注 `review_level`，决定完成后的验证深度：

| Level | 标记 | 适用场景 | 处理流程 |
|-------|------|---------|---------|
| `full` | 🔴 | 资金安全、核心逻辑、安全关键 | 派 cross-review agent → 必须 pass（无 Critical/High） |
| `scan` | 🟡 | 集成代码、持久化、中等复杂 | 编排层读 `git diff HEAD~1`，快速检查关键函数 |
| `skip` | 🟢 | UI 页面、脚本、CLI、低风险 | 仅验证 scope（`git diff HEAD~1 --stat`），直接 done |

### 分配指南

**`full` — 资金/安全/核心逻辑：**
- 签名/认证/凭据处理
- 订单执行和生命周期管理
- 策略信号（入场/出场/止损/止盈）
- 风控 / guardrails

**`scan` — 集成/持久化：**
- 数据提供者集成（WS 客户端、REST 封装）
- 数据库 CRUD（非金融表）
- 状态恢复 / 对账

**`skip` — UI/脚本/工具：**
- 前端页面和组件
- 验证/测试脚本
- CLI 工具
- 只读数据层和 API routes

### Full Review 流程

```
Agent 完成 → 编排层验证 scope
  ↓
dispatch.sh 派 cross-review agent（附 diff 内容）
  → 使用 references/prompt-cc-review.md 模板
  ↓
Review agent 输出：Critical / High / Low / Suggestion
  ↓
无 Critical/High → Pass → 标记 done
有 Critical/High → Fail → 返回原 agent 修改 → 最多 3 轮
  ↓
3 轮不过 → 换 agent → 最多 2 轮
  ↓
仍不过 → escalate 给人类
```

**总计：最多 5 次自动尝试（3 原始 + 2 替代）。**

### Pre-deploy 检查

```bash
~/.openclaw/workspace/skills/coding-swarm-agent/scripts/review-dashboard.sh
```

输出每个任务的 review 状态，`full` 级别任务若缺少 review → exit 1（release gate）。

---

## 9. 任务注册规范

### 铁律

**dispatch 前必须注册，没有例外，没有"太小可以跳过"。**

### Hotfix 快速注册（1 行命令）

```bash
TASK_FILE=~/.openclaw/workspace/swarm/active-tasks.json
TASK_ID="FIX-001"   # 改这里
TASK_DESC="修复描述"  # 改这里
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

### Hotfix + Deploy 链式注册

FIX 完成后 on-complete.sh 自动解锁 DEPLOY 为 pending，orchestrator 被 event 唤醒后 dispatch。

```bash
TASK_FILE=~/.openclaw/workspace/swarm/active-tasks.json

python3 - << EOF
import json, datetime
with open('$TASK_FILE') as f:
    data = json.load(f)
now = datetime.datetime.utcnow().isoformat() + "Z"
data['tasks'].extend([
    {"id": "FIX-001", "name": "修复描述", "domain": "frontend",
     "status": "pending", "agent": "cc-frontend", "review_level": "skip",
     "depends_on": [], "created_at": now},
    {"id": "DEPLOY-001", "name": "部署", "domain": "deploy",
     "status": "blocked", "agent": "codex-deploy", "review_level": "skip",
     "depends_on": ["FIX-001"], "created_at": now},
])
with open('$TASK_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
print("✅ Registered FIX-001 + DEPLOY-001 (chained)")
EOF
```

**规则：hotfix 和 deploy 永远成对注册，deploy 永远依赖 fix。** dispatch deploy 前先运行 `review-dashboard.sh` 确认"可以发版 ✅"。

### 完整 Hotfix Flow

```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent

# 1. 链式注册（如上）

# 2. 写 prompt 到文件
cat > /tmp/fix-xxx-prompt.txt << 'PROMPT'
## 你的任务
...
PROMPT

# 3. dispatch FIX
$SKILL_DIR/scripts/dispatch.sh cc-frontend FIX-001 --prompt-file /tmp/fix-xxx-prompt.txt \
  claude --model claude-sonnet-4-6 --permission-mode bypassPermissions \
  --no-session-persistence --print --output-format json

# 4. FIX 完成 → DEPLOY 自动解锁 → orchestrator dispatch
# deploy 前先运行 review dashboard
$SKILL_DIR/scripts/review-dashboard.sh
```

---

## 10. 批次管理

### swarm-new-batch.sh

当开始新项目或新阶段时，归档当前批次：

```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent
$SKILL_DIR/scripts/swarm-new-batch.sh --project "<project-name>" --repo "<github-url>"
```

**行为：**
1. 检查是否有 `running` 状态的任务 — 有则拒绝归档（防止 late completion 落入新批次）。`--force` 可强制覆盖。
2. 将 `active-tasks.json` 复制到 `swarm/history/<date>-<project>.json`（自动避免重名）
3. 创建新的空 `active-tasks.json`，含 `batch_id`、`project`、`repo`

### 批次文件位置

```
~/.openclaw/workspace/swarm/
├── active-tasks.json          # 当前批次
└── history/
    ├── 2026-03-16-PolyGo.json # 归档批次
    └── 2026-03-20-PolyGo-2.json
```

---

## 11. 配置系统

### config.json 结构

位置：`~/.openclaw/workspace/swarm/config.json`

```json
{
  "notify": {
    "target": "<telegram_chat_id>",
    "verbose_dispatch": true
  },
  "models": {
    "cc-plan": "claude-opus-4-6",
    "cc-review": "claude-sonnet-4-6",
    "cc-frontend": "claude-sonnet-4-6",
    "codex": "gpt-5.4"
  },
  "reasoning_effort": {
    "default": "high",
    "retry": "extra-high",
    "simple": "medium"
  },
  "domain_routing": {
    "backend": "codex-1",
    "docs": "cc-plan",
    "writing": "cc-plan",
    "analysis": "cc-plan",
    "design": "cc-plan",
    "test": "codex-test",
    "deploy": "codex-deploy",
    "frontend_internal": "codex-1",
    "frontend_external": "cc-frontend"
  },
  "capabilities": {
    "image_generation": true,
    "browser_qa": false,
    "prompt_validate": true
  },
  "image_generation": {
    "default_backend": "nano-banana",
    "output_dir": "docs/images",
    "backends": {
      "nano-banana": { "api_key": "${GEMINI_API_KEY}" },
      "openai": { "api_key": "${OPENAI_API_KEY}", "model": "dall-e-3" }
    }
  }
}
```

### swarm-config.sh 用法

```bash
SKILL_DIR=~/.openclaw/workspace/skills/coding-swarm-agent

# 读取配置值
$SKILL_DIR/scripts/swarm-config.sh get notify.verbose_dispatch

# 写入配置值（flock + tmpfile + fsync + os.replace 原子写入）
$SKILL_DIR/scripts/swarm-config.sh set notify.verbose_dispatch false

# 读取并展开 ${ENV_VAR} 模板
$SKILL_DIR/scripts/swarm-config.sh resolve image_generation.backends.nano-banana.api_key

# 从 active-tasks.json 读取项目信息
$SKILL_DIR/scripts/swarm-config.sh project get project
```

### 运行时状态文件

```
~/.openclaw/workspace/swarm/
├── active-tasks.json     # 任务状态（update-task-status.sh 原子维护）
├── agent-pool.json       # Agent 注册表（dispatch/on-complete/health-check 维护）
├── config.json           # 配置文件（swarm-config.sh 维护）
├── notify-target         # Telegram chat_id（fallback，config.json 优先）
├── project-dir           # 当前项目路径（install-hooks.sh 写入）
├── hook-token            # Webhook 认证 token
└── history/              # 归档批次
```

### agent-pool.json 结构

```json
{
  "limits": {
    "max_codex": 4,
    "max_cc_frontend": 2,
    "min_free_memory_mb": 2048,
    "stuck_timeout_minutes": 15
  },
  "naming": {
    "codex_pattern": "codex-{1..4}",
    "cc_frontend_pattern": "cc-frontend-{1..2}",
    "fixed_sessions": ["cc-plan", "cc-review", "codex-review"]
  },
  "agents": [
    {
      "id": "codex-1",
      "type": "codex",
      "domain": "backend",
      "tmux": "codex-1",
      "status": "busy",
      "current_task": "T003",
      "spawned_at": "ISO8601",
      "last_seen": "ISO8601"
    }
  ]
}
```

---

## 12. 项目记忆库

每个 swarm 项目在 `projects/<slug>/` 下有独立记忆目录：

```
~/.openclaw/workspace/skills/coding-swarm-agent/projects/
  <slug>/
    context.md      ← 项目背景（手动维护），cc-plan 任务自动注入
    retro.jsonl     ← 任务回顾记录（on-complete.sh 自动 append）
```

### context.md

记录项目的技术栈、关键决策、已知坑等背景信息。dispatch.sh 在派发 cc-plan 任务时自动检测并注入该文件内容到 prompt 开头。建议每个大批次结束后更新。

### retro.jsonl

每条记录对应一个完成的任务，格式为 JSON Lines。on-complete.sh 在任务成功完成时自动 append。

```jsonl
{"ts":"2026-03-20T10:35:42Z","task_id":"T001","task_name":"CLOB WS 客户端","commit":"f28f10a","result":"done","duration_sec":840,"contributor_report":"实现了 WS 连接和心跳..."}
```

### Slug 约定

读取 `active-tasks.json` 中 `project` 字段，或取 `repo` 字段的最后一段路径。

---

## 13. 文档三层规范

### 三层分工

| 层 | 产出 | 负责方 |
|----|------|--------|
| **Requirements** | 需求文档 `docs/requirements/` | 编排层（C 档复杂任务） |
| **Design** | 设计文档 `docs/design/` | cc-plan（需代码探索时）；否则编排层直接写 |
| **Plan / 任务拆解** | 任务列表、swarm prompt `docs/swarm/` | **永远由编排层负责** |

### 三档任务判断

| 档位 | 判断标准 | 需求文档 | 设计文档 | 负责方 |
|------|---------|---------|---------|--------|
| **A** | 一句话任务，目标和实现路径都清楚 | 不写 | 不写；prompt 放 `docs/swarm/` | 编排层 |
| **B** | 目标清楚，但实现方案仍需设计 | 不写 | 写到 `docs/design/` | 设计由 cc-plan 或编排层；任务拆解始终由编排层 |
| **C** | 复杂或模糊，需求本身仍不确定 | 先写到 `docs/requirements/` | 再写到 `docs/design/` | Requirements 和 Plan 由编排层；Design 由 cc-plan 或编排层 |

### 文档目录结构

```text
<project-or-skill-root>/
  docs/
    requirements/   ← 需求文档（编排层写，C 档复杂任务）
    design/         ← 技术设计文档（cc-plan 产出 或 编排层写）
    swarm/          ← swarm dispatch prompt、任务分析（编排层写，A 档）
```

### 执行规则

- Requirements、Design、Plan 是三层，**不要混写**，也不要把任务拆解塞给 cc-plan
- 档位 A 不写 requirements/design，prompt 直接放 `docs/swarm/`
- 档位 B 先完成 design，再由编排层拆任务
- 档位 C 必须先收敛需求（`docs/requirements/`），再进入 design 和任务拆解
- **任何进入 swarm 的任务，最终任务拆解都由编排层完成**

### cc-plan 职责定位

- **核心价值**：探索代码库后输出 Design 文档
- 只负责 Design 层，不负责 Requirements，不负责 Plan / 任务拆解
- 产出写到 `docs/design/<feature>-design.md`

---

## 14. 权限边界

### 编排层可自主决定

- 回答 agent 的技术问题
- 重试失败任务（调整 prompt）
- Revert 有问题的 commit
- 手动补 commit（agent 忘了提交时 dispatch.sh 已自动兜底）
- 调整任务优先级
- 选择用哪个 agent 执行任务
- 标记 skip/scan 级别任务为 done

### 必须问人类

- **需求不明确** — 设计意图模糊
- **涉及密钥** — .env、API key、私钥
- **5 次重试失败** — 当前方案无法解决
- **架构大改动** — 模块拆分、技术栈变更
- **删除重要文件或数据**

### 通知策略

| 时机 | 行为 |
|------|------|
| **即时通知** | 涉及密钥 / 需要设计决策 / 5 次重试失败 |
| **每次派发** | Dispatch Card（verbose/compact） |
| **每次完成** | 任务名、token 用量、用时、下一步建议 |
| **汇总通知** | 全部任务完成时的 swarm 总汇报 |
| **静默处理** | 回答 agent 技术问题 / scan review 通过 / 正常重试 |

### 编排层绝对禁止

**⚠️ ORCHESTRATOR NEVER TOUCHES PROJECT FILES — NO EXCEPTIONS.**

编排层是纯调度和审计角色。**NEVER** 使用 edit / write / exec 工具修改项目目录内的任何文件，包括：
- 源代码（.ts, .tsx, .js, .py 等）
- 配置文件（next.config.ts, package.json, tsconfig.json, .env* 等）
- 脚本、文档、或项目 repo 内的任何文件

编排层**可以**直接写的文件：
- `~/.openclaw/workspace/swarm/*`（任务注册表、agent 池、配置）
- `~/.openclaw/workspace/docs/*`（编排层自己的文档）
- `~/.openclaw/workspace/skills/*`（skill 定义）
- `~/.openclaw/workspace/memory/*`（记忆文件）

**任务大小不是标准。** 即使是 1 行 fix 也通过 agent dispatch。问题始终是："这是否触及项目目录？" → 是 → dispatch to agent。

---

## 15. 脚本参考

所有脚本位于 `~/.openclaw/workspace/skills/coding-swarm-agent/scripts/`。

### 核心流水线

| 脚本 | 用途 |
|------|------|
| **dispatch.sh** | 唯一合法派发入口。TASK_ID 白名单校验 + tmux pre-check + mark running（check-and-set）+ mark agent busy + 构建 quoted heredoc runner（env-var 注入，无 shell 插值）+ tee 捕获输出 + CC JSON sidecar + force-commit 兜底 + cleanup trap rollback + on-complete 回调 + 背景 heartbeat。读 `notify.verbose_dispatch` 选 verbose/compact 输出。cc-plan 任务自动注入 `projects/<slug>/context.md` |
| **on-complete.sh** | 完成回调。parse-tokens.sh 解析 token → update-task-status.sh 原子更新（含自动解锁）→ 停止 heartbeat → mark agent idle → 同步 agent-pool 活性 → 全部完成时 cleanup → `openclaw system event` 唤醒主 session → 项目 retro.jsonl append → token 里程碑预警 → swarm 总汇报（幂等去重）→ Telegram 通知（含 Field Report 前 300 字符） |
| **update-task-status.sh** | 原子更新 active-tasks.json。flock + tmpfile + fsync + os.replace。running 状态带 check-and-set（pending/failed/retrying→running 允许，已 running 视为 heartbeat 只刷新 updated_at，其他状态 exit 2）。done 时自动扫描并解锁 blocked 依赖。done 后台触发 milestone-check.sh |
| **update-agent-status.sh** | 更新 agent-pool.json 单个 agent 的 idle/busy/dead 状态。flock + tmpfile + fsync + os.replace |
| **parse-tokens.sh** | 解析 agent 输出 log 的 token 用量。支持 Claude Code JSON sidecar、Claude Code `--print` 文本格式、Codex `prompt_tokens/completion_tokens` 格式、Codex `tokens used` 格式。输出 JSON |
| **install-hooks.sh** | 安装 git post-commit hook。tsc --noEmit 编译门禁（只查改动文件新错误，失败 soft reset）+ ESLint 门禁（web-admin 改动文件，--max-warnings=0）+ auto-push + 写信号 + webhook wake + Telegram 通知 |

### Swarm 管理

| 脚本 | 用途 |
|------|------|
| **swarm-new-batch.sh** | 归档当前批次到 `history/`，创建新的空 active-tasks.json。有 running 任务时拒绝（`--force` 覆盖） |
| **swarm-config.sh** | 统一配置读写。`get <dot.path>` / `set <dot.path> <value>`（flock + tmpfile + fsync + os.replace）/ `resolve <dot.path>`（展开 `${ENV_VAR}` 模板）/ `project get <dot.path>`（从 active-tasks.json 读） |
| **review-dashboard.sh** | Pre-deploy 就绪检查。精确 `depends_on` 反向查找（无 T1/T10 误匹配）。`full` 级别任务缺少 review → exit 1（release gate） |

### 巡检与清理

| 脚本 | 用途 |
|------|------|
| **health-check.sh** | 巡检所有 running agent。检测 tmux session 死亡 / shell prompt 可见（agent 静默退出）/ 超时无更新（>15min）。自动标记 failed + Telegram 告警。同步 agent-pool.json 活性。退出时运行 validate-prompts.sh |
| **cleanup-agents.sh** | 全部任务完成后自动关闭动态 session（codex-1~4, cc-frontend-1/2）。保留固定 session（cc-plan, cc-review, codex-review）。原子更新 agent-pool.json 移除已关闭 agent |
| **check-memory.sh** | 检查可用 RAM。>4GB → ok（exit 0），2~4GB → warn（exit 1），<2GB → block（exit 2）。基于 macOS vm_stat 的 free + inactive pages |
| **milestone-check.sh** | 任务 done 后检查所属 milestone 是否全部完成。完成则写 `milestone_done` 信号 + 触发 codex-test（通过 webhook）。幂等文件去重 |

### 辅助工具

| 脚本 | 用途 |
|------|------|
| **validate-prompts.sh** | 扫描 `references/prompt-*.md`，验证每个引用的 `scripts/*.sh` 路径存在。检测未知字段引用（与 task-schema.md 中 JSON schema 对比） |
| **generate-image.sh** | 统一图片生成接口。`--prompt "..." --output path.png [--backend name] [--style "..."]`。后端白名单校验：nano-banana（Gemini Imagen）、openai（DALL-E 3）、stub（离线占位图）。失败自动回退到 stub |
| **backends/nano-banana.sh** | Gemini Imagen 后端。从 `${GEMINI_API_KEY}` 或 swarm-config resolve 获取 API key |
| **backends/openai.sh** | OpenAI DALL-E 3 后端。从 `${OPENAI_API_KEY}` 获取 API key |
| **backends/stub.sh** | 离线占位图后端。优先用 PIL 生成带文字说明的占位图；PIL 不可用时输出 1px 透明 PNG |

---

## 16. 已知限制

1. **task-not-found vs race-protection 共用 exit 2** — `update-task-status.sh` 对"task 未找到"和"race-condition 回滚"都返回 exit 2。可拆为 exit 2 / exit 3 做更细粒度处理。实际影响小：调用方都视为非成功。

2. **generate-image.sh `--output` 路径未校验** — 输出路径直接使用，无目录穿越检查。agent 可通过 `--output ../../etc/foo` 写任意路径。实际风险低：agent 运行在沙盒环境，输出是临时性的。

3. **`/tmp/agent-swarm-token-warned.json` 非批次隔离** — token 里程碑去重文件是全局的，跨批次共享。批次 N 抑制的预警在批次 N+1 仍被抑制。需要时手动删除该文件。

---

> **维护者：** OpenClaw Agent 编排层
> **文件路径：** `~/.openclaw/workspace/skills/coding-swarm-agent/references/agent-swarm-playbook.md`
