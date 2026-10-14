#!/usr/bin/env bash
# verify-write.sh — PostToolUse hook for Claude Code (Edit, Write, MultiEdit)
#
# Catches when Claude claims to have edited a file but the file didn't actually change.
# Reads the tool_input JSON from stdin (Claude Code hook contract).
# Exit 0  = silent OK
# Exit 2  = BLOCK and feed stderr back to Claude as a correction prompt.
#
# Install: see install.sh in the parent folder, or add manually to .claude/settings.json:
#   {
#     "hooks": {
#       "PostToolUse": [
#         { "matcher": "Edit|Write|MultiEdit",
#           "hooks": [{"type": "command", "command": "/path/to/verify-write.sh"}] }
#       ]
#     }
#   }

set -euo pipefail

case ",${CLAUDE_HOOKS_DISABLED:-}," in *,verify-write,*|*,all,*) exit 0 ;; esac

payload="$(cat)"

# Extract file path from tool_input. Supports Edit, Write, MultiEdit.
file_path="$(printf '%s' "$payload" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    ti = d.get('tool_input', {})
    print(ti.get('file_path') or ti.get('path') or '')
except Exception:
    print('')
")"

if [ -z "$file_path" ] || [ ! -f "$file_path" ]; then
  # Nothing to verify (new-file write will be a file; missing = odd but not our problem).
  exit 0
fi

# Record the write for the end-of-turn audit (if the audit hook is also installed).
audit_log="${CLAUDE_PROJECT_DIR:-$PWD}/.claude/trust-audit.log"
mkdir -p "$(dirname "$audit_log")"
printf '%s\twrite\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$file_path" >> "$audit_log"

# If the file is tracked by git, verify it actually differs from HEAD or the index.
if git -C "$(dirname "$file_path")" rev-parse --git-dir >/dev/null 2>&1; then
  rel="$(git -C "$(dirname "$file_path")" ls-files --full-name -- "$(basename "$file_path")" 2>/dev/null || true)"
  if [ -n "$rel" ]; then
    repo_root="$(git -C "$(dirname "$file_path")" rev-parse --show-toplevel)"
    # Compare working tree to index. If nothing is staged OR changed, flag it.
    if git -C "$repo_root" diff --quiet -- "$rel" && git -C "$repo_root" diff --cached --quiet -- "$rel"; then
      cat >&2 <<EOF
[trust-but-verify] You just edited ${file_path} but git shows ZERO changes against the index/HEAD.
This usually means one of:
  1. You wrote the same bytes that were already there.
  2. The Edit old_string/new_string pair cancelled out.
  3. You believe you edited the file but didn't.
Re-check your intended change, run a real diff, and either make the change or state clearly that no change was needed.
EOF
      exit 2
    fi
  fi
fi

exit 0
