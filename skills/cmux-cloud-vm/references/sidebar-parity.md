# Cloud sidebar and CLI

Every Cloud sidebar, palette and context-menu item is an app action. The CLI runs
the same action through the app control socket, so an agent reaches it with
`cmux vm <verb>` or `cmux action run <id>`. Check targets and arguments with
`cmux action describe "<cli name>"` first. From the CLI or MCP, a machine action
needs `--target vm:vm-…`; without it the run is refused.

| Sidebar or palette item | CLI |
| --- | --- |
| List Cloud Machines (the Cloud sidebar) | `cmux vm ls` (returns `machines`) |
| New Cloud Machine… | `cmux vm new-machine` (returns `machine_id`) |
| New Cloud Workspace | `cmux vm new-workspace` |
| New workspace on a machine | `cmux workspace new-on-machine --machine machine:vm-…` |
| Open Machine | `cmux vm open-machine --target vm:vm-…` |
| New Terminal on Machine | `cmux vm new-terminal-on-machine --target vm:vm-…` |
| Rename Machine… | `cmux vm rename-machine --target vm:vm-… --name <label>` |
| Resize Machine… | `cmux vm resize-machine --target vm:vm-… --size small\|medium\|large\|xlarge` |
| Cloud Machine Status | `cmux vm machine-status --target vm:vm-…` |
| Cloud Machine Ports | `cmux vm machine-ports --target vm:vm-…` |
| Cloud Machine Tools | `cmux vm machine-tools --target vm:vm-…` |
| Set Up GitHub on This Machine | `cmux vm setup-github --target vm:vm-…` |
| Snapshot Cloud Machine | `cmux vm snapshot-machine --target vm:vm-…` |
| Fork Cloud Machine | `cmux vm fork-machine --target vm:vm-…` |
| Restore Cloud Machine… | `cmux vm restore-machine --target vm:vm-… --snapshot <id>` |
| Promote Machine to Template | `cmux vm promote-machine-to-template --target vm:vm-…` |
| Hand Off Cloud Machine | `cmux vm hand-off-machine --target vm:vm-…` |
| Kill Machine | `cmux vm kill-machine --target vm:vm-…` |
| Pause Machine / Resume Machine | `cmux vm pause-machine`, `cmux vm resume-machine` (with `--target vm:vm-…`) |
| Open Cloud SSH Terminal / Run Command on Cloud Machine… | `cmux vm ssh`, `cmux vm exec --command '<cmd>'` |
| Cloud files (list, read, write, create directory, remove, details) | `cmux vm files-list\|file-read\|file-write\|file-mkdir\|file-remove\|file-stat --path <p>` |
| Networks, firewall rules and tunnels | `cmux vm network-list`, `firewall-list\|get\|create\|delete`, `tunnel-attach\|detach\|rotate-key` |
| Move to Cloud / Bring Back Local (agent chat tab) | `cmux vm move`, `cmux vm bring-back` |
| Copy Machine ID / Link / Port | Menu only: the CLI never writes the clipboard |
| Cloud Diagnostics… | `cmux vm diagnostics` |
| Switch Active Team… (also Settings > Accounts > Active Team) | `cmux vm team-picker` |
| Sign In / Sign Out | `cmux login`, `cmux logout` |
| Open Mobile Pairing | `cmux vm open-mobile-pairing` |

Actions return the app's action result. From the CLI, read and list actions put
their data in its `result` (command output, a file, a listing, status); they return
no tree or port URL, and copy actions write to the clipboard.

Removed with the Swift CLI, with no action equivalent: `vm tree` and its sidebar
pin/order verbs, `vm workspace open|close|rm|rename` against a machine,
`surface ls|open|new-terminal`, `vm open <m>:desktop|:port/<n>`, `vm tui`,
`vm prompt`, `vm layout|env` from the Mac and the headless
`vm terminal send|read|wait|wait-exit|output` verbs. Inside a machine terminal, the
machine's own `cmux` covers the terminal verbs; see [guest operations](guest.md).
