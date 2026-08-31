# Harbor

Harbor is cmux's terminal-session index. It discovers local and SSH-hosted
cmux-tui, tmux, zellij, GNU screen, zmx, and Herdr sessions, then exposes one
row for each attachable terminal.

The Herdr rows follow Herdr's public agent lifecycle vocabulary and terminal
session-control API. See the [Herdr repository](https://github.com/herdrdev/herdr)
and [CLI reference](https://github.com/herdrdev/herdr/blob/master/docs/next/website/src/content/docs/cli-reference.mdx).
Harbor does not copy Herdr source code. Herdr is licensed under Apache-2.0;
Harbor code remains under cmux's project license.

Harbor currently uses Herdr's terminal attach command inside a cmux manual-IO
terminal. Direct frame-level `terminal session control` integration is a later
step, because it needs a separate JSON frame pump and resize lifecycle.

## Manual IO coverage

Harbor rows request manual IO whenever both terminal-backend beta flags are on.
The drop provisions one cmux-tui daemon terminal, runs the external attach
command there, and mirrors that terminal into the destination pane.

The global terminal creation policy is still narrower. Plain local terminals
and restored daemon-backed panels use manual IO. Splits, the first terminal in
a new workspace, explicit startup commands, tmux-start commands, remote PTY
sessions, and remote workspaces remain on their existing PTY paths. These are
migration cuts, not per-row Harbor exceptions.

zellij, GNU screen, and zmx currently expose session-level fallback attaches;
tmux, cmux-tui, and Herdr expose terminal leaves when their probes provide a
stable pane or terminal id.
