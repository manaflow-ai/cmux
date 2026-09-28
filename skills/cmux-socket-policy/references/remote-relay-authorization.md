# Remote CLI relay authorization (GHSA-9vmv-3hjw-j28c)

Use this when adding or changing a v2 socket method, a remote CLI command
(`daemon/remote/cmd/cmuxd-remote/commands.go`), or the relay policy.

Every v2 socket method you add or touch is a potential `cmux ssh` relay payload.
The relay on the remote host authenticates but does not trust:
`RemoteRelayCommandPolicy`
(`Packages/macOS/CmuxRemoteWorkspace/Sources/CmuxRemoteWorkspace/Relay/`) denies
every method by default and only forwards an allowlist, scoped to objects the
remote session owns. Command-bearing params (`initial_command`, `command`,
`tmux_start_command`, `pane_start_command`) are denied on every method except
`surface.resume.set`.

That one exception records an agent's resume command on a surface the remote
session owns. It is safe only because the app drops relay-originated resume
bindings (`ControlSurfaceResumeTarget.registeredBinding` returns `nil` when the
request carries a remote workspace ID), so the stored command never runs on the
Mac. Keep that check if you touch either side, and do not add another exception
without the same analysis and tests.

## Checklist

1. **Default is deny, and deny is safe.** A new method that is not added to the
   policy allowlist does not work through `cmux ssh`. Add it only when the remote
   product flow needs it.
2. **Answer in the PR description before allowlisting a method:**
   - Can it execute commands or open content on local objects (spawn terminals,
     respawn, send keys or text, eval scripts, open URLs)?
   - Can it mutate or destroy objects the remote session does not own (close,
     rename or delete by ID)?
   - Does it read local state the remote has no business seeing?

   If any answer is yes, do not allowlist it; reshape the method or its params.
3. **Never allowlist a method that spawns or respawns terminals** unless you have
   verified in the running app that the target executes on the remote host. The
   plain-SSH respawn path falls back to local execution under the same surface
   ID; that is why `surface.respawn` is denied.
4. **Cover new ID params with the policy's scoped key sets** (`workspaceIDKeys`,
   `surfaceIDKeys`, `ambiguousIDKeys`, and the array variants). A new
   `*_workspace_id`-shaped param name that is not added to the sets is unscoped.
5. **Add policy tests** in `RemoteCLIRelayPolicyTests`
   (`Packages/macOS/CmuxRemoteWorkspace/Tests/CmuxRemoteWorkspaceTests/RemoteCLIRelayPolicyTests.swift`):
   the allow case with an owned target, and the deny cases (unmapped target,
   command params).

## Review

A PR that adds a method to the allowlist without this analysis is a security
regression and is blocked in review. The review bot enforces it through
[`.github/review-bot-rules/remote-relay-authorization.md`](../../../.github/review-bot-rules/remote-relay-authorization.md).
