# cmux next: computer use (CUA host, sessions, Agent activity pane)

Design note, 2026-10-02. Owner: the cmux-next computer use lead. Binding inputs: cmux-next-spec `spec/computer-use.md` (draft 2, incl. remote view and the measured lessons), `decisions.md` D15, D18, D19, D20, `spec/identity-and-permissions.md` (sections 3, 4a, 5, 6), `spec/operation-catalog.md`, `research/computer-use.md`; OWNERSHIP-PRINCIPLES.md; architecture.md; browser-host.md (sibling host, same identity rules). Engine: cmux-cua, `manaflow-ai/cmux-cua`, live line `cmux-cua-native` (code in `libs/cmux-cua/rust`), pinned in `scripts/build-cmux-cua.sh` at `e0f73880` (the `cmux-pin/display-placement` line, which includes the reliability-journal stack and PR 27). This note does not change the spec; where it narrows or orders something it says so.

User goal (verbatim): "SOTA computer use, for both linux and macOS. we need to improve cmux CUA drastically. in terms of observability (should have a pane to see all cua windows happening, be able to view their timeline screenshots), visibility into which agent started the cua session, etc..."

## 0. What exists today

- cmux-next: computer use is typed-unavailable (`palette.computerUse.setup`, `computerUseFocus`, `computerUseFocusCallingTerminal`, `computerUseStop` in `AgentHandlers.swift`); only the two "Grant ... Access" palette actions work (they open System Settings). The helper build, signing and notarization steps are deleted on this branch (deletion.md, M-gate row "drop, or keep if Computer Use returns"). `cmux-tui` has a `computer-use` remote service whose `invoke-computer-use` is "unavailable in protocol 5" and whose provider is "not configured" (`cmux-remote/src/services.rs`).
- Old app (main): `Packages/macOS/CmuxComputerUse` plus `Sources/App/ComputerUse*` start the helper, run onboarding, and infer "which agent drives which window" by scanning HMAC-signed state files (`DriverProcessState`: driver pid, kernel-verified writer pid + start time, caller session string, last target) and joining the writer pid against the agent process index. Inference, not ownership. Nothing in it is ported.
- Engine (cmux-cua at the pin): a session is a caller-chosen string (`start_session(session)`), used for the cursor color, per-session config and recording ownership; it is not authenticated. Session state lives in process-global statics (`session.rs`: activity map, `ENDED_SESSIONS` that never shrinks). Recording is one daemon-global `RecordingSession` (per-turn `turn-NNNNN/` folders, off by default; a second session's start replaces the first). There is no durable event log, no session list API and no timeline. `begin_turn`/`finish_turn` in `cmux-cua-core/src/recording.rs` is the one chokepoint every non-read-only tool call passes; it already captures before/after window frames and the click point when recording is on.
- Reliability: 12.6 percent of agent calls failed in 2026-09-20..29 (idle sweep ending live sessions, 55 s permission stall); fixes are on the pin line.

## 1. Process model

```
agents ──MCP stdio (cmux-cua mcp proxy) / catalog op cua.* / cmux cua CLI──▶ CUA host
                                                                             (cmux-cua serve, Rust)
  macOS: inside "cmux Computer Use.app" (com.cmuxterm.cua), LaunchServices-launched by the proxy
  Linux: the same binary, started by the proxy or the session host; no TCC
CUA host
  ├ dispatcher: one envelope for every request {op, args, idempotency_key, origin} + connection identity
  ├ activity store (NEW, Rust): cua_session records, event log, thumbnails, frames, retention, redaction
  ├ policy (user-set denylist only, D15), consent, scope from the credential
  ├ engine: macOS AX + SkyLight/CGEvent + ScreenCaptureKit; Linux AT-SPI + X11/XTest + Xvfb + cua-compositor
  └ cursor overlay (helper draws it; works with the app closed)
session host (cmux-tui daemon): mints launch credentials; supervises the CUA host and headless displays on Linux;
  relays cua.* reads/streams to remote clients over the daemon relay (D20 rules)
Mac app: Agent activity pane + titlebar indicator + onboarding window (projections; no session logic)
```

Decisions in this note (each also in section 9 for Lawrence):

1. **The CUA host stays the cmux-cua daemon, in the cmux-cua repo.** The activity store is a new module family in `cmux-cua-core` (pure reducer, redaction, retention, schema) plus a SQLite store in the daemon crate. Reason: it must run inside the signed helper (TCC), on Linux unchanged, and it must see every tool call at the dispatcher. Hosted Linux CI (`ci-rust-linux.yml`, `cargo test -p cmux-cua-core ...`) already covers `cmux-cua-core`, so every step gets hosted verification without local cargo.
2. **One store per daemon process.** The native and Codex-compat profiles are separate daemons on separate sockets; each owns `<state>/cua/activity-<profile>.sqlite` and its blobs (single writer per file). Readers merge by session id; ids embed the profile (`cua_n_…`, `cua_c_…`).
3. **The Mac app reads the local CUA host directly** (owner = CUA host, OWNERSHIP-PRINCIPLES "one code path picks the owner"), over the host's existing per-user socket with the app's identity; remote machines go through the session host relay. The app never parses state files.
4. **Who starts the host:** unchanged: the `cmux-cua mcp` proxy launches the helper on the first call (macOS) or `serve` (Linux). The pane only connects when the socket appears (one directory event, no polling) and shows "no computer use on this Mac yet" until then.

## 2. Ownership

| Entity | Owner (single writer) | Writers through ops | Readers |
| --- | --- | --- | --- |
| `cua_session` record | CUA host of that machine | agent with a credential: `start`, `end`, acts; user origin: `stop`, `pause`, `resume`, `policy` | pane, CLI, TUI, iOS (relay), mux |
| `cua_event` log, thumbnails, frames, export bundles | CUA host | appended by the dispatcher only; retention deletes | same; frames per D19 rules (section 5) |
| cursor overlay state | CUA host | derived from events | drawn by the helper |
| launch credential | session host | n/a | CUA host verifies it |
| headless displays on Linux/VMs | session host | n/a | CUA host uses them |
| "Agent activity" tab placement | workspace store (tab kind `agent_activity {machine?, cua_session?}`) | store ops | app |
| selection, scrub position, watch toggle, filters | client (pane view state) | that client | that client |

Invariants (CUA host reducer, property tested):

- C1 user stop wins: after `cua.session.stop` commits, every later agent op on that session is rejected `session_stopped`; no act reaches the engine. Pause rejects acts with `session_paused` until `resume`.
- C2 idempotent acts: a retried act with the same `(session, idempotency_key)` returns the first result and never reaches the engine twice (bounded TTL cache, 10 min, 4096 entries per session).
- C3 identity is stamped, never accepted: `agent`, `actor`, `on_behalf_of` in records and events come from the connection; any caller-supplied value is ignored.
- C4 monotonic log: event `seq` is gap-free per session; retention deletes whole prefixes of frames, never punches holes into events.
- C5 no clear text: no stored event contains the `text` of `type_text`, `set_value`, printable `press_key`, `page.insert_text`/`type_keystrokes`, or JavaScript source (section 5).
- C6 ended is terminal: `ended` never goes back to `active`; `start_session` with the same label after end creates a new session id (the label is the idempotency key only while live).

## 3. Session model

```
cua_session {
  id: "cua_<profile>_<ulid>",            // minted by the host; the caller's string is `label`
  machine, profile: native | codex_compat,
  label,                                  // old free-form `session`, display + live idempotency key
  agent: {                                // stamped from the connection (C3)
    attribution: credential | process_tree | none,
    kind: claude | codex | acp:<harness> | mux | cli | script | unknown,
    class: mux | agent | user,            // D20; from the principal record when the credential carries one
    actor, on_behalf_of?,                 // identity-and-permissions.md section 5
    agent_id?, terminal_id?, acp_session?, workspace_id?, harness_session_id?,
    proxy_pid, proxy_pid_start            // kernel peer credentials of the MCP proxy
  },
  origin: mcp | cli | acp | script | remote,
  color,                                  // derived from id; cursor, chip and timeline share it
  started_at, ended_at?, last_action_at,
  status: active | idle | paused | ended(reason: agent_end | idle_ttl | user_stop | host_restart | policy),
  delivery: background | foreground_only, // foreground_only on a user's real Wayland desktop
  targets: [{app_bundle_id?, app_name, pid, pid_start, window_id?, title_redacted?, display?}],
  scope: {apps_allowed?, apps_denied?, ttl, consent_ref?},
  counters: {observes, acts, errors, frames, bytes},
  recording: events | events+frames | video   // events+thumbnails is the floor, always on
}
```

Attribution, in order of strength (the pane shows which one applied; never silently):

1. `credential` (target): the proxy presents the session host's launch credential `HMAC(host_key, {host, terminal|acp_session, agent?, issued_at})`; the CUA host verifies it with the session host (socket call `credential.verify`, cached per proxy connection). Not implemented anywhere yet (identity-and-permissions.md section 6 calls it a near-term item); the session host owner builds it, this lane consumes it.
2. `process_tree` (interim, ships first): the CUA host already gets the proxy's kernel peer credentials (pid + start time). It asks the session host `terminal.for_pid {pid, start}`; the session host walks the process ancestry of its own terminals (it spawned them, it knows each root pid and start time) and answers `{terminal_id, workspace_id, agent_id?, harness_session_id?}` or nothing. This cannot be forged by an environment variable; a same-uid process can still reparent itself into a terminal's tree, which is inside the D16 trust boundary.
3. `none`: a raw `cmux-cua call` from outside any cmux terminal: `kind: cli`, no terminal link.

Caller-claimed values (an env var such as `CMUX_TUI_TERMINAL_ID` forwarded by the proxy) are never used for attribution; they may be shown as `claimed_terminal` in diagnostics only.

Lifecycle: `start` (explicit `start_session` or implicitly on the first act with a new label), `idle` after 5 min without calls (still live; the cursor fades), `ended` on `end_session`, on idle TTL (30 min, the pin's sweep, but it must skip a session with an in-flight call), on user stop, or `host_restart` (records found `active` at host start are closed with that reason; the log survives the restart).

## 4. Event log and frames

Event row (append-only, written by the dispatcher in the same transaction as the act's result):

```
cua_event {
  session, seq, ts, tx,                   // tx = request transaction id; every request ends with request-settled
  kind: session.start | session.end | session.stop | session.pause | session.resume | observe | act
        | policy.reject | consent.request | consent.decide | error | browser.* (later, same schema),
  tool, actor, origin,
  target: {app_name, pid, window_id?, element?: {index?, role, label_redacted, frame}},
  args_redacted,                          // section 5
  result: {ok, effect: confirmed | unverifiable | suspected_noop, verified, error_code?, escalation?},
  duration_ms, click_point?,
  before_frame?, after_frame?,            // blob ids (thumbnail always when pixels exist; full frame per recording)
  ax_digest?,                             // hash + count of the AX tree seen, for diffs; no AX text
  untrusted_read?                         // true when the last observe read another app's text (spec "flags acts that follow reading untrusted text")
}
```

- Thumbnails: about 320 px long edge, JPEG q70, made from pixels the call already captured (every act's after-frame, every observe that returned a screenshot). No extra capture for events that have no pixels. Acts also get a before thumbnail when the engine captured one.
- Full frames (PNG/JPEG at capture size) only when `recording` is `events+frames` or `video` for that session. Video is the existing ScreenCaptureKit (macOS) / ffmpeg (Linux) path, per session now: the global singleton becomes a map keyed by session id, so session B no longer replaces session A.
- Storage: `<state>/cua/activity-<profile>.sqlite` (WAL, `synchronous=NORMAL`: losing the last few events on power loss is acceptable for an audit trail of a physical action that already happened; a crash of the process loses nothing) and content-addressed blobs `<state>/cua/blobs/<sha256[0..2]>/<sha256>.<ext>` written before the row that names them. `<state>` is `~/Library/Application Support/cmux/cmux-cua/<scope>/` on macOS (helper-owned, as today) and `$XDG_STATE_HOME/cmux/cmux-cua/<scope>/` on Linux.
- Writes never block an act: the engine result is returned after the row commit (a few hundred microseconds), thumbnail encoding runs on a bounded worker (queue 64; when full, the thumbnail is dropped and the event says `frame_dropped: queue_full`).

## 5. Retention, redaction, remote frames (D19)

Retention (one pure planner, `retention::plan(now, sessions, blobs, caps) -> Deletions`, run at host start, after each session end and on a one-shot `DemandTimer` at the next expiry; never a periodic sweep):

| Item | Rule |
| --- | --- |
| events and session records | 30 days after `ended_at` (live sessions never expire) |
| frames and thumbnails | 7 days after capture, or earlier to keep the machine total at or under 2 GB (oldest frames of ended sessions first, then oldest frames of live sessions; full frames before thumbnails) |
| per session | 500 MB frames (full frames first, then thumbnails, oldest first) and 20,000 events (past it the oldest prefix of events goes, with their frames; seq stays gap-free from the new first event) |
| export bundles | written where the user asks; not counted, not deleted |

Frames go before events (spec): only the 30-day rule and the per-session event cap delete events. A frame removed by retention leaves its event with `frame: expired`.

Redaction at write time (C5). The spec says typed text is never stored in clear; this note applies that to everything an agent can make the machine type or inject:

- `type_text.text`, `set_value.value`, `page.insert_text.text`, `page.type_keystrokes.text`, a `press_key` of one printable character without a command modifier, and the characters of `perform_actions` steps of those kinds: stored as `{redacted: "text", length}`. No hash (a short text hashed with a key on the same disk is guessable).
- `page.execute_javascript.javascript`: stored as `{redacted: "javascript", length}` by default (it can carry the same secrets as typed text). A user policy `store_javascript: true` keeps the first 4 KB. Decision for Lawrence (section 9).
- Hotkeys with a command, control or option modifier, key names (`return`, `tab`, arrows), coordinates, element indices, app names and window ids: clear.
- AX: element labels of secure text fields are masked; the stored `ax_digest` keeps no AX text at all.
- Frames: ScreenCaptureKit content filters exclude password manager and authentication UI windows from stored frames (capture redaction, not an action denylist, D15); secure field rectangles from the AX snapshot are blurred before the thumbnail is encoded. Linux: crop and blur from AT-SPI `PASSWORD_TEXT` roles. A screenshot of a field that shows typed text in clear (not a secure field) is stored as captured; the pane says so in its info popover.

Remote clients (D19): an iPhone or another Mac sees session records, events and thumbnails only while it shows the pane (fetched through the relay on demand, never pushed); full frames and live frames only after the user presses Watch on that client (user origin). Frames never leave the machine on their own.

## 6. Ops and surfaces (catalog, owner `cua-host`)

Reads (idempotency forbidden): `cua.sessions.list {machine?, status?, agent?, since?, limit, cursor}`, `cua.session.get {id}`, `cua.session.timeline {id, after_seq?, limit, include: [events, thumbnails]}` (events plus thumbnail blob ids), `cua.frame.get {blob, size: thumb|full}`, `cua.policy.get`.

Streams: `cua.sessions.subscribe` (record changes), `cua.session.events.subscribe {id, after_seq}`, `cua.surface.watch {id, window?}` (user origin; live frames; push-based: ScreenCaptureKit `SCStream` on macOS, XDamage on X11, compositor frame callbacks in `cua-compositor`; at most 10 fps and the pane's pixel size; stops when the watcher detaches or the pane hides).

Mutations: `cua.session.start {label, scope?}` and `cua.session.end {id}` (agent; MCP `start_session`/`end_session` map here), `cua.session.stop {id, reason?}`, `cua.session.pause {id}`, `cua.session.resume {id}`, `cua.policy.set`, `cua.recording.set {id, mode}` (user, or the session for itself), `cua.recording.export {id, format: bundle|mp4}`. Runtime: `cua.act.*`, `cua.observe.*` (the existing MCP tools; names unchanged for agents).

Metadata: `stop`, `pause`, `resume`, `policy.set` are `risk: destructive|mutate-own`, MCP `expose: never` (user origin only, operation-catalog.md section 5). `act.*` is `risk: execute`, `remote_relay: grant` (mux principals of the host's owner only, D20). Reads are `remote_relay: allow` for the owner's own clients.

Surfaces:

- MCP: the existing cmux-cua tools, plus read tools `list_cua_sessions` and `get_cua_session_timeline` (opt-in group; agents should not need them).
- CLI (Rust `cmux`, request to session feat-cmux-next-99 while the CLI is frozen): `cmux cua ls [--all-machines] [--json]`, `cmux cua show <id>`, `cmux cua log <id> [--follow] [--json]`, `cmux cua stop <id>`, `cmux cua pause|resume <id>`, `cmux cua export <id> [--mp4]`. Until then the same verbs ship on the engine binary (`cmux-cua sessions ls|show|log|stop|...`), which the Rust CLI will call through the catalog later.
- App actions (palette, menu, CLI through `cli: true`): `agentActivity.open` (palette "Agent Activity"; opens the tab, reuses an existing one), `agentActivity.stopAll` (stop every live session on this Mac), and the existing `computerUseStop`, `computerUseFocus`, `computerUseFocusCallingTerminal` re-bound to the store (focus the selected session's target window or its originating terminal tab; user origin, so focus is allowed). The palette entries become available as each step lands.

## 7. The Agent activity pane

A tab kind (`agent_activity`) plus the palette action, so it can sit in any column like other tabs (spec open question proposes both; this note builds the tab and the action, no separate global panel). Projection of CUA host state: the Swift module (`CmuxNextAgentActivity`) holds no session logic; it renders an `AgentActivitySource` snapshot plus event stream and sends user-origin ops.

Layout (default variant "split"):

- Left: session list grouped by machine. Row: color chip (cursor color), agent icon and kind ("Claude Code", "Codex", mux name), label, originating workspace and terminal title, target app icons, status pill (active, idle, paused, ended + reason), counts (acts, errors), relative last action. Attribution badge when not `credential` ("process", "unattributed"). Live sessions first, then ended, newest first. Filter field: agent, app, status.
- Right, top: the selected frame, large, with the click marker and element frame drawn over it; for a live session with Watch on, live frames instead (a "Live" pill, the measured fps in the info popover).
- Right, middle: filmstrip of thumbnails (CALayers, decoded off main, virtualized), one per event with pixels; a scrubber; Left/Right step events, Shift+Left/Right step frames, Home/End.
- Right, bottom: event rows (time, tool, target, effect, duration, error code, redaction markers). Selecting a row moves the scrubber and vice versa.
- Toolbar: Stop (always enabled for a live session; user origin), Pause/Resume, Watch, Export, Open Agent (focuses the originating terminal tab or ACP chat), Open Target (raises the target window; user origin).
- Titlebar indicator while any session on this Mac is active: a small chip with the count in the cursor color; click opens the pane.
- Empty and error states: "Computer use is not set up" (opens onboarding), "Helper not running", "No sessions yet", "Remote machine unreachable" (disconnected state; nothing queues).

Prototype variants behind Debug Settings (`AgentActivityTunables.layout`, choice tunable, DEV and NIGHTLY only):

1. `split` (default): list left, preview + filmstrip + events right.
2. `timeline`: one vertical timeline across all live sessions (per-agent lanes, like a trace viewer), click a lane to drill in.
3. `grid`: a wall of live session tiles (latest thumbnail, or live frame when watched), click to open the split view; for many concurrent agents.

Each variant is screenshotted from the mock data source in a contained no-activate window; Lawrence picks.

Performance: idle pane with no live session: zero wakeups. Live session: one wakeup per new event batch (stream push). Thumbnails decoded off main into an LRU of 256 decoded images. List and filmstrip virtualized; 1,000 sessions and 20,000 events per session must scroll at 120 Hz.

## 8. Linux

- Same binary, same store and ops. The session host starts `cmux-cua serve` on demand (or the proxy does, as today) and owns headless displays.
- Cloud VMs and fleet Linux: agent GUI work runs in a headless display owned by the session host. Phase 1: one Xvfb (or nested `cua-compositor`) per machine at `:90`, started lazily on the first `cua.*` op, `delivery: background`, parallel sessions share it with separate cursors (XInput2 MPX where available). Phase 2: one display per workspace, which needs the X11 backend to open one connection per display (today it holds one); tracked as a step, not assumed.
- A user's real desktop: X11 works in the background today; Wayland is foreground-only through the portal and libei, recorded as `delivery: foreground_only` and shown in the pane.
- Frames from a VM reach the pane through the relay as thumbnails; live watch uses the same push sources (XDamage, compositor callbacks). Remote view (spec section "Remote view") is a later lane; its producer is the same CUA host.

## 9. Decisions (Lawrence, 2026-10-02, via the coordinator)

1. Activity store lives in the cmux-cua repo, brought into cmux by a pin bump.
2. Agent identity by process match (`attribution: process_tree`, pane badge "Matched by process") until launch credentials exist.
3. JavaScript through `page.execute_javascript` is hidden like typed text by default; a user policy `store_javascript` keeps the first 4 KB.
4. Fast-mode writes are acceptable (power loss may drop the last events; a process crash loses nothing).
5. The pane is a tab kind plus a palette action; no floating panel.
6. Linux: one headless display per machine first; per workspace later.
7. Helper build, signing and notarization return to nightly and release CI: coordinate with the release lane's existing jobs, use the release environment secrets, same notarization path via the team App Store Connect API key.
8. Default layout: split.
9. A user stop blocks the same label; "Stop agent" refuses new sessions from that agent until the user allows it.
10. Before dogfood, the pane views are rewritten in AppKit (CALayer filmstrip, virtualized lists) as section 7 asks; the SwiftUI views are prototype only.

Storage format (decided in step b, consequence of the no-local-cargo rule and `--locked` CI): no new crate dependency is added, so the store is plain files instead of SQLite: per session `<state>/cua/activity-<profile>/sessions/<id>/record.json` (rewritten atomically by rename) and `events.jsonl` (append-only, one event per line, fsync on session end only), blobs content-addressed under `<state>/cua/activity-<profile>/blobs/`. Retention deletes session directories, rewrites `events.jsonl` without a truncated prefix, and unlinks blobs whose last reference went. A SQLite index can be added later behind the same `ActivityStore` API.

## 6a. Wire protocol (CUA host socket)

Same socket, framing and envelope as the existing daemon (`{"method":...,"args":{...}}` lines, `{"ok":true,"result":...}` replies, optional `auth_token`/`host_auth_token` envelope). User operations require `host_auth_token` (the embedding cmux app holds it; the daemon marks the request `host_authenticated`), which is how the host knows the caller is the user's own client. Agent connections are identified by the proxy's kernel peer pid and start time.

| Method | Args | Result | Who |
| --- | --- | --- | --- |
| `activity_sessions_list` | `{status?: "live"\|"ended"\|"all", since_ms?, limit?}` | `{profile, machine, sessions: [SessionRecord]}` | any local client |
| `activity_session_get` | `{id}` | `SessionRecord` | any |
| `activity_timeline` | `{id, after_seq?, limit?}` (default limit 500) | `{events: [Event], next_seq, frames: {blob: {width, height, source_width, source_height, expired}}}` (click points are in source pixels) | any |
| `activity_frame` | `{blob, size: "thumb"\|"full", id?}` (`id` lets `full` find the full frame of a thumbnail) | `{mime, data_base64}` | any |
| `activity_subscribe` | `{sessions: bool, events_for: [id]}` | stream: one line per update, `{"ok":true,"result":{"type":"sessions","sessions":[...]}}` or `{"type":"events","session":id,"events":[...]}`; ends when the client closes | any |
| `activity_session_stop` / `_pause` / `_resume` | `{id}` | `{applied: bool}` | host-authenticated |
| `activity_agent_stop` / `activity_agent_allow` | `{actor}` | `{applied: bool}` | host-authenticated |
| `activity_recording_set` | `{id, mode: "events"\|"events+frames"\|"video"}` | `{applied: bool}` | host-authenticated or the session's own actor |
| `activity_policy_get` / `_set` | `{store_javascript?: bool}` | policy | set: host-authenticated |

`SessionRecord` and `Event` are the serde shapes of `cmux-cua-core::activity::model` (snake_case enums, `status: {"state": "active"|"idle"|"paused"|"ended", "reason"?}`, timestamps in ms since the epoch). Catalog names map one to one: `cua.sessions.list` = `activity_sessions_list`, `cua.session.timeline` = `activity_timeline`, `cua.session.stop` = `activity_session_stop`, and so on.

Session host lookup for `process_tree` attribution: the CUA host calls the cmux-tui daemon at `CMUX_CUA_SESSION_HOST_SOCKET` (set by whoever starts the host; else the default cmux-tui socket) with `terminal.for_pid {pid, start_seconds}` and caches the answer per proxy connection. No answer within 200 ms means `attribution: none`.

## 10. Steps (each lands with failing tests first)

| Step | Repo | Content | Verification |
| --- | --- | --- | --- |
| a | cmux-cua | `cmux-cua-core::activity`: record and event types, pure session reducer (C1, C2, C3, C6), redaction (C5), retention planner, thumbnail sizing; no I/O | hosted `ci-rust-linux.yml` (`cargo test -p cmux-cua-core`); property tests for C1, C2, C4 |
| b | cmux-cua | daemon store: SQLite schema + blob store + retention executor; dispatcher hook at `begin_turn`/`finish_turn` so every call appends events and thumbnails regardless of recording; per-session recording map | hosted Linux CI with an Xvfb e2e (`e2e-rust-linux.yml`): drive a test app, assert events + thumbnails, no clear text in the database |
| c | cmux-cua | socket methods for the reads, streams and user ops of section 6; `cmux-cua sessions ...` verbs; MCP read tools; `process_tree` attribution through the session host (falls back to `none` when no session host answers) | hosted CI; contract tests against a fake session host |
| d | cmux (`cmux-tui`) | session host: `terminal.for_pid` and later `credential.verify`; relay of `cua.*` reads and streams (D20 rules, relay analysis first); catalog entries owner `cua-host` | hosted cmux-tui verification |
| e | cmux (Swift) | `CmuxNextAgentActivity` module: view model, mock source, three variants behind the Debug Settings switch, screenshots | `swift build --build-tests`, module tests, throwaway demo screenshots |
| f | cmux (Swift) | App wiring: `AgentActivitySource` over the local CUA host socket, tab kind, palette and menu actions re-bound, titlebar indicator | tagged no-activate build; live run against a contained test app (never the user's windows) |
| g | cmux | pin bump of cmux-cua with a–c; helper bundled in cmux-next builds | fleet build; bundle check |
| h | cmux CI | helper signing and notarization in nightly and release (decision 7) | nightly dry run |
| i | cmux-cua | Linux headless display through the session host; `delivery` field; per-workspace displays | hosted Linux e2e |

Not decided here, or UNVERIFIED: ScreenCaptureKit content filters for "authentication UI" need a concrete window list (Keychain, SecurityAgent, 1Password, Bitwarden, ...); SCStream on a backgrounded or occluded window may deliver no frames (pane shows "window hidden"); the Codex-compat daemon's tool names differ, so its events map to the same `tool` vocabulary through a table in step b.

## 11. Progress

| Step | State | Where |
| --- | --- | --- |
| a | done: reducer, redaction, retention, thumbnail sizing; CI red then green | https://github.com/manaflow-ai/cmux-cua/pull/28 (draft, base `cmux-cua-native`) |
| b | done: file store, `ActivityHost`, daemon gate on every tool call, thumbnails, idle sweep; hosted Linux CI green (31 core + 3 daemon tests); Windows compiles | same PR, 68d1e0aec, b5f791766 |
| c | done for the activity methods of 6a (list, get, timeline, frame, subscribe stream, stop/pause/resume, agent stop/allow, recording, policy); `cmux-cua sessions` CLI verbs and the MCP read tools are not done | same PR |
| e | done (SwiftUI prototype views) | feat-cmux-next |
| f | partly done: `AgentActivitySocketSource` (stream + requests, fake-host tests), `cmux://agent-activity` page in a browser tab record, palette and Window menu "Agent Activity"; not done: AppKit rewrite (decision 10), titlebar indicator, Stop All, Computer Use Stop/Focus rebinding, live watch | feat-cmux-next d7c609149b0, 04b1f9019c4 |
| d, g, h, i | not started | |

Notes: user stop, pause and resume are enforced by the connection's authenticated class (`user`, the host-authorized connection), not by the claimed `origin` channel. `StopAgent {actor}` stops every live session of one agent and refuses its new sessions until the user allows it again. Until step d, agents are keyed by the parent process of their MCP proxy (`agent:<ppid>`, kind from its process name), attribution `none`. The act frame is captured after the tool returns, before the reply, with a 300 ms budget. The HTTP MCP transport and the second (non-Unix) call loop in `serve.rs` do not log activity yet. cmux-cua's full Linux test step is red on trunk (6 pre-existing failures in `bundle`, `telemetry`, `version_check`), so the activity tests run in their own CI step first.
