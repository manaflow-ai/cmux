# cmux next: what a third-party file browser needs from the platform

Status: spec proposal, 2026-10-02 (lane 3 helper, first-party apps). Input to `plans/cmux-next/app-platform.md` section 12 (Platform v2: V2 interfaces, V3 documents, V6 handles, 12.4 drag and drop), `plans/cmux-next/app-platform-critique.md` (C5, 2.1) and `plans/cmux-next/transport.md` (lane 12, branch feat-cmux-next-transport). Only the coordinator writes the spec. Prototype: `first-party-apps/finder/` (`cmux/finder`), built with only what a verified third-party app can get: the public `cmux` global, scene views, and the operations below called through `cmux.call` with fixtures.

The test for every proposal: a third-party Finder published by someone else, installed from the store, must be able to browse this Mac, a cmux server, the team VM and a plain SSH host, copy between them with progress, preview files and hand them to terminals and agents, while it never sees an absolute path it was not given, a host name it was not given, or any credential.

## 0. Decisions in this proposal

1. **Handles only.** An app holds `root_…` (a folder subtree), `conn_…` (a connection to a host) and, through drag and drop, per-item references. Paths in app code are relative to a root. There are no path-pattern scopes (agrees with 12.2 item 1).
2. **The app-facing connection handle is `conn_…`, not `host_…`.** `host_…` is already the public id of an enrolled session host (spec `00-overview.md`, `identity-and-permissions.md`): it is enumerable and is not a capability. A plain SSH host has no `host_…` at all. `conn_…` is unforgeable, per (user, app), revocable, and points at either a `host_…` or an SSH target record. DECISION for the coordinator (section 3.1).
3. **The owner of the bytes runs every file operation.** Listing, sorting, filtering, watching, copying and trashing run in the file system owner on that machine (the session host for cmux endpoints, `cmux link` for plain SSH targets). The app sends intents and renders events. A cross-host copy is a job of the destination owner, which pulls from the source owner over the transport.
4. **Listings are owner-side snapshots behind a cursor.** The owner reads, sorts and filters once, hands out batches, and streams watch events with revisions after the snapshot. A 100 000-entry directory never crosses into the app VM; the app holds one page plus a batch.
5. **Every mutation carries the user's gesture; every destructive one also gets a host-owned confirmation.** Scripts, agents and automations reach the same ops through the catalog with their own grant; permanent delete is never available to MCP.
6. **No polling anywhere.** Live updates are `fs.watch` events from FSEvents or inotify on the owner. An SSH target without a cmux daemon has no live watch: the app shows that and relists on user action; nothing polls.

## 1. Threat model and roles

- The app VM is untrusted. It may lie about every parameter. Owners check handle, scope, gesture and path containment on every call.
- The shell (Mac app or `cmux link`) owns every UI that grants something: the folder panel, the connect sheet, host key verification, credential pickers, confirmations, the drag session.
- The file system owner on each machine enforces containment: every relative path is resolved beneath the root's directory descriptor (`openat` with `O_NOFOLLOW` per component on macOS; `openat2(RESOLVE_BENEATH)` on Linux). A symlink whose target is outside the root lists as `symlink` with `target_kind: null` and cannot be followed.
- Agents and automations get the same ops through the catalog (`cmux fs …`, MCP tools) with their own grants; an agent that receives a file by drag gets only that item (section 7.3).

## 2. File-system scopes and root handles

Scopes stay the coarse consent: `fs:read` (list, stat, read, preview, watch, job list) and `fs:write` (mkdir, rename, copy, move, trash, undo). Handles are the fine grant.

### 2.1 `root_…`

Record (owner: app supervisor grant store, V8; per (user, app); replicated to the owner that enforces it):

| Field | Meaning |
| --- | --- |
| `root` | `root_` + 22 random base62 characters; unforgeable |
| `conn` | the connection it lives on (`conn_…`) |
| `base` | absolute path on that machine; **never sent to the app** |
| `rights` | `read` or `read_write` (the user picks; the panel defaults to the scope the app holds) |
| `kind` | `home`, `folder`, `workspace`, `volume`, `remote` |
| `label`, `display` | what the app may show (`"Home"`, `"~/src/orbit"`, `"acme:/home/dev"`); display strings, never parsed |
| `source` | `panel`, `workspace`, `connect_sheet`, `drop`, `automation` |
| `expires_at` | null (persistent) or a time; drop-created roots expire with the drop |

