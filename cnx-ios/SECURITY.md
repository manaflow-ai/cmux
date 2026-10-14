# cnx phone link: relay authorization

This is the analysis that the repository's "Remote CLI relay" rule asks for
(`skills/cmux-socket-policy/references/remote-relay-authorization.md`). It
covers every path by which a phone reaches this Mac through `cnx-hostd`. Each
path goes through one link service: `daemon`, `chief`, `acpmux`, `file`,
`upload`, or `echo`, and, when the app supervises hostd, only after the
`auth` pairing service (below) accepted the phone.
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
- **The Mac is pinned.** The phone pins each paired Mac's identity key on
  first use (the Mac app's Keychain key, proved in every `auth` over the
  phone's own nonce; PROTOCOL.md "Mac identity"). A host registered with a
  stolen token under that Mac's device id cannot prove the key, so the phone
  refuses it before it signs or sends anything, and says the Mac's identity
  changed. A host under a new device id is a new Mac to the phone: it shows in
  the list as one more Mac, and the person pairs it only by choice.
- **Revoking.**
  - Turning off Settings > Mobile > Allow iPhone Connections stops hostd, so
    no link can start.
  - Remove in Settings > Mobile forgets the phone on the service
    (`DELETE /v1/devices/:id`, which closes its signaling socket). It also
    tells hostd (`drop_phone`), which closes that phone's live links at once.
  - Remove also forgets the phone's paired keys on this Mac; its next link
    asks the person again ("Allow … to connect to this Mac?").
  - A phone that is still signed in registers again. To keep a lost phone out,
    sign that session out of the account.

## `daemon`: a splice to the app's cmux-tui session socket

The phone writes v12 JSON lines, and every line is judged by
`DaemonPolicy::evaluate` before it reaches the daemon. Anything not on the
allowlist gets a local `forbidden` error line and never reaches the daemon.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | Yes, by design, and only in these bounded forms. `send` and `send-key` type into a terminal the person already sees in their own workspaces: the phone is a remote keyboard for the owner. `create-terminal`, `new-tab`, `new-pane`, `split`, `new-screen` and `new-workspace` start the person's default shell. Their parameters are limited to size and placement fields (`creation_fields`), so `argv`, `command`, `cwd`, `env` and any other field are refused. The browser commands (`new-browser-tab`, `browser-navigate`, `browser-key`, `browser-insert-text`, `browser-mouse`, ...) drive the Mac's cmux browser tabs. A URL the phone opens must be `http(s)://` or `about:blank` (test `browser_tabs_open_web_pages_only`), so `file:`, `javascript:` and app schemes are refused. This narrowing is in the Rust policy only; the Swift mirror keeps the same command list. There is no `run`, `respawn-*` or `eval` command. |
| Mutates or destroys objects the session does not own? | The phone's session is the owner's whole daemon, the same set of workspaces the person sees on the Mac, so close, rename, move and select act on the person's own objects. There is no per-object scoping beyond that, and none is needed while admission is same-user only. Frontend projections are the exception: reads and writes are limited to `scope: personal`, `subject_key: ios-device:<phone deviceId>`, so a phone cannot overwrite the Mac's own projection or another phone's. |
| Reads local state the remote should not see? | It reads what the owner's Mac shows: terminal screens and scrollback, process info, listening ports, machine usage. All of that is the owner's own data on the owner's own device. Settings, credentials, keychain, the control socket and other users' sessions cannot be reached. When the app supervises hostd, a phone that names a session gets only the app's own one (`forbidden` otherwise), so it never reaches another channel's or tag's daemon in the same socket folder. |

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
- **What it serves.** Regular files only (opened non-blocking, so a FIFO
  cannot hold the open), up to 64 MiB. It never writes, lists
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
| `conversation-op`: `question.answer` with `approval` | Answer Chief's questions. Supervised, it counts only with the phone's Face ID signature over this Mac, conversation, question and answer (one use, at most 300 s; `chief_answers.rs`); hostd strips `approval`, and the owner stamps the respondent. An unsigned or forged answer is refused `forbidden`. |
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

## `daemon`: agent tabs and tab create, close and select

Added by `feat-cnx-ios-dataflow` so tabs made on the phone are real tabs of
the Mac.

- **Terminal and browser tabs** use commands already on the allowlist:
  `new-tab {pane, cols, rows}` (size and placement only, as above),
  `new-browser-tab {url, pane}`, and `close-surface {surface}`. The phone still
  never names a folder: hostd adds the Mac's own choice to a phone's `new-tab`,
  the folder of that pane's active tab (else another tab of the pane, else of
  its workspace), from the daemon's own `list-workspaces`, canonicalized, never
  `/`, the home folder or above (`pane_folder`). The terminal opens where the
  person's other terminals in that workspace already are, as one made on the
  Mac does; it gains no folder the phone's terminals in that pane lack. Selecting a
  tab stays on the phone (it remembers the last tab per workspace). The phone
  never sends `select-tab` or `report-focus` for its own navigation, because
  both move the Mac's view for the person sitting at it.
