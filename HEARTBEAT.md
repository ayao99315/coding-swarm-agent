# HEARTBEAT.md

## Agent Swarm Check (fallback — primary is event-driven via git hooks)

### ⚠️ 卡死 Agent 兜底检查（每次心跳必做）
检查 `swarm/active-tasks.json` 里所有 `status=running` 的任务：
1. 读取任务的 `started_at`（或 `updated_at`）
2. 若超过 **15 分钟**没有更新 → 认为 agent 卡死
3. 立刻 Telegram 通知爸爸，内容格式：
   `⚠️ Agent 疑似卡死：[task_id] → [session] 已运行 [N] 分钟无响应，请检查 tmux capture-pane -t [session] -p`
4. 运行 health-check.sh 获取详细状态：
   `~/.openclaw/workspace/skills/coding-swarm-agent/scripts/health-check.sh`

**为什么重要：** on-complete.sh 依赖 agent 主动退出，agent 卡死则永远不触发。心跳是唯一的独立兜底。

If `swarm/active-tasks.json` has tasks with status "running" or "reviewing":
1. Read `/tmp/agent-swarm-signals.jsonl` for unprocessed signals (check timestamps vs last processed)
2. For any completed task signal: verify commit scope → dispatch cross-review → update task status
3. For any completed review signal: check pass/fail → mark done or return for fixes
4. Auto-unblock and dispatch next pending tasks
5. Run health check: `~/.openclaw/workspace/skills/coding-swarm-agent/scripts/health-check.sh`
   - Detects stuck agents (>15min no update), dead tmux sessions, silent exits
   - Auto-notifies via Telegram if issues found

If no active swarm tasks, skip this check.
