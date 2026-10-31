# Workspace Board

A custom pane: a web page in a sandboxed web view
([custom-panes-DESIGN.md](../../../plans/cmux-next/custom-panes-DESIGN.md)).
It lists every workspace with its terminals and sends a typed line to a
terminal with `cmux.call("terminal.input.write", ...)`, which needs the
optional `terminal:execute` scope.
Use Refresh to read the workspace list again; it preserves unfinished lines and
does not refresh in the background.

Try it: copy the folder to `<cmux state>/apps/local/workspace-board`
(`cmux raw command --request-json '{"cmd":"apps-list"}'` prints it as `local_dir`), install it in the App Store, then
`cmux app open local/workspace-board`. Saving a file reloads the pane.
