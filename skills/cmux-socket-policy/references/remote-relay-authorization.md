# Remote CLI relay authorization (GHSA-9vmv-3hjw-j28c)

Use this when adding or changing a v2 socket method, a remote CLI command
(`daemon/remote/cmd/cmuxd-remote/commands.go`), or any path that forwards
requests from a remote host to the app.

The `cmux ssh` reverse relay stores its credential on the remote host, so a
relay client is a compromised client. The legacy app enforced this with
`RemoteRelayCommandPolicy` in `CmuxRemoteWorkspace`; that package was deleted
with the legacy app, and the app in `Packages/macOS/CmuxNext` has no relay
policy yet. Until one exists, no relay path may reach the app's control socket.
Any new relay must implement the rules below.

## Rules for any relay

1. **Default is deny, and deny is safe.** The relay forwards only an explicit
   allowlist of methods, scoped to objects the remote session owns. A method not
   on the list does not work remotely. Add one only when a remote flow needs it.
2. **Answer in the PR description before allowlisting a method:**
   - Can it execute commands or open content on local objects (spawn terminals,
     respawn, send keys or text, eval scripts, open URLs)?
   - Can it mutate or destroy objects the remote session does not own (close,
     rename or delete by ID)?
   - Does it read local state the remote has no business seeing?

   If any answer is yes, do not allowlist it; reshape the method or its params.
3. **Deny command-bearing params** (`initial_command`, `command`,
   `tmux_start_command`, `pane_start_command`) on every method. The legacy
   policy's one exception (`surface.resume.set`, safe only because the app
   dropped relay-originated resume bindings) does not carry over; a new
   exception needs the same analysis and tests.
4. **Never allowlist a method that spawns or respawns terminals** unless you have
   verified in the running app that the target executes on the remote host. The
   legacy plain-SSH respawn path fell back to local execution under the same
   surface ID.
5. **Scope every ID param.** Each workspace, surface or tab ID param name,
   including arrays and new `*_workspace_id`-shaped names, must be checked
   against the remote session's owned objects; reject ref-form and unmapped IDs.
6. **Add policy tests** for the allow case with an owned target and the deny
   cases (unmapped target, command params).

## Review

A PR that adds a relay path or allowlists a method without this analysis is a
security regression and is blocked in review. The review bot enforces it through
[`.github/review-bot-rules/remote-relay-authorization.md`](../../../.github/review-bot-rules/remote-relay-authorization.md).
