# Harbor

Harbor is cmux's terminal-session index. It discovers local and SSH-hosted
cmux-tui, tmux, zellij, GNU screen, zmx, and Herdr sessions, then exposes one
row for each attachable terminal.

The Herdr rows follow Herdr's public agent lifecycle vocabulary and terminal
session-control API. See the [Herdr repository](https://github.com/herdrdev/herdr)
and [CLI reference](https://github.com/herdrdev/herdr/blob/master/docs/next/website/src/content/docs/cli-reference.mdx).
Harbor does not copy Herdr source code. Herdr is licensed under Apache-2.0;
Harbor code remains under cmux's project license.

Terminal leaves use their owner's control protocol directly inside one cmux
manual-IO surface. tmux uses its control-mode command stream and `%output`
notifications. Herdr uses `terminal session control` JSON lines. cmux-tui uses
its `--pipe-io` byte relay. No foreign session creates a second terminal just to
render the first one.

## Manual IO coverage

Harbor uses manual IO for a leaf only when its owner exposes a writable,
frame-preserving protocol and the local client is available. Session rows and
tools without that protocol keep their native PTY attach command.

The bundled cmux-tui client comes from a rolling artifact. cmux probes
`attach --help` before it creates a manual-mirror surface. If that client does
not advertise `--pipe-io`, cmux uses the existing exec-attach PTY path instead
of showing a broken manual-IO pane.

The global terminal creation policy covers plain local terminal tabs, the
first terminal in a new workspace, ordinary splits, placeholder repairs, and
restored daemon-backed panels. Explicit startup commands, initial input,
restore agents, tmux-start commands, remote PTY sessions, and remote workspaces
remain on their existing PTY paths until the daemon launch contract can carry
their startup state. These are migration cuts, not per-row Harbor exceptions.

zellij, GNU screen, and zmx currently expose session-level fallback attaches.
Their current public interfaces do not provide a byte-exact terminal stream
that can replace a PTY without losing terminal modes. tmux, cmux-tui, and Herdr
expose terminal leaves when their probes provide a stable pane or terminal id.
