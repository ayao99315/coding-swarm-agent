# Task Schema — active-tasks.json

Location: `~/.openclaw/workspace/swarm/active-tasks.json`

## Structure

```json
{
  "project": "project-name",
  "repo": "github.com/user/repo",
  "updated_at": "ISO8601",
  "ui_quality": "internal | external",
  "milestones": [
    {
      "id": "M1",
      "name": "市场数据层",
      "task_ids": ["T001", "T002", "T003"],
      "test_status": "pending | running | passed | failed",
      "test_scope": {
        "unit_test_files": [
          "src/providers/clob-ws.ts",
          "src/providers/clob.ts"
        ],
        "verify_script": "scripts/verify-phase2.ts",
        "description": "验证 WS 连接、行情订阅、快照格式"
      }
    }
  ],
  "tasks": [
    {
      "id": "T001",
      "name": "Short task name",
      "domain": "backend | frontend | test | deploy | docs",
      "agent": "codex-1 | codex-2 | codex-frontend | cc-frontend | cc-plan | codex-test | codex-deploy | null",
      "tmux": "tmux session name | null",
      "milestone": "M1 | null",
      "status": "pending | blocked | running | reviewing | done | failed | escalated",
      "review_level": "full | scan | skip",
      "note": "Free-text notes, warnings, or special handling instructions",
      "commits": ["hash1", "hash2"],
      "issue": "GitHub issue number or null",
      "depends_on": ["T00X"],
      "created_at": "ISO8601",
      "updated_at": "ISO8601",
      "attempts": 0,
      "max_attempts": 3,
      "tokens": {
        "input": 0,
        "output": 0,
        "cache_read": 0,
        "cache_write": 0
      }
    }
  ]
}
```

## Status Definitions

| Status | Meaning | Next |
|--------|---------|------|
| `pending` | Ready to dispatch (dependencies met) | → running |
| `blocked` | Waiting on depends_on tasks | → pending (auto) |
| `running` | Agent is working | → reviewing / failed |
| `reviewing` | Cross-review in progress (full review only) | → done / running (fix) |
| `done` | Complete, commit pushed | terminal |
| `failed` | Max retries exhausted | → escalated |
| `escalated` | Sent to human | terminal |

## Review Level

Each task has a `review_level` that determines post-completion verification:

| Level | When to Use | What Happens |
|-------|-------------|--------------|
| `full` 🔴 | Core logic, financial operations, security-critical code | Dispatch cross-review agent. Must pass (no Critical/High). Fail → return for fixes. |
| `scan` 🟡 | Integration code, data persistence, moderate complexity | Orchestrator checks `git diff --stat` + reads key functions. Obvious issues → return. Otherwise → done. |
| `skip` 🟢 | UI pages, scripts, CLI tools, low-risk CRUD | Mark done immediately after commit verification. |

### Assignment Guidelines

**`full` — money/security/core logic:**
- Anything that signs transactions or handles credentials
- Order execution and lifecycle management
- Strategy signals (entry/exit/stop-loss/take-profit)
- Risk management / guardrails
- Real trading integration points

**`scan` — integration/persistence:**
- Data provider integrations (WS clients, REST wrappers)
- Database CRUD for non-financial tables
- State recovery / reconciliation
- Account configuration management

**`skip` — UI/scripts/utilities:**
- Frontend pages and components
- Verification/test scripts
- CLI tools
- Data layer queries and API routes for read-only display

### Completion Flow by Level

```
full:  Agent done → verify scope → dispatch review agent → pass → done
scan:  Agent done → verify scope → orchestrator reads diff → ok → done
skip:  Agent done → verify scope → done
```

## Auto-unblock Rule

When a task reaches `done`, scan all `blocked` tasks. If all their `depends_on` tasks are `done`, flip to `pending`.
