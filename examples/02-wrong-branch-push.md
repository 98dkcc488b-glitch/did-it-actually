# Example 02 — Blocked push to the wrong branch

**Scenario.** You told Claude "work on a feature branch and push there when green." Mid-session, Claude forgets, runs `git push origin main`, and your protected-branch rules on the server are... not quite as strict as you thought.

This one shows up on r/ClaudeAI every few weeks. Someone wakes up to `main` on fire because Claude Code pushed a half-finished rewrite over night.

## Setup

Your `.claude/branch-policy.json`:

```json
{
  "allowed_push_branches": ["feature/*", "fix/*", "chore/*"],
  "blocked_push_branches": ["main", "master", "production", "release/*"]
}
```

You start the session with:

> Create a `feature/csv-export` branch, implement the new CSV exporter, run tests, and push when they pass.

## Mid-session — the drift happens

Claude starts well. It branches, writes code, runs tests. Around the 20th tool call it does this:

```
> Tests pass. Pushing to feature branch now.
> [Bash tool]
>   git push origin main   # ← wrong branch, Claude is on main because it checked something out
```

## Without `block-wrong-branch.sh`

The push goes through. On GitHub, `main` is now at a commit that nobody reviewed. If `main` is deploy-tracked, you're deploying to prod.

## With `block-wrong-branch.sh` installed

The `PreToolUse` hook on `Bash` sees `git push`, parses the ref, compares to the policy. It blocks:

```
[branch-policy] Refused: pushing to 'main' is forbidden by .claude/branch-policy.json.

Allowed patterns: feature/*, fix/*, chore/*
Blocked:          main, master, production, release/*

Fix: switch to a branch matching one of the allowed patterns (e.g.
'git checkout -b feature/csv-export') and retry. If the push to main is
actually intended, update the policy file or run the push manually outside
Claude Code.
```

Exit 2. The Bash call doesn't run. Claude reads the correction, says "right, I'd drifted to main — switching back":

```
> [Bash: git checkout feature/csv-export]
> [Bash: git push origin feature/csv-export]  → allowed, succeeds
```

## How the matching works

The hook supports glob patterns in both `allowed_push_branches` and `blocked_push_branches`. Rules of precedence:

1. If the pushed ref matches **anything** in `blocked_push_branches` → **block**.
2. Else if `allowed_push_branches` is set and the ref matches **nothing** in it → **block**.
3. Else allow.

`blocked_push_branches` wins over `allowed_push_branches` when both match — so a policy like `{"allowed_push_branches": ["*"], "blocked_push_branches": ["main"]}` ("allow everything except main") does what you expect.

The hook recognises these push forms:

- `git push`
- `git push origin feature/x`
- `git push origin HEAD:main`
- `git push --force origin main`
- `git push -u origin main`
- `git push` (uses the configured upstream — hook resolves it via `git rev-parse`)

## Trade-offs

- **Not a replacement for server-side protection.** Branch-protection rules on GitHub/GitLab are the real safety net. This hook is the near-side guard — it catches the mistake before it leaves your machine, which is cheaper than a protected-branch rejection + Claude trying three creative workarounds.
- **Policy drift.** If you edit `.claude/branch-policy.json` mid-session, Claude's cached picture of "where it's allowed to push" doesn't update until it reads the file again. That's fine — the hook reads the current file every time.
- **Non-git contexts.** The hook is a no-op if there's no `.claude/branch-policy.json` at all. It's opt-in by file presence, not by install.
