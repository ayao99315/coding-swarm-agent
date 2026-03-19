#!/usr/bin/env python3
"""
migrate-history.py — 把旧的单文件 active-tasks.json 按批次拆分成多个 history 文件

旧格式：一个文件包含所有项目、所有任务，project/repo 字段混乱
新格式：每批次一个文件，包含 batch_id、project、repo、created_at、updated_at、tasks

用法：
  python3 migrate-history.py [--dry-run] [--source PATH] [--dest-dir DIR]

  --dry-run    只打印结果，不写文件
  --source     旧文件路径（默认：history/2026-03-20-PolyGo-Backtest.json）
  --dest-dir   输出目录（默认：history/）
"""

import json, os, sys, argparse, datetime
from pathlib import Path

SWARM_DIR = Path.home() / ".openclaw/workspace/swarm"
HISTORY_DIR = SWARM_DIR / "history"

# ── 批次定义（按任务 ID 前缀归组）────────────────────────────────────────────
# 格式：(batch_id, project, repo, task_id_prefixes_or_ids)
BATCH_DEFS = [
    {
        "batch_id":   "2026-03-18-PolyGo-Backtest",
        "project":    "PolyGo-Backtest",
        "repo":       "github.com/ayao99315/PolyGo",
        "task_ids":   ["B000", "B001", "B002", "B003"],
    },
    {
        "batch_id":   "2026-03-19-PolyGo",
        "project":    "PolyGo",
        "repo":       "github.com/ayao99315/PolyGo",
        "task_ids":   ["DEPLOY-003", "FIX-005", "DEPLOY-004"],
    },
    {
        "batch_id":   "2026-03-19-ayao-updater",
        "project":    "ayao-updater",
        "repo":       "github.com/ayao99315/openclaw-auto-update",
        "task_ids":   [
            "AYAO-P001", "AYAO-P002",
            "AYAO-T001", "AYAO-T002", "AYAO-T003", "AYAO-T004",
            "AYAO-T005", "AYAO-T006", "AYAO-T007", "AYAO-T008",
            "AYAO-T009", "AYAO-T010", "AYAO-T011",
            "AYAO-DEPLOY",
        ],
    },
    {
        "batch_id":   "2026-03-19-coding-swarm-agent",
        "project":    "coding-swarm-agent",
        "repo":       "github.com/ayao99315/coding-swarm-agent",
        "task_ids":   [
            "SWARM-T001", "SWARM-REVIEW",
            "SWARM-T002", "SWARM-T003", "SWARM-T004", "SWARM-REVIEW2",
            "SWARM-T005", "SWARM-T006", "SWARM-REVIEW3",
        ],
    },
]


def build_batch_file(batch_def, task_map):
    """Build a new-format batch dict from batch_def + task lookup."""
    tasks = []
    missing = []
    for tid in batch_def["task_ids"]:
        if tid in task_map:
            tasks.append(task_map[tid])
        else:
            missing.append(tid)

    if missing:
        print(f"  ⚠️  missing task IDs in source: {missing}", file=sys.stderr)

    # Derive created_at / updated_at from tasks
    created_ats = [t["created_at"] for t in tasks if t.get("created_at")]
    updated_ats = [t.get("updated_at") or t.get("created_at", "") for t in tasks]

    batch_created = min(created_ats) if created_ats else datetime.datetime.utcnow().isoformat() + "Z"
    batch_updated = max(updated_ats) if updated_ats else batch_created

    return {
        "batch_id":   batch_def["batch_id"],
        "project":    batch_def["project"],
        "repo":       batch_def["repo"],
        "created_at": batch_created,
        "updated_at": batch_updated,
        "tasks":      tasks,
    }


def dest_path(batch_id, dest_dir):
    """Return the output path, auto-incrementing if already exists."""
    base = dest_dir / f"{batch_id}.json"
    if not base.exists():
        return base
    seq = 2
    while True:
        candidate = dest_dir / f"{batch_id}-{seq}.json"
        if not candidate.exists():
            return candidate
        seq += 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="print only, don't write")
    parser.add_argument(
        "--source",
        default=str(HISTORY_DIR / "2026-03-20-PolyGo-Backtest.json"),
        help="source JSON file",
    )
    parser.add_argument("--dest-dir", default=str(HISTORY_DIR), help="output directory")
    args = parser.parse_args()

    source = Path(args.source)
    dest_dir = Path(args.dest_dir)

    if not source.exists():
        print(f"❌ source not found: {source}", file=sys.stderr)
        sys.exit(1)

    with open(source) as f:
        old = json.load(f)

    all_tasks = old.get("tasks", [])
    task_map = {t["id"]: t for t in all_tasks}

    # Track which task IDs were assigned
    assigned_ids = set()
    for bd in BATCH_DEFS:
        assigned_ids.update(bd["task_ids"])

    unassigned = [t["id"] for t in all_tasks if t["id"] not in assigned_ids]
    if unassigned:
        print(f"⚠️  unassigned task IDs (will be skipped): {unassigned}", file=sys.stderr)

    print(f"\nSource: {source} ({len(all_tasks)} tasks)")
    print(f"Output: {dest_dir}\n")

    if not args.dry_run:
        dest_dir.mkdir(parents=True, exist_ok=True)

    results = []
    for bd in BATCH_DEFS:
        batch = build_batch_file(bd, task_map)
        out = dest_path(bd["batch_id"], dest_dir)

        # Skip if file already exists and has matching batch_id
        if out.exists():
            existing = json.loads(out.read_text())
            if existing.get("batch_id") == bd["batch_id"]:
                print(f"  ⏭  skip (already migrated): {out.name}")
                results.append((out, batch, "skipped"))
                continue

        task_count = len(batch["tasks"])
        print(f"  {'[dry-run] ' if args.dry_run else ''}✅ {out.name}  ({task_count} tasks)")
        for t in batch["tasks"]:
            print(f"      {t['id']:20s} {t['status']:8s}  {t['name'][:50]}")
        print()

        if not args.dry_run:
            with open(out, "w") as f:
                json.dump(batch, f, indent=2, ensure_ascii=False)

        results.append((out, batch, "written"))

    total_written = sum(1 for _, _, s in results if s == "written")
    print(f"\nDone: {total_written} file(s) written, {len(results) - total_written} skipped")

    if args.dry_run:
        print("(dry-run — no files were modified)")


if __name__ == "__main__":
    main()
