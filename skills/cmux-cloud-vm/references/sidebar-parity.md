# Sidebar ↔ CLI parity (1:1)

Every verb in the Cloud sidebar has a CLI verb that goes through the **same socket method** and the same app code path (`SurfaceCatalog`, the machine's `CmuxTuiSurfaceProvider`). An agent can do anything a person can do from the sidebar, and a sidebar action never does something the CLI cannot. Ids come from `cmux vm tree --json` / `cmux surface ls --json` (`<machine>/<kind>/<key>`, `ws_…`, `term_…`).

Sidebar (human) | CLI (agent) | Socket method | Verified
--- | --- | --- | ---
**Machines panel ＋ / palette "New Cloud Machine…"** (name, Desktop/Base, size; Create closes the sheet and the create runs in the background) | `cmux vm new [--desktop\|--base] [--size 8g] [--name <label>] [--focus false] [--detach] [--json]` — the sheet passes `--focus false` | `vm.create` | ✅ the pending row in the tree ("Creating…", then failure with Retry / Show Error / Dismiss) is `MachineCreateCoordinator`; `--detach` is the agent's way to get the same non-blocking outcome without a workspace
**Open Base / Set Up Base** (first setup closes its sheet immediately and continues in the background) | `cmux vm base open [--desktop\|--base] [--focus false]` — the sheet passes `--focus false` | `vm.base_open` | ✅ pending row reads "Setting up Base…"
Control bar › **Open Cloud Agent** (Claude/Codex/OpenCode) | `cmux vm prompt --open <agent>` | `vm.cloud_agent_open` | ✅ installs the bundled cmux-cloud skill file (`~/.config/cmux/skills/cmux-cloud.md`), opens a local agent terminal with the kickoff prompt
Control bar › **Copy Cloud Prompt** | `cmux vm prompt` | `vm.cloud_prompt` | ✅ prints the same prompt (skill path on stderr) — bootstraps ANY agent/harness
Machine row › **Open Shell** / click | `cmux surface new-terminal --machine <m>` (into the current workspace, like the row) · `cmux vm open <m> [--workspace <ref>]` (a shell, its own workspace by default) | `vm.terminal_new` / `workspace.cloud_vm_terminal_ready` | ✅
Machine row › **New Workspace**, Workspaces ＋ | `cmux vm workspace new <m> [--name n]` | `vm.workspace_new` | ✅
Machine row › **Open Desktop**, VNC Displays › Open Desktop, screen row click (one row per screen, `display:1`, …) | `cmux vm open <m>:desktop` / `cmux surface open <m>/display/display:1` | `vm.desktop_open` / `surface.project` | ✅
Machine row › **Open Full cmux-tui Client** | `cmux vm tui <m>` | (pane command) | ✅
Machine row › **Refresh**, any group › Refresh | `cmux vm tree --refresh` / `cmux surface ls --refresh` | `vm.tree {refresh}` | ✅
Machine row › **Rename…** | `cmux vm rename <m> <label>` | `vm.rename` | ✅
Machine row › **Status** | `cmux vm status <m>` (+ `vm stats`) | `vm.status` / `vm.stats` | ✅
Machine row › **Checkpoint** (only when `capabilities.snapshot`) | `cmux vm snapshot <m> [--name n]` | `vm.snapshot` | ✅ hidden on providers that cannot; `vm ls --json` → `capabilities`
Machine row › **Fork** (only when `capabilities.fork`) | `cmux vm fork <m> [--name n]` | `vm.fork` | ✅ hidden on providers that cannot
Machine row › **Delete…** | `cmux vm rm <m>` | `vm.destroy` | ✅
Terminals / Workspaces group › **New Terminal** | `cmux surface new-terminal --machine <m> [-- <cmd>]` | `vm.terminal_new` | ✅
Workspace row › **New Terminal Here** | `cmux surface new-terminal --machine <m> --remote-workspace <ws>` | `vm.terminal_new {workspace_id}` | ✅
Workspace row › **Go to Workspace** (the open verb's label once the workspace is showing locally), click, Return | `cmux workspace select <local-id>` (the local workspace from `vm tree --json` projections) | `workspace.select` | ✅ one open verb; never opens a second copy
Workspace row › **Open Workspace** (not open yet), click, Return | `cmux vm workspace open <m> <ws>` — every member of the workspace (terminals, browsers, pinned displays) as its own local workspace | `vm.workspace_open` | ✅ resolved exactly like the row (`ws_…` id or an unambiguous name; every view counted, so a terminal viewed in two workspaces opens from both); an empty workspace opens nothing (D9) — the CLI says so and names `cmux vm open <m>/<ws>`
(no menu verb — one terminal, not the whole workspace) | `cmux vm open <m>/<ws>` — the workspace's focused/first live terminal, or a new shell in it when nothing is running | `surface.project` / `surface.new_terminal` | ✅ same id-or-unambiguous-name resolution; this is the verb that creates in an empty workspace
(no menu verb — drop onto the current pane) | `cmux vm workspace open <m> <ws> --here [--workspace <local>]` | `vm.workspace_open {here}` | ✅
(no menu verb — CLI placement only) | `cmux vm workspace open <m> <ws> --tabs [--pane <p>]` | `vm.workspace_open {here, placement: tab}` | ✅
Drag a workspace row onto a pane edge | `cmux vm workspace open <m> <ws> --pane <p> --left\|--right\|--up\|--down` | `vm.workspace_open {here, pane_id, direction}` | ✅
Workspace row › **Close Workspace…**, hover × (confirms when it has terminals) | `cmux vm workspace rm <m> <ws>` | `vm.workspace_delete` | ✅ same `CloudTreeNodeActions.deleteWorkspaceAndTerminals`: kills every terminal viewed there, then closes it — a closed workspace never leaves stray pool rows
(no menu verb — CLI only) | `cmux vm workspace close <m> <ws>` | `vm.workspace_close` | ✅ the protocol's keep-terminals close: they keep running (only `terminal close` kills) and, their workspace being gone, show in Terminals greyed as "detached"
Workspace row › **Rename…** | `cmux vm workspace rename <m> <ws> <name>` | `vm.workspace_rename` | ✅ same `provider.renameRemoteWorkspace`
Workspace row › **Copy Workspace ID** | `cmux vm tree --json` (`remote_workspace.id`) | `vm.tree` | ✅
Terminal / browser / display row click, **Open** | `cmux surface open <resource>` (reuses an open pane) / `cmux vm open <m>/<ws>/<term>` | `surface.project` | ✅
Row › **Open in New Tab** | `cmux surface open <resource> --pane <p> --tab` | `surface.project {placement: tab}` | ✅
Row › **Open in New Pane** (a second pane) | `cmux surface open <resource> --new` | `surface.project {reuse: false}` | ✅
Drag a row onto a pane edge | `cmux surface open <resource> --pane <p> --left\|…` | `surface.project {pane_id, direction}` | ✅
Terminal row › **Kill Terminal…**, hover × | `cmux vm terminal close <m> <term>` | `vm.terminal_close` | ✅ also closes every local pane showing it
Terminals › detached row (greyed, "detached": still running, no tab on the machine shows it, so it is in no workspace folder); click re-attaches it in a pane, right-click › **Kill Terminal…** | `cmux vm tree` lists it in the final `terminals/` section, under its `(detached — …)` subgroup (`remote_views: []` in `--json`), `cmux surface open <m>/terminal/<term>` / `cmux vm terminal close <m> <term>` | `surface.project` / `vm.terminal_close` | ✅
Display pointer row › Close (removes it from the workspace) | `cmux vm terminal close <m> display:1` | `vm.terminal_close` (tab close) | ⏳ needs daemon `display` tabs
Row › **Copy Surface ID** / **Copy Port** | `cmux surface ls --json` (`id`, `port`) | `surface.ls` | ✅
Port row (when shown) click | `cmux vm open <m>:port/<n>` / `cmux vm open <m> <n> [--print]` | `vm.port_open` | ✅

Rules that keep it 1:1:

- **One machine, many workspaces; four groups.** A machine is the big box; its cmux-tui workspaces are rows under it, never machines of their own. Under a connected machine, in this order: **Workspaces** (always its own row — with one workspace, with none, a "No workspaces yet" line under it — so its ＋, `cmux vm workspace new`, is one click away; a workspace row shows its own name, never a folded "Workspaces / name" breadcrumb, and lists exactly its layout: the terminals with a tab in it, its browsers, its screen), **Ports**, **VNC Displays** (one row per screen), and last, its own section, **Terminals** (every terminal resource the machine owns, one row per identity, badge = daemon tabs, detached ones greyed; always present so its ＋ is New Terminal, "No terminals yet" under it when empty). `cmux vm tree` prints the same sequence — workspaces, ports, one row per VNC display, then the final `terminals/` section (with its detached subgroup); the Terminals section is the sidebar's flat index of what those lines already name. A daemon browser with neither a workspace tab nor a port has no group of its own.
- **A workspace folder is its layout.** A terminal whose tab in the workspace closed (or whose workspace closed with `vm workspace close`) has left the workspace: no row lingers under it. It keeps running on the machine, so the Terminals group still lists it, greyed as "detached", where a click re-attaches it and Kill Terminal… ends it. Exited records with stale unresolved tab ids remain ordinary exited rows, not detached ones.
- A sidebar verb is implemented as a closure in `CloudTreeNodeActions` that calls the catalog/provider; the matching socket handler in `SurfaceSocketCommands` calls the same catalog/provider method. Adding a sidebar verb without a socket method is a parity bug.
- `--focus false` means the same on `vm new`, `vm base open`, and `vm open`: open the surface where it belongs, never select its workspace or move keyboard focus out of the workspace the person is in (a pane is still focused when its workspace is the one already on screen). The New Machine / Set Up Base sheets always create this way; the success notification's click goes to the new workspace.
- Placement flags mean the same everywhere: `--pane <p>` + side = split that pane on that side; `--tab` / `--tabs` = tabs in that pane; nothing = the focused pane of the current (or `--workspace`) local workspace; `--new` = never reuse a pane that already shows the surface.
- Ports are a first-class group in the tree when a machine exposes listening ports; the CLI and sidebar use the same port-open path.
- Agent-only primitives (`cmux vm terminal send|read|wait` → `vm.terminal_write|read|wait`, plus `exec`, `push`, `pull`, `route`, `run`, `agent`) have no sidebar verb by design: a person does those things by typing into a pane. They still go through the machine's `CmuxTuiSurfaceProvider`, so what an agent types headlessly shows up in every pane projecting that terminal.
