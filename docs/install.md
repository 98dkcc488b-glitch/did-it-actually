# Install walkthrough

## The one-command path

```bash
unzip did-it-actually.zip -d ~/.claude-hooks
~/.claude-hooks/install.sh ~/path/to/your/project
```

`install.sh` edits `~/path/to/your/project/.claude/settings.json`. It:

- creates `.claude/settings.json` if it doesn't exist,
- backs up the existing file to `.claude/settings.json.bak-YYYYMMDD-HHMMSS` if it does,
- merges in four hook entries pointing at the scripts in `~/.claude-hooks/hooks/`,
- is **idempotent** — running it twice does not create duplicates.

Verify:

```bash
jq . ~/path/to/your/project/.claude/settings.json
```

You should see entries for `verify-write.sh`, `block-wrong-branch.sh`, `scope-fence.sh`, `audit-turn.sh`.

## Manual install

If you'd rather not run the installer, add this to your `.claude/settings.json` (adjust paths):

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [{"type": "command", "command": "/absolute/path/to/hooks/verify-write.sh"}]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "/absolute/path/to/hooks/block-wrong-branch.sh"}]
      },
      {
        "matcher": "Edit|Write|MultiEdit",
        "hooks": [{"type": "command", "command": "/absolute/path/to/hooks/scope-fence.sh"}]
      }
    ],
    "Stop": [
      {
        "hooks": [{"type": "command", "command": "/absolute/path/to/hooks/audit-turn.sh"}]
      }
    ]
  }
}
```

The hooks are self-contained — you can drop them anywhere on your filesystem. The `install.sh` script defaults to installing with absolute paths pointing at the extracted ZIP location.

## Verify the guards are fail-closed

The installer sets `"onFailure": "block"` on the three blocking hooks. To confirm the setting actually fails *closed* instead of fail-open, rename a hook script and trigger the guarded action:

```bash
# move verify-write.sh out of the way temporarily
mv .claude/hooks/dia/verify-write.sh .claude/hooks/dia/verify-write.sh.off
```

Then in a Claude Code session, ask Claude to make any edit. You should see the tool call *refused* with a hook error ("failed; blocking because onFailure is \"block\""), not silently waved through. Move the file back when you're done:

```bash
mv .claude/hooks/dia/verify-write.sh.off .claude/hooks/dia/verify-write.sh
```

Repeat for `scope-fence.sh` and `block-wrong-branch.sh` if you want full coverage. This test takes under a minute and is worth doing once after install — otherwise you have no evidence the guards actually fire when broken, and that's the condition that matters most.

## Per-hook configuration

### `verify-write.sh`

No configuration. Reads the file-path field from the hook's `tool_input` payload, runs `git diff` against the index, blocks (exit 2) if there are zero changes.

### `block-wrong-branch.sh`

Reads `.claude/branch-policy.json`:

```json
{
  "allowed_push_branches": ["feature/*", "fix/*", "chore/*"],
  "blocked_push_branches": ["main", "master", "production", "release/*"]
}
```

- If the policy file is missing, the hook stays silent (opt-in by file presence).
- `blocked_push_branches` wins over `allowed_push_branches` when both match.
- Glob patterns use shell-globbing semantics (`*` matches within a path segment).

### `scope-fence.sh`

Reads `.claude/scope.json`:

```json
{
  "allow": ["src/billing/**", "tests/billing/**", "README.md"],
  "deny":  ["**/secrets/**"]
}
```

- Any `Edit`/`Write`/`MultiEdit` on a file outside `allow` is blocked.
- `deny` is checked first and wins on match.
- Paths are relative to the project root (where `.claude/` lives).

### `audit-turn.sh`

No configuration. Reads the `Stop` event's `transcript_path`, extracts filename-like claims from the final assistant message, cross-checks against `.claude/trust-audit.log` entries from this turn, prints a verification summary.

## Uninstall

```bash
~/.claude-hooks/install.sh --uninstall ~/path/to/your/project
```

Restores from the most recent `.bak-*` file. If no backup is found (fresh install), removes only the entries that match our script paths.

## Troubleshooting

**"Hooks don't fire."** Check `claude --help | grep hook` — hooks need Claude Code CLI ≥ 1.0.60. On older CLIs, `.claude/settings.json` is read but `hooks` is ignored silently.

**"Hook times out."** Each hook has a 10-second timeout by default (Claude Code's limit). All four of these hooks finish in under 50 ms on normal repos. If you see timeouts, run `bash -x hooks/verify-write.sh < /tmp/dummy-payload.json` to see where it hangs.

**"Hook keeps blocking a legitimate change."** For `verify-write`, the most common cause is an untracked file — the hook correctly stays silent on untracked paths. If it blocks on a tracked file where you believe you did make a change, `git status --short` is the honest check. If `git` agrees nothing changed, Claude's `Edit` call didn't apply (which is exactly what the hook is for).

**"I want to disable one hook temporarily."** Edit `.claude/settings.json` and remove the entry. Or set `CLAUDE_HOOKS_DISABLED=verify-write,audit-turn` in your shell — all four hooks respect that env var and skip themselves silently.
