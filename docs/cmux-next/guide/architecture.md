# How cmux NEXT fits together

The app, the daemons that run your terminals and agents, your machines, and cmux Cloud: what each part does and where its code is.

cmux-next is several programs that work together. The window is one of them. Your terminals and agents run in two daemons that keep going when the window closes, on this Mac or on other machines. cmux Cloud, the service behind your account, links the machines.

This Mac runs the cmux app and two daemons: cmux-tui for terminals and layout, and acpmux for agent sessions. Machines you add and Cloud machines run the same two daemons, and acpmux links them. cmux Cloud holds your account, your machines, your vault, and the team hub, and starts Cloud machines.

## The app

The macOS app is a native window around web views and a Rust core. The web views draw the agent chat, diffs, Markdown, and Settings. The Rust core is linked into the app and holds the action catalog, the palette ranking, and the layout rules. Every command in the palette, the menus, the CLI, and the MCP tools comes from that one catalog, so they always match. The iPhone app is another client of the same machines.

| Where | What |
| --- | --- |
| [`Packages/macOS/CmuxNext`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/Packages/macOS/CmuxNext) | The macOS app, one Swift module per feature |
| [`cmux-tui/crates/cmux-app-ffi`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-app-ffi) | The Rust library linked into the app |
| [`cmux-tui/crates/cmux-action-catalog`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-action-catalog) | The action catalog: every command, its shortcut and surfaces |
| [`cmux-next-ios`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-next-ios) | The iPhone app |

## Web views

Chat, diffs, Markdown, Settings, Home, and the other pages are React, built from one source tree. The app serves each page from its own cmux-page:// origin, and the page talks to the app only over a small bridge. A dev server can feed them to a running app with hot reload.

| Where | What |
| --- | --- |
| [`webviews`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/webviews) | The React source and its dev server |
| [`webviews/src/pages`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/webviews/src/pages) | Pages the app hosts: Settings, Home, history, and more |

## Terminals: the cmux-tui daemon

Terminals, panes, and the workspace layout live in the cmux-tui daemon, not in the window. The app keeps a read-only copy and sends the daemon requests over a local socket. So terminals keep running while the app restarts or updates. The cmux CLI and cmux mcp serve talk to the same daemon, which is why they can do everything the app can.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/cmux-tui`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui) | The cmux command and the cmux-tui daemon |
| [`cmux-tui/crates/cmux-tui/src/cli`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli) | The CLI, including cmux mcp serve |
| [`cmux-tui/docs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/docs) | cmux-tui docs: concepts, protocol, remote, machines |

## Agents: acpmux

Every agent chat is a session in acpmux, a daemon on each machine. acpmux starts the agent program (a harness: Claude Code, Codex, or one you add), keeps it running by name, records every message, and lets any number of clients attach: the chat in the app, the CLI, or another agent. It also keeps the cost ledger of every turn.

The acpmux daemons on your machines link up. A session on another machine is addressed as MACHINE/NAME. A message to a session can also go through your team's hub in cmux Cloud, which delivers it wherever that session runs.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/acpmux`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux) | The agent daemon and its CLI |
| [`cmux-tui/crates/acpmux/harnesses`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/harnesses) | The harness profiles cmux ships |
| [`cmux-tui/crates/acpmux/docs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/docs) | acpmux docs: daemon, sessions, harnesses, machines |

## Machines

A machine is any computer that runs cmux-tui and acpmux: this Mac, a computer you add, or a Cloud machine. The sidebar shows each machine's workspaces under its name. Agents on another machine keep running when your laptop sleeps.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/acpmux/src/cli/host_enroll.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/src/cli/host_enroll.rs) | Add Machine over SSH: reach, install, start, link |
| [`cmux-tui/crates/cmux-tui/src/cli/machine_join.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/machine_join.rs) | cmux machine add: join with a pasted line |
| [`cmux-tui/crates/cmux-remote`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-remote) | The remote daemon, its clients and connection |

## cmux Cloud

cmux Cloud is the service behind your cmux account. It starts, pauses, forks, and snapshots Cloud machines, keeps the list of machines you added, holds your vault, runs the team hub, and connects GitHub. A Cloud machine boots from an image that already has cmux-tui, acpmux, and the agents installed. A Cloud chat can start on your paused spare machine, which wakes as you start, so you do not wait for a new one.

