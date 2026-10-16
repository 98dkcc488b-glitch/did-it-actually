#!/usr/bin/env bash
# block-wrong-branch.sh — PreToolUse hook for Claude Code (Bash tool)
#
# Blocks `git push` to disallowed branches. Reads policy from
# .claude/branch-policy.json in the project root:
#
#   {
#     "allowed_push_branches": ["feature/*", "fix/*"],
#     "blocked_push_branches": ["main", "master", "production"]
#   }
#
# Behaviour:
#   - If the Bash command contains `git push`, extract the target branch
#     (either from `git push <remote> <branch>` or current HEAD).
#   - If the target matches a blocked pattern, exit 2 with a correction prompt.
#   - If an allow-list exists and the target is not in it, exit 2.
#   - Otherwise exit 0.
#
# Exit codes: 0 OK · 2 BLOCK (fed back to Claude).

set -euo pipefail

case ",${CLAUDE_HOOKS_DISABLED:-}," in *,block-wrong-branch,*|*,all,*) exit 0 ;; esac

payload="$(cat)"

command="$(printf '%s' "$payload" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('tool_input', {}).get('command', ''))
except Exception:
    print('')
")"

# Normalize runs of whitespace so `git  push` parses the same as `git push`.
command="$(printf '%s' "$command" | tr -s ' \t')"

# Only inspect git push commands.
case "$command" in
  *"git push"*) : ;;
  *) exit 0 ;;
esac

# Short-circuit: these flags are harmless (no push happens).
case "$command" in
  *--dry-run*|*"--help"*) exit 0 ;;
esac

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
policy="$project_dir/.claude/branch-policy.json"

if [ ! -f "$policy" ]; then
  # No policy = no opinion.
  exit 0
fi

# Figure out which branch would be pushed.
# `git push`                  → current HEAD
# `git push <remote>`         → current HEAD (to remote's matching ref)
# `git push <remote> <ref>`   → <ref> (may be "src:dst", we take dst)
target_branch=""
# Strip everything up to and including "git push".
tail="${command#*git push}"
# Tokens after "git push", drop options starting with "-".
read -r -a tokens <<< "$tail"
positional=()
for t in "${tokens[@]}"; do
  case "$t" in
    -*) ;;
    *) positional+=("$t") ;;
  esac
done

if [ "${#positional[@]}" -ge 2 ]; then
  refspec="${positional[1]}"
  target_branch="${refspec##*:}"  # dst half of src:dst, or whole thing
elif git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
  target_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi

if [ -z "$target_branch" ] || [ "$target_branch" = "HEAD" ]; then
  # Can't tell — don't block, but don't lie about it.
  exit 0
fi

decision="$(python3 - "$policy" "$target_branch" <<'PY'
import fnmatch, json, sys
policy_path, branch = sys.argv[1], sys.argv[2]
try:
    with open(policy_path) as f:
        pol = json.load(f)
except Exception as e:
    print(f"ok:policy-unreadable:{e}")
    sys.exit(0)

blocked = pol.get("blocked_push_branches", []) or []
allowed = pol.get("allowed_push_branches", []) or []

for pat in blocked:
    if fnmatch.fnmatchcase(branch, pat):
        print(f"block:matches blocked pattern {pat!r}")
        sys.exit(0)

if allowed:
    for pat in allowed:
        if fnmatch.fnmatchcase(branch, pat):
            print("ok:in allow-list")
            sys.exit(0)
    print(f"block:not in allow-list {allowed}")
    sys.exit(0)

print("ok:no blocked match, no allow-list")
PY
)"

verdict="${decision%%:*}"
reason="${decision#*:}"

if [ "$verdict" = "block" ]; then
  cat >&2 <<EOF
[trust-but-verify] Blocked: \`git push\` to branch "${target_branch}" is not allowed by .claude/branch-policy.json.
Reason: ${reason}.

If you were told to push to a feature branch, you may have the wrong branch checked out.
Check with: git rev-parse --abbrev-ref HEAD
Switch, or push explicitly: git push origin <intended-branch>
EOF
  exit 2
fi

exit 0
