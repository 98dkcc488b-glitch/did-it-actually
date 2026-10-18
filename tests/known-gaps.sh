#!/usr/bin/env bash
# known-gaps.sh — demonstrates known weaknesses in the current hooks.
#
# Not run by run-tests.sh. Each case prints what WOULD be the right behaviour
# and what the current hook actually does. When a fix lands, convert the case
# into a regression test in run-tests.sh.

set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks"

echo "=== Known gap 1: audit-turn — 'right file, wrong change' false positive ==="
echo "Origin: @launchgatecheck comment on Day-5 article (2026-10-17)."
echo "Expected: claim 'I fixed X in file.ts' should be flagged if the actual diff doesn't touch X."
echo "Actual: claim is accepted if file.ts has ANY write event this session, regardless of what was written."
echo

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
cd "$workdir"
git init -q
git config user.email test@example.com
git config user.name  Test
cat > retry.py <<'PY'
def retry(fn, max_attempts=5):
    for i in range(max_attempts):
        try:
            return fn()
        except Exception:
            continue
PY
git add retry.py
git commit -q -m init
mkdir -p .claude

transcript="$workdir/transcript.jsonl"
cat > "$transcript" <<'JSONL'
{"role":"assistant","content":[{"type":"text","text":"I fixed the timeout in retry.py. The retries now give up after 30 seconds."}]}
JSONL

# Case A: retry.py was NEVER written this session → should BLOCK (and does)
: > .claude/trust-audit.log
payload=$(printf '{"transcript_path":"%s"}' "$transcript")
set +e
echo "$payload" | CLAUDE_PROJECT_DIR="$workdir" "$HOOKS_DIR/audit-turn.sh" 2>/dev/null
rc_a=$?
set -e
echo "Case A (retry.py untouched):  exit=$rc_a  — expected 2 (BLOCK), got $rc_a $([ $rc_a -eq 2 ] && echo '[OK]' || echo '[GAP]')"

# Case B: retry.py was written (unrelated change) → should still BLOCK but DOESN'T
echo "# comment added" >> retry.py
printf '%s\twrite\t%s/retry.py\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$workdir" >> .claude/trust-audit.log
set +e
echo "$payload" | CLAUDE_PROJECT_DIR="$workdir" "$HOOKS_DIR/audit-turn.sh" 2>/dev/null
rc_b=$?
set -e
echo "Case B (retry.py had unrelated write): exit=$rc_b — expected 2 (BLOCK), got $rc_b $([ $rc_b -eq 2 ] && echo '[OK]' || echo '[GAP: false positive — claim verified]')"

echo
echo "Design options being considered (none shipped):"
echo "  1. Agent emits '## Changes' block declaring per-file semantics; hook flags symmetric diff."
echo "  2. Keyword match: claim verbs/nouns must appear in the actual diff."
echo
exit 0
