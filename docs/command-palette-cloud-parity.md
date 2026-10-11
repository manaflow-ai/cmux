# Command palette actions in Cloud workspaces

The Cmd-Shift-P palette uses the selected workspace's explicit Cloud machine
identity to decide which actions can target that workspace. The same action
paths used by shortcuts, menus, and the CLI remain responsible for execution;
the palette only applies the capability gate before it materializes a command.

## Capability matrix

| Capability | Palette actions | Local workspace | Cloud workspace |
| --- | --- | --- | --- |
| Shared | Workspace creation and lifecycle, workspace and tab names/colors/read state, pane navigation and sizing, terminal creation and splits, browser tabs and browser splits, terminal search and input controls, copy/screen actions, Cloud browser navigation/focus/zoom/devtools/console/React Grab/history/duplicate, canvas/layout controls, notifications, settings, account actions, **New Cloud Machine**, and restoring a Cloud VM from a supplied checkpoint or snapshot ID | Shown when the normal context gate passes; Cloud restore also requires the Cloud feature and account | Shown when the normal context gate passes; terminal creation/splits use the Cloud terminal reservation and remote placement path; browser creation and splits reuse the selected workspace's Cloud proxy when present; Cloud restore creates a new machine from the supplied snapshot and is hidden when the selected VM advertises no restore capability |
| Cloud-only | Fork, checkpoint, promote-to-template, status, ports, tools, and agent handoff for the current Cloud VM | Hidden because there is no selected VM target | Shown only for the selected Cloud VM, and capability-dependent actions are omitted when the server says that VM cannot honor them; ports use the VM's port-preview capability and tools use its execution capability |
| Local-only | New browser workspace, new Agent Chat, open terminal as chat, new Simulator pane, open a local folder or VS Code Inline folder, open workspace pull requests, diff viewers, directory search, VS Code serve-web stop/restart, terminal text-box file attachment, and every `palette.terminalOpenDirectory.*` action | Shown when the normal context gate passes | Omitted because these create or inspect this Mac's local filesystem/browser/simulator resources |

Agent conversation forks remain shared where the existing remote capability
probe confirms that the selected terminal can fork. A failed probe leaves the
action unavailable, preserving the provider's permission, loading, and failure
semantics.

Cloud browser panes opened from the Cloud tree retain their Cloud resource
identity for navigation, zoom, developer tools, console, React Grab, history,
and duplication. New tabs and browser splits use the selected workspace's
existing proxy route when one is available, including legacy managed Cloud SSH
workspaces. A new browser workspace still creates a local browser workspace and
is omitted from a Cloud workspace. Opening a terminal as chat also creates a
local browser split and is omitted for the same reason.

The Cloud palette includes **Show Cloud command availability**, which explains
these local-only categories in the current locale. It is available whenever a
Cloud workspace is selected, including when the Cloud VM feature gate changes
while a workspace is already open.

## Verification

To verify the routing against a real machine, select an authorized Cloud
workspace and open Cmd-Shift-P. Confirm that terminal tab/split, terminal
search/input, workspace metadata, Cloud browser navigation, and the Cloud VM
status action operate on the selected workspace. Confirm that the local-only
entries above are absent. Do not use a local SSH workspace as a proxy for this
check: SSH is remote, but it is not a managed Cloud workspace for palette
capability classification.
