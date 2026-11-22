# Session worktrees inside the project

Claude Code starts a local session in a Git folder with its Worktree control off, and keeps the
worktrees it makes in `<project>/.claude/worktrees/` (its desktop app lets you pick another
place). This look does the same for cmux: a chat's New Worktree is made at
`<project>/.claude/worktrees/<name>` on a branch `cmux/<name>`, instead of
`~/.cmux/worktrees/<project>/<name>`.

The folder gets a `.gitignore` of `*` the first time, so the project's own `git status` never
lists the worktrees, and your repository's settings are not touched. A new worktree's
`.worktreeinclude` copy skips `.claude/worktrees`, so one worktree never copies the others.

| File | What it does |
| --- | --- |
| `cmux-setup.json` | Sets `agentPane.sessionWorktrees` to `project` |

In Settings, **Session Worktrees** offers Off (the default: `~/.cmux/worktrees`, as before),
Shared Worktree Folder (`~/.cmux/worktrees`) and Inside Project (`<project>/.claude/worktrees`).

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/claude-code/session-worktree@feat-cmux-next
cmux setup remove manaflow-ai/claude-code-session-worktree
```

Or preview it from the repository root first:

```sh
cmux customize use examples/looks/claude-code/session-worktree/cmux-setup.json
cmux customize apply
```

The reference is the Worktree control and worktree location in Claude Code's session settings.
[Source capture](https://github.com/manaflow-ai/cmux-design-references/blob/3d0278494adbf4d67517f168aecf8add198c4bcd/apps/claude/live/settings-linked-sessions-worktrees.png)
