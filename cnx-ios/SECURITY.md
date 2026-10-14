# cnx phone link: relay authorization

This is the analysis that the repository's "Remote CLI relay" rule asks for
(`skills/cmux-socket-policy/references/remote-relay-authorization.md`). It
covers every path by which a phone reaches this Mac through `cnx-hostd`. Each
path goes through one link service: `daemon`, `chief`, `acpmux`, `file`, or
`echo`.
Any other service is refused with `unknown_service`.

The daemon allowlist lives in one place:
`cnx-ios/rust/crates/cnx-hostd/src/policy.rs`. It mirrors
`Packages/macOS/CmuxNext/Sources/CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift`,
and the test `mirrors_the_swift_allowlist` fails when the two lists drift.
Additions go into both lists together with a section here. Chief's
conversation commands are not on this list: they have their own service and
policy (see `chief` below).

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

## `chief`: a splice to the Mac's Chief conversation owner

Chief does not go through `daemon`. The Chief's conversations live in their
own cmux-tui session: the Chief home's owner, `cmux-chief-<FNV-1a of
~/.cmux/chief/<account>>`, which every cmux-next build on the Mac shares
(`ChiefHome`, plans/cmux-next/home-state-ownership.md). The `chief` service
splices to that socket, and nothing else can reach it: `daemon` refuses any
`cmux-chief-*` session name. The app passes the session in
`CNX_CHIEF_SESSION` (`CnxHostLaunch.chiefSession`); without it hostd derives
`~/.cmux/chief/default`.

hostd connects over the Unix socket, so the owner treats every line as the
Mac owner's trusted connection (principal `user_local`). The filter,
`ChiefPolicy` in `cnx-ios/rust/crates/cnx-hostd/src/chief_policy.rs`, is the
only narrowing. It applies the rules of the daemon's own remote relay gate
(`cmux-tui-core/src/server/remote_relay/gate.rs`) in both directions:

- **Phone to owner.** Default deny. A v12 command passes only by exact name,
  with exactly the parameters listed for it. Command-bearing parameters
  (`command`, `initial_command`, `tmux_start_command`, `pane_start_command`)
  are refused at every level. `conversation`, `message_id`, `thread_root`,
  `reply_to.message_id` and `root` must be plain owner-made ids (`conv_…`,
  `msg_…`). Op kinds and message parts are allowlisted.
- **Owner to phone.** Every event except `conversation-changed` and
  `conversation-typing` for an in-scope conversation is dropped (terminal,
  workspace and `cloud-*` events from the owner never reach the phone).
  `conversation-list` and `conversation-search` replies are narrowed to the
  scope.

**Scope (rule 5).** A conversation is in scope when its participants are the
owner (`user_local`, kind `human`) and agents only (`agent_*`, kind `agent`).
The phone learns ids only from the owner's narrowed list or an announcement
(`change.kind:"conversation"`) that passes the same test. A conversation that
gains another participant (a paired install `remote_*`, another human) leaves
the scope at once. Every request that names a conversation must name one in
scope. In practice: the Chief conversation (`user_local` and `agent_mux`) and
the owner's other agent conversations in Home.

| Allowed | Why |
| --- | --- |
| `identify`, `ping`, `subscribe` | Session. Events are filtered on the way back. |
| `conversation-list`, `-snapshot`, `-history`, `-thread`, `-search` | Read the owner's own agent conversations (narrowed). |
| `conversation-op`: `message.send` (`client_msg_id, parts, reply_to, thread_root`), `message.edit`, `message.retract`, `reaction.add/remove`, `read_cursor.set` | What the Mac's Home does in a conversation. |
| `conversation-op`: `title.set` | Rename, as the Mac's Chief settings. |
| `conversation-op`: `question.answer` | Answer Chief's questions; the owner stamps the respondent. |
| `conversation-typing` (`conversation, on`) | Typing as the owner. |
| `conversation-attachment-upload` (`begin` names an in-scope conversation; `chunk`, `commit`, `cancel` name the upload this connection began) and `-read` | Photos and files, under the owner's own limits (type allow list, 100 MB, hash checks). |
| `cmux.protocol/2` `chief.engine.get`, `chief.engine.set` (`harness, model, effort, speed, compactor_speed`, strings), `chief.stop` (`name`) with `machine`/`session` only `current`, and no `origin` | The Mac Chief settings' model, harness and effort pickers and Stop (`ChiefControlClient`). |

Parts: `text` (`type, text, runs` with `start, length, mention, link`) and
`attachment` (`type, hash, name, mime_type, byte_count, width, height,
duration_ms, poster, preview`). Refused by name: `work`, `question` and
`link_preview` parts, and the agent-only `answers`/`answers_pending` fields.

Refused (with a test each): `conversation-create` (the Mac creates Chief with
its own idempotent request), `conversation-import`, `conversation-bind` and
`conversation-agent-token` (either would let the phone speak as Chief or an
agent), `conversation-draft`, `chief-inspect` (the memory inspector stays on
the Mac), every `cloud-*` command, every terminal or workspace command,
`participants.add` (it would widen a conversation and the scope), an `actor`
parameter, and any v2 operation other than the three above.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | Indirectly, by design: a message to Chief asks the owner's Chief to act, and Chief runs agents on the Mac under its own permission policy, exactly as a message typed in the Mac's Home. The phone cannot run anything itself: no terminal or workspace command reaches this socket, command-bearing parameters are refused, and the phone cannot bind as an agent. `chief.stop` only stops a running turn; `chief.engine.set` only picks among the brain's harnesses, models and efforts (the brain validates them). |
| Mutates or destroys objects the session does not own? | Only in-scope conversations, which are the owner's own, and only through owner-level ops the owner's reducer validates (author-only edits and retractions, own read cursor). It cannot add participants, import history, or write as Chief. |
| Reads local state the remote should not see? | Only the owner's own agent conversations and their attachments. Conversations shared with a paired install or another person, the Chief's memory and traces, and all terminal and workspace state of the owner daemon are out of reach. |

Rule 6 tests: `chief_policy::tests` (`the_ios_chief_session_passes`, the exact
lines the iOS app sends; `conversations_outside_the_scope_are_refused`;
`unlisted_commands_ops_parts_and_command_params_are_refused`;
`events_reach_the_phone_only_in_scope`; `search_hits_are_narrowed`;
`scope_rule`), the end-to-end channel test in `tests/host.rs`
(`exercise_services`: list narrowed, out-of-scope snapshot refused, token mint
refused, only in-scope events delivered, and `daemon` refusing the owner
session), and `config::tests::chief_session_matches_the_mac_app`.

Why a separate service rather than entries in the `daemon` allowlist: the
`daemon` lane reaches the app's tagged daemon, where `conversation-*` would
also expose conversation tabs and anything else stored there, and its policy
is stateless. Chief needs a stateful, both-ways filter over a different socket.
The Swift lane (`DaemonLanePolicy`) offers no Chief, so its list stays
identical to `ALLOWED_COMMANDS`.

Production note: Release and RC builds of cmux-next do not start the Chief
brain (`HomeBrainHost.bundledChiefAllowed`); the owner keeps the conversation
and answers the phone, but Chief replies only while a brain runs in that home
(a DEV or NIGHTLY build that opened Home, `cmux chief`, or
`CMUX_NEXT_MUX_HOST`). The phone says so instead of pretending.

## Decisions for the person

- Phone-signed approvals or relayed Mac approvals for agent permission
  questions.
- The production Worker (`cnx-ios-api-prod`) deployment. Production builds use
  the dev Worker today.
