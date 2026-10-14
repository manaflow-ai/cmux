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
  - Remove in Settings > Mobile forgets the phone on the service
    (`DELETE /v1/devices/:id`, which closes its signaling socket). It also
    tells hostd (`drop_phone`), which closes that phone's live links at once.
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

## `daemon`: agent tabs and tab create, close and select

Added by `feat-cnx-ios-dataflow` so tabs made on the phone are real tabs of
the Mac.

- **Terminal and browser tabs** use commands already on the allowlist:
  `new-tab {pane, cols, rows}` (size and placement only, as above),
  `new-browser-tab {url, pane}`, and `close-surface {surface}`. Selecting a
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

## Decisions for the person

- Phone-signed approvals or relayed Mac approvals for agent permission
  questions.
- The production Worker (`cnx-ios-api-prod`) deployment. Production builds use
  the dev Worker today.
