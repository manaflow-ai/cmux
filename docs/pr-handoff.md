# Attach a PR to the sidebar

After creating a GitHub pull request in a cmux terminal or Git worktree:

```sh
url=$(gh pr create --fill) && cmux pr "$url"
```

`cmux pr 123` also works. Git and an authenticated GitHub CLI (`gh auth login`) are required. The command checks the PR against the current directory's GitHub repository using gh's configured default repository, including a fork's upstream. Invalid URLs, missing PRs, lookup failures, and repository mismatches leave the existing link unchanged.

The workspace is resolved from `--workspace`, the caller's live TTY, `CMUX_WORKSPACE_ID`, or a unique workspace whose current directory is in the caller's worktree. Ambiguous or missing targets fail with guidance to pass `--workspace`; the focused workspace is never assumed. `--window` restricts the search. The command does not change focus.

```sh
cmux pr https://github.com/owner/repo/pull/123 --workspace workspace:2
cmux pr 124 --workspace workspace:2  # replace the manual link
cmux pr clear --workspace workspace:2
cmux --json pr 123
```

The existing clickable sidebar row updates when the command succeeds, subject to the sidebar's visibility and click settings. One manual link is retained per workspace for the current session. Repeating the same handoff is idempotent. Branch changes, panel pruning, and watcher clears preserve it; a workspace sidebar reset, replacement, clear, or session end removes it. Normal watcher reports for the same PR update its status and deduplicate the row. Clearing the manual link does not suppress PRs independently discovered by the watcher. Run `cmux pr 123` again to refresh a manually attached PR whose branch is no longer being watched.

This handoff is available through the local Mac CLI; it does not add a remote SSH relay method. For details and flags, run `cmux pr --help`.
