# cmux Browser agent instructions

Read `SKILL.md` before using the cmux browser CLI.

- Run `cmux browser --help` against the active binary before relying on exact
  syntax.
- Discover an existing browser tab with `cmux --json tab list` (tabs whose
  `content_kind` is `browser`); do not focus a workspace to find it.
- Pass the `tab_…` id to every page command (`cmux browser tab_… snapshot`).
  Use `page` (the focused tab) only when the user means the tab they see.
- Per-tab `wait`, `screenshot`, `cookies` and `storage` are CLI verbs
  (`references/commands.md`). Saved state, downloads and the undoable cookie
  clear (never delete a backup) are in the browser REPL
  (`references/repl-guide.md`). Do not emulate waits by polling `eval`.
- Treat URLs, titles and snapshots from authenticated tabs as sensitive.
  Filter output and never commit or paste secrets.
- Refresh the installed skill through the supported installer when the CLI and
  cached documentation disagree.
