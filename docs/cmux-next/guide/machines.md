# Machines

This Mac, computers you add, and Cloud machines: what runs on each, and how they join.

A machine is a computer that runs your terminals and agents. Each one runs the same two daemons: cmux-tui for terminals and workspaces, and acpmux for agent sessions. The sidebar shows each machine's workspaces under its name.

- This Mac. cmux starts its daemons when you open the app.
- A computer you own: a Mac mini, a Linux box, or a server. cmux installs its daemons for you.
- A Cloud machine: a computer cmux Cloud runs for you. It starts with the daemons and agents installed.

## Add a computer you own

Over SSH: run Add Machine… in the command palette and give its host name. The Remote machines page has the steps.

Without SSH: cmux machine add prints one line to paste on the other computer. The line holds a single-use token that expires after 10 minutes. The computer joins your cmux account and shows in your sidebar.

```bash
cmux machine add                  # print the line to paste
cmux machine add --vault          # the same, and give the machine your vault
cmux device list                  # every device that can reach yours
cmux device doctor NAME           # check an SSH machine step by step; --fix repairs
cmux device revoke NAME           # remove a machine that joined with a pasted line
```

## Cloud machines

cmux Cloud starts, pauses, forks, and snapshots Cloud machines. A Cloud chat can start on your paused spare machine, which wakes as you start, so you do not wait for a new one.

A repository describes the machine it needs in .cmux/machine.toml. cmux applies it on the machine: it writes the environment, reports any named secret not delivered yet, runs setup in the checkout, and reports the checks. Setup runs again only when the file changes. Secret values never reach setup or checks.

```toml
version = 1
[env]
NODE_ENV = "development"
[secrets]
names = ["DATABASE_URL"]     # names only; values come from cmux cloud secret set
[setup]
run = ["bun install"]
timeout_minutes = 30
check = ["bun run typecheck"]
```

## Which machine runs a new session

You pick the machine when you start a chat. With --machine auto, acpmux picks the least-loaded machine you allow; pick says which one and why.

```bash
cmux acp machine pick
cmux acp new --machine auto -m codex -d "Fix the flaky test"
```

| Where | What |
| --- | --- |
| [`cmux-tui/crates/cmux-tui/src/cli/machine_join.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/machine_join.rs) | cmux machine add: join with a pasted line |
| [`cmux-tui/crates/cmux-tui/src/cli/machine_doctor.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/cli/machine_doctor.rs) | cmux machine doctor |
| [`cmux-tui/crates/cmux-tui/src/devices`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-tui/src/devices) | cmux device: every device that can reach yours |
| [`cmux-tui/crates/acpmux/src/cli/host_enroll.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/acpmux/src/cli/host_enroll.rs) | Add Machine over SSH: reach, install, start, link |
| [`cmux-tui/crates/cmux-cloud-start-core/src/machine_config.rs`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-cloud-start-core/src/machine_config.rs) | The .cmux/machine.toml format |
| [`cmux-tui/crates/cmux-cloud-machine`](https://github.com/manaflow-ai/cmux/tree/feat-cmux-next/cmux-tui/crates/cmux-cloud-machine) | A Cloud machine's record and its pause and resume rules |

- [Remote machines and Tailscale](remote.md)
- [Cloud machines](cloud.md)
- [Secrets and the vault](vault.md)
- [acpmux, the agent daemon](acpmux.md)
- [How cmux NEXT fits together](architecture.md)
