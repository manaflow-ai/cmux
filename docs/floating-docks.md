# Floating Docks

A Floating Dock is a movable, resizable Bonsplit container owned by one workspace. It appears above that workspace's main content and hides when another workspace is selected. A workspace may own multiple Floating Docks.

New Floating Docks start with a terminal. Their tabs and panes use the same Bonsplit drag behavior as the existing right Dock, so notes, terminals, and browsers can move between the main workspace, right Dock, and Floating Docks without recreating the surface. The default glass tint follows the active Ghostty background while keeping the translucent Raycast-style material; a per-window color overrides that derived tint.

Create one from the command palette with `New Terminal Floating Window`, `New Notes Floating Window`, or `New Browser Floating Window`. The yellow titlebar control stashes the window at the right screen edge without using the macOS Dock. The three most recent stashed windows have direct edge buttons; additional windows collapse into a `+N` tray with a scrollable list. Stashes are workspace-scoped and survive session restore. Double-clicking the titlebar has no action. `Stash Floating Window`, `Restore Stashed Floating Windows`, `Customize Floating Window Color…`, and `Close All Floating Windows in Workspace` use the same workspace lifecycle as the CLI:

```sh
cmux workspace float create --type terminal --title Scratch --focus
cmux workspace float create --type notes --relative-to float:1 --focus
cmux workspace float create --type browser --url https://cmux.com --color '#272822' --focus
cmux workspace float list --json
cmux workspace float color set float:1 --color '#272822'
cmux workspace float color reset float:1
cmux workspace float note set float:1 "release checklist"
cmux workspace float pane create float:1 --type browser --direction right --url https://cmux.com
cmux workspace float stash float:1
cmux workspace float restore float:1 --focus
cmux workspace float restore-all --focus
cmux workspace float focus float:1
cmux workspace float close-all
```

`list --json` returns every Floating Dock in the target workspace, including its `visible` or `stashed` presentation, frame, background color, workspace visibility and focus state, panes, selected tabs, and surface identifiers. `focus` restores a stashed window before focusing it. With no explicit frame, new windows use AppKit's cascade placement relative to `--relative-to`, the most recently active floating window, or the last visible floating window. Mutations preserve the user's current focus unless `--focus` is explicit.

Run `cmux workspace float --help` for the complete command set. The target workspace defaults to the caller's `CMUX_WORKSPACE_ID`; use `--workspace <id|ref|index>` to inspect another workspace.
