#!/usr/bin/env bash
# install.sh — Install the Did-It-Actually hooks into a Claude Code project.
#
# Usage, from the directory of the project you want to protect:
#   /path/to/this-pack/install.sh
#
# What it does:
#   1. Copies hooks/*.sh into <project>/.claude/hooks/dia/ (keeps your other hooks untouched).
#   2. Merges the four hook entries into <project>/.claude/settings.json, creating a
#      timestamped backup first (settings.json.bak-YYYYMMDD-HHMMSS). Non-destructive:
#      your existing hooks and settings are preserved.
#   3. Writes sample .claude/branch-policy.json and .claude/scope.json if they are
#      missing (both commented out by default — scope.json ships empty so nothing is
#      fenced until you decide).
#   4. Prints next steps.
#
# Uninstall: remove the four entries from .claude/settings.json and delete
# .claude/hooks/dia/. settings.json.bak-* is left for you to restore.

set -euo pipefail

if [ -t 1 ]; then
  B='\033[1m'; R='\033[0m'; G='\033[32m'; Y='\033[33m'
else
  B=''; R=''; G=''; Y=''
fi

self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hooks_src="$self_dir/hooks"
project_dir="${1:-$PWD}"

if [ ! -d "$hooks_src" ]; then
  echo "Could not find hooks/ next to install.sh ($hooks_src)." >&2
  exit 1
fi

echo -e "${B}Did-It-Actually — installing into $project_dir${R}"
echo

claude_dir="$project_dir/.claude"
dest="$claude_dir/hooks/dia"
mkdir -p "$dest"
cp -f "$hooks_src"/*.sh "$dest/"
cp -f "$hooks_src"/trust-report "$dest/"
chmod +x "$dest"/*.sh "$dest/trust-report"
echo -e "  ${G}✓${R} hooks copied to .claude/hooks/dia/"

settings="$claude_dir/settings.json"
backup=""
if [ -f "$settings" ]; then
  backup="$settings.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$settings" "$backup"
  echo -e "  ${G}✓${R} backup written to $(basename "$backup")"
else
  echo "{}" > "$settings"
fi

python3 - "$settings" "$dest" <<'PY'
import json, os, sys

settings_path, dest = sys.argv[1], sys.argv[2]
with open(settings_path) as f:
    try:
        s = json.load(f)
    except Exception:
        s = {}
if not isinstance(s, dict):
    s = {}

hooks = s.setdefault("hooks", {})
def ensure_entry(event, matcher, command):
    arr = hooks.setdefault(event, [])
    # Dedupe: skip if the exact command is already present.
    for group in arr:
        for h in group.get("hooks", []):
            if h.get("command") == command:
                return False
    arr.append({"matcher": matcher, "hooks": [{"type": "command", "command": command}]})
    return True

added = []
if ensure_entry("PreToolUse",  "Bash",             os.path.join(dest, "block-wrong-branch.sh")):
    added.append("PreToolUse/Bash → block-wrong-branch")
if ensure_entry("PreToolUse",  "Edit|Write|MultiEdit", os.path.join(dest, "scope-fence.sh")):
    added.append("PreToolUse/Edit* → scope-fence")
if ensure_entry("PostToolUse", "Edit|Write|MultiEdit", os.path.join(dest, "verify-write.sh")):
    added.append("PostToolUse/Edit* → verify-write")
if ensure_entry("Stop",        "",                 os.path.join(dest, "audit-turn.sh")):
    added.append("Stop → audit-turn")

with open(settings_path, "w") as f:
    json.dump(s, f, indent=2)
    f.write("\n")

for a in added:
    print(f"  \033[32m✓\033[0m hook registered: {a}")
if not added:
    print("  \033[33m•\033[0m all four hooks already registered — nothing to add")
PY

# Sample policy files, only create if missing.
if [ ! -f "$claude_dir/branch-policy.json" ]; then
  cat > "$claude_dir/branch-policy.json" <<'JSON'
{
  "_comment": "Which branches is Claude allowed to push to? Patterns are fnmatch-style (shell globs).",
  "allowed_push_branches": ["feature/*", "fix/*", "chore/*"],
  "blocked_push_branches": ["main", "master", "production", "release/*"]
}
JSON
  echo -e "  ${G}✓${R} sample .claude/branch-policy.json created (edit to taste)"
else
  echo -e "  ${Y}•${R} .claude/branch-policy.json already exists — not touched"
fi

if [ ! -f "$claude_dir/scope.json" ]; then
  cat > "$claude_dir/scope.json.sample" <<'JSON'
{
  "_comment": "Rename to scope.json to activate. Edits are blocked outside allow / inside deny.",
  "allow": ["src/**", "tests/**"],
  "deny":  ["src/legacy/**", ".env*", "secrets/**"]
}
JSON
  echo -e "  ${G}✓${R} sample .claude/scope.json.sample created (rename to activate)"
fi

cat <<EOF

${B}Done.${R}

Next steps:
  1. Start a Claude Code session in this project. The hooks run on every turn.
  2. See the audit log live:   tail -f .claude/trust-audit.log
  3. Weekly report:            .claude/hooks/dia/trust-report --last 7d

If something is wrong, the stderr from each hook is fed back to Claude. You will
see it as a "correction prompt" in the next turn.
EOF
