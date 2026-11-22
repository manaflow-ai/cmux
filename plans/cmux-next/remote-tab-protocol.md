# cmux.rb/1: the remote browser tab service on cmux.rd/1

Status: protocol proposal, 2026-10-04, remote tab lead. Parent: remote-tab.md (RT5, RT6, RT11, RT12), remote-tab-r1.md. Carrier and media engine: remote-desktop.md section 6 and the landed crates `cmux-rd-proto`, `cmux-rd-core`, `cmux-rd-ffi`. Types and reducers: `cmux-tui/crates/cmux-remote-browser`. Shared vectors: `schemas/remote-tab/`.

## 1. Principle

`cmux.rb/1` adds no transport. It is a service that runs inside one `cmux.rd/1` session: the same WireGuard overlay link, the same control stream framing (`u8 type`, `u32 len`, payload; type 1 = control JSON), the same 16-byte datagram header, the same packetizer, FEC, NACK, reassembly, flow control, congestion control, quality ladder, input sequencing with redundancy, feedback and recovery. rb defines only (a) the control messages of a browser tab, (b) the browser input events carried inside rd input datagrams, and (c) which rd stream carries which surface. Every rb control message has a `t` value that starts with `rb.`; rd's own control messages (`hello`, `welcome`, `start`, `stop`, `stats`, ...) keep their meaning.

## 2. Session setup

