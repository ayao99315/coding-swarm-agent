#!/bin/bash
set -euo pipefail

CONFIG_FILE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}/swarm/config.json"
TASKS_FILE="${OPENCLAW_WORKSPACE:-$HOME/.openclaw/workspace}/swarm/active-tasks.json"

print_usage() {
  cat <<'EOF' >&2
Usage:
  swarm-config.sh get <dot.path>
  swarm-config.sh set <dot.path> <value>
  swarm-config.sh resolve <dot.path>
  swarm-config.sh project get <dot.path>
EOF
}

json_read() {
  local file="$1"
  local path="$2"

  python3 - "$file" "$path" <<'PY'
import json
import os
import sys

file_path, path = sys.argv[1], sys.argv[2]

if not os.path.exists(file_path):
    print("", end="")
    raise SystemExit(0)

try:
    with open(file_path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    print("", end="")
    raise SystemExit(0)

value = data
if path:
    for part in path.split("."):
        if isinstance(value, dict) and part in value:
            value = value[part]
        else:
            print("", end="")
            raise SystemExit(0)

if value is None:
    print("", end="")
elif isinstance(value, bool):
    print("true" if value else "false", end="")
elif isinstance(value, (str, int, float)):
    print(value, end="")
else:
    print(json.dumps(value, ensure_ascii=False), end="")
PY
}

json_write() {
  local file="$1"
  local path="$2"
  local raw_value="$3"

  python3 - "$file" "$path" "$raw_value" <<'PY'
import json
import os
import sys
import tempfile

file_path, path, raw_value = sys.argv[1:4]

directory = os.path.dirname(file_path) or "."
os.makedirs(directory, exist_ok=True)

data = {}
if os.path.exists(file_path):
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            loaded = json.load(f)
        if isinstance(loaded, dict):
            data = loaded
    except Exception:
        data = {}

parts = path.split(".")
cursor = data
for part in parts[:-1]:
    if not isinstance(cursor.get(part), dict):
        cursor[part] = {}
    cursor = cursor[part]

try:
    value = json.loads(raw_value)
except Exception:
    value = raw_value

cursor[parts[-1]] = value

fd, tmp_path = tempfile.mkstemp(prefix=".config.", suffix=".tmp", dir=directory)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as tmp:
        json.dump(data, tmp, indent=2, ensure_ascii=False)
        tmp.write("\n")
    os.replace(tmp_path, file_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PY
}

resolve_value() {
  local raw_value
  raw_value="$(json_read "$CONFIG_FILE" "$1")"

  if [[ "$raw_value" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
    local var_name="${BASH_REMATCH[1]}"
    printf '%s' "${!var_name-}"
    return 0
  fi

  printf '%s' "$raw_value"
}

command="${1:-}"

case "$command" in
  get)
    [[ $# -eq 2 ]] || {
      print_usage
      exit 1
    }
    json_read "$CONFIG_FILE" "$2"
    ;;
  set)
    [[ $# -eq 3 ]] || {
      print_usage
      exit 1
    }
    json_write "$CONFIG_FILE" "$2" "$3"
    ;;
  resolve)
    [[ $# -eq 2 ]] || {
      print_usage
      exit 1
    }
    resolve_value "$2"
    ;;
  project)
    [[ "${2:-}" == "get" && $# -eq 3 ]] || {
      print_usage
      exit 1
    }
    json_read "$TASKS_FILE" "$3"
    ;;
  *)
    print_usage
    exit 1
    ;;
esac
