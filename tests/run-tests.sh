#!/usr/bin/env bash
# run-tests.sh — Integration tests for the four hooks + install.sh.
# Builds a throwaway git repo in a temp dir and feeds the hooks real JSON
# payloads matching the Claude Code hook contract.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks"
PACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
RED='\033[31m'; GREEN='\033[32m'; CLR='\033[0m'

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then
    echo -e "  ${GREEN}PASS${CLR} $name"
    pass=$((pass+1))
  else
    echo -e "  ${RED}FAIL${CLR} $name — expected exit $expected, got $actual"
    fail=$((fail+1))
  fi
}

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"
git init -q
git config user.email test@example.com
git config user.name  Test
echo "orig" > hello.txt
git add hello.txt
git commit -q -m initial
mkdir -p .claude

export CLAUDE_PROJECT_DIR="$workdir"

echo "=== Hook 1: verify-write.sh ==="

# 1a. Real change → exit 0
echo "changed" > hello.txt
payload=$(printf '{"tool_input":{"file_path":"%s/hello.txt"}}' "$workdir")
set +e
echo "$payload" | "$HOOKS_DIR/verify-write.sh" 2>/dev/null
rc=$?
set -e
check "verify-write accepts real change" 0 "$rc"

# 1b. No-op change (same content as HEAD) → exit 2
git checkout -q -- hello.txt
payload=$(printf '{"tool_input":{"file_path":"%s/hello.txt"}}' "$workdir")
set +e
echo "$payload" | "$HOOKS_DIR/verify-write.sh" 2>/dev/null
rc=$?
set -e
check "verify-write blocks no-op edit" 2 "$rc"

# 1c. New untracked file → exit 0 (nothing in index yet, but file exists)
echo "new" > brandnew.txt
payload=$(printf '{"tool_input":{"file_path":"%s/brandnew.txt"}}' "$workdir")
set +e
echo "$payload" | "$HOOKS_DIR/verify-write.sh" 2>/dev/null
rc=$?
set -e
check "verify-write accepts untracked new file" 0 "$rc"

echo "=== Hook 2: block-wrong-branch.sh ==="

cat > .claude/branch-policy.json <<'JSON'
{"allowed_push_branches": ["feature/*"], "blocked_push_branches": ["main"]}
JSON

# 2a. push to main → block
payload='{"tool_input":{"command":"git push origin main"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch blocks git push origin main" 2 "$rc"

# 2b. push to feature/x → allow
payload='{"tool_input":{"command":"git push origin feature/foo"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch allows feature/*" 0 "$rc"

# 2c. push to other branch not in allow-list → block
payload='{"tool_input":{"command":"git push origin develop"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch blocks non-allowed branch" 2 "$rc"

# 2d. --dry-run bypass
payload='{"tool_input":{"command":"git push --dry-run origin main"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch ignores --dry-run" 0 "$rc"

# 2e. unrelated bash command → allow
payload='{"tool_input":{"command":"ls -la"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch ignores non-push commands" 0 "$rc"

# 2f. no policy file → allow
rm .claude/branch-policy.json
payload='{"tool_input":{"command":"git push origin main"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch is silent when no policy" 0 "$rc"

# v1.4 regression tests — launchgatecheck's Dev.to report (Oct 16).
cat > .claude/branch-policy.json <<'JSON'
{"allowed_push_branches": ["feature/*"], "blocked_push_branches": ["main"]}
JSON

# 2g. TAB-separated `git<TAB>push` → still blocked (JSON uses \t escape;
#     shlex normalises whitespace, so `git` and `push` end up as adjacent tokens)
payload='{"tool_input":{"command":"git\tpush origin main"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch blocks tab-separated git<TAB>push" 2 "$rc"

# 2h. `printf 'git push origin main'` → NOT a push, allow
payload=$(printf '{"tool_input":{"command":"printf %%s %sgit push origin main%s"}}' "'" "'")
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch skips printf of literal git-push string" 0 "$rc"

# 2i. `echo "git push origin main"` → NOT a push, allow
payload='{"tool_input":{"command":"echo \"git push origin main\""}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch skips echo of literal git-push string" 0 "$rc"

# 2j. env var prefix: `GIT_SSH=... git push origin main` → still blocked
payload='{"tool_input":{"command":"GIT_SSH_COMMAND=ssh git push origin main"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch blocks env-prefixed git push" 2 "$rc"

