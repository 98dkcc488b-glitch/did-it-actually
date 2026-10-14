# Example 01 — Caught no-op edit

**Scenario.** You ask Claude Code to tighten a regex. Claude says it did. The file is unchanged.

This is the single most common failure mode we hear about on r/ClaudeAI: *"Claude said it fixed the bug, but when I ran the tests, same error."*

## The task

A tiny Python file, `parser.py`:

```python
import re

SKU_RE = re.compile(r"^[A-Z]{3}\d{4}$")

def is_valid_sku(s: str) -> bool:
    return bool(SKU_RE.match(s))
```

Prompt to Claude:

> The regex should also accept SKUs with a hyphen before the digits, like `ABC-1234`. Update `parser.py`.

## Without `verify-write.sh` — what happens today

Claude's turn (abridged):

```
> I'll update the regex to accept an optional hyphen.
> [Edit tool: parser.py]
>   old_string: r"^[A-Z]{3}\d{4}$"
>   new_string: r"^[A-Z]{3}-?\d{4}$"
> Done. The regex now accepts optional hyphens.
```

But — in this particular session — Claude's `old_string` had a trailing space it couldn't see, the Edit failed silently to apply, and Claude printed success anyway. (This is a real failure mode: Claude's `Edit` tool returns a result dict that Claude sometimes misreads.)

You find out an hour later, when your tests still fail.

## With `verify-write.sh` installed

Same prompt, same session. After Claude's `Edit` call, the `PostToolUse` hook fires. It reads the file path from the tool payload, checks `git diff` against the index — and sees zero changes.

Claude's own context now includes this (fed back as a correction prompt via `stderr` + exit 2):

```
[trust-but-verify] You just edited /tmp/repo/parser.py but git shows ZERO changes
against the index/HEAD. This usually means one of:
  1. You wrote the same bytes that were already there.
  2. The Edit old_string/new_string pair cancelled out.
  3. You believe you edited the file but didn't.
Re-check your intended change, run a real diff, and either make the change
or state clearly that no change was needed.
```

Claude's next action:

```
> You're right — the Edit didn't apply. Let me read the file and re-try with
> the exact bytes.
> [Read tool: parser.py]
> [Edit tool: parser.py]
>   (new old_string with the exact bytes from the read)
> [verify-write passes silently]
> Confirmed: parser.py now contains the updated regex.
```

The lie didn't ship. You didn't have to notice.

## How the check works (10 lines)

```bash
# verify-write.sh — the core logic
if git diff --quiet -- "$rel" && git diff --cached --quiet -- "$rel"; then
    echo "[trust-but-verify] You just edited $file but git shows ZERO changes..." >&2
    exit 2  # tells Claude Code: block, feed stderr back to Claude.
fi
```

The hook is honest about *why* this might have happened — the correction prompt doesn't accuse Claude of lying, it lists the three plausible causes and asks for a re-check. That phrasing is deliberate: it keeps Claude from doubling down and instead triggers a fresh read.

## When the hook is quiet

If your edit is a legitimate no-op (idempotency check, re-formatting with the same formatter), you'll want to tell Claude to say so explicitly ("confirm no change was needed") instead of claiming an edit. The hook's correction prompt literally offers that as option 3.

## Trade-offs

- **False positives** can happen when you edit a file that isn't tracked by git. The hook detects this and stays silent.
- **Non-git repos** aren't covered. (We think that's rare enough to be an acceptable gap for v1.)
- **Streaming edits** (long MultiEdit sequences) only check once at the end of each tool call — which is where Claude's own self-report happens, so that's the right place.
