# App platform critique: first principles, drastic changes

Status: proposal 1, lane 3 lead, 2026-10-02. Input: what building six first-party prototypes on the current platform taught us (plans/cmux-next/first-party-apps.md sections 3 and 8), Lawrence's requests of 2026-10-02 (rethink the store and apps from scratch; no tolerance for tech debt; we are not live, so rewrite freely; first-party apps installed by default; install-but-hide; Diffs, Monaco and CodeMirror apps; Finder with SSH; email in the feed; an integrations app), and the decided server shape (plans/cmux-next/tasks.md section 13). Owners: the app platform lead (runtime, manifest, store), with the feed, server, transport, sections and palette leads for their parts. Only the coordinator writes the spec; this is "spec proposal: app platform critique".

## 0. Verdict

The current platform is a good sidebar-widget system (signals, scene ops, native rows) with an app store bolted on. It is not yet an application platform. The apps Lawrence asks for (editors, diffs, Finder, mail, git, logs, DB and HTTP clients) all need four things the platform does not have: **documents**, **interfaces between apps**, **handles instead of strings**, and **rich panes**. Six prototypes hit the same walls (no editor, no rich text, no pane mount, no way for one app to use another, scopes that cannot name a file root or a host). Patching each gap one by one gives a long list of special cases. The proposal below changes the model so these are natural.

## 1. Drastic changes (each replaces something, nothing is added beside the old way)

### C1. Apps implement typed interfaces; the shell composes them

Today an app contributes to UI places (`sidebarSections`, `statusItems`, `paneKinds`). A Diffs app that wants "an editor" or a search app that wants "results from notes" has no way to ask. Change: the unit of composition is a **versioned interface**, and apps declare which interfaces they implement and which they consume.

```jsonc
"implements": {
  "cmux.editor/1":      { "export": "editor", "types": ["public.source-code", "public.plain-text"] },
  "cmux.search.provider/1": { "export": "search" },
  "cmux.fs.provider/1": { "export": "fs", "schemes": ["ssh"] }
},
"consumes": ["cmux.editor/1", "cmux.diff.source/1"]
```

Standard interfaces (owned by the app platform lead, each a schema in `cmux-tui/crates/cmux-app-host/interfaces/<name>/<major>.json`, generated into `cmux-app.d.ts` and Swift/Rust types):

| Interface | Implemented by | Consumed by |
| --- | --- | --- |
| `cmux.editor/1` (edit a document handle in a pane or embed) | Monaco app, CodeMirror app, notes (native), built-in plain editor | Diffs, Finder, notes, PR review, any opener |
| `cmux.viewer/1` (read-only view of a document: image, PDF, markdown, CSV, log) | image viewer, markdown preview, log viewer | Finder previews, open-with |
| `cmux.diff.renderer/1` (render a diff resource) | Diffs | feed review requests, git client, PR review, agents |
| `cmux.diff.source/1` (produce diffs) | git (built in), agents, automations | Diffs |
| `cmux.fs.provider/1` (list, stat, read, write, watch under a root) | built in: local, cmux server, team VM; apps: SSH, S3 | Finder, editors, search |
| `cmux.search.provider/1` | notes, feed, mail, Finder, every app with items | search, palette |
| `cmux.feed.source/1` (post items, receive responses) | mail, integrations, CI, calendar | feed |
| `cmux.opener/1` (handle a URL scheme or file type) | any app | the shell's open-with |
| `cmux.credential.provider/1` (produce a credential handle on request) | password manager hook, SSH agent bridge | Finder (SSH), integrations, HTTP client |

The shell resolves "open this" or "embed an editor for this" by interface plus file type, with a user default per type (open-with, below). The same contract serves panes, embeds, the palette, CLI (`cmux open --with <app> <ref>`) and MCP. This replaces the per-place contribution kinds: `sidebarSections` and `statusItems` stay as places, but each place renders an interface (`cmux.section/1`, `cmux.status/1`), so places are just interfaces the sidebar and menu bar consume.