# 2k. chained: `ls && git push origin main` → still blocked (second fragment)
payload='{"tool_input":{"command":"ls && git push origin main"}}'
set +e; echo "$payload" | "$HOOKS_DIR/block-wrong-branch.sh" 2>/dev/null; rc=$?; set -e
check "block-wrong-branch blocks git push after && chain" 2 "$rc"

echo "=== Hook 3: scope-fence.sh ==="

cat > .claude/scope.json <<'JSON'
{"allow": ["src/**"], "deny": ["src/legacy/**", ".env"]}
JSON
mkdir -p src/components src/legacy
touch src/components/button.tsx src/legacy/old.ts .env README.md

# 3a. in allow → OK
payload=$(printf '{"tool_input":{"file_path":"%s/src/components/button.tsx"}}' "$workdir")
set +e; echo "$payload" | "$HOOKS_DIR/scope-fence.sh" 2>/dev/null; rc=$?; set -e
check "scope-fence allows in-scope edit" 0 "$rc"

# 3b. not in allow → BLOCK
payload=$(printf '{"tool_input":{"file_path":"%s/README.md"}}' "$workdir")
set +e; echo "$payload" | "$HOOKS_DIR/scope-fence.sh" 2>/dev/null; rc=$?; set -e
check "scope-fence blocks out-of-scope edit" 2 "$rc"

# 3c. denied path (overrides allow) → BLOCK
payload=$(printf '{"tool_input":{"file_path":"%s/src/legacy/old.ts"}}' "$workdir")
set +e; echo "$payload" | "$HOOKS_DIR/scope-fence.sh" 2>/dev/null; rc=$?; set -e
check "scope-fence blocks denied path" 2 "$rc"

# 3d. .env blocked explicitly
payload=$(printf '{"tool_input":{"file_path":"%s/.env"}}' "$workdir")
set +e; echo "$payload" | "$HOOKS_DIR/scope-fence.sh" 2>/dev/null; rc=$?; set -e
check "scope-fence blocks .env" 2 "$rc"

# 3e. no scope file → OK regardless
rm .claude/scope.json
payload=$(printf '{"tool_input":{"file_path":"%s/README.md"}}' "$workdir")
set +e; echo "$payload" | "$HOOKS_DIR/scope-fence.sh" 2>/dev/null; rc=$?; set -e
check "scope-fence inert without scope.json" 0 "$rc"

echo "=== Hook 4: audit-turn.sh ==="

# Set up a fake transcript (JSONL) and audit log pretending a write happened.
transcript="$workdir/transcript.jsonl"

# 4a. Claim matches a recorded write → OK
cat > "$transcript" <<'JSONL'
{"role":"user","content":"please add foo"}
{"role":"assistant","content":[{"type":"text","text":"I added a test in tests/foo.test.ts and updated src/foo.ts."}]}
JSONL
mkdir -p .claude
printf '%s\twrite\t%s/src/foo.ts\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$workdir" >  .claude/trust-audit.log
printf '%s\twrite\t%s/tests/foo.test.ts\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$workdir" >> .claude/trust-audit.log
payload=$(printf '{"transcript_path":"%s"}' "$transcript")
set +e; echo "$payload" | "$HOOKS_DIR/audit-turn.sh" 2>/dev/null; rc=$?; set -e
check "audit-turn verifies matching claims" 0 "$rc"

# 4b. Claim refers to file that was never written → BLOCK
cat > "$transcript" <<'JSONL'
{"role":"assistant","content":[{"type":"text","text":"I created ghost.ts with the fix."}]}
JSONL
: > .claude/trust-audit.log  # empty write log
payload=$(printf '{"transcript_path":"%s"}' "$transcript")
set +e; echo "$payload" | "$HOOKS_DIR/audit-turn.sh" 2>/dev/null; rc=$?; set -e
check "audit-turn blocks unverified claim" 2 "$rc"

# 4c. No filename in claim → skip (OK)
cat > "$transcript" <<'JSONL'
{"role":"assistant","content":[{"type":"text","text":"I added some helpful comments."}]}
JSONL
: > .claude/trust-audit.log
payload=$(printf '{"transcript_path":"%s"}' "$transcript")
set +e; echo "$payload" | "$HOOKS_DIR/audit-turn.sh" 2>/dev/null; rc=$?; set -e
check "audit-turn skips claim without filename" 0 "$rc"

