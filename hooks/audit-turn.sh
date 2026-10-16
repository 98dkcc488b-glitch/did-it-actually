#!/usr/bin/env bash
# audit-turn.sh — Stop event hook for Claude Code.
#
# Runs at the end of each assistant turn. Reads the session transcript,
# extracts claims of the form "I ... <verb> ..." (added, created, wrote,
# updated, fixed, deleted, pushed, moved, renamed), and compares them to
# the actual file-change log recorded by verify-write.sh (and git status).
#
# Writes a one-line verdict into .claude/trust-audit.log and, when claims
# don't check out, exits 2 to feed a correction prompt back to Claude.
#
# Exit 0 = silent OK or verified · Exit 2 = BLOCK (claim unverified).

set -euo pipefail

case ",${CLAUDE_HOOKS_DISABLED:-}," in *,audit-turn,*|*,all,*) exit 0 ;; esac

payload="$(cat)"
project_dir="${CLAUDE_PROJECT_DIR:-$PWD}"
audit_log="$project_dir/.claude/trust-audit.log"
mkdir -p "$(dirname "$audit_log")"

# Loop guard: Stop payloads carry stop_hook_active=true when a Stop hook has
# already refused to stop once in this turn. If we exit 2 again, Claude Code
# will refuse the stop a second time and we'd loop. Honour the flag.
if printf '%s' "$payload" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    sys.exit(0 if d.get('stop_hook_active') else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
    exit 0
fi

payload_file="$(mktemp)"
trap 'rm -f "$payload_file"' EXIT
printf '%s' "$payload" > "$payload_file"

result="$(python3 - "$project_dir" "$audit_log" "$payload_file" <<'PY'
import json, os, re, subprocess, sys, time

project_dir, audit_log, payload_file = sys.argv[1], sys.argv[2], sys.argv[3]

try:
    with open(payload_file) as f:
        d = json.load(f)
except Exception:
    print("ok:no-payload")
    sys.exit(0)

transcript_path = d.get("transcript_path") or ""
if not transcript_path or not os.path.isfile(transcript_path):
    print("ok:no-transcript")
    sys.exit(0)

# Read the last assistant message from the transcript (JSONL).
last_assistant_text = ""
try:
    with open(transcript_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except Exception:
                continue
            role = msg.get("role") or msg.get("message", {}).get("role")
            if role != "assistant":
                continue
            # Content may be a string or list of blocks.
            content = msg.get("content")
            if content is None:
                content = msg.get("message", {}).get("content")
            if isinstance(content, str):
                last_assistant_text = content
            elif isinstance(content, list):
                parts = []
                for b in content:
                    if isinstance(b, dict) and b.get("type") == "text":
                        parts.append(b.get("text", ""))
                last_assistant_text = "\n".join(parts)
except Exception as e:
    print(f"ok:transcript-unreadable:{e}")
    sys.exit(0)

if not last_assistant_text.strip():
    print("ok:no-assistant-text")
    sys.exit(0)

# Extract claims. Split the assistant text into sentences, then classify.
# A sentence is a "claim" if it contains a first-person perfective verb AND
# at least one filename-looking token.
VERBS = {
    "added", "created", "wrote", "written", "updated", "modified", "edited",
    "fixed", "deleted", "removed", "renamed", "moved", "pushed", "committed",
    "implemented", "refactored",
}
DESTRUCTIVE_VERBS = {"deleted", "removed", "pushed", "committed", "renamed", "moved"}

FILENAME_RE = re.compile(r"[A-Za-z0-9_][A-Za-z0-9_./-]*\.[A-Za-z0-9]{1,8}\b")

def split_sentences(text):
    # Simple sentence splitter: break on period/exclaim/newline followed by space or EOF.
    # Keeps periods inside filenames intact because we don't split mid-token.
    parts = re.split(r"(?<=[.!?])\s+|\n+", text)
    return [p.strip() for p in parts if p.strip()]

claims = []  # list of (verb, sentence, filenames_in_sentence)
for sent in split_sentences(last_assistant_text):
    low = sent.lower()
    verb_hit = None
    for v in VERBS:
        if re.search(rf"\b{v}\b", low):
            verb_hit = v
            break
    if not verb_hit:
        continue
    files = FILENAME_RE.findall(sent)
    claims.append((verb_hit, sent, files))

if not claims:
    print("ok:no-claims")
    sys.exit(0)

# Gather evidence.
# 1) Writes recorded by verify-write.sh in this session.
recent_writes = set()
if os.path.isfile(audit_log):
    cutoff = time.time() - 60 * 60  # last hour window
    try:
        with open(audit_log) as f:
            for line in f:
                parts = line.strip().split("\t")
                if len(parts) >= 3 and parts[1] == "write":
                    recent_writes.add(os.path.basename(parts[2]))
    except Exception:
        pass

# 2) Current git status (uncommitted work).
git_touched = set()
try:
    out = subprocess.run(
        ["git", "-C", project_dir, "status", "--porcelain=v1"],
        capture_output=True, text=True, timeout=5, check=False,
    )
    for line in out.stdout.splitlines():
        if len(line) > 3:
            p = line[3:].strip().split(" -> ")[-1]
            git_touched.add(os.path.basename(p.strip('"')))
except Exception:
    pass

evidence_names = recent_writes | git_touched

verified = []
unverified = []
skipped = []

for verb, sent, files in claims:
    if verb in DESTRUCTIVE_VERBS:
        skipped.append((verb, sent))
        continue
    if not files:
        skipped.append((verb, sent))
        continue
    hit = any(os.path.basename(n) in evidence_names for n in files)
    if hit:
        verified.append((verb, sent))
    else:
        unverified.append((verb, sent, files))

# Record outcome.
try:
    with open(audit_log, "a") as f:
        f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\taudit\t"
                f"claims={len(claims)}\tverified={len(verified)}\t"
                f"unverified={len(unverified)}\tskipped={len(skipped)}\n")
except Exception:
    pass

if unverified:
    lines = ["[trust-but-verify] Audit found claims that don't match actual file changes:"]
    for verb, sent, names in unverified[:5]:
        snippet = sent if len(sent) <= 120 else sent[:117] + "..."
        lines.append(f"  - [{verb}] \"{snippet}\" — files mentioned {names} not in write log.")
    lines.append("")
    lines.append("Either (a) actually make the change, or (b) correct your previous message to say the change was NOT made and why.")
    print("block:" + "\n".join(lines))
    sys.exit(0)

print(f"ok:verified={len(verified)} skipped={len(skipped)}")
PY
)"

if [ "${result%%:*}" = "block" ]; then
  printf '%s\n' "${result#block:}" >&2
  exit 2
fi

exit 0