- **Agent chat tabs:** `new-conversation-tab` is new on the allowlist, and
  `DaemonPolicy::agent_tab_verdict` narrows it to one shape. Rule 2 answers:

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | It creates one tab that shows an acpmux session of this Mac. The tab itself runs nothing. The session behind it is created over the phone's `acpmux` lane with `session/new`, under acpmux's remote guard: an existing folder, an asking policy, no MCP servers, and folder trust held for the person to answer. Codex and opencode are refused families there. The phone may set only `pane`, `workspace`, `cols`, `rows`, `origin`, `mutation_id`, `transaction` and `agent_session {harness, session, host_name}`. `harness` and `session` must be short identifiers (`[A-Za-z0-9._:-]`, at most 64 and 128 bytes). `host_name` is a display name of at most 256 bytes with no control characters. `conversation`/`owner` (another conversation owner), `page`/`route` (the app's own pages) and any other field are refused. |
| Mutates or destroys objects the session does not own? | `agent_session.host` is never the phone's choice. hostd sets it to this Mac's own `install:<id>` (`CNX_AGENT_TAB_HOST`, supplied by the app's `AgentTabStore.localHost`). A phone that names any other host, such as a `registry:` host or another Mac's install, is refused. The tab therefore always belongs to this Mac's acpmux and shows in the Mac app as its own chat. Without `CNX_AGENT_TAB_HOST` (an older app), every `new-conversation-tab` is refused with `unavailable`. The Swift mirror refuses it always, because the irx lane has no such host. |
| Reads local state the remote should not see? | No new read. A session id the phone names is one it can already attach to over `acpmux`. |

- **Rule 3:** no field carries a command, argv, environment or folder. The
  agent's folder is the `session/new` cwd, which acpmux checks.
- **Rule 6 (tests):** `agent_tabs_get_this_macs_host` and
  `agent_tabs_refuse_other_sources_and_hosts` (policy), and the
  `new-conversation-tab` rewrite in `tests/host.rs`.

## `acpmux`: messages larger than one link frame

The link splits a write above 256 KiB into several data frames. hostd now
joins the frames of one phone message until they parse as one JSON value
(`MessageAssembler`, at most 32 MiB) before it sends one WebSocket message,
so a prompt carrying an image reaches acpmux whole. A frame sequence that is
not JSON closes the channel with `bad_request`. This adds no new method and
does not change acpmux's own guard.

## `upload`: phone attachments into this Mac

`upload {name, size, cwd?}` writes the bytes that follow into one new file
and answers `{"path","size"}`. A refusal is answered with
`{"error","message"}` and the channel closes with that code. The phone uses
it for terminal attachments, where the real path is inserted into the
composer and Return is never pressed, and for agent chat files, which are
sent as an ACP `resource_link` to that path.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. It creates one regular file. Nothing is executed, opened or indexed. The file mode follows the umask, without the executable bit. |
| Mutates or destroys objects the session does not own? | It never overwrites. The bytes go to a hidden `.<uuid>.part` file created with `O_EXCL`. That file is hard-linked to `<name>`, or to `<name> 2`, `<name> 3` and so on when the name is taken, and only then removed. A short, long or oversized upload removes the part and leaves nothing. The name is reduced to its last path component. Separators, `:` and control characters are replaced, leading dots and spaces are trimmed, and the name is cut at 120 bytes (`safe_file_name`). The size is declared first and capped at `CNX_UPLOAD_MAX_BYTES` (100 MiB by default). Receiving more than the declared size is refused. |
| Where can it write? | With `cwd`, the folder must exist and be either the folder of a tab the daemon lists right now (`list-workspaces`, canonicalized) or inside `CNX_FILE_ROOTS`. The file goes to `<cwd>/.cmux/attachments/phone-<link session>/`, next to acpmux's own attachments, so the workspace's agent can read it without leaving its folder. hostd canonicalizes that folder again after creating it, so a `.cmux` or `attachments` symlink that points out of the workspace is refused. Without `cwd`, the file goes to `<CNX_STATE_DIR>/uploads/<link session>/` (mode 0700). The phone never picks any other part of the path. |
| Reads local state the remote should not see? | No. The reply contains only the path of the file the phone just wrote. |

- **Rule 6 (tests):** `upload_names_are_safe`, `publish_never_replaces`, and
  the `upload` cases in `tests/host.rs`: a plain upload, a workspace folder, a
  folder that is no tab's and outside the roots (`forbidden`), and an
  oversized upload (`too_large`).
- **Open:** there is no total quota per phone, and old uploads are not
  cleaned up. Both are bounded only by the per-file cap and the person's
  disk.

## `auth`: pairing a phone with this Mac

When the app supervises hostd, every link starts with `auth`. A channel the
phone opens after `auth` waits for its outcome (at most the signature and
approval waits) and is refused with `unpaired` unless it pairs; a channel with
no `auth` before it (`echo` included) is refused at once. The design is in
`verify/phone-approvals.md`.

| Rule 2 question | Answer |
| --- | --- |
| Executes commands or opens content on local objects? | No. Its arguments are two P-256 public keys, a display name and `pair` or `unpair`. It runs nothing and reads no file. |
| Mutates or destroys objects the session does not own? | It can only ask the person to approve this link's own device id (stamped by the backend, never taken from the arguments), or, with `unpair` and a signature by the approved identity key, ask the app to forget that same device. |
| Reads local state the remote should not see? | It answers only a fresh 32-byte challenge and the Mac's own device id. The paired list stays in the app (a 0600 file per signed-in user). |

- **Prompt limits.** A token holder can bring any number of fresh key pairs,
  so the deny list (keyed on the key) alone does not stop it re-asking. hostd
  runs one `auth` at a time per link (`busy`), lets at most 32 channels wait
  behind it (`busy`), and asks at most 3 new identity keys per device id and
  6 in all per 10 minutes. After the person refuses a key, that device id
  asks nothing for 10 minutes whatever key it brings (`rate_limited`). hostd
  asks nothing until the app sent its approved list, so an approved phone is
  never asked again after a hostd restart.
- **Prompt content.** `pair_request` carries `registered_at_ms` (PROTOCOL.md
  "Pairing"): when the backend first saw that device id. The phone sets the
  `name` it shows, so a spoofed "Aziz's iPhone" from a device registered
  minutes ago is visible as new.
- **Rule 6 (tests):** `pairing::tests` and the pairing cases in
  `tests/host.rs` (a token alone reaches no service, a forged signature asks
  nobody, approval opens the link, a new approval key asks again, unpair
  reaches the app, a refused key is closed `denied`, channels opened
  behind `auth` wait for it, one `auth` per link, a refusal silences new keys
  from that device id, and nothing is asked before the app's list arrives).

## Test-only pairing seed (DEBUG builds)

A hidden rig app cannot press the person-only "Allow … to connect?" prompt.
For tagged test instances only, a DEBUG build reads `CMUX_NEXT_IPHONE_PAIRING_SEED`
once at launch: the path of a JSON file `{"devices": [{"id"?, "name"?,
"identityKey"?, "approvalKey"?}]}`. When a phone asks, the app reads that file;
an entry whose given fields all match the request (at least an `id` or a `name`)
pairs it without the prompt, exactly as Allow would (`IPhonePairingSeed`). A
Release build compiles none of it and ignores the variable, so it is no path
for anyone but a developer who launches their own DEBUG build with it. The e2e
rig sets it in the rig app's `LSEnvironment` (`e2e/mac.py`) and names its
simulator; it never clicks Allow and never writes `paired-devices.json`.

## Decisions for the person

- Phone pairing and Face ID signed approvals (`verify/phone-approvals.md`),
  a trust-policy change recommended on issue #13742.
- None for the service: production builds use the production Worker
  (`https://cnx-ios-api.cmux.dev`), and development builds use the dev Worker.
