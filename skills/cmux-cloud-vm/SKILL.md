---
name: cmux-cloud-vm
description: "Operate cmux Cloud machines, run durable remote commands or agents, and present their workspaces or services. Use for cmux vm/cloud tasks; backend implementation belongs to cmux-backend."
---

# cmux Cloud machines

Use an existing machine and a workspace for the task. Machine terminals persist
when panes close or the Mac disconnects. Work headlessly; open a pane or share a
URL when there is a result for the user to inspect.

## Start with discovery

```sh
cmux vm --help
cmux auth status
cmux vm ls --json
cmux vm route --json
```

On the Mac, host operations need the app, sign-in and its private tunnel. Inside a
machine, use `cmux self --json` and the guest's help; read [guest operations](references/guest.md)
for its supported subset and auth. Installed help is authoritative when versions differ.

`route` inspects placement without creating a machine. Read `would_provision` and
the backend's `limits`/`capabilities`; do not assume a plan cap, memory size or
provider feature. Reuse the router's pool machine, or explicitly pin an existing
target with `--machine <id>`. Base is the user's persistent work. Prefer another
workspace on a machine to another machine.

## Run and observe

After identifying an authorized target, choose the operation:

| Need | Start here |
| --- | --- |
| Bounded command and exit code | `cmux vm run --machine <id> -- <command>` |
| Detached coding agent | `cmux vm agent --machine <id> --agent codex --no-open -- "<task>"` |
| Project with a dev layout | `cmux vm dev <id> --dry-run --json`, then the approved plan |
| Observe without opening panes | `cmux vm tree <id> --json`, `cmux vm terminal read <id> <term>` |
| Completion and full output | `cmux vm terminal wait-exit <id> <term>`, then `terminal output` |

Read the selected verb's `--help` before adding flags. Retain the machine,
workspace/terminal identity and actual exit result. A finished wait is not proof
that tests passed. Use `vm open`/`workspace open` to present verified results;
closing a view does not stop the machine terminal.

## Constraints that apply throughout

- Provisioning, forking, resetting, resizing and destructive cleanup need the
  user's authorization for the target and effect; retain authorization already
  given. Do not delete machines to make capacity or reset Base as a workaround.
- Keep account/upstream tokens on the host. Do not copy the user's credentials
  into a machine unless requested. Use the secret/env transfer paths when authorized;
  values do not belong in layout JSON, logs or command arguments.
- Use `--no-open`, `--detach` or `--print` while working. Focus changes are intentional.
  `workspace rm` kills its terminals; `workspace close` detaches them.

## Read only the relevant detail

- [Workflow recipes](references/agent-workflows.md): project setup, interactive
  terminals, long runs, peer agents, forks and service publication.
- [Command reference](references/commands.md): exact flags, JSON/exit contracts,
  file/env transfer, layouts, limits and capabilities. Search its task index first.
- [Guest operations](references/guest.md): host/guest grammar, CodeRouter,
  peer access, mirror behavior, notifications and browser authentication.
- [Sidebar parity](references/sidebar-parity.md): map a specific UI action to CLI.
- [Local workspace rules](../cmux-workspace/SKILL.md): presenting cloud work
  without disrupting the caller's workspace.
