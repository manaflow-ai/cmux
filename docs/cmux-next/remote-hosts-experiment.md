# Remote workspaces preview

Turn on Settings > Advanced > Labs > Show Preview Features (`labs.previewFeatures`, default `false`), then open Settings > Devices > Remote Workspaces > New Remote Group….
Choose a connected host, a Tailscale peer, an SSH alias, or enter an SSH destination. The existing native picker connects through SSH and shows that host's workspaces as a sidebar group. Create a workspace in that group to run it on the host; select an existing workspace to attach.

The experiment is the discoverable Devices entry point. It reuses `remote.newGroup`, its host catalog, connection consent, and host-owned workspaces. Existing palette, CLI, and MCP entry points remain available. Turning the preview off hides the entry point; it does not disconnect a host or destroy its workspaces. Opening Devices never connects by itself.

A fresh native click opens the picker as the person's action. Script-only calls retain page origin. A refused call displays an error and can be retried. No transport, persistence, rendering, or collaboration defaults change.

Manual acceptance: with the setting absent/off, Devices has no Remote Workspaces section; with it on, click New Remote Group, select a test SSH host, attach to an existing workspace and create another in that host's group. Disable the preview and verify the entry point disappears while the existing group remains. The design names no numeric performance threshold; this slice adds no mount-time discovery or connection request.

Private design: `manaflow-ai/cmuxterm-hq/plans/feat-remote-hosts/DESIGN.md` (client sidebar source). Layout follows existing Settings group/row/button tokens, without new motion or tiles.
