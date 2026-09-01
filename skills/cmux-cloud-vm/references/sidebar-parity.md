# Sidebar ↔ CLI parity (1:1)

Every verb in the Cloud sidebar has a CLI verb that goes through the **same socket method** and the same app code path (`SurfaceCatalog`, the machine's `CmuxTuiSurfaceProvider`). An agent can do anything a person can do from the sidebar, and a sidebar action never does something the CLI cannot. Ids come from `cmux vm tree --json` / `cmux surface ls --json` (`<machine>/<kind>/<key>`, `ws_…`, `term_…`).

The Verified column is the last live loop: every row executed from the tag-bound CLI against a fresh machine (issue #11347, 2026-09-01, staging E2B `base` machine; the effect checked through `vm tree --json` / `surface ls --json` / `cmux tree --all`, not the exit code). "unit" means the row's path is pinned by tests but could not be exercised on that machine (no desktop image on staging).

Sidebar (human) | CLI (agent) | Socket method | Verified
--- | --- | --- | ---
**Machines panel ＋ / palette "New Cloud Machine…"** (name, Desktop/Base, size) | `cmux vm new [--desktop\|--base] [--size 8g] [--name <label>] [--provider <p>] [--detach] [--json]` | `vm.create` | ✅ live (`--base --provider e2b`)
**Open Base / Set Up Base** | `cmux vm base open [--desktop\|--base]` | `vm.base_open` | ✅ path (the staging default provider refused the create with a backend 502; the verb and error surfaced correctly)
Control bar › **Open Cloud Agent** (Claude/Codex/OpenCode) | `cmux vm prompt --open <agent>` | `vm.cloud_agent_open` | ✅ installs the bundled cmux-cloud skill file (`~/.config/cmux/skills/cmux-cloud.md`), opens a local agent terminal with the kickoff prompt (not launched in the loop: it starts a real agent session)
Control bar › **Copy Cloud Prompt** | `cmux vm prompt` | `vm.cloud_prompt` | ✅ live — prints the same prompt (skill path on stderr), bootstraps ANY agent/harness
Machine row › **Open Shell** / click | `cmux surface new-terminal --machine <m>` (into the current workspace, like the row) · `cmux vm open <m> [--workspace <ref>]` (a shell, its own workspace by default) | `vm.terminal_new` / `workspace.cloud_vm_terminal_ready` | ✅ live — a fresh machine gets `main` created for it (never a workspace named after the terminal) and the tree shows it at once
Machine row › **New Workspace**, Workspaces ＋ | `cmux vm workspace new <m> [--name n]` | `vm.workspace_new` | ✅ live — one starter terminal, opened as `<m>: <name>`
Machine row › **Open Desktop**, Displays › Open Desktop, Desktop row click | `cmux surface open <m>/display/display:1` (open-or-focus, exactly the row) · `cmux vm open <m>:desktop` (always a fresh pane beside the shell, `focus: false`) | `surface.project` / `vm.desktop_open` | unit (`MachinesPanelModelTests`, `SurfaceCatalogTests`) — no desktop image on staging
Machine row › **Open Full cmux-tui Client** | `cmux vm tui <m>` | (pane command) | ✅ live
Machine row › **Refresh**, any group › Refresh | `cmux vm tree --refresh` / `cmux surface ls --refresh` | `vm.tree {refresh}` / `surface.catalog {refresh}` | ✅ one shared path (`CmuxTuiSurfaceProviderRegistry.refreshEverything`): fleet list + every provider, so a machine created since the last poll shows up
Machine row › **Rename…** | `cmux vm rename <m> <label>` | `vm.rename` | ✅ live
Machine row › **Status** | `cmux vm status <m>` (+ `vm stats`) | `vm.status` / `vm.stats` | ✅ live (`vm stats` answered a backend 502 on staging; the app surfaced it verbatim)
Machine row › **Checkpoint** (only when `capabilities.snapshot`) | `cmux vm snapshot <m> [--name n]` | `vm.snapshot` | ✅ live on E2B; hidden on providers that cannot (Blaxel); `vm ls --json` → `capabilities`
Machine row › **Fork** (only when `capabilities.fork`) | `cmux vm fork <m> [--name n]` | `vm.fork` | ✅ live on E2B (fork listed, then `vm rm`'d); hidden on providers that cannot (Blaxel)
Machine row › **Delete…** | `cmux vm rm <m>` | `vm.destroy` | ✅ live
Terminals / Workspaces group › **New Terminal** | `cmux surface new-terminal --machine <m> [-- <cmd>]` | `vm.terminal_new` | ✅ live — joins the machine's focused (else first) workspace
Workspace row › **New Terminal Here**, hover ＋ | `cmux surface new-terminal --machine <m> --remote-workspace <ws>` | `vm.terminal_new {workspace_id}` | ✅ live
Workspace row › **Go to Workspace** (the open verb's label once the workspace is showing locally), double-click, Return | `cmux workspace select <local-id>` (the local workspace from `vm tree --json` projections) | `workspace.select` | ✅ live — one open verb; never opens a second copy
Workspace row › **Open Workspace** (not open yet), double-click, Return | `cmux vm workspace open <m> <ws>` (also `cmux vm open <m>/<ws>`) — opens as its own local workspace | `vm.workspace_open` | ✅ live — an empty workspace opens nothing: the row is inert, the CLI answers `opened=0` (D9)
(no menu verb — drop onto the current pane) | `cmux vm workspace open <m> <ws> --here [--workspace <local>]` | `vm.workspace_open {here}` | ✅ live — one pane + the rest as tabs
(no menu verb — CLI placement only) | `cmux vm workspace open <m> <ws> --tabs [--pane <p>]` | `vm.workspace_open {here, placement: tab}` | ✅ live; `--tabs` plus a pane side is rejected
Drag a workspace row onto a pane edge | `cmux vm workspace open <m> <ws> --pane <p> --left\|--right\|--up\|--down` | `vm.workspace_open {here, pane_id, direction}` | ✅ live (all four sides)
Workspace row › **Close Workspace (Keep Terminals)**, hover × | `cmux vm workspace close <m> <ws>` | `vm.workspace_close` | ✅ live — terminals keep running and detach into the Terminals pool (only `terminal close` kills)
Workspace row › **Delete Workspace and Terminals…** (confirms) | `cmux vm workspace rm <m> <ws>` | `vm.workspace_delete` | ✅ live — same `CloudTreeNodeActions.deleteWorkspaceAndTerminals`: kills every terminal viewed there (their local panes close), then closes it
Workspace row › **Rename…** | `cmux vm workspace rename <m> <ws> <name>` | `vm.workspace_rename` | ✅ live — same `provider.renameRemoteWorkspace`
Workspace row › **Copy Workspace ID** | `cmux vm tree --json` (`machines[].remote_workspaces[].id`) | `vm.tree` | ✅ live
Terminal / browser / display row click, **Open** | `cmux surface open <resource>` (reuses an open pane) / `cmux vm open <m>/<ws>/<term>` | `surface.project` | ✅ live (`reused=true` on the second open)
Row › **Open in New Tab** | `cmux surface open <resource> --pane <p> --tab` | `surface.project {placement: tab}` | ✅ live (both reuse an open pane first; `--new --pane <p> --tab` lands the tab)
Row › **Open in New Pane** (a second pane) | `cmux surface open <resource> --new` | `surface.project {reuse: false}` | ✅ live
Drag a row onto a pane edge | `cmux surface open <resource> --pane <p> --left\|…` | `surface.project {pane_id, direction}` | ✅ live; `--tab` plus a side is rejected
Terminal row › **Kill Terminal…**, hover × | `cmux vm terminal close <m> <term>` | `vm.terminal_close` | ✅ live — the resource leaves the catalog and every local pane showing it closes
Display pointer row › Close (removes it from the workspace) | `cmux vm terminal close <m> display:1` | `vm.terminal_close` (tab close) | ⏳ needs daemon `display` tabs (cmux-tui `ContentPublicId::Display`, `content_kind: "display"`, `tab create display --workspace <ws>`, (display, workspace)-keyed tab identity)
Row › **Copy Surface ID** / **Copy Port** | `cmux surface ls --json` (`id`, `port`) | `surface.ls` | ✅ live
Port row click, **Open** | `cmux surface open <m>/browser/port:<n>` (open-or-focus, exactly the row) · `cmux vm open <m>:port/<n>` (always a fresh pane, `focus: false`; `--print` mints the URL only) | `surface.project` / `vm.port_open` | ✅ live — the probe found the port after `--refresh`, the pane opened; `vm.port_open` also registers a port the probe has not seen yet

Rules that keep it 1:1:

- A sidebar verb is implemented as a closure in `CloudTreeNodeActions` that calls the catalog/provider; the matching socket handler in `SurfaceSocketCommands` calls the same catalog/provider method. Adding a sidebar verb without a socket method is a parity bug.
- Placement flags mean the same everywhere: `--pane <p>` + side = split that pane on that side; `--tab` / `--tabs` = tabs in that pane (never together with a side); nothing = the focused pane of the current (or `--workspace`) local workspace; `--new` = never reuse a pane that already shows the surface. A `--workspace`/`--pane`/`--surface` that names nothing is an error, never a silent open in the selected workspace.
- Open never creates (D9): an empty workspace opens nothing from the row and answers `opened=0` from the CLI; `surface new-terminal --remote-workspace <ws>` is how a terminal gets there.
- Ports are in the tree (Ports group under a machine, lowest port first): the row and `vm open <m>:port/<n>` open the same `<m>/browser/port:<n>` resource.
- Agent-only primitives (`exec`, `push`, `pull`, `route`, `run`, `agent`, and the headless `vm terminal send|read|wait` in #11301) have no sidebar verb by design: a person does those things by typing into a pane.