# 4d. Destructive claim ("deleted X") → skip (we don't record deletes yet)
cat > "$transcript" <<'JSONL'
{"role":"assistant","content":[{"type":"text","text":"I deleted old.ts."}]}
JSONL
: > .claude/trust-audit.log
payload=$(printf '{"transcript_path":"%s"}' "$transcript")
set +e; echo "$payload" | "$HOOKS_DIR/audit-turn.sh" 2>/dev/null; rc=$?; set -e
check "audit-turn skips destructive claims" 0 "$rc"

echo "=== trust-report CLI ==="

printf '%s\tapt\twrite\t%s/foo.ts\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$workdir" > /dev/null  # noop
cat > .claude/trust-audit.log <<EOF
2026-10-13T10:00:00Z	write	$workdir/foo.ts
2026-10-13T10:00:01Z	audit	claims=3	verified=2	unverified=1	skipped=0
EOF
set +e
out=$("$HOOKS_DIR/trust-report" 2>&1); rc=$?
set -e
if [ $rc -eq 0 ] && echo "$out" | grep -q "Unverified-claim rate"; then
  echo -e "  ${GREEN}PASS${CLR} trust-report renders stats"
  pass=$((pass+1))
else
  echo -e "  ${RED}FAIL${CLR} trust-report — rc=$rc output=$out"
  fail=$((fail+1))
fi

echo "=== install.sh ==="

installdir="$(mktemp -d)"
cd "$installdir"
git init -q
git config user.email test@example.com
git config user.name  Test
# Pre-existing settings.json with an unrelated hook
cat > .claude.setup.sh <<EOF
mkdir -p .claude
cat > .claude/settings.json <<'JSON'
{"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": [{"type":"command","command":"/some/other.sh"}]}]}}
JSON
EOF
mkdir -p .claude
cat > .claude/settings.json <<'JSON'
{"hooks": {"PostToolUse": [{"matcher": "Bash", "hooks": [{"type":"command","command":"/some/other.sh"}]}]}}
JSON

set +e
out=$("$PACK_DIR/install.sh" "$installdir" 2>&1); rc=$?
set -e
if [ $rc -ne 0 ]; then
  echo -e "  ${RED}FAIL${CLR} install.sh — rc=$rc output:\n$out"
  fail=$((fail+1))
else
  # Verify: existing hook preserved, four new entries present, backup made.
  if ! grep -q "/some/other.sh" .claude/settings.json; then
    echo -e "  ${RED}FAIL${CLR} install.sh overwrote existing hook"
    fail=$((fail+1))
  else
    echo -e "  ${GREEN}PASS${CLR} install.sh preserved pre-existing hook"
    pass=$((pass+1))
  fi
  for name in verify-write.sh block-wrong-branch.sh scope-fence.sh audit-turn.sh; do
    if grep -q "$name" .claude/settings.json; then
      echo -e "  ${GREEN}PASS${CLR} install.sh registered $name"
      pass=$((pass+1))
    else
      echo -e "  ${RED}FAIL${CLR} install.sh missed $name"
      fail=$((fail+1))
    fi
  done
  if ls .claude/settings.json.bak-* >/dev/null 2>&1; then
    echo -e "  ${GREEN}PASS${CLR} install.sh created backup"
    pass=$((pass+1))
  else
    echo -e "  ${RED}FAIL${CLR} install.sh did NOT create backup"
    fail=$((fail+1))
  fi

  # Idempotency: run again, should not add duplicates.
  "$PACK_DIR/install.sh" "$installdir" >/dev/null 2>&1
  count=$(grep -c "verify-write.sh" .claude/settings.json || true)
  if [ "$count" = "1" ]; then
    echo -e "  ${GREEN}PASS${CLR} install.sh is idempotent"
    pass=$((pass+1))
  else
    echo -e "  ${RED}FAIL${CLR} install.sh is NOT idempotent (verify-write.sh count=$count)"
    fail=$((fail+1))
  fi
fi
rm -rf "$installdir"

echo
echo "============================="
echo "  $pass passed, $fail failed"
echo "============================="
[ "$fail" -eq 0 ]
