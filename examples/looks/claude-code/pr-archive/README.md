# Archive chats when their pull requests finish

Install the setup in a build that includes PR auto-settle.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/claude-code/pr-archive@feat-cmux-next
```

In the Command Palette, run **Archive chats after pull requests merge** or **Archive chats after pull requests close** and confirm the setting in cmux. Enable both to cover both outcomes. The merge rule covers a mix of merged and closed PRs. The close rule covers PRs that all closed without merging. Both start off. Turn either off in Settings → Agents.

Once every recorded pull request has merged or closed, an idle chat moves to the archived shelf. An open pull request, unknown state, active turn, draft, or someone viewing the chat keeps it open. You can bring a chat back from the shelf.

With automatic worktree cleanup enabled, the next eligible cleanup pass after the quiet period can move the chat’s clean, pushed, cmux-managed worktree into `~/.cmux/worktree-archive/parked/`. Other open chats, active processes, local changes, ignored files, and unpushed commits keep the worktree in place. The move preserves the complete directory, branch, and disk contents. Starting the chat again restores its checkout to the original path.

Design reference in the private reference collection: `apps/claude/live/settings-linked-sessions-worktrees.png`.
