# cmux vm command reference

`cloud` is an alias for `vm` (`cmux cloud ls` == `cmux vm ls`). The global `--json` flag works on every subcommand and may appear before or after the subcommand. All of this requires the cmux app running and a signed-in account.

## Context and discovery

```bash
cmux auth status                       # signed in?
cmux vm ls                             # NAME / LABEL / STATE / PROVIDER / IMAGE + plan meter
cmux vm ls --json                      # {vms: [...], limits: {maxActiveVms, planId}}
cmux vm status <id>                    # provider, status, image
cmux vm stats <id>                     # CPU/mem/disk now; sleeping machines stay asleep
cmux vm tools <id>                     # which tools are installed (git, gh, node, bun, python3, ...)
cmux vm ports <id>                     # listening TCP ports inside the machine
cmux vm handoff <id>                   # short attach block to paste to a human or another agent
```

## Lifecycle

```bash
cmux vm new --detach                   # new Desktop machine (screen + shell), headless create
cmux vm new --base --detach            # shell-only machine
cmux vm new --size 16g --detach        # memory preset: 2g|4g|8g|16g|32g or raw MB
cmux vm wait <id> [--timeout <sec>] [--wake]   # block until ready; --wake also wakes it
cmux vm rename <id> <label>            # display label; the id stays the address
cmux vm rename <id> --clear
cmux vm rm <id>                        # PERMANENT delete of machine + data (aliases: destroy, delete)
```

Without `--detach`, `vm new`, `vm fork`, and `vm restore` also open the machine as a workspace in the user's app.

## Base (the pinned persistent slot)

```bash
cmux vm base open                      # open (or create) the one persistent Base machine
cmux vm base reset --reason "fresh"    # new Base generation; the old VM is retained
```

## Running work

```bash
# routed (no machine id): sticky per directory, then an idle machine the router provisioned earlier, then provision
cmux vm run -- <command...>
cmux vm run --sync -- bun test                 # push cwd to work/<basename>, run there
cmux vm run --sync --pull work/app/dist -- sh -c 'cd work/app && bun run build'
cmux vm run --machine <id> -- <command...>     # pin; --new forces a fresh pool machine
# --sync is additive: files that exist only on the machine are kept. For a clean
# slate use --new, or `cmux vm run -- rm -rf work/<dir>` before syncing again.
cmux vm run --size 16g --new -- <command...>   # size applies to machines this run creates

cmux vm exec <id> -- <command...>      # run a command; remote exit code passes through
cmux vm exec <id> --json -- ls -la     # {stdout, stderr, exit_code}
# long-running work: background it, then poll
cmux vm exec <id> -- sh -c 'nohup bun run build > /tmp/build.log 2>&1 &'
cmux vm exec <id> -- tail -n 20 /tmp/build.log
```

## Files

```bash
cmux vm push <id> <local-path> [remote-path]        # file or directory (tarball), SHA-256 verified
cmux vm push <id> ./site --exclude dist             # extra excludes on top of defaults
cmux vm push <id> ./repo --no-default-excludes      # include .git, node_modules, ...
cmux vm pull <id> <remote-path> [local-path]        # file or directory back to local disk
```

Aliases: `upload` / `download`. Transfers ride the exec channel (no SSH), chunked base64, 256 MB cap; directories travel as tarballs and merge into the destination.

## Ports, panes, and desktops (user-visible)

```bash
cmux vm open <id> 3000 --print         # mint a private tokened URL for the port; print only
cmux vm open <id> 3000                 # same, plus a browser split in the user's app
cmux vm shell <id>                     # cmux-tui session in the app (the machine runs the cmux-tui remote daemon)                     # terminal pane attached to the machine
cmux vm desktop <id>                   # noVNC screen pane (desktop-image machines only)
```

## Checkpoints, forks, templates

```bash
cmux vm snapshot <id> [--name <name>]  # checkpoint; prints the snapshot id (alias: checkpoint)
cmux vm fork <id> [--name <n>] [--detach]      # clone for a parallel experiment
cmux vm restore <snapshot-id> [--detach]       # snapshot -> new tracked machine
cmux vm promote-template <id>          # template-named snapshot for reuse
```

## SSH (provider-dependent)

```bash
cmux vm ssh <id>                       # cmux-managed SSH workspace (not on every provider)
cmux vm ssh-info <id>                  # raw SSH endpoint details when available
```

The default cmux Cloud provider attaches over a WebSocket PTY, not SSH — when `ssh` errors, use `exec`/`shell` instead.
