#!/usr/bin/env bash
# scope-fence.sh — PreToolUse hook for Claude Code (Edit, Write, MultiEdit)
#
# Blocks edits outside a user-declared scope. Reads scope from
# .claude/scope.json in the project root:
#
#   {
#     "allow": ["src/components/**", "src/styles/colors.ts"],
#     "deny":  ["src/legacy/**"]
#   }
#
# When the policy is active, Claude can only edit paths matching an allow pattern
# (and never a deny pattern). Blocks are fed back as a stderr correction prompt.
#
# Enable per-session by writing scope.json before you run a task.
# Delete scope.json to deactivate.
#
# Exit codes: 0 OK · 2 BLOCK.

set -euo pipefail

case ",${CLAUDE_HOOKS_DISABLED:-}," in *,scope-fence,*|*,all,*) exit 0 ;; esac

payload="$(cat)"

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
scope="$project_dir/.claude/scope.json"

if [ ! -f "$scope" ]; then
  exit 0
fi

payload_file="$(mktemp)"
trap 'rm -f "$payload_file"' EXIT
printf '%s' "$payload" > "$payload_file"

verdict="$(python3 - "$scope" "$project_dir" "$payload_file" <<'PY'
import fnmatch, json, os, sys

scope_path, project_dir, payload_file = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(scope_path) as f:
        pol = json.load(f)
except Exception as e:
    print(f"ok:scope-unreadable:{e}")
    sys.exit(0)

allow = pol.get("allow", []) or []
deny = pol.get("deny", []) or []

try:
    with open(payload_file) as f:
        d = json.load(f)
except Exception:
    print("ok:no-payload")
    sys.exit(0)

ti = d.get("tool_input", {}) or {}
# Collect candidate file paths from the tool call.
candidates = []
for key in ("file_path", "path", "notebook_path"):
    v = ti.get(key)
    if isinstance(v, str) and v:
        candidates.append(v)
# MultiEdit style: edits=[{file_path:...}] (defensive)
for edit in ti.get("edits", []) or []:
    if isinstance(edit, dict):
        v = edit.get("file_path") or edit.get("path")
        if isinstance(v, str) and v:
            candidates.append(v)

if not candidates:
    print("ok:no-file")
    sys.exit(0)

def relpath(p):
    try:
        return os.path.relpath(os.path.realpath(p), start=os.path.realpath(project_dir))
    except Exception:
        return p

for raw in candidates:
    rel = relpath(raw)
    # Deny wins over allow.
    for pat in deny:
        if fnmatch.fnmatchcase(rel, pat) or fnmatch.fnmatchcase(raw, pat):
            print(f"block:{raw}:denied by pattern {pat!r}")
            sys.exit(0)
    if allow:
        ok = False
        for pat in allow:
            if fnmatch.fnmatchcase(rel, pat) or fnmatch.fnmatchcase(raw, pat):
                ok = True
                break
        if not ok:
            print(f"block:{raw}:not in allow-list {allow}")
            sys.exit(0)

print("ok:in-scope")
PY
)"

if [ "${verdict%%:*}" = "block" ]; then
  # Strip "block:" prefix for a cleaner message.
  msg="${verdict#block:}"
  path="${msg%%:*}"
  reason="${msg#*:}"
  cat >&2 <<EOF
[trust-but-verify] Blocked: editing "${path}" is outside the declared scope (.claude/scope.json).
Reason: ${reason}.

If this edit is actually required for the task, stop and ask the user to widen the scope.
Do NOT work around the fence by editing an allowed file to achieve the same effect.
EOF
  exit 2
fi

exit 0
