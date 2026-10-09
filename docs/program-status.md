# Program status (OSC 7501)

cmux supports the [Program Status Protocol](https://www.superlogical.com/rex/docs/build/program-status)
(OSC 7501, rev 0.3). A program writes its state to the terminal and cmux shows it in the sidebar. It
works over SSH and inside containers because it travels through the pty.

```bash
status() {
  printf '\e]7501;state=%s:msg=%s\e\\' "$1" "$(printf '%s' "$2" | base64 | tr -d '\n')"
}
status working "Syncing photos"
rsync -a ~/Photos backup:/photos && status done "Photos synced" || status error "rsync failed"
```

Programs can detect support with `printf '\e]7501;?\e\\'`; cmux answers with the same bytes. The
`xterm-ghostty` terminfo entry also carries the `Pst` capability.

## What cmux shows

cmux keeps the records of each terminal pane separately and shows the most urgent one as a status
row on the workspace: `blocked` (bell), then `error`, `working` (with its percentage when the
program sends `progress`), and `done`. `idle` records are kept but not shown. The row text is the
record's `app` (inherited from the nearest parent record) and its `msg`, or `title`, or a state
label such as "Needs permission".

- `working` and `blocked` records are removed when a new shell prompt starts (OSC 133 A or cmux
  shell integration) and when the pane's process exits.
- `done` and `error` records stay until you focus that pane again.
- A full terminal reset (RIS) removes every record of the pane.
- `msg` and `title` are plain text. cmux strips invisible formatting characters, such as text
  direction overrides, and shortens long text before display.

Program status rows are terminal state, not agent state: they do not change agent hibernation,
agent detection, or desktop notifications. Use `cmux notify` or OSC 9/99/777 for notifications.