Revocation: Settings > Apps > Finder > Folders lists every root with Remove; `fs.root.release` by the app; uninstall removes all (V9). A revoked root fails every call with `root.revoked` and fires `fs.roots.watch`.

### 2.2 Operations

| Op | Params | Result | Errors | Notes |
| --- | --- | --- | --- | --- |
| `fs.roots.list` | `{conn?}` | `{roots: Root[]}` | `scope.missing` | roots this app holds; scope `fs:read` |
| `fs.root.pick` | `{mode: "folder", conn?, prompt?, rights?}` + gesture | `{root: Root}` | `user.cancelled`, `gesture.required` | host file panel (local) or the host's remote folder picker (remote conn); the app suggests, the user decides |
| `fs.root.release` | `{root}` | `{}` | `root.unknown` | |
| `workspace.roots` | `{workspace}` | `{roots: Root[]}` | `scope.missing` | the workspace's folders as read-only roots, granted while the app holds `workspace:read` and `fs:read`; `read_write` needs one panel confirmation per workspace |
| stream `fs.roots.watch` | `{}` | `{root, change: "added" \| "removed" \| "revoked"}` | | |

### 2.3 Status

`root_…`: proposed in v2 (V6, C5). The ops above: new.

## 3. Host connections (through the transport)

### 3.1 `conn_…` (DECISION)

DECISION: name the app-held connection handle `conn_…` and keep `host_…` for enrolled hosts. RECOMMEND: yes, because `host_…` is a public, enumerable registry id (it cannot be a capability) and plain SSH targets have no `host_…`; `Conn.host` carries the `host_…` id for display and for CLI routing when there is one.

| Field | Meaning |
| --- | --- |
| `conn` | unforgeable, per (user, app) |
| `host` | `host_…` for cmux endpoints (local, cmux server, Cloud VM, team VM), null for plain SSH |
| `kind` | `local`, `server`, `cloud_vm`, `team_vm`, `ssh` |
| `label` | user-chosen name |
| `state` | `connected`, `connecting`, `verifying` (host key sheet open), `needs_auth`, `disconnected`, `unreachable` |
| `path` | display string from the transport (`"direct · 3 ms"`, `"relay · 41 ms"`, `"tunnel · 9 ms"`) |
| `capabilities` | `{watch: "native" \| "none", trash: boolean, thumbnails: boolean, server_side_copy: boolean}` |

The local Mac is always present as `kind: local` for an app with `fs:read`. Its home root is granted only through the panel (not by default).

### 3.2 Operations