### C2. Documents are a platform primitive (buffers, dirty state, save, conflict)

Every editor-like app today would reinvent file reading, dirty tracking, save, external-change detection and conflict handling, and two panes on one file would fork. Change: a **document** resource owned by one writer, edited by any number of views.

- Identity: `doc_…` with a URI (`file://host/path`, `cmux-fs://<provider>/<root>/<path>`, `note://<id>`, `untitled:`), a type (UTType + language id), a revision (content hash + counter) and an encoding.
- Owner: the **document host** on the machine that owns the bytes (session host for local and remote files through `cmux.fs.provider/1`; the notes server for notes; an app server for app documents). One buffer per document per owner, shared by all views (multi-pane = many views, one buffer).
- Ops (catalog family `document`): `document.open {uri} -> {doc, revision, text|chunks}`, `document.edit {doc, base_revision, edits[]}` (OT-free: edits apply only on the current revision; a stale edit is rejected and the view rebases locally, then resends), `document.save {doc, revision}`, `document.revert`, `document.close`, events `document.changed {doc, revision, edits, dirty, origin}`, `document.conflict {doc, disk_revision, buffer_revision}`.
- Dirty state lives in the owner (so every view and every device shows the same dot); unsaved buffers survive app restarts (journal in the owner).
- External change: the owner watches the file (FSEvents/inotify, no polling); clean buffer -> reload and emit; dirty buffer -> `document.conflict` with a three-way merge offered through Diffs.
- Save rules are the owner's: atomic write, preserve mode and xattrs, refuse when the disk revision moved since the base.
- Large files: chunked reads and a read-only "large file" mode above a size cap.
- Views hold only view state (selection, scroll, folds) and the client keeps an intent log of edits (OWNERSHIP-PRINCIPLES, clients are projections).

Open-with: the config layer keeps `openWith."<type>" = "<app>#<interface export>"` per user; the shell asks when there is no default and offers "Always use". `cmux.opener/1` implementers declare types and schemes.

### C3. Composition by embedding (Diffs embeds an editor)

`cmux.ui.embed(interface, {doc | diff | input}, options) -> EmbedHandle` mounts another app's implementation inside the caller's pane or scene. The embed is a separate mount owned by the embedded app (its own VM, its own grant), connected through the interface's typed props and events (`cmux.editor/1`: props `{doc, readOnly, language, decorations, revealRange}`, events `{selectionChanged, requestSave}`). The caller never sees the embedded app's internals and gets no extra scope: the shell passes the embedded app a **document handle**, not file access. Diffs therefore implements side-by-side and inline views by embedding two `cmux.editor/1` instances (or one with a diff mode when the editor declares `capabilities: ["diff"]`), and the user's editor choice (Monaco or CodeMirror) applies everywhere.

### C4. Diffs are resources with producers

`diff_…` resource owned by its producer, with `{base: ref, head: ref, files: [{path, status, hunks?}], producer: git|agent|automation|user, title, context}` where a ref is a document revision, a git object (`git:<repo>@<rev>:<path>`), a snapshot or a working tree.

- Git: session host ops `git.status`, `git.diff {repo, base, head, paths?}`, `git.show`, `git.log` (read, per machine, `git:read`), and `git.apply`/`git.stage` (`git:write`, origin user or approved).
- Agents: MCP tool `diff.propose {base, head|patch, title}` creates a diff and a feed item of kind `request review`; the user opens it in Diffs, comments, accepts (applies through the owner), or rejects. This is how "the agent wants to change these files" reaches the user.
- Automations: a run step `diff.publish` attaches its diff to the run and to the feed.
- The diff renderer interface lets the git client, PR review and the feed share one Diffs app.

### C5. Handles, not strings (capability security)

