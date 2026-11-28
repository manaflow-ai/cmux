# Cloud sidebar and CLI

Every Cloud sidebar, palette and context-menu item is an app action. The CLI runs
the same action through the app control socket, so an agent reaches it with
`cmux cloud <verb>` or `cmux action run <id>`. Check targets and arguments with
`cmux action describe "<cli name>"` first. Without `--target`, a machine action
applies to the focused cloud workspace's machine.

| Sidebar or palette item | CLI |
| --- | --- |
| New Cloud Machine… | `cmux cloud new-machine` (opens the sheet) |
| New Cloud Workspace | `cmux cloud new-workspace` |
| New workspace on a machine | `cmux workspace new-on-machine --machine machine:vm-…` |
| Open Machine | `cmux cloud open-machine --target machine:vm-…` |
| New Terminal on Machine | `cmux cloud new-terminal-on-machine --target machine:vm-…` |
| Rename Machine… | `cmux cloud rename-machine --target machine:vm-… --name <label>` |
| Resize Machine… | `cmux cloud resize-machine --target machine:vm-… --size small\|medium\|large\|xlarge` |
| Cloud Machine Status | `cmux cloud machine-status --target machine:vm-…` |
| Cloud Machine Ports | `cmux cloud machine-ports --target machine:vm-…` |
| Cloud Machine Tools | `cmux cloud machine-tools --target machine:vm-…` |
| Snapshot Cloud Machine | `cmux cloud snapshot-machine --target machine:vm-…` |
| Fork Cloud Machine | `cmux cloud fork-machine --target machine:vm-…` |
| Restore Cloud Machine… | `cmux cloud restore-machine --target machine:vm-… --snapshot <id>` |
| Promote Machine to Template | `cmux cloud promote-machine-to-template --target machine:vm-…` |
| Hand Off Cloud Machine | `cmux cloud hand-off-machine --target machine:vm-…` |
| Kill Machine | `cmux cloud kill-machine --target machine:vm-…` |
| Copy Machine ID / Link / Port | `cmux cloud copy-machine-id`, `copy-machine-link --port <n>`, `copy-machine-port --port <n>` |
| Cloud Diagnostics… | `cmux cloud diagnostics` |
| Team Picker | `cmux cloud team-picker` |
| Sign In / Sign Out | `cmux cloud sign-in`, `cmux cloud sign-out` |
| Open Mobile Pairing | `cmux cloud open-mobile-pairing` |

Actions return the app's action result. They do not return machine data such as a
tree, command output or a port URL on stdout; copy actions write to the clipboard.

Removed with the Swift CLI, with no action equivalent: `vm tree` and its sidebar
pin/order verbs, `vm workspace open|close|rm|rename` against a machine,
`surface ls|open|new-terminal`, `vm open <m>:desktop|:port/<n>`, `vm tui`,
`vm pause|resume`, `vm prompt`, `vm layout|env` from the Mac and the headless
`vm terminal send|read|wait|wait-exit|output` verbs. Inside a machine terminal, the
machine's own `cmux` covers the terminal verbs; see [guest operations](guest.md).