A repository describes the machine it needs in .cmux/machine.toml: environment variables, the names of the secrets it needs, setup commands, and checks. cmux applies the file on the machine.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/cmux-cloud-api`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-cloud-api) | The Cloud API client |
| [`cmux-tui/crates/cmux-cloud-start-core`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-cloud-start-core) | How a Cloud chat starts, spares included |
| [`cmux-tui/crates/cmux-cloud-start-core/src/machine_config.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-cloud-start-core/src/machine_config.rs) | The .cmux/machine.toml format |
| [`web/services/vms`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/web/services/vms) | Cloud machine drivers |
| [`web/services/vms/images/devbox`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/web/services/vms/images/devbox) | The Cloud machine image |

## Secrets and the vault

Keys never go on a command line. A key for an agent you added stays in this Mac's Keychain. A secret a Cloud machine needs stays in the Keychain too, and goes to the machine only over its own connection. Your vault in cmux Cloud gives machines you add their keys, and agents on them get a placeholder: the machine puts the real value only into requests to the hosts you allow.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/cmux-vault-egress`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-vault-egress) | The proxy that puts a vault value into allowed requests |
| [`cmux-tui/crates/cmux-tui/src/cli/machine_join/vault.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/machine_join/vault.rs) | cmux machine vault |
| [`cmux-tui/crates/cmux-tui/src/cli/cloud_secret.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/cloud_secret.rs) | cmux cloud secret |
| [`cmux-tui/crates/acpmux/src/cli/harness_secret.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/src/cli/harness_secret.rs) | cmux harness secret |

## GitHub

Agents use GitHub with your own gh sign-in on this Mac. Connect GitHub to your cmux account for Cloud machines. A machine you added can borrow this Mac's GitHub access for a short list of actions: read a repository or pull request, open a draft pull request, and file or comment on an issue. It cannot push or merge. Agents can ask which GitHub account is connected, but never get a token from it.

```bash
cmux accounts github-connect
cmux cloud setup-github
```

| Where | What |
| --- | --- |
| [`cmux-tui/crates/acpmux/src/github_status.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/src/github_status.rs) | Which GitHub account an agent can use, never a token |
| [`cmux-tui/crates/acpmux/src/github_broker.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/src/github_broker.rs) | The GitHub actions a machine you added may borrow |
| [`cmux-tui/crates/cmux-host/src/github_cli.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-host/src/github_cli.rs) | cmux github: credentials and gh for agents |

## MCP and connectors

cmux is an MCP server: cmux mcp serve gives Claude Code, Codex, or any MCP client the same control of cmux that the CLI has. Agent chats inside cmux have it already.

Connecting other MCP servers to your agents is being built. You will ask an agent to connect a service, approve a card that says what it gets, and sign in in a cmux browser tab. Agents will get the tools, never the token. It is not on in builds yet; this page will link its guide when it is.

| Where | What |
| --- | --- |
| [`cmux-tui/crates/cmux-tui/src/cli/mcp`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/mcp) | The MCP server (cmux mcp serve) |
| [`cmux-tui/crates/cmux-mcp-connect`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-mcp-connect) | Rules for connecting other MCP servers (in progress) |

## Updates

nightly-next updates itself from the update feed; cmux NEXT DEV updates with its script. Quitting to update keeps your sessions: the daemons keep your terminals and agents running, and the new app attaches to them. A daemon still on the old version shows Restart Recommended in Settings > Server, and restarts only when you choose.

| Where | What |
| --- | --- |
| [`Packages/macOS/CmuxUpdater`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/Packages/macOS/CmuxUpdater) | The app updater and its channels |
| [`scripts/cmux-next/update-dev-daily.sh`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/scripts/cmux-next/update-dev-daily.sh) | The cmux NEXT DEV install and update script |
| [`cmux-tui/crates/cmux-tui/src/cli/older_daemon.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/older_daemon.rs) | How the CLI notices a daemon on an older version |

## Design docs

Longer docs live next to the code. Design notes for each feature are in plans/cmux-next, and how-to guides for running and building cmux-next are in docs/cmux-next.

| Where | What |
| --- | --- |
| [`plans/cmux-next`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/plans/cmux-next) | Design notes, one per feature |
| [`docs/cmux-next`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/docs/cmux-next) | Guides: install, dev builds, hot reload, dotfiles |
| [`plans/cmux-next/docs-DESIGN.md`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/plans/cmux-next/docs-DESIGN.md) | How these docs are built |

## Read more

- [acpmux, the agent daemon](acpmux.md)
- [Agents and subagents](agents.md)
- [Machines](machines.md)
- [Remote machines and Tailscale](remote.md)
- [Cloud machines](cloud.md)
- [Secrets and the vault](vault.md)
- [MCP server](mcp.md)
- [Install, update, and nightly](updates.md)
