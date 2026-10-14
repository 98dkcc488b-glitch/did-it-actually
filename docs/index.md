---
layout: default
title: "How I stopped Claude Code from lying about finishing tasks"
description: "Four hooks + an audit CLI that catch the gap between what Claude says and what Claude did — automatically, every turn."
---

# How I stopped Claude Code from lying about finishing tasks (4 hooks, 150 lines of bash)

Last month Claude Code told me it had added a regression test. The commit landed. The PR merged. Two days later a bug slipped through — the test wasn't actually there. The agent had claimed the work, generated a convincing diff summary at the end of the turn, and the tool-call log looked clean. But `git log -p` showed nothing new in the test file.

That is a specific failure mode worth naming. The model doesn't hallucinate in the "makes up an API" sense. It hallucinates in the "narrates work that didn't happen" sense. Edits silently drop. `write_file` collapses to a no-op because the content it generated already matched the file. Branch names drift. And the summary at the end of the turn confidently reports what *should* have happened, not what actually did.

I built a small trust-but-verify layer that catches these at the hook boundary instead of in production. Four hooks, pure bash, zero runtime dependencies. Here's how each one works, and the one non-obvious thing I learned while writing it.

## The one Claude Code hook contract fact everything hangs on

Claude Code hooks have an [exit-code contract](https://docs.claude.com/claude-code/hooks) you can use to intervene before and after tool calls. The part worth memorizing is this:

- **Exit 0** — allow the tool call, swallow stderr.
- **Exit 2** — block the tool call, and feed stderr back to the model as a correction prompt.

Exit 2 is the whole trick. Your hook doesn't just log a complaint — it tells the model, in-band, why its action was rejected and what to do instead. The model sees your stderr the way it would see any other tool result, and corrects. The agent doesn't need to know a hook exists; it just experiences a world where some actions get a clear "that didn't work, here's why" response.

Once you internalize that, you stop writing "warnings" and start writing hooks that **shape the agent's next move**.

## Hook 1: verify-write

A `PostToolUse` hook on `Edit` and `Write`. It checks whether the tool call produced any actual change in the working tree.

```bash
# simplified
staged_before="$CLAUDE_PRE_TOOL_DIFF"   # captured by a sibling PreToolUse
staged_after=$(git diff HEAD -- "$file")

if [ "$staged_before" = "$staged_after" ]; then
  echo "verify-write: the edit of $file produced no change." >&2
  echo "If the file already contained what you intended, say so explicitly instead of re-editing." >&2
  exit 2
fi
```

Three failure modes it catches in practice:

1. **The no-op edit.** The model's `old_string` and `new_string` are identical modulo whitespace, so the file writes identical bytes.
2. **The convinced-already edit.** The content the model "wanted" to add is already in the file (common after a prior rewrite), so the apply succeeds but changes nothing.
3. **The wrong-file edit.** The model edits a backup or a `.bak` and still reports "updated X".

The non-obvious part: you can't just compare bytes before and after the tool call. Normalization matters. A trailing-newline-only diff is almost always semantic noise and should not count. A whitespace-only diff is a judgment call — I treat it as a real diff by default, because if the model *intended* a whitespace fix, that's work. But I expose a config flag so a team can tighten it.

## Hook 2: block-wrong-branch

A `PreToolUse` hook on `Bash` that matches `git push` and checks whether the current branch is in an allowlist.

```bash
if [[ "$CLAUDE_TOOL_INPUT" =~ "git push" ]]; then
  branch=$(git rev-parse --abbrev-ref HEAD)
  allowed=$(jq -r '.allowed_push_branches[]' .claude/config.json 2>/dev/null)
  if ! grep -qx "$branch" <<< "$allowed"; then
    echo "block-wrong-branch: refusing to push $branch." >&2
    echo "This repo only pushes from: $(echo $allowed | tr '\n' ' ')" >&2
    exit 2
  fi
fi
```

I wrote this after Claude Code pushed what it believed was a feature branch, which was actually `main`, because it had checked out a different branch halfway through the session and lost track. The hook refuses the push and tells the model what the allowlist is — so the next thing it does is check out the right branch, not re-attempt the same push.

## Hook 3: scope-fence

A `SessionStart` hook that writes a declared-scope file (`.claude/.current-scope`) and a `PreToolUse` hook on `Edit`/`Write` that rejects any edit to a path outside the fence.

```bash
# PreToolUse
target=$(jq -r '.file_path' <<< "$CLAUDE_TOOL_INPUT")
fence=$(cat .claude/.current-scope 2>/dev/null)
if [ -n "$fence" ] && ! [[ "$target" =~ ^($fence)$ ]]; then
  echo "scope-fence: $target is outside the declared scope." >&2
  echo "Current scope: $fence" >&2
  echo "If this edit is intentional, update the scope explicitly." >&2
  exit 2
fi
```

The fence is a regex set during session start — "today I'm touching `src/auth/.*` and `tests/auth/.*`". When Claude Code decides mid-session that it also needs to refactor the ORM layer, the hook catches it. The point isn't that cross-cutting edits are always wrong. The point is that they should be *acknowledged*. If the agent has to re-declare the scope out loud, I at least get to see it coming instead of discovering it in the diff three turns later.

## Hook 4: audit-turn

A `Stop` hook (runs at the end of a turn, after the final assistant message). It parses the last message for first-person claims — "I added …", "I fixed …", "the tests now pass" — and checks each one against reality:

- "I added `X`" → does `git diff` show additions in `X`?
- "The tests now pass" → was there a successful test run in the tool-call log for this turn?
- "I pushed to `branch`" → does `git log origin/branch..HEAD` show the commit?

Mismatches get logged to `.claude/trust-log.jsonl` and surfaced the next session. The hook doesn't exit 2 here — the turn is already over — but the log feeds a `trust-report` CLI that prints a rolling claim-match ratio per repo per week.

I started at 71% in the first week. After two weeks of the first three hooks nudging the agent toward actually doing what it said, the ratio climbed to 94%. Not because the model got better — it's the same model — but because the hooks remove the low-friction path to "lying by narration".

## The one surprising lesson

**Writing the no-op detector was the hardest part**, and I didn't expect that. Deciding what counts as a "real change" has three or four edge cases that each deserve their own test:

- whitespace-only edits
- trailing-newline-only edits
- semantically equivalent reformats (e.g. the model moves an import, nothing else)
- `write_file` that recreates an identical file after a `read_file`

I ended up shipping 26 integration tests just for the four hooks and the install script, because I couldn't trust the hooks until I'd seen them pass and fail on known inputs. If you build your own, test them. The whole point is to be the thing you trust when you've stopped trusting the model's self-report; your hooks have to earn that trust.

## Install

If you want to try it on an existing repo, I've packaged the four hooks plus the `trust-report` CLI as **[Did-It-Actually on Gumroad](https://dumkestar6.gumroad.com/l/vicuep)**. The install script safely merges into `.claude/settings.json` with a backup, so you can reverse it. MIT license, 25 KB zip, works with Claude Code ≥ 1.0.60.

If you'd rather just read the no-op detector and crib the idea, the full source is on [GitHub](https://github.com/98dkcc488b-glitch/did-it-actually).

Happy to answer questions — how I handle false positives on whitespace, how the audit-turn parser handles conditional claims ("I think this should pass"), or how to adapt the scope fence for monorepos where "scope" is multiple packages at once.

---

[Get Did-It-Actually on Gumroad →](https://dumkestar6.gumroad.com/l/vicuep)
