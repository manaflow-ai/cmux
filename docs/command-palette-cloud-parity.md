# Command palette actions in Cloud workspaces

The Cmd-Shift-P palette uses the selected workspace's explicit Cloud machine
identity to decide which actions can target that workspace. The same action
paths used by shortcuts, menus, and the CLI remain responsible for execution;
the palette only applies the capability gate before it materializes a command.

## Capability matrix

| Capability | Palette actions | Local workspace | Cloud workspace |
| --- | --- | --- | --- |
| Shared | Workspace creation and lifecycle, workspace and tab names/colors/read state, pane navigation and sizing, terminal creation and splits, terminal search and input controls, copy/screen actions, Cloud browser navigation/focus/zoom/devtools/console/React Grab/history/duplicate, canvas/layout controls, notifications, settings, account actions, and **New Cloud Machine** | Shown when the normal context gate passes | Shown when the normal context gate passes; terminal creation/splits use the Cloud terminal reservation and remote placement path |
| Cloud-only | Fork, checkpoint, restore, promote-to-template, status, ports, tools, and agent handoff for the current Cloud VM | Hidden because there is no selected VM target | Shown only for the selected Cloud VM; handlers resolve that selected workspace rather than another open machine |
| Local-only | New browser workspace/tab, new Agent Chat, new Simulator pane, open a local folder or VS Code Inline folder, open workspace pull requests, diff viewers, directory search, VS Code serve-web stop/restart, browser splits, terminal-to-browser splits, and every `palette.terminalOpenDirectory.*` action | Shown when the normal context gate passes | Omitted because these create or inspect this Mac's local filesystem/browser/simulator resources |

Agent conversation forks remain shared where the existing remote capability
probe confirms that the selected terminal can fork. A failed probe leaves the
action unavailable, preserving the provider's permission, loading, and failure
semantics.

Cloud browser panes opened from the Cloud tree retain their Cloud resource
identity for navigation, zoom, developer tools, console, React Grab, history,
and duplication. Creating a new browser surface still requires a local browser
creation path, so browser creation and split commands are intentionally omitted
from a Cloud workspace until a Cloud browser creation route exists.

## Verification

To verify the routing against a real machine, select an authorized Cloud
workspace and open Cmd-Shift-P. Confirm that terminal tab/split, terminal
search/input, workspace metadata, Cloud browser navigation, and the Cloud VM
status action operate on the selected workspace. Confirm that the local-only
entries above are absent. Do not use a local SSH workspace as a proxy for this
check: SSH is remote, but it is not a managed Cloud workspace for palette
capability classification.
