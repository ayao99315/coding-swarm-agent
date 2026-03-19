# MEMORY.md — 小明的长期记忆

## 关于爸爸
- 叫阿尧，Telegram: @plus_jin, chat_id: 8449051145
- 喜欢中文交流，希望助手风格调皮一点
- 时区 Asia/Shanghai

## 当前项目

### PolyGo — Polymarket NBA 自动交易系统
- 路径: /Users/tongyaojin/code/PolyGo
- GitHub: github.com/ayao99315/PolyGo
- 技术栈: TypeScript, Next.js (web-admin), Node.js daemon, PostgreSQL (pg), Recharts
- 注意: 项目用 pg 不是 SQLite！prompt 别写错
- 部署: 本机 + Nginx + Cloudflare Tunnel → https://polygo.doai.run
- 服务管理: launchctl（com.polygo.daemon + com.polygo.web-admin）
- daemon SSL 已修复: `NODE_TLS_REJECT_UNAUTHORIZED=0`（本地临时方案）
- Sports WS 实时比分: 已修复 ping heartbeat + warmup 等待逻辑
- 已完赛比分同步: daemon schedule-sync 每日拉取，SSL 修后正常运行

### openclaw-auto-update — OpenClaw + Skills 自动更新工具
- 路径: /Users/tongyaojin/code/openclaw-auto-update
- GitHub: github.com/ayao99315/openclaw-auto-update
- ClawHub: ayao-updater@1.0.2
- 配置: ~/.openclaw/workspace/skills/ayao-updater/config.json
- cron: 每天凌晨 3 点自动运行，完成后发 Telegram 通知
- 功能: 自动检测 npm/pnpm/yarn，保护本地修改的 skill，skipPreRelease

## Agent Swarm 系统

### Skill
- 名称: coding-swarm-agent（原 agent-swarm，已改名）
- ClawHub: coding-swarm-agent@1.2.0（2026-03-20 更新）
- GitHub: github.com/ayao99315/coding-swarm-agent
- 路径: skills/coding-swarm-agent/SKILL.md

### 架构 v2.3（2026-03-20 重大改进）
- **dispatch 链路简化（方案B）**: 去掉 webhook → isolated agent 这一跳
  - on-complete.sh 直接发 Telegram 通知主 session
  - update-task-status.sh 内置同步解锁：task done → 自动把依赖它的 blocked 任务改为 pending
  - 可靠性从 ~50% 提升到 ~95%
- **--prompt-file 修复**: 兼容单字符串/argv 两种调用，macOS mktemp 修复，Codex 真正走 stdin
- **swarm 完成总汇报**: 所有任务 done 时自动发 token 汇总消息
- **parse-tokens.sh**: 支持 Codex `tokens used\nNNNN` 格式
- **批次生命周期管理（2026-03-20 新增）**:
  - 一批次一文件：`swarm/active-tasks.json`（当前）+ `swarm/history/YYYY-MM-DD-<project>.json`（已归档）
  - 新增 `swarm-new-batch.sh`：一键 archive 旧批次 + 新建 active-tasks.json
  - on-complete.sh swarm-complete 改为判断当前文件全部任务 done（无需 meta 补丁）
  - active-tasks.json 新增顶层字段：`batch_id`、`project`、`repo`
  - 历史迁移：旧单文件已拆分为 4 个标准批次文件存入 history/

### 模型配置
- cc-plan: claude-opus-4-6
- cc-review / cc-frontend: claude-sonnet-4-6
- codex-*: gpt-5.4（reasoning: high 默认，extra-high 重试）

### 铁律
- **代码修改铁律**: 除非爸爸明确说"你来改"，否则一切代码走 swarm dispatch
- **任务注册铁律**: 所有任务（包括 hotfix/deploy）dispatch 前必须注册到 active-tasks.json
- **hotfix 流程**: FIX+DEPLOY 成对注册，DEPLOY 依赖 FIX，自动链式触发
- **dispatch 通知卡片**: 每次派发必须汇报 session/时间/模型/任务描述
- **Review 分级**: full(核心逻辑) / scan(集成) / skip(UI/脚本)

### 经验教训
- codex 不 commit → dispatch.sh force-commit 兜底
- cc-frontend 超额完成 → prompt 加 ⚠️ "只做当前任务"
- prompt 技术栈描述不准 → 铁律：引用实际代码文件
- webhook 链路不可靠 → 方案B：直接通知，同步解锁（2026-03-19）
- 任务跳过注册 → 改为一行快速注册命令（见 SKILL.md Hotfix Flow）

## 系统配置

### exec 权限
- ~/.openclaw/exec-approvals.json: security=full, ask=off（无需每次确认）

### Heartbeat
- 频率: 15 分钟（openclaw.json agents.defaults.heartbeat.every=15m）
- HEARTBEAT.md: 包含 swarm 卡死检测（15 分钟无更新自动通知）

### swarm 配置
- notify-target: 8449051145
- project-dir: /Users/tongyaojin/code/PolyGo
- config.json: verbose_dispatch=true
