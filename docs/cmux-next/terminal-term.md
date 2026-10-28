# TERM in cmux-next terminals

Every new cmux-next terminal starts with `TERM=xterm-256color`. Every program
knows this name, and every ssh host, VM and container has its terminfo entry.
So `clear`, `htop`, `vim`, `tmux` and `less` work, also after `ssh` to a host
that has never seen Ghostty, with no "unknown terminal type" error.

The terminal still says what it can do:

- `COLORTERM=truecolor`: 24-bit color works.
- `TERM_PROGRAM=ghostty` and `TERM_PROGRAM_VERSION`: programs such as Neovim
  detect Ghostty's features from these.

cmux-next no longer picks `xterm-ghostty` because Ghostty.app or its terminfo
is installed on the Mac. The value is the same from the first byte of the
shell's startup; the shell integration does not change it.

## Choose another TERM

Set `terminal.term` in `~/.config/cmux/cmux-next.json`, or in Settings >
Terminal > Compatibility > Terminal Type (TERM):

```json
{ "terminal": { "term": "xterm-ghostty" } }
```

- cmux uses the name only when its terminfo entry is installed where ncurses
  looks on this Mac (`~/.terminfo`, `/usr/share/terminfo`,
  `/opt/homebrew/share/terminfo` and the other system folders). Otherwise new
  terminals get `xterm-256color` and the app logs why.
- When `terminal.term` is not set, a `term = ...` line in your Ghostty config
  applies, with the same check. Ghostty's own default (`xterm-ghostty`) does
  not.
- The change applies to new terminals. Terminals that are open keep their
  `TERM`. A terminal that cmux restores or reopens gets `xterm-256color`.
- Agents cannot change this setting; only you can.

With `xterm-ghostty`, an ssh host without that entry shows "unknown terminal
type". Install the entry there (`infocmp -x xterm-ghostty | ssh HOST -- tic -x -`)
or keep the default.
