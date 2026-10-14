# cnx phone link: relay authorization

This is the analysis that the repository's "Remote CLI relay" rule asks for
(`skills/cmux-socket-policy/references/remote-relay-authorization.md`). It
covers every path by which a phone reaches this Mac through `cnx-hostd`. Each
path goes through one link service: `daemon`, `acpmux`, `file`, or `echo`.
Any other service is refused with `unknown_service`.

The daemon allowlist lives in one place:
`cnx-ios/rust/crates/cnx-hostd/src/policy.rs`. It mirrors
`Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift`,
and the test `mirrors_the_swift_allowlist` fails when the two lists drift.
Additions, including the Chief `conversation-*` commands, go into both lists
together with a section here.

## Who the peer is

- **Admission.** A link starts only from a dial whose `fromUserId` is the Mac's
  own Stack user, and only the backend sets that field (PROTOCOL.md
  "Admission"). The peer is therefore one of the account owner's own phones.
  It is never another user, and never an arbitrary remote host that holds a
  copied credential.
- **The phone acts for the person, but is not the app.** It cannot send
  `client-hello` or `origin.confirmation.issue` (both are refused by the
  policy). So the daemon gives the phone lane origin `agent`, and Gate A2's
  user-only operations (`apps.*`, the agent folder, history purges and
  imports) refuse it. The phone never proves the app's install key and never
  gets `user_origin_allowed`. This is deliberate: the phone is a scoped remote
  client, not the local owner.
- **Revoking.**
  - Turning off Settings > Mobile > Allow iPhone Connections stops hostd, so
    no link can start.
  - Remove (Settings > Mobile, or `DELETE /v1/devices/:id`) forgets a phone
    and closes its signaling socket.
  - A phone that is still signed in registers again. To keep a lost phone out,
    sign that session out of the account.

## `daemon`: a splice to the app's cmux-tui session socket

The phone writes v12 JSON lines, and every line is judged by
`DaemonPolicy::evaluate` before it reaches the daemon. Anything not on the
allowlist gets a local `forbidden` error line and never reaches the daemon.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | Yes, by design, and only in these bounded forms. `send` and `send-key` type into a terminal the person already sees in their own workspaces: the phone is a remote keyboard for the owner. `create-terminal`, `new-tab`, `new-pane`, `split`, `new-screen` and `new-workspace` start the person's default shell. Their parameters are limited to size and placement fields (`creation_fields`), so `argv`, `command`, `cwd`, `env` and any other field are refused. There is no `run`, `respawn-*`, `eval`, open-URL, or browser automation command. |
| Mutates or destroys objects the session does not own? | The phone's session is the owner's whole daemon, the same set of workspaces the person sees on the Mac, so close, rename, move and select act on the person's own objects. There is no per-object scoping beyond that, and none is needed while admission is same-user only. Frontend projections are the exception: reads and writes are limited to `scope: personal`, `subject_key: ios-device:<phone deviceId>`, so a phone cannot overwrite the Mac's own projection or another phone's. |
| Reads local state the remote should not see? | It reads what the owner's Mac shows: terminal screens and scrollback, process info, listening ports, machine usage. All of that is the owner's own data on the owner's own device. Settings, credentials, keychain, the control socket and other users' sessions cannot be reached. |

- **Rule 3 (command-bearing parameters):** refused on every creation command
  through the per-command field allowlist (test
  `refuses_unlisted_and_command_bearing_requests`).
- **Rule 4 (spawning terminals):** these terminals are meant to run on this
  Mac, where the person's shell lives. That is the product, not a fallback.
  No variant runs a program the phone picks.
- **Rule 5 (ID scoping):** IDs are the owner daemon's own. The only
  phone-specific object, the projection subject, is checked.
- **Rule 6 (tests):**
  - `allows_listed_commands` and `allows_the_phone_terminal_session` (the exact
    lines the iOS terminal tab sends) cover the allowed cases.
  - `refuses_unlisted_and_command_bearing_requests`,
    `projections_are_scoped_to_the_phone` and
    `the_phone_cannot_claim_the_app_identity` cover the refusals.

## `acpmux`: a splice to the app's acpmux WebSocket

- **How it connects.** The phone's frames go to the app's acpmux on loopback,
  with acpmux's dashboard bearer token. A listener that is not on loopback is
  refused.
  - acpmux treats the connection as remote-origin (`Web`). It never gets the
    LocalApp token, so the pane-only methods stay closed.
  - The endpoint comes from the app over hostd's stdin and is never written to
    disk.
- **Executing commands.** The phone can prompt agents, and agents run commands
  on the Mac. This is the product, and it runs under acpmux's permission
  policy: tool approvals reach the phone as questions, and the agent waits for
  the answer.
- **Unowned objects.** The phone sees only the owner's acpmux sessions.
- **Local state.** Transcripts belong to the owner.

## `file`: read-only previews

- **Path checks.** Only absolute paths inside `CNX_FILE_ROOTS` are served.
  These are the chat roots from Settings, and there are none by default, which
  refuses every read.
  - The path is canonicalized (symlinks resolved) before the open.
  - After the open, the descriptor's real path (`F_GETPATH`) is checked again,
    so a component swapped for a symlink in between cannot escape.
- **What it serves.** Regular files only, up to 64 MiB. It never writes, lists
  directories, or executes anything.

## Decisions for the person

- Phone-signed approvals or relayed Mac approvals for agent permission
  questions.
- The production Worker (`cnx-ios-api-prod`) deployment. Production builds use
  the dev Worker today.
