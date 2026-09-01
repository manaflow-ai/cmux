# Sidebar ↔ CLI parity (1:1)

Every verb in the Cloud sidebar has a CLI verb that goes through the **same socket method** and the same app code path (`SurfaceCatalog`, the machine's `CmuxTuiSurfaceProvider`). An agent can do anything a person can do from the sidebar, and a sidebar action never does something the CLI cannot. Ids come from `cmux vm tree --json` / `cmux surface ls --json` (`<machine>/<kind>/<key>`, `ws_…`, `term_…`).

Sidebar (human) | CLI (agent) | Socket method | Verified
--- | --- | --- | ---
**Machines panel ＋ / palette "New Cloud Machine…"** (name, Desktop/Base, size) | `cmux vm new [--desktop\|--base] [--size 8g] [--name <label>] [--detach] [--json]` | `vm.create` | ✅
**Open Base / Set Up Base** | `cmux vm base open [--desktop\|--base]` | `vm.base_open` | ✅
Control bar › **Open Cloud Agent** (Claude/Codex/OpenCode) | `cmux vm prompt --open <agent>` | `vm.cloud_agent_open` | ✅ installs the bundled cmux-cloud skill file (`~/.config/cmux/skills/cmux-cloud.md`), opens a local agent terminal with the kickoff prompt
Control bar › **Copy Cloud Prompt** | `cmux vm prompt` | `vm.cloud_prompt` | ✅ prints the same prompt (skill path on stderr) — bootstraps ANY agent/harness
Machine row › **Open Shell** / click | `cmux surface new-terminal --machine <m>` (into the current workspace, like the row) · `cmux vm open <m> [--workspace <ref>]` (a shell, its own workspace by default) | `vm.terminal_new` / `workspace.cloud_vm_terminal_ready` | ✅
Machine row › **New Workspace**, Workspaces ＋ | `cmux vm workspace new <m> [--name n]` | `vm.workspace_new` | ✅
Machine row › **Open Desktop**, Displays › Open Desktop, Desktop row click | `cmux vm open <m>:desktop` / `cmux surface open <m>/display/display:1` | `vm.desktop_open` / `surface.project` | ✅
Machine row › **Open Full cmux-tui Client** | `cmux vm tui <m>` | (pane command) | ✅
Machine row › **Refresh**, any group › Refresh | `cmux vm tree --refresh` / `cmux surface ls --refresh` | `vm.tree {refresh}` | ✅
Machine row › **Rename…** | `cmux vm rename <m> <label>` | `vm.rename` | ✅
Machine row › **Status** | `cmux vm status <m>` (+ `vm stats`) | `vm.status` / `vm.stats` | ✅
Machine row › **Checkpoint** (only when `capabilities.snapshot`) | `cmux vm snapshot <m> [--name n]` | `vm.snapshot` | ✅ hidden on providers that cannot (Blaxel); `vm ls --json` → `capabilities`
Machine row › **Fork** (only when `capabilities.fork`) | `cmux vm fork <m> [--name n]` | `vm.fork` | ✅ hidden on providers that cannot (Blaxel)
Machine row › **Delete…** | `cmux vm rm <m>` | `vm.destroy` | ✅
Terminals / Workspaces group › **New Terminal** | `cmux surface new-terminal --machine <m> [-- <cmd>]` | `vm.terminal_new` | ✅
Workspace row › **New Terminal Here** | `cmux surface new-terminal --machine <m> --remote-workspace <ws>` | `vm.terminal_new {workspace_id}` | ✅
Workspace row › **Go to Workspace** (the open verb's label once the workspace is showing locally), click, Return | `cmux workspace select <local-id>` (the local workspace from `vm tree --json` projections) | `workspace.select` | ✅ one open verb; never opens a second copy
Workspace row › **Open Workspace** (not open yet), click, Return | `cmux vm workspace open <m> <ws>` (also `cmux vm open <m>/<ws>`) — opens as its own local workspace | `vm.workspace_open` | ✅ an empty workspace opens nothing (D9)
(no menu verb — drop onto the current pane) | `cmux vm workspace open <m> <ws> --here [--workspace <local>]` | `vm.workspace_open {here}` | ✅
(no menu verb — CLI placement only) | `cmux vm workspace open <m> <ws> --tabs [--pane <p>]` | `vm.workspace_open {here, placement: tab}` | ✅
Drag a workspace row onto a pane edge | `cmux vm workspace open <m> <ws> --pane <p> --left\|--right\|--up\|--down` | `vm.workspace_open {here, pane_id, direction}` | ✅
Workspace row › **Close Workspace…**, hover × (confirms when it has terminals) | `cmux vm workspace rm <m> <ws>` | `vm.workspace_delete` | ✅ same `CloudTreeNodeActions.deleteWorkspaceAndTerminals`: kills every terminal viewed there, then closes it — a closed workspace never leaves stray pool rows
(no menu verb — CLI only) | `cmux vm workspace close <m> <ws>` | `vm.workspace_close` | ✅ the protocol's keep-terminals close: they keep running in the Terminals pool (only `terminal close` kills); the sidebar shows them as plain pool rows, never as "detached"
Workspace row › **Rename…** | `cmux vm workspace rename <m> <ws> <name>` | `vm.workspace_rename` | ✅ same `provider.renameRemoteWorkspace`
Workspace row › **Copy Workspace ID** | `cmux vm tree --json` (`remote_workspace.id`) | `vm.tree` | ✅
Terminal / browser / display row click, **Open** | `cmux surface open <resource>` (reuses an open pane) / `cmux vm open <m>/<ws>/<term>` | `surface.project` | ✅
Row › **Open in New Tab** | `cmux surface open <resource> --pane <p> --tab` | `surface.project {placement: tab}` | ✅
Row › **Open in New Pane** (a second pane) | `cmux surface open <resource> --new` | `surface.project {reuse: false}` | ✅
Drag a row onto a pane edge | `cmux surface open <resource> --pane <p> --left\|…` | `surface.project {pane_id, direction}` | ✅
Terminal row › **Close Terminal**, hover × | `cmux vm terminal close <m> <term>` | `vm.terminal_close` | ✅ also closes every local pane showing it
Display pointer row › Close (removes it from the workspace) | `cmux vm terminal close <m> display:1` | `vm.terminal_close` (tab close) | ⏳ needs daemon `display` tabs
Row › **Copy Surface ID** / **Copy Port** | `cmux surface ls --json` (`id`, `port`) | `surface.ls` | ✅
Port row (when shown) click | `cmux vm open <m>:port/<n>` / `cmux vm open <m> <n> [--print]` | `vm.port_open` | ✅

Rules that keep it 1:1:

- A sidebar verb is implemented as a closure in `CloudTreeNodeActions` that calls the catalog/provider; the matching socket handler in `SurfaceSocketCommands` calls the same catalog/provider method. Adding a sidebar verb without a socket method is a parity bug.
- Placement flags mean the same everywhere: `--pane <p>` + side = split that pane on that side; `--tab` / `--tabs` = tabs in that pane; nothing = the focused pane of the current (or `--workspace`) local workspace; `--new` = never reuse a pane that already shows the surface.
- Ports are not in the tree today, but the CLI still opens them.
- Agent-only primitives (`cmux vm terminal send|read|wait` → `vm.terminal_write|read|wait`, plus `exec`, `push`, `pull`, `route`, `run`, `agent`) have no sidebar verb by design: a person does those things by typing into a pane. They still go through the machine's `CmuxTuiSurfaceProvider`, so what an agent types headlessly shows up in every pane projecting that terminal.
