# cmux Cloud CLI reference

The Rust `cmux` reaches Cloud machines through the app's cloud actions. The Swift
`cmux vm …` family and its `cmux cloud` alias were removed; there is no `vm` scope,
no `vm.*` socket method on the CLI, and no `cmux rpc`.

## Conventions

- **Requires** the cmux app running on the Mac and a signed-in account. Actions go
  to the app control socket (`CMUX_SOCKET_PATH`, else the app bundle's socket).
- **Discover** with `cmux action list --category cloud [--available]` and
  `cmux action describe "<cli name>"`. `describe` prints targets and arguments.
- **Run** with `cmux <noun> <verb> [--target machine:vm-…] [--<arg> <value>] [--wait]`
  or `cmux action run <id> …` with the same flags. `--wait` waits for the action's
  work to finish. `--json` prints the result object.
- **Target:** `--target machine:vm-…`. Without it, a machine action applies to the
  focused cloud workspace's machine. `cmux cloud copy-machine-id` copies an id to
  the clipboard.
- **Results** are action results, not machine data. No action returns command
  output, a file, a tree or a URL on stdout.
- **Exit codes:** `0` success, `1` action failure, `2` usage, `3` app unreachable.

## Machine actions

```bash
cmux cloud new-machine                                      # New Cloud Machine… sheet
cmux cloud new-workspace                                    # New Cloud Workspace
cmux cloud open-machine --target machine:vm-…
cmux cloud new-terminal-on-machine --target machine:vm-…
cmux cloud rename-machine --target machine:vm-… --name <label>
cmux cloud resize-machine --target machine:vm-… --size small|medium|large|xlarge
cmux cloud machine-status --target machine:vm-…
cmux cloud machine-ports --target machine:vm-…
cmux cloud machine-tools --target machine:vm-…
cmux cloud snapshot-machine --target machine:vm-…
cmux cloud fork-machine --target machine:vm-…
cmux cloud restore-machine --target machine:vm-… --snapshot <snapshot-id>
cmux cloud promote-machine-to-template --target machine:vm-…
cmux cloud hand-off-machine --target machine:vm-…
cmux cloud kill-machine --target machine:vm-…
cmux cloud copy-machine-id --target machine:vm-…
cmux cloud copy-machine-link --target machine:vm-… --port <n>
cmux cloud copy-machine-port --target machine:vm-… --port <n>
cmux workspace new-on-machine --machine machine:vm-…
```

Creating, forking, restoring, resizing and killing machines need the user's
authorization for the target and effect.

## Account and diagnostics

```bash
cmux cloud sign-in
cmux cloud sign-out
cmux cloud team-picker
cmux cloud diagnostics
cmux cloud open-mobile-pairing
```

## SSH remotes

`cmux remote connect|new-workspace|reconnect|disconnect|install|forget` are the
app's actions for cmux-tui on an SSH host. `cmux action describe "remote connect"`
lists its arguments (destination, session, binary, state directory).

## Inside a machine

The machine's own `cmux` speaks the cmux-tui resource grammar (`cmux workspace …`,
`cmux pane …`, `cmux tab …`, `cmux terminal …`) plus guest verbs: `self`, `auth
status`, `coderouter`, `agent`, `env`, `layout export|apply`, `notify`, `open-url`
and `vm ls`. See [guest operations](guest.md).

## Removed, with no CLI replacement

| Old verb | Closest supported path |
| --- | --- |
| `vm ls`, `vm route`, `vm tree`, `vm self`, `surface ls` | none on the Mac; `cmux self` and `cmux self peers` inside a machine |
| `vm new\|create` with `--size`, `--name`, `--desktop`, `--detach` | `cmux cloud new-machine` (the sheet) |
| `vm exec`, `vm run`, `vm dev`, `vm agent` | open a terminal on the machine, then `cmux workspace current run -- <argv>` or `cmux agent <harness>` there |
| `vm terminal send\|read\|wait\|wait-exit\|output\|close` from the Mac | the same work with `cmux terminal <term_…> write\|screen read\|screen wait\|process wait\|output read\|close` inside the machine |
| `vm push\|pull\|upload\|download`, `vm push --secret` | none; `cmux env set` inside the machine for settings |
| `vm layout export\|apply`, `vm env set\|ls\|rm` from the Mac | `cmux layout …` and `cmux env …` inside the machine |
| `vm open`, `vm shell`, `vm tui`, `vm desktop`, `surface open\|new-terminal` | `cmux cloud open-machine`, `cmux cloud new-terminal-on-machine` |
| `vm open <id> <port>`, `vm ports` | `cmux cloud machine-ports`, `cmux cloud copy-machine-link --port <n>` |
| `vm ssh`, `vm scp` diagnostics | none |
| `vm wait`, `vm pause`, `vm resume`, `vm stats`, `vm base open\|reset`, `vm prompt` | none |
| `vm snapshot\|fork\|restore\|promote-template\|rename\|rm\|handoff\|status\|resize` | the matching `cmux cloud …-machine` action |
| `cloud domains list\|publish\|verify\|access\|rm\|zones` | none |
| `vpn up\|down\|status`, `ai-accounts`, `auth login\|logout` | none on the CLI; use the app |
| `capabilities`, `rpc <method>` | `cmux app capabilities`, `cmux action list` |
