# SSH Reuse Existing Workspace Design

## Goal
Make `cmux ssh <destination>` attach to an existing matching remote SSH workspace by default instead of always creating a duplicate workspace.

## Behavior
- `cmux ssh acer` searches existing workspaces before creating a new one.
- If a workspace with `remote.enabled == true` and matching `remote.destination` exists, the CLI reuses it.
- If `--port` is provided, the existing workspace must also have the same `remote.port`.
- If `--identity` or custom `--ssh-option` is provided, the CLI creates a new workspace because current public remote metadata only exposes booleans, not comparable values.
- `--new` bypasses reuse and preserves the old always-create behavior.
- `--no-focus` keeps its existing meaning: reuse can return the existing workspace without selecting it.

## Architecture
The change stays in `CLI/cmux.swift`. `parseSSHCommandOptions` gains a `forceNewWorkspace` flag for `--new`. `runSSH` performs a preflight `workspace.list` lookup after parsing options and before generating SSH relay/bootstrap state. When a match is found, it returns the workspace payload with `reused: true`; otherwise it runs the existing create/configure flow and returns `reused: false`.

## Testing
Add focused Python regression coverage in `tests_v2/test_ssh_remote_cli_metadata.py` because that file already validates SSH CLI metadata and workspace list behavior.