1. The viewer opens an rd session as today (`hello`, carrier choice, `max_datagram`), with the new field `service: "rb/1"` (rd change C1).
2. The viewer sends `rb.open {tab, profile, viewer, screen, caps}`. The remote browser host checks the tab record (workspace store: `runtime_host` is this host, the viewer's principal may view the tab) and the relay rule (default deny for `remote.*`, D20), then answers `rb.opened {session, main_stream}` or `rb.refused {reason}`. The `screen` in `rb.open` is the viewer's screen seq 0: after `rb.opened` the host sends `rb.screen_applied {seq: 0}`, and the viewer's first `rb.screen` carries seq 1.
3. Media flows on rd stream `main_stream` (stream 0 by convention). Popup surfaces get their own streams (`rb.surface.show {stream}`).
4. `rb.visibility {visible}` pauses and resumes. Hidden pane = paused stream (RD3); the page becomes a background page when no viewer is visible.
5. `rb.close` ends this viewer's session. Closing the tab is a store op (`tab.close`), never an rb message.

Overlay service name (open question Q5 in remote-tab-r1.md): proposal is a separate catalog service `remote-browser` on overlay port 4104 that speaks the rd protocol, so a network policy can allow "stream my browser profile" without "control my desktop". Fallback: port 4103 with the hello `service` field only.

## 3. Channels

| Content | Carrier | Notes |
| --- | --- | --- |
| page video, popup surface video | rd `Video`/`Fec` datagrams, `stream` = surface stream | unchanged rd frame body (H.264/HEVC access unit) |
| lossless tiles (top-off of static regions, RT4) | rd datagrams of a new kind `Tile` (rd change C3), same shard and FEC machinery, `stream` = surface stream | tile payload: `u16 x, u16 y, u16 w, u16 h, u8 codec, ...`; codec is r2 work |
| page audio | rd `Audio` datagrams | Opus 48 kHz, 10 ms (r5) |
| mic, camera, screen share up | rd datagrams of a new viewer-to-host media kind (rd change C4) | r5 |
| keys, pointer, wheel, pinch, IME | rd `Input` datagrams, one service-defined event tag (rd change C2) | rd applies each sequence number once and in order and repeats until acked; rb events are the payload |
| everything else in section 4 | rd control stream, JSON | reliable, ordered |
| uploads and downloads (bytes) | rd control stream, new stream frame type 3 `bulk` (rd change C5): `u64 transfer id`, `u64 offset`, bytes | keeps file bytes out of JSON; at most one bulk frame per media frame interval so control latency stays bounded |

## 4. Control messages

Field types are in `cmux-remote-browser/src/proto.rs`; `schemas/remote-tab/messages.json` has one example of each, and every implementation must round-trip it byte-identically through its JSON model (key order is not significant).

Direction: V = viewer to host, H = host to viewer.

| `t` | Dir | Fields | Meaning |
| --- | --- | --- | --- |
| `rb.open` | V | `tab`, `profile`, `viewer`, `screen`, `caps` | start viewing a remote tab |
| `rb.opened` | H | `session`, `main_stream` | accepted |
| `rb.refused` | H | `reason` | refused (`not_runtime_host`, `not_allowed`, `relay_denied`, `profile_missing`, `busy`) |
| `rb.close` | V | | stop viewing |
| `rb.closed` | H | `reason` | the host ended this viewer's session |
| `rb.state` | H | `state` | session state (section 5.1) |
| `rb.visibility` | V | `visible` | pane shown or hidden |
| `rb.screen` | V | `seq`, `screen` | viewer screen and pane size changed; the host applies the smallest visible viewer (section 5.1) |
| `rb.screen_applied` | H | `seq`, `pixel_width`, `pixel_height`, `scale` | the size frames now have; until it arrives the viewer stretches the last frame. `seq` is the receiving viewer's own last seq (0 = the screen in its `rb.open`): when one viewer's change moves the applied size, each viewer gets it under its own seq, never another viewer's |
| `rb.vsync` | V | `timebase_us`, `interval_us` | viewer display timing in the rd session clock; drives begin frames (RT12, RP3) |
| `rb.page` | H | `url`, `title`, `loading`, `can_go_back`, `can_go_forward` | runtime facts; the viewer forwards URL and title to the store only for the record's current URL revision (OWNERSHIP) |
| `rb.history` | V | `op` (`back`, `forward`, `reload`, `reload_no_cache`, `stop`) | history and loading are owned by the page runtime |
| `rb.navigate` | V | `url` | the omnibar (local chrome, RT11) loads a typed or opened address in the page |
| `rb.key_unhandled` | H | `input_seq` | the page did not handle the key with that input sequence number; the viewer runs its menu or KeyRouter action for it |
| `rb.cursor` | H | `cursor` | `{kind}` for standard shapes, `{kind: "custom", hash}` for an image |
| `rb.cursor_image` | H | `hash`, `width`, `height`, `hotspot_x`, `hotspot_y`, `scale`, `png_base64` | sent once per hash per session; the viewer caches it |
| `rb.tooltip` | H | `text` (null hides) | native tooltip |
| `rb.status_url` | H | `url` (null hides) | link hover status |
| `rb.text_input` | H | `input_type`, `composition_rects`, `caret` | for NSTextInputClient `firstRectForCharacterRange` and the IME candidate window (RP5) |
| `rb.menu.show` | H | `token`, `menu` | context menu or `<select>` (section 5.2) |
| `rb.menu.result` | V | `token`, `choice` | user choice |
| `rb.menu.cancel` | H | `token` | the page or host closed the menu |
| `rb.dialog.show` | H | `token`, `dialog` (`alert`, `confirm`, `prompt`, `beforeunload` with `origin`, `message`, `default_text`, `is_reload`) | JS dialog as a native sheet |
| `rb.dialog.result` | V | `token`, `accept`, `text` | |
| `rb.dialog.cancel` | H | `token` | the page closed the dialog itself (it navigated away or closed; Chromium reset its dialog state): the viewer closes the sheet and sends no answer |
| `rb.file_chooser.show` | H | `token`, `mode` (`open`, `open_multiple`, `folder`, `save`), `accept`, `default_name` | |
| `rb.file_chooser.result` | V | `token`, `files` (null = cancel; else `{upload, name, size, mime}` per file) | bytes follow as bulk frames under each `upload` id |
| `rb.upload.end` | V | `upload`, `sha256` | upload complete; the host verifies and gives the file to the page |
| `rb.download.begin` | H | `download`, `url`, `suggested_name`, `mime`, `total` | bytes follow as bulk frames; the viewer writes ~/Downloads with quarantine and WhereFroms |
| `rb.download.end` | H | `download`, `status` (`complete`, `cancelled`, `failed`) | |
| `rb.download.cancel` | V | `download` | |
| `rb.permission.request` | H | `token`, `origin`, `kinds` | camera, microphone, geolocation, notifications, clipboard_read, midi, ... |
| `rb.permission.result` | V | `token`, `grant` | site permission decided on the viewer; macOS TCC is the viewer's own prompt |
| `rb.clipboard.push` | V | `seq`, `items` | before a paste key or a Paste menu item (no continuous mirroring) |
| `rb.clipboard.write` | H | `items` | the page copied; the viewer writes the pasteboard |
| `rb.open_tab` | H | `request`, `url`, `disposition` (`foreground_tab`, `background_tab`, `new_window`, `popup`), `user_gesture` | Cmd-click, `window.open`, target=_blank; the viewer creates the tab through the store on the same runtime host |
| `rb.open_tab.result` | V | `request`, `tab` or `refused` | |
| `rb.surface.show` | H | `surface`, `stream`, `kind` (`page_popup`, `extension_popup`, `autofill`, `bubble`), `anchor`, `width`, `height` | popup surface (RT5, RP7); the viewer shows a borderless child panel at the anchor |
| `rb.surface.update` | H | `surface`, `anchor`, `width`, `height` | |
| `rb.surface.hide` | H | `surface` | |
| `rb.find` | V | `query`, `forward`, `match_case`, `next` | |
| `rb.find.stop` | V | `keep_selection` | |
| `rb.find.result` | H | `matches`, `active` | |
| `rb.scroll.claim` | V | `scroller`, `gesture` | r9 split compositor: client becomes the scroll writer (section 5.3) |
| `rb.scroll.update` | V | `scroller`, `gesture`, `offset` | r9; carried as an input event in production, listed here for the reducer |
| `rb.scroll.release` | V | `scroller`, `gesture`, `offset` | r9 |
| `rb.scroll.offset` | H | `scroller`, `offset`, `seq` | r9: server-written offset |
| `rb.cookie.change` | both | `site`, `change` (`key`, `version`) | live cookie sync between profile owners (section 5.4); not a viewer message, it runs between the two profile owners over their own link |

## 5. Pure reducers (shared vectors in `schemas/remote-tab/`)

Each reducer is `(state, input) -> (state', effects)` or a pure function, with no clock (time is an input). Each implementation (Rust host, Rust client core, any later port) replays every vector case from the given initial state.

### 5.1 Session state (host, one per remote tab) — `session.json`

States: `idle`, `opening`, `live`, `paused`, `crashed`, `closed`.

| Input | From | To | Effects |
| --- | --- | --- | --- |
| `open {viewer, screen}` | idle | opening | `start_page`, `apply_screen`, `start_capture` (the viewer is visible) |
| `open {viewer, screen}` | opening, live, paused, crashed | unchanged, except paused → live | viewer joins or re-opens as visible: `apply_screen` if the canonical screen changed; from paused also `start_capture`, `notify_state` |
| `first_frame` | opening | live, or paused when no viewer is visible | `notify_state` (and `stop_capture` when paused) |
| `visibility {viewer, visible}` | any open state | live → paused when no viewer is visible; paused → live when one is | `apply_screen` if the canonical screen changed, then `stop_capture` / `start_capture`, `notify_state` |
| `screen {viewer, screen}` | any open state | unchanged | `apply_screen` if the canonical screen changed |
| `leave {viewer}` | any open state | live → paused when no visible viewer remains | `apply_screen` if viewers remain and the canonical screen changed; `stop_capture`, `notify_state` when it pauses; the page runtime stays (the tab is the store's) |
| `renderer_crashed` | opening, live, paused | crashed | `stop_capture` if capturing, `notify_state` |
| `reload` | crashed | opening | `start_page`, `start_capture` |
| `close` | any but closed | closed | `stop_capture` if capturing, `stop_page` if a page was started |
| any other input in idle | idle | idle | reject `not_open` |
| an input not listed for the state | | unchanged | reject `unexpected` |
| anything | closed | closed | reject `closed` |

Effects come in this order: `start_page`, `apply_screen`, capture change, `notify_state`. Canonical screen: among visible viewers (all viewers when none is visible), the smallest CSS width and the smallest CSS height, independently (U6, the terminal rule); the scale is the largest scale of those viewers, so no visible viewer upscales. `apply_screen` is emitted only when the canonical screen differs from the last applied one. Unknown viewer in `visibility`, `screen`, `leave`: reject `unknown_viewer`.

### 5.2 Menu token lifecycle (host, per session) — `menu-token.json`

- Tokens are u64, start at 1, increase by 1, never repeat in a session. At most one menu is open (Chrome's rule).
- `show {kind, item_ids, item_count, multiple}`: if a menu is open, it is cancelled first (`chrome_cancel {token}` and `viewer_cancel {token}`); the new token opens (`viewer_show {token}`).
- `result {token, choice}`: token open → validate the choice, then `chrome_continue {token, choice}` and close. Token below the next token but not open → ok, no effect (`duplicate`). Token never issued → reject `unknown_token`. Invalid choice → reject `invalid_choice`, the menu stays open in the reducer. The host then cancels that menu as a defense (as a `page_cancel {token}`: Chromium gets cancel, the viewer gets `rb.menu.cancel {token}`), so a viewer that sends a choice it was never shown cannot leave Chromium's menu waiting.
- Choices: `cancel` (always valid); `command {id}` (context menu; id must be one of the menu's `item_ids`); `indices {indices}` (select; each < `item_count`, unique, exactly one unless `multiple`).
- `page_cancel {token}`: token open → close, `viewer_cancel {token}`. Otherwise no effect (`stale`).
- `viewer_gone`: an open menu is cancelled (`chrome_continue {token, cancel}`).

The same lifecycle serves dialogs, file choosers and permission prompts (one open per kind); r4 adds those vectors. Dialogs today: tokens start at 1 per session; a new dialog cancels one still open on the viewers; when Chromium resets its dialog state (navigation, close) the host drops the callback and sends `rb.dialog.cancel {token}`, and a later `rb.dialog.result` for that token does nothing.

The viewer checks its own answers too (client vectors, `client.json`): a menu choice the shown menu did not offer is refused as `invalid_choice` and is never sent, and the menu stays open. The viewer makes a new client for each rb session (each `rb.open`), because tokens and screen seqs restart per session.

### 5.3 Scroll-offset writer handoff (r9) — `scroll-writer.json`

One writer per scroller at a time (OWNERSHIP, remote-tab.md 1a). Host state per scroller: `writer` (`server` or `client` with a gesture id), `offset`, `max`, `pending` (a programmatic offset deferred during a client gesture), `seq` (last server offset message).

- `claim {gesture}`: writer becomes `client(gesture)`, at once, from any state (a new gesture replaces an older one of the same viewer). The server stops writing this scroller.
- `update {gesture, offset}`: only from the current writer, else reject `not_writer`; offset is clamped to `[0, max]`; effect `apply_to_page {offset}` (Blink fires scroll events and runs scroll-linked work).
- `release {gesture, offset}`: only from the current writer, else reject `not_writer`; offset clamped; writer becomes `server`. If a programmatic offset is pending it is applied now (last one wins) and sent: `apply_to_page`, `send_offset {offset, seq}`. Otherwise effect `apply_to_page {offset}` only.
- `programmatic {offset}` (script `scrollTo`, anchor navigation, focus scroll; the page has already applied it): writer `server` → offset = clamp(offset), `seq` + 1, effect `send_offset {offset, seq}`; writer `client` → `pending = offset`, no effect (the user's gesture wins while it runs).
- `extent {max}` (content size changed): always applies; offset is clamped; if the clamp changes the offset and the writer is `server`, effect `send_offset`; if the writer is `client`, effect `send_extent {max}` and the client clamps.
- Client rule (not a vector): the client ignores `rb.scroll.offset` for a scroller while it is the writer, and after a release it accepts only messages with `seq` greater than the last `seq` it saw before its claim.

### 5.4 Cookie sync conflict rule (RT9) — `cookie-sync.json`

Pure function `resolve(local, remote, ctx) -> outcome`, evaluated on the machine that receives `remote`. A cookie version is `{value, last_update_us, origin, deleted, expires_us}`; key = (name, domain, path, partition key), already matched by the caller. `ctx = {site, granted_sites, phase: initial|live, now_us}`.

Rules in order:
1. `site` not in `granted_sites` → `drop_not_granted`.
2. A version whose `expires_us` is not null and `<= now_us` counts as deleted.
3. Both absent or deleted, or equal `(value, deleted)` → `noop_equal`.
4. `phase = initial` and both present, not deleted, values differ → `prompt` (the two machines may be signed in to different accounts; never overwrite without the user).
5. Otherwise the larger `last_update_us` wins; on a tie the larger `origin` (byte-wise string order) wins, then a deletion beats a value, then the larger value (byte order) wins, so both machines pick the same version. Local wins → `keep_local`; remote wins → `take_remote`. A deletion is a version and wins by the same rule (tombstone).
6. A missing side is "absent": it loses to any present version (absent has no time), except rule 3.

HttpOnly and partitioned cookies are ordinary versions here. Echo suppression is rule 3: a change that comes back equal is a no-op.

## 6. Input events (inside rd input datagrams)

JSON form (`InputEvent` in `proto.rs`); the binary form for the datagram is r3 work and keeps the same fields. Every event names its `surface` (0 = page).

| `e` | Fields |
| --- | --- |
| `key` | `down`, `code` (DOM `KeyboardEvent.code`), `key`, `text`, `unmodified_text`, `modifiers`, `repeat`, `location`, `edit_commands` (`[{name, value}]`, from the viewer's key bindings, RP4) |
| `pointer` | `kind` (`move`, `down`, `up`, `enter`, `leave`), `x`, `y` (CSS px, f32), `button`, `buttons`, `click_count`, `modifiers`, `pointer_type` |
| `wheel` | `x`, `y`, `dx`, `dy`, `precise`, `phase`, `momentum_phase` (`none`, `began`, `changed`, `ended`, `cancelled`, `may_begin`), `modifiers` |
| `pinch` | `phase`, `scale`, `x`, `y` |
| `ime_set_composition` | `text`, `underlines` (`[{start, end, thick}]`), `selection_start`, `selection_end`, `replacement` (`[start, end]` or null) |
| `ime_commit` | `text`, `replacement` |
| `ime_finish` | `keep_selection` |
| `ime_cancel` | |

Rules: moves are coalesced to the frame rate on the viewer and never across a button change; every key repeat is sent (the host never repeats); cmux-reserved shortcuts never leave the viewer; `rb.key_unhandled {input_seq}` refers to the rd input sequence number of the `key` down event.

## 7. Changes rb needs in rd (for the lane 17 lead; not made by this lane)

| Id | Change | Why |
| --- | --- | --- |
| C1 | `hello.service` (string, default `"desktop"`), echoed in `welcome`; unknown service → `refused {reason: "service"}` | one engine, several services; versioning of rb |
| C2 | rd input event tag `service` (0x80): `u16 len` + opaque bytes, applied in order and acked like other events; size bound = `max_datagram` minus headers | browser input needs modifiers, phases, IME, edit commands; rd stays browser-agnostic |
| C3 | datagram kind `Tile` (lossless tile frames) using the frame/shard/FEC/reassembly path, with `ref_frame` semantics "applies on top of frame N" | RT4 top-off without a second packetizer |
| C4 | viewer-to-host media kind (mic, camera, screen share) with the same shard path in the other direction | RT/r5 media up |
| C5 | stream frame type 3 `bulk` (`u64 transfer`, `u64 offset`, bytes) with a scheduler rule: one bulk frame per media frame interval while video flows | uploads and downloads without base64 in JSON |
| C6 | per-stream feedback and recovery (keyframe or LTR request) for streams other than 0 | popup surfaces are separate streams |
| C7 | move the carrier (`cmux-rd-host/src/wire.rs` framing and `Control` hello types) and the encoders (`vt.rs`, `x264.rs`) into shared crates (`cmux-rd-carrier`, `cmux-encode`, both named in remote-desktop.md section 3) | the remote browser host reuses them instead of copying |
| C8 | rd session clock offset exposed to services (viewer clock ↔ host clock) | `rb.vsync` timing (RT12) |