| Op | Params | Result | Errors | Notes |
| --- | --- | --- | --- | --- |
| `host.list` | `{}` | `{conns: Conn[]}` | | scope `host:read` |
| `host.connect` | `{conn?}` + gesture | `{conn: Conn}` | `user.cancelled`, `host.key_rejected`, `host.key_mismatch`, `auth.failed`, `host.unreachable`, `policy.denied` | opens the **host-owned connect sheet**: pick a known cmux host or team VM, or enter an SSH target (`user@host:port`, or a name from the user's SSH config, which only the host reads); pick a credential (3.3); verify the host key (3.4); choose which folders to grant (home, pick, none). With `conn`, reconnects that connection. Scope `host:control` |
| `host.disconnect` | `{conn}` | `{conn: Conn}` | | ends this app's use; the transport keeps a shared link while others use it |
| `host.forget` | `{conn}` + gesture | `{}` | | removes the handle and its roots for this app |
| stream `host.watch` | `{}` | `{conn: Conn}` | | every state or path change; no polling |

### 3.3 Credentials by handle (`cred_…`)

The app never sees a key, a password, an agent socket or a certificate. The connect sheet produces a `cred_…` that only the connection owner can use:

| Source | Owner | How |
| --- | --- | --- |
| SSH agent | `cmux link` (it reads `SSH_AUTH_SOCK` of the user's session) | the sheet lists agent identities by comment and fingerprint |
| Key file | `cmux link` | the user picks the file in the host panel; the host reads it by path and keeps it in the Keychain item it owns (passphrase prompt in the sheet) |
| Password | host secure field | stored in the Keychain only if the user ticks Remember |
| Credential provider app | an app implementing `cmux.credential.provider/1` | `credential.request {kind: "ssh", target}` → provider's own UI → `cred_…`; the provider hands the secret to the host process, never to the asking app |
| Team VM | `TeamDO` SSH CA (team-vm.md) | short-lived certificate, issued automatically for members; no user step |

Ops: `credential.request {kind, target, purpose}` + gesture → `{cred}` (owner: credential broker in `cmux link`; providers implement the interface), `credential.release {cred}`. Status: `cmux.credential.provider/1` is proposed in v2; `credential.*` ops are new.

### 3.4 Host key verification

Owned by the host. First contact shows the SHA256 fingerprint and key type; the user confirms; `cmux link` stores it in its own known-hosts store and imports the user's `~/.ssh/known_hosts` read-only (the host reads it; no app sees it). A changed key is a hard stop with the old and new fingerprints and no "continue" button; the app sees `host.key_mismatch`. While the sheet is open the connection state is `verifying`.

### 3.5 What Finder needs from the transport (lane 12)

The transport plan covers cmux endpoints: one WireGuard overlay, `cmux link` dials a host and returns a local socket that speaks the daemon protocol (transport.md 0.9, 12). For Finder that is enough for local, cmux server, Cloud VM and team VM: `fs.*` ops route to the target's session host over that link. Needed in addition:

1. **A bulk stream class on the link** for `fs.read` ranges and cross-host copy (transport.md 1 "Bulk"), with backpressure, so a 4 GB copy never starves terminals, and per-stream cancel.
2. **Owner-to-owner streams**: the destination session host opens a read stream on the source session host (both cmux endpoints) without routing bytes through the Mac when both are remote. Requires a link between two hosts the user can reach, authorized by the user's token (transport.md 0.7 `hello {token}`) with the job's grant.
3. **Plain SSH targets**: an SSH client and SFTP v3 inside `cmux link` (no install on the target). It provides list, stat, read, write, rename, mkdir, remove; no watch, no trash (trash = move to `~/.cmux-trash/<job>` on that host or refuse), no thumbnails beyond what the Mac renders after a capped read. Optional: install the cmux daemon on the target through the same SSH session for watch and server-side copy (user asks for it in the sheet).
4. **Connection state events** (`host.watch`) from the link's path selector: state and path label per conn, pushed.
5. **Sleep and reconnect semantics for jobs**: a job survives a path change; after a link reconnect the destination owner resumes from the last confirmed offset (transport.md 10).

## 4. Listings

### 4.1 Entry

`{name, kind: "file"|"dir"|"symlink"|"other", size: number|null, mtime: ms|null, type?: string (type id), hidden?: boolean, target_kind?: kind|null}`. No owner, mode or absolute path; `fs.stat` adds `{mode_display, owner_display}` as display strings for a details view.

### 4.2 `fs.list` (cursor batches, owner-side snapshot)

| | |
| --- | --- |
| Params | `{conn, root, path, sort: {key: "name"\|"modified"\|"size"\|"kind", dir: "asc"\|"desc", dirs_first: bool}, filter: {query?: string, hidden: bool, kinds?: string[]}, limit: 1..1000, cursor?, listing?}` |
| Result | `{listing: "lst_…", entries: Entry[], cursor: string\|null, total: number\|null, revision: string}` |
| Errors | `fs.not_found`, `fs.not_a_directory`, `fs.permission_denied`, `fs.not_inside_root`, `cursor.expired`, `root.revoked`, `host.unreachable`, `fs.too_large` |
| Owner | the file system owner of `conn` (session host; `cmux link` for SSH) |
| Scope | `fs:read` + `root` handle |

The first call reads the directory once, applies filter and sort (natural, case-insensitive names as tiebreaker; the same comparator the app uses so watch events land in the right place), stores the snapshot as `lst_…` (idle TTL 5 minutes, at most 8 per (app, conn)), and returns the first batch. `revision` is the owner's change counter for that directory at snapshot time. Later calls pass `cursor` and `listing`. A changed sort or filter on a partial listing is a new listing; a complete listing may be re-sorted by the app.

Stream form for clients with streamed results: `fs.list.stream` with the same params yields `{kind: "batch", entries, cursor}` items and ends with `{kind: "end", total, revision}`; the app's reducer handles both forms the same way.

Random access for a scrollbar: `fs.list.window {listing, offset, limit}` → `{entries, offset}` (owner keeps the sorted snapshot, so any window is O(limit)). Needed once the scene can report a visible range (G2).

Limits: 1000 entries per batch, 1 MiB per response; up to 1 000 000 entries per snapshot (about 100 MB owner memory worst case; typical 100 000 entries is about 10 MB and sorts in under 100 ms). Above that: `fs.too_large {total}` and the stream form returns unsorted batches in directory order.

### 4.3 `fs.watch` (stream)

Subscribe with `{conn, root, path}`. Events: `{conn, root, path, event}` where `event` is one of `created {entry}`, `modified {entry}`, `deleted {name}`, `renamed {from, entry}`, `overflow`, `reset`, each with a monotonic `revision`. Owner: FSEvents (macOS, per-directory stream, 100 ms latency, coalesced) or inotify (Linux) in the session host; one OS watch per directory shared by all subscribers. `overflow` when more than 512 changes arrive in one coalescing window or the OS dropped events; `reset` when the directory itself was replaced or the root was revoked. A `conn` with `capabilities.watch: "none"` (plain SSH) refuses with `fs.watch_unsupported`; the app shows a Refresh button and relists on user action, never on a timer.

Client contract (implemented and tested in `first-party-apps/finder/src/model/listing.ts`): subscribe before the first `fs.list`; buffer events that arrive before the first batch; drop events whose revision is at or below the snapshot revision; keep later events in an overlay that wins over batches with the same name; place created entries by the shared comparator; on `overflow`, `reset` or `cursor.expired`, relist and keep the old rows until the new first batch lands.

### 4.4 `fs.stat`, `fs.read`

- `fs.stat {conn, root, path}` → `Entry & {mode_display, owner_display, link_display?}`.
- `fs.read {conn, root, path, offset?, max_bytes ≤ 1 MiB}` → `{text: string|null, bytes_base64?: string, truncated, size, encoding: "utf8"|"binary"}`. For previews only; editors use documents (section 8).

## 5. File operations

### 5.1 Operations

| Op | Params | Result | Risk | Undo |
| --- | --- | --- | --- | --- |
| `fs.mkdir` | `{conn, root, path, name}` + gesture | `{entry}` | mutate-shared | `fs.undo` removes it if still empty |
| `fs.rename` | `{conn, root, path, name}` + gesture | `{entry, undo}` | mutate-shared | rename back if the name is still free |
| `fs.copy` | `{from: {conn, root, paths[]}, to: {conn, root, path}, conflict: "ask"\|"replace"\|"skip"\|"keep_both"}` + gesture | `{job, subject, destination, cross_host}` | mutate-shared | removes what the job created (by inode/hash check) |
| `fs.move` | same as copy | same | mutate-shared | same host: move back; cross host: copy back, then trash the moved copy |
| `fs.trash` | `{conn, root, paths[]}` + gesture | `{job, …}` | destructive (recoverable) | restore from the Trash (macOS `trashItem` result URL kept by the owner) |
| `fs.delete` | `{conn, root, paths[], permanent: true}` + gesture | `{job}` | destructive | none; host-owned confirmation sheet with the item count; never available to MCP |
| `fs.undo` | `{undo}` + gesture | `{}` | as the original | undo handles expire after 10 minutes or when a later change touched the items (revision check) |

Every op checks: `fs:write` scope, `root.rights == read_write` for every written root, containment, gesture (origin `user`) for app calls. Catalog surfaces (CLI, MCP, automations) carry their own grant; `fs.trash` from an agent needs a `destructive` op class in its grant.

### 5.2 Jobs and cross-host copy

All multi-item and all cross-host operations are jobs (`job_…`). Owner: the **destination** file system owner (it can write to a temporary name and rename atomically, and it knows conflicts). Same host: the owner uses `clonefile`/`copyfile` (APFS) or `copy_file_range` (Linux). Cross host: the destination owner pulls from the source owner over a bulk stream (3.5 item 2); when the source is a plain SSH target, `cmux link` on the Mac relays. Cross-host move = copy, verify size and SHA-256, then trash the source (never delete before verify).

| Op / stream | Shape |
| --- | --- |
| `fs.job.list` | `{}` → `{jobs: JobSnapshot[]}` (active + finished in the last 10 minutes, this app's jobs only) |
| stream `fs.job` | `{job, event}`; events: `preparing {items_total, bytes_total}`, `progress {bytes_done, bytes_total?, items_done, items_total?, current?, eta_s?}` (at most 4 per second per job), `conflict {conflict: {item, existing: {size, mtime}, incoming: {size, mtime}}}`, `resolved`, `cancelling`, `done {undo?}`, `failed {error}`, `cancelled`; every event has `seq` |
| `fs.job.cancel` | `{job}` → `{}`; the owner stops at the next chunk, removes partial files, emits `cancelling` then `cancelled` |
| `fs.job.resolve` | `{job, choice: "replace"\|"skip"\|"keep_both", apply_to_all}` + gesture |

State machine (client half implemented and tested in `src/model/jobs.ts`): `queued → preparing → running ⇄ conflict`, any live state `→ cancelling → cancelled`, `running → done | failed`; terminal states absorb; events apply once in `seq` order; client requests (cancel, resolve) are pending until the owner's event confirms them. The ETA comes from the owner, which measures the real throughput between the two hosts.

Limits: at most 4 running jobs per (user, destination owner), others `queued`; 1 000 000 items per job; a link loss pauses the job (`progress` stops, state stays `running`) and resumes from the last confirmed offset; after 10 minutes without a link the job fails with `host.unreachable` and cleans up.

### 5.3 Errors

`fs.exists` (only with `conflict` not `ask`), `fs.no_space {needed, available}`, `fs.read_only`, `fs.permission_denied`, `fs.not_inside_root`, `fs.name_invalid`, `fs.busy`, `job.unknown`, `undo.expired`, `host.unreachable`, `gesture.required`, `confirmation.declined`.

## 6. Previews

- `cmux.viewer/1` (proposed in v2): input `{doc}` (section 8) or `{conn, root, path}` for read-only viewing; implementations declare types. Built in: plain text, source code, markdown, image, PDF. Finder embeds the user's viewer for the selected type with `cmux.ui.embed("cmux.viewer/1", input)` (V4).
- `fs.thumbnail {conn, root, path, size: 64..1024, page?}` → `{image: "img_…", width, height, pages?}` (owner: the file system owner; macOS QuickLook thumbnailing on Macs, a capped decoder elsewhere). `img_…` is an opaque image handle the scene `Image` node accepts as `src` (scene change, G7); the bytes never enter the app VM.
- Size caps: text preview reads at most 32 KiB; thumbnails for files up to 200 MB; above that the preview shows metadata only.

Status: `cmux.viewer/1` v2; `fs.thumbnail` and `img_…` new.

## 7. Drag and drop

### 7.1 Payload (2.1 of the critique, made concrete)

`{kinds: ["file"], items: [{kind: "file", ref: {conn, root, path}, display, name, dir}], operations: ["copy", "move"?, "reference"], truncated}`. `ref` uses handles the dragging app already holds; `display` is shown only. At most 1000 items; more are dropped with `truncated: true`. Builder: `src/model/drag.ts`, tested.

Scene contract (new, G8): a node prop `drag: export name` whose function returns the payload when the drag starts, and `drop: {kinds: [...]}` with an `onDrop {items, operation, gesture}` event. The host owns the drag session, the pasteboard (`dev.cmux.items` plus file promises for other macOS apps, so a remote file dragged to the desktop is fetched by the host), and the drop.

### 7.2 Targets and the rule table

| Target | Same host as the items | Another host |
| --- | --- | --- |
| Folder in a Finder app | move (copy offered) | copy (move offered); one `fs.copy`/`fs.move` job |
| Terminal | the shell resolves each ref to a real path on that machine and types it, POSIX-quoted, space-separated, no newline | the shell copies the items into the terminal host's drop folder (`~/.cmux/drops/<job>/`, cleaned after 24 hours) through `fs.copy`, then types the copies' paths |
| Agent pane | attach each item as an `ent_…` handle (one file or subtree) with rights = dragger's root rights ∩ the agent's file grant; refused when the agent has no file grant | same, and the agent reads through the owner on that host |
| Another app's pane | delivered only if that app declared `drop: {kinds: ["file"]}`; it receives `ent_…` handles, never the dragger's `root_…` | same |

Refusals: read-only target, a folder into itself, a no-op drop on its own folder, kinds not accepted. Every drop carries the user's gesture.

### 7.3 Keyboard and menu alternatives (every drop has one)

- `terminal.drop {terminal?, items}` + gesture: same rules as dropping on the focused terminal (or the named one). Scope `terminal:input`. Owner: session host of the terminal.
- `agent.attach {agent?, items}` + gesture: attach to the focused agent pane. Scope `agent:write`. Owner: the agent's ACP session owner.
- `ent_…` (new handle): one file or subtree; created only by the shell at drop or attach time; inherits `expires_at` from the agent session.

Status: typed drag and drop proposed in v2 (12.4); scene props, `terminal.drop`, `agent.attach`, `ent_…` new.

## 8. Open with (documents, V3)

- `document.open {conn, root, path, with?: app_id, show: true}` + gesture → `{doc: "doc_…", opened_with}`. The document host for files is the session host on that machine (V3). Without `with`, the user's `openWith."<type>"` default; none set → the host's Open With chooser.
- `open.with.list {type}` → `{apps: [{app, name, default}]}` for an Open With menu.
- Open in the system default app (local files only): `document.open {…, with: "system"}`; remote files are fetched to a host cache first and re-uploaded on save only through a document.

Status: V3 proposed; `open.with.list` new.

## 9. Capability list

| Capability | Owner | Status |
| --- | --- | --- |
| `root_…` handles | app supervisor grant store; enforced by the file system owner | v2 (V6) |
| `fs.roots.list`, `fs.root.pick`, `fs.root.release`, `fs.roots.watch` | app supervisor + host file panel | new |
| `workspace.roots` | workspace store | new |
| `conn_…` connection handles | `cmux link` (transport) + app supervisor | new (v2 named `host_…`; see 3.1) |
| `host.list`, `host.connect` (sheet), `host.disconnect`, `host.forget`, `host.watch` | `cmux link` (transport) | new |
| `cred_…` + `credential.request/release` | credential broker in `cmux link`; providers | v2 interface `cmux.credential.provider/1`; ops new |
| Host key verification UI | `cmux link` + host sheet | new |
| `cmux.fs.provider/1` (list, stat, read, write, watch under a root) | session host (local, server, VMs); `cmux link` SFTP for SSH | v2 |
| `fs.list` cursor batches + `fs.list.stream` + `fs.list.window` | file system owner | new |
| `fs.watch` stream with revisions | file system owner (FSEvents, inotify) | new |
| `fs.stat`, `fs.read` | file system owner | new |
| `fs.mkdir`, `fs.rename`, `fs.copy`, `fs.move`, `fs.trash`, `fs.delete`, `fs.undo` | destination file system owner | new |
| Jobs: `fs.job.list`, `fs.job` stream, `fs.job.cancel`, `fs.job.resolve` | destination file system owner | new |
| Owner-to-owner bulk streams | transport (lane 12) | new |
| `cmux.viewer/1` | viewer apps; built-in viewers | v2 |
| `fs.thumbnail` + `img_…` image handles in `Image` | file system owner; scene renderer | new |
| Typed drag and drop | shell drag session | v2 (12.4) |
| Scene `drag` / `drop` props and `onDrop` | scene renderer | new |
| `terminal.drop`, `agent.attach`, `ent_…` | session host; ACP session owner; app supervisor | new |
| `document.open`, `openWith` | document host (V3), config layer | v2 (V3) |
| `open.with.list` | config layer | new |
| `app.pane.open {kind, input}` | app supervisor / Mac app | new (also asked by the Diffs app) |
| `app.storage.*`, `app.settings`, `cmux.events.on` | app supervisor | exists |

## 10. Platform gaps the prototype hit (scene and runtime)

| # | Gap | Effect today | Ask |
| --- | --- | --- | --- |
| G1 | No scroll container in the scene | long lists overflow the pane; the app pages 22 rows at a time | `ScrollView` (or a scrolling `List`) node |
| G2 | No visible-range events | cannot fetch the window under the scrollbar | `onVisibleRange {first, last}` on lazy lists; pairs with `fs.list.window` |
| G3 | No keyboard selection or focus in lists | arrow keys, Return, Space (preview), type-to-select and Cmd-Delete do nothing | semantic `List` with selection, focus and key commands (V7 lists it) |
| G4 | No modifier keys and no double-click on tap | tap selects, a second tap opens; no Shift/Cmd multi-select | `tap {count, modifiers}` in the event payload |
| G5 | No `Table` node | columns are hand-built `HStack`s; no column resize, no header sort affordance | `Table` with sortable, resizable columns (V7 lists it) |
| G6 | No embed placement node | the preview is built in, not the user's viewer app | `Embed` node for `cmux.viewer/1` (V4) |
| G7 | `Image` loads bundle files only | thumbnails show a placeholder | accept `img_…` handles as `src` |
| G8 | No drag source or drop target props | drag to terminals and agents is only reachable through menus | `drag` / `drop` props (7.1) |
| G9 | No pane size and no pane input in the mount context | page size is fixed; the sidebar cannot open the pane at a location | `ctx.size` + resize events; `app.pane.open {kind, input}` |
| G10 | The preview harness runtime lags the repo runtime | no global `onCleanup`, no `cmux.gesture`; the app feature-checks both (`src/runtime.ts`) | rebuild the harness from the current runtime |
| G11 | Manifest: `storage:local` cannot be declared; no `files` category; `x-cmux-devOnly` not honored on commands | recents work only when the host grants storage silently | allow `storage:local` in `optionalScopes`; add `files`; honor the key |
| G12 | `untrack` exists at runtime but not in `cmux-app.d.ts` | the app works around tracking leaks by hand (plain mirrors of signals) | declare it |
| G13 | `TextField` in a toolbar renders as plain text | the filter field does not read as a field | a `bordered` / `search` style |

## 11. Questions for the transport lead (lane 12)

1. Will `cmux link` carry plain SSH targets (SSH client + SFTP inside the link process), or does that belong to a separate process? Finder assumes the link, so one process owns all connection state and credentials.
2. Can two remote cmux endpoints of the same user open a direct link to each other for an owner-to-owner bulk copy (3.5 item 2), or does every byte go through the Mac?
3. Is there a bulk stream class with backpressure and per-stream cancel, separate from the control and interactive classes, and what throughput should a job expect over `do_relay` (the plan measured about 40 Mbit/s unbatched)?
4. Who owns the per-app connection record (`conn_…` → `host_…`): the app supervisor (grants) or the link (connections)? Finder assumes: supervisor owns the grant, link owns the live connection and its state events.
5. How does the link report path changes to apps (`host.watch`): a stream from the link, or a projection in the session registry?
6. For team VMs: does the link fetch the `TeamDO` SSH certificate itself when a member connects, so the connect sheet has no credential step?

## 12. CLI and MCP

Requested in `.cmux-scratch/nx-worker/cli-requests/finder-fs.md` (`cmux fs ls|stat|cat|cp|mv|mkdir|rename|trash|watch|jobs|cancel|undo|roots`) and `finder-host.md` (`cmux host ls|connect|disconnect|forget|watch`). CLI callers name local paths and hosts directly (the user is the principal); the CLI resolves them to the same ops with the user's own grant. MCP gets read ops, `fs.copy`, `fs.mkdir`, `fs.trash` (destructive class) and `fs.job.*`; never `fs.delete` and never `host.connect`.

## 13. Order of work

1. `cmux.fs.provider/1` schema and the local owner (session host): `fs.list` snapshot + cursor, `fs.watch`, `fs.stat`, `fs.read`, roots and the panel. Unblocks Finder on this Mac.
2. Jobs and file ops on the local owner, with undo and the host confirmation sheet.
3. Scene: `ScrollView`/`List` with selection and keys, `Table`, tap modifiers, `img_…` in `Image`, `drag`/`drop` props.
4. Transport: `conn_…`, `host.*`, the connect sheet, host key UI, `cred_…`; routing `fs.*` to remote session hosts.
5. Cross-host jobs (owner-to-owner bulk streams), plain SSH targets through SFTP, `terminal.drop`, `agent.attach`, `ent_…`.
6. `cmux.viewer/1` embeds and documents for Open With.