Scopes such as `fs:read` cannot say which folder, `net:` cannot say which SSH host, and secrets cannot be passed at all. Change: every sensitive object reaches an app as an **opaque handle** created by the user or the shell, never as a path, host or token the app names itself.

| Handle | Created by | Gives |
| --- | --- | --- |
| `root_…` (file root) | the host file panel, a workspace folder, a provider connection | `fs.*` under that root only |
| `host_…` connection (local, cmux server, team VM, SSH) | the transport (lane 12) after the user connects | remote `fs.*`, terminals, port forwards through the transport |
| `cred_…` (SSH key, token, password) | the credential provider or a host-owned secure field | use as a param of ops that accept it; never readable |
| `doc_…` | document host | edit and view rights for one document |
| `diff_…` | its producer | render and comment; apply needs the owner's approval |

Scopes stay as the coarse consent ("can read files you give it"); handles are the fine grant. Drag and drop, open-with and embeds pass handles, so a third-party Finder or editor works with no broad scope. This replaces string paths in `fs.search` and `net:<host>` for SSH.

### C6. Three renderers, chosen by need, all first class

| Renderer | For | Who |
| --- | --- | --- |
| Scene (native) | sections, status items, small panes, forms | every app, every client (Mac, iOS, web, TUI) |
| Web pane (sandboxed WKWebView, `cmux-app://` scheme, no network but `cmux.net.fetch`, injected `cmux` global with the same grant) | rich editors (Monaco, CodeMirror), diff views, charts, maps, any existing web UI library | every tier |
| Native pane (Swift module in the cmux bundle) | the notes editor (decided), built-in system UI | first-party only |

Today web panes are "phase 2 escape hatch". Monaco and CodeMirror are web code, so web panes must be phase 1 and first class: one WebContent process per window shared by an app's panes (budget), suspended when hidden, with the document bridge (C2) and the embed contract (C3) available inside. The scene renderer keeps growing only for small UI (rich text runs, meters, toggles, lists with keyboard selection); it never tries to become an editor.

### C7. Install, enable, hide: one per-user state model

Requirement (Lawrence): first-party apps are installed by default, sample apps are opt-in, and a user can install an app but hide it.

