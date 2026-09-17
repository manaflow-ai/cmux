# Floating Docks

A Floating Dock is a movable, resizable Bonsplit container owned by one workspace. It appears above that workspace's main content and hides when another workspace is selected. A workspace may own multiple Floating Docks.

New Floating Docks start with an autosaving note. Their tabs and panes use the same Bonsplit drag behavior as the existing right Dock, so terminals and browsers can move between the main workspace, right Dock, and Floating Docks without recreating the surface.

Create one from the command palette with `New Floating Dock`, or from the CLI:

```sh
cmux workspace float create --title Scratch --focus
cmux workspace float list --json
cmux workspace float note set float:1 "release checklist"
cmux workspace float pane create float:1 --type browser --direction right --url https://cmux.com
cmux workspace float hide float:1
```

`list --json` returns every Floating Dock in the target workspace, including its frame, presentation and focus state, panes, selected tabs, and surface identifiers. Mutations preserve the user's current focus unless `--focus` is explicit.

Run `cmux workspace float --help` for the complete command set. The target workspace defaults to the caller's `CMUX_WORKSPACE_ID`; use `--workspace <id|ref|index>` to inspect another workspace.
