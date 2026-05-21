# cmux sudo

`cmux sudo -- <command...>` lets a process running inside a cmux terminal request one elevated command. The request is never a root shell and never creates a reusable sudo session.

## Request flow

1. The bundled CLI sends `sudo.request` over the cmux Unix socket with `argv`, `workspace_id`, `surface_id`, `caller_pid`, `caller_uid`, and `cwd`.
2. The app validates the socket peer PID and UID, confirms the PID is a real cmux child process, reads the process environment, and rejects requests whose workspace or surface does not match the cmux terminal scope.
3. The app records the request as pending and returns a request id immediately, so the socket worker is not blocked while the user is looking at a native authentication prompt.
4. The CLI polls `sudo.result` with that request id until the app returns the terminal result. Result polling and `sudo.cancel` are accepted only from the same socket peer PID and UID that submitted the request.
5. The app shows the exact command to the user and calls `LAContext.evaluatePolicy(.deviceOwnerAuthentication, localizedReason:)`. Apple documents that this policy uses Touch ID and Apple Watch on macOS when available, then falls back to the user password.
6. The app signs the helper payload with a per-app-session P-256 key and sends it to `/var/run/cmux-sudo-helper.sock`.
7. The privileged helper validates the cmux app signature and Team ID, verifies the signed payload, rejects stale or replayed request ids, resolves the executable without a shell, runs one command with `/dev/null` stdin, then returns captured output and exit status.
8. The app appends an audit entry whether the request is rejected, denied, or executed.

## Apple APIs

- Local Authentication: https://developer.apple.com/documentation/localauthentication/
- `LAContext.evaluatePolicy`: https://developer.apple.com/documentation/localauthentication/lacontext/evaluatepolicy%28_%3Alocalizedreason%3Areply%3A%29
- `LAPolicy.deviceOwnerAuthentication`: https://developer.apple.com/documentation/localauthentication/lapolicy/deviceownerauthentication
- Service Management: https://developer.apple.com/documentation/servicemanagement/
- `SMAppService.register()`: https://developer.apple.com/documentation/servicemanagement/smappservice/register%28%29
- `SMJobBless`: https://developer.apple.com/documentation/servicemanagement/1431078-smjobbless

`SMJobBless` is deprecated. New packaging should embed the helper and LaunchDaemon property list in the signed app bundle and register it with `SMAppService.daemon(plistName:)`. Apple documents that LaunchDaemons registered this way require admin approval before bootstrapping.

## Helper packaging

The helper source is in `PrivilegedHelpers/cmux-sudo-helper/main.swift`. The LaunchDaemon plist scaffold is `PrivilegedHelpers/cmux-sudo-helper/com.cmuxterm.sudo-helper.plist`. The app-side client fails closed unless `/var/run/cmux-sudo-helper.sock` exists.

Production packaging still has to embed and sign the helper as an `SMAppService` LaunchDaemon. The load-bearing requirements are:

- The LaunchDaemon must run as root and create `/var/run/cmux-sudo-helper.sock`.
- The socket must be writable only by root and the local admin group (`0660`, `root:admin`).
- The helper must validate the connecting process code signature before reading the request. It accepts only cmux bundle identifiers signed by Manaflow Team ID `7WLXT3NR37`, including tagged debug, nightly, and staging bundle id suffixes.
- The helper must accept only signed payloads from the cmux app process and must reject malformed payloads.
- The helper must reject stale or replayed signed payloads. Current payloads expire after five minutes and are tracked by request id while the helper daemon is running.
- The helper must execute `argv` directly with `Process`, never through `/bin/sh` or a shell string.

## Audit log

Path: `~/Library/Logs/cmux/sudo-audit.jsonl`

Each entry includes:

- timestamp
- request id
- workspace id and surface id
- requester PID and UID
- command argv and display string
- result (`rejected`, `denied`, `completed`, or helper error status)
- exit code
- error code and message
- `previous_sha256`
- `entry_sha256`

Rotation: the app rotates at 10 MB and keeps five previous files named `sudo-audit.jsonl.1` through `sudo-audit.jsonl.5`. The directory is `0700`; log files are `0600`. Hash chaining carries the previous active entry into the first fresh entry after rotation.

## Threat model

An agent running inside cmux can ask for elevation, but it cannot grant elevation. The app verifies the request came from the socket peer process, from the same UID as the app, from a descendant of cmux, and from a process whose cmux workspace and surface match the request.

A malicious or hallucinating agent can display a request for a dangerous command. The user still sees the exact command and must approve with device-owner authentication. Approval covers only that `argv`. The helper does not start an interactive root shell, attaches stdin to `/dev/null`, does not cache approval, and does not allow shell escapes because it never executes a shell string.

A compromised non-cmux process cannot use the app socket path to bypass validation because it will not be a cmux child with matching workspace and surface scope. It also cannot read another request's command output with only a guessed request id because result polling is pinned to the original socket peer. A compromised same-user process that can inject code into the cmux app is out of scope; it can act as the app. Revocation is removing or unregistering the SMAppService daemon, deleting the helper socket, and restarting cmux.

The per-session signing key protects the payload between the app and helper from in-transit modification. It is not a substitute for helper-side code-signature validation because the public key travels with the payload. The helper therefore also pins the connecting app to Manaflow's signing Team ID. The vertical slice uses a long-running `SMAppService` LaunchDaemon, but each approved request maps to one direct child process and no retained sudo session.
