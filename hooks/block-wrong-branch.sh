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
#   - Detects `git push` as two consecutive top-level shell tokens
#     (so `printf 'git push origin main'` and quoted strings don't trigger).
#   - Handles tabs, multiple spaces, env prefixes, `sudo`, pipelines,
#     logical operators (;, &&, ||, |, &).
#   - If the target matches a blocked pattern, exit 2 with a correction prompt.
#   - If an allow-list exists and the target is not in it, exit 2.
#   - Otherwise exit 0.
#
# Exit codes: 0 OK · 2 BLOCK (fed back to Claude).

set -euo pipefail

case ",${CLAUDE_HOOKS_DISABLED:-}," in *,block-wrong-branch,*|*,all,*) exit 0 ;; esac

payload="$(cat)"

project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
policy="$project_dir/.claude/branch-policy.json"

# No policy = no opinion. Short-circuit before parsing.
if [ ! -f "$policy" ]; then
  exit 0
fi

# Shell-aware detection: parse the Bash command into real tokens, find
# `git push` as adjacent top-level tokens, and extract the ref argument.
# Emits one of:
#   ok              → not a push, allow
#   dry-run         → push with --dry-run or --help, allow
#   push:<branch>   → push, inspect against policy
#   push:           → push, branch unknown (fall back to current HEAD)
detect="$(python3 - "$payload" <<'PY'
import json, re, shlex, sys

def split_commands(s):
    """Split on ;, &, |, &&, ||, newline — respecting single/double quotes
    and backslash escapes. Returns list of fragments."""
    out, buf = [], []
    i, n = 0, len(s)
    quote = None
    while i < n:
        c = s[i]
        if quote is None:
            if c in ("'", '"'):
                quote = c; buf.append(c); i += 1; continue
            if c == '\\' and i + 1 < n:
                buf.append(c); buf.append(s[i+1]); i += 2; continue
            if c in ';\n':
                out.append(''.join(buf)); buf = []; i += 1; continue
            if c == '&' and i + 1 < n and s[i+1] == '&':
                out.append(''.join(buf)); buf = []; i += 2; continue
            if c == '|' and i + 1 < n and s[i+1] == '|':
                out.append(''.join(buf)); buf = []; i += 2; continue
            if c in '&|':
                out.append(''.join(buf)); buf = []; i += 1; continue
            buf.append(c); i += 1
        else:
            buf.append(c)
            if c == '\\' and quote == '"' and i + 1 < n:
                buf.append(s[i+1]); i += 2; continue
            if c == quote:
                quote = None
            i += 1
    if buf:
        out.append(''.join(buf))
    return out

ENV_RE = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
WRAPPERS = {'sudo', 'env', 'nice', 'ionice', 'time', 'command', 'exec',
            'nohup', 'stdbuf', 'script', 'xargs'}

def find_push(fragment):
    try:
        toks = shlex.split(fragment, posix=True)
    except ValueError:
        return None  # unparseable, don't block
    i = 0
    # Skip env assignments and simple wrappers at the start.
    while i < len(toks):
        t = toks[i]
        if ENV_RE.match(t):
            i += 1; continue
        if t in WRAPPERS:
            i += 1; continue
        break
    if i + 1 < len(toks) and toks[i] == 'git' and toks[i+1] == 'push':
        return toks[i+2:]
    return None

try:
    payload = json.loads(sys.argv[1] if len(sys.argv) > 1 else '{}')
    command = payload.get('tool_input', {}).get('command', '') or ''
except Exception:
    print('ok'); sys.exit(0)

if not command:
    print('ok'); sys.exit(0)

push_args = None
for frag in split_commands(command):
    frag = frag.strip()
    if not frag:
        continue
    args = find_push(frag)
    if args is not None:
        push_args = args
        break

if push_args is None:
    print('ok'); sys.exit(0)

if '--dry-run' in push_args or '--help' in push_args:
    print('dry-run'); sys.exit(0)

# Extract first positional-after-remote as the ref.
# `git push`                  → ref unknown (use HEAD)
# `git push <remote>`         → ref unknown (use HEAD)
# `git push <remote> <ref>`   → ref = <ref> (dst half of src:dst)
positional = [t for t in push_args if not t.startswith('-')]
if len(positional) >= 2:
    refspec = positional[1]
    branch = refspec.rsplit(':', 1)[-1]
    print(f'push:{branch}')
else:
    print('push:')
PY
)"

verdict="${detect%%:*}"
rest="${detect#*:}"

case "$verdict" in
  ok|dry-run) exit 0 ;;
  push) : ;;
  *) exit 0 ;;  # unknown output, fail open
esac

target_branch="$rest"

if [ -z "$target_branch" ]; then
  if git -C "$project_dir" rev-parse --git-dir >/dev/null 2>&1; then
    target_branch="$(git -C "$project_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  fi
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