State per (user, app), personal and synced, owner `UserDO` (team installs: the install record is `TeamDO`, the user's enable/hide overlay is still `UserDO`):

| Field | Values | Meaning |
| --- | --- | --- |
| `installed` | bool (+ source: default, user, team) | the bundle is available and its grant exists |
| `enabled` | bool | the app may run at all (servers, VMs, contributions) |
| `hidden` | bool | no presence in the sidebar, palette, menus, menu bar, open-with lists or App Store "Installed" badges; still runs |
| `hiddenAccess` | `{cli, mcp, automations}` bools, default all true | whether CLI, MCP and automations may still run the app while hidden |

Invariants (reducer, property-tested): `hidden ⇒ installed`; `enabled = false` overrides everything (nothing runs, hidden or not); `uninstall` clears `enabled`, `hidden` and storage in one commit; a team-installed app can be hidden and disabled by a member but removed only by an admin; hide and unhide never touch the grant, storage or the sidebar layout records (a hidden app's sections keep their layout records and render nothing, so unhide restores them exactly); default-installed first-party apps can be hidden or disabled, and "Remove" turns into "Hide" for them unless the user confirms full removal.

Ops (catalog family `app`, owner `UserDO`/`TeamDO`, every op with an idempotency key, each emits `app.changed {app, installed, enabled, hidden, revision}`):

| Op | Risk | Origin | CLI | MCP | Palette | Right-click |
| --- | --- | --- | --- | --- | --- | --- |
| `app.hide {app}` | mutate-own | any (user, cli) | `cmux apps hide <id>` | exempt: personal view preference | "Hide <App>" | app section header, app status item, App Store row |
| `app.unhide {app}` | mutate-own | user, cli | `cmux apps unhide <id>` | exempt | "Show Hidden Apps" (list with Unhide) | Settings > Apps row |
| `app.enable` / `app.disable {app}` | mutate-own | user, cli | `cmux apps enable|disable <id>` | exempt | per app | App Store row |
| `app.set_hidden_access {app, cli?, mcp?, automations?}` | mutate-own | user only | `cmux apps hidden-access <id> --cli on --mcp off` | never | — | Settings > Apps |
| `app.list {include_hidden?}` | read | any | `cmux apps list [--all] --json` | yes | — | — |

Surface rules: the catalog filter that builds the palette, menus, sidebar and menu bar drops every contribution of a hidden app (one central filter in the action registry, never per surface); `app.run`, MCP tools and automation triggers check `hiddenAccess`; "Show Hidden Apps" is always present so a user can never lose an app. Tests: reducer property tests for the invariants and idempotent replay; a surface test that a hidden app contributes nothing to `action.list` with `surfaces` yet `app.run` succeeds when allowed and fails with `app.hidden` when not; a sync convergence test (two clients hide/unhide concurrently, both converge); the UI prototype shows Hide, Unhide and the hidden list (CmuxNextAppPermissions).

Defaults: first-party apps are `installed: default` on first launch; the App Store "Samples" category is opt-in and never default-installed.

### C8. One owner taxonomy for app state

| State | Owner | Examples |
| --- | --- | --- |
| View state | the client | selection, scroll, expanded rows, a pane's tab |
| App-local data | app supervisor on that machine | caches, recent searches |
| Personal synced data | the app's server with `instances: user`, else `UserDO` synced KV | notes, inbox view filters |
| Team data | the app's server with `instances: team` (single writer per team) | Tasks |
| Per-machine data | the app's server with `instances: machine` | usage readings, local indexes |
| Documents | the document host (C2) | files, notes bodies |

Apps never keep a second copy of data another owner has (the inbox prototype's own item model was the counter-example and was removed).

### C9. Kill the prototype debt now

| Debt | Action |
| --- | --- |
| In-process JavaScriptCore engine | keep only as the DEV test engine; stop adding features to it; the Rust host (QuickJS, one process per app, OS sandbox) is the only shipping engine |
| `registry.json` install record | delete when C7 lands in `UserDO`; no migration (not live) |
| Scene runtime node-count bug, origin lost after `await`, unknown ops refused as `scope.missing`, missing typings, no `onCleanup`, no `app.settings.set`, MCP opt-out, `x-cmux-devOnly`, no app i18n | fix in one platform pass before more apps land (first-party-apps.md 3.5) |
| Scope grammar (`storage:local`, restricted scopes) and id grammar (`cmux/<name>` everywhere, including Tasks) | one grammar, generated from `scopes.json` |
| Sample apps (github-prs, running-agents, agent-status) | rewrite on C1 to C7: github-prs becomes a `cmux.feed.source/1` + section; running-agents and agent-status use the feed and agent interfaces |
| Per-app ad hoc variant switches | platform `variants` block in the manifest (DEV/NIGHTLY), rendered in Debug Settings |

### C10. The store follows the model

Listings show implemented interfaces ("Editor for TypeScript, JSON, Markdown"), handles the app will ask for, server presence and where it runs, tier and sandbox profile. Search by interface ("editors", "file providers"). Installing an app that implements an interface the user has no default for asks "Use for .ts files?".

## 2. Apps Lawrence will likely ask for, and the primitives each needs

| App | Needs |
| --- | --- |
| Diffs | C1 `cmux.diff.renderer/1`, C3 embed editor, C4 diff resources and git ops, web pane |
| Monaco editor, CodeMirror editor | C1 `cmux.editor/1`, C2 documents, web pane, open-with, language ids, decorations API (diagnostics from agents and LSP later) |
| Finder (with SSH) | `cmux.fs.provider/1`, C5 root/host/credential handles, transport connections (lane 12), streaming listings (cursor + `fs.changed`), previews via `cmux.viewer/1`, drag-and-drop contract (below) |
| Mail | `cmux.feed.source/1` (threads as items, reply as a feed response kind), integration connections, `cmux.viewer/1` for message bodies |
| Integrations | one integration model shared with backend automations (connections in `ConnectionDO`, credential handles), `cmux.credential.provider/1` |
| Git client | git ops (C4), documents, Diffs embed, feed for CI status |
| PR review | integration (GitHub), Diffs, comments as feed responses, documents for local checkout |
| Logs viewer | streaming documents (append-only, chunked), terminal output streams, search provider |
| DB client | credential handles, host connections (tunnel through the transport), a result grid node (scene) or web pane, documents for queries |
| HTTP client | `cmux.net.fetch` with user-granted hosts per request, credential handles, documents for request files |
| Markdown preview | `cmux.viewer/1`, documents (live preview follows the buffer revision) |
| Image viewer | `cmux.viewer/1`, documents with binary chunks, Finder previews |
| Calendar | app server (`instances: user`), integration connections, feed source for reminders |
| Contacts (for Home) | app server, integration connections, a `cmux.contact.provider/1` consumed by Home, mail and calendar |
| Password manager hook | `cmux.credential.provider/1` producing credential handles; never returns secrets to apps |
| AI usage | per-machine server reading the local router status, coderouter API, menu-bar status, pane |
| Tasks, agent messages, feed | app servers (decided), feed interfaces |
| Caffeinate (keep the Mac awake) | a host power capability: `power.assertion.create {kinds: [display, idle, disk, system], reason, timeout_s?, until_pid?|until_terminal?|until_task?} -> pwr_…` (owner: the native host on that machine, IOKit power assertions, no process spawn), `power.assertion.release`, `power.assertion.list`, event `power.changed`; scope `power:write`; menu-bar status item; presets bound to a terminal or build handle so "while this build runs" ends with it |
| Remote desktop (lane 17, not built here) | `host_…` connection handles through the transport, a streaming video surface renderer (native pane, not scene), input forwarding with origin user only, clipboard bridging by handle, per-host consent and a visible "being controlled" indicator, bandwidth and quality settings |

### 2.1 Drag-and-drop contract

A drag carries typed items `{kind: "file"|"doc"|"diff"|"text"|"url"|"task", handle | value, display}`. Drop targets declare accepted kinds. A drop on a terminal inserts the path (local) or a remote-safe reference (remote: the transport copies or the target host resolves the handle); a drop on an agent pane attaches the handle to the agent's context with the agent's grant intersected with the dragger's handle; a drop between hosts offers copy or move through `fs.copy` on the owners. Apps never get a path for a handle they did not receive.

## 3. Order of work

1. Platform pass (C9 fixes, C7 install/enable/hide, id and scope grammar).
2. C2 documents + open-with and C6 web panes (unblocks editors).
3. C1 interfaces + C3 embeds (unblocks Diffs, search providers, Finder previews).
4. C5 handles with the transport (unblocks Finder with SSH, DB and HTTP clients).
5. Rewrite the three sample apps and the five first-party prototypes on the new model.

## 4. Strongest objections

- **Interfaces are a big up-front design.** Answer: start with five (`editor`, `viewer`, `diff.renderer`, `fs.provider`, `search.provider`), version them, and let first-party apps prove each before it is public.
- **Web panes cost memory and break the "native look".** Answer: they are for document editors where users expect Monaco/CodeMirror behavior; one WebContent per window, suspended when hidden; chrome stays native.
- **A shared document owner adds latency to every keystroke.** Answer: the view applies edits locally at once (intent log) and the owner confirms; only conflicting edits round-trip.
- **Hidden apps that still run can surprise the user.** Answer: `hiddenAccess` is visible in Settings, defaults are listed, and "Show Hidden Apps" is always in the palette.

## 5. Decisions for Lawrence (through the coordinator)

See the lane 3 report.
