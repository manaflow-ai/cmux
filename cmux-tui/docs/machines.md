# Machines

The optional machine rail adds a connection layer to the left of the existing workspace rail. Selecting a machine replaces the attached cmux session while the client, rail layout, mouse handling, and workspace rendering stay local.

The feature is disabled by default. It activates when `machine_sidebar.enabled` is `true` or the `machines` array contains at least one valid entry. An active static catalog always starts with the current local session, labeled with the local hostname and `local`, followed by configured Unix-socket and SSH targets. A configured machine with id `current` is skipped because that id belongs to the local entry.

## Layout and input

The machine list and built-in workspace list use the same rail renderer, selection treatment, two-line entries, and divider. Each right divider has an independent drag width. `machine_sidebar.width` and `sidebar.width` provide their separate starting widths; their `max_width` settings provide separate drag limits. Both rails preserve at least 40 columns for pane content. When the terminal cannot fit two 10-column rails and the content minimum, cmux hides the machine rail first.

`Ctrl-b S` focuses the workspace rail. Left or `h` moves to the machine rail, and Right or `l` returns to the workspace rail. Up/Down or `k`/`j` changes the selected machine. Home, End, PageUp, and PageDown move through long catalogs. Enter connects to the selected machine or invokes the selected footer action. Esc returns focus to the active pane. Mouse clicks focus either rail; a machine switch occurs on release over the same machine row. Drag either divider to resize only that rail. Wheel input scrolls the rail body, or the footer when a very short terminal clips its actions.

The static catalog shows `+ Connect machine`. It accepts one `host` or `user@host` without whitespace, adds an SSH target for the current process, and connects to its `main` session. This temporary target is not written to configuration. `+ New VM` is capability-gated and does not appear for the static catalog. A future dynamic provider can expose it when that provider implements machine creation.

## Static targets

Unix targets connect directly to another local cmux control socket. Use an absolute socket path because configuration paths do not pass through a shell.

SSH targets start this process:

```text
ssh -T [-p PORT] [-i IDENTITY_FILE] -- [USER@]HOST 'BINARY' relay --session SESSION
```

The remote session must already be running. The remote `binary` must resolve in a noninteractive SSH login and defaults to `cmux-tui`. `relay` copies protocol bytes between stdio and that session's Unix socket. SSH owns host verification, authentication, encryption, and network transport; relay adds no authentication.

See [Configuration](configuration.md#machines) for the full schema and examples.

## Dynamic providers

A dynamic provider supplies scopes, machines, lifecycle actions, and transports without adding provider logic to the TUI. Choose exactly one startup transport:

```bash
cmux-tui --machine-provider /run/cmux/provider.sock
cmux-tui --machine-provider-command /opt/cmux-provider --profile production --
cmux-tui --cloud
```

The direct-command form treats every value through the terminating `--` as one literal argument. It does not use a shell. cmux appends `control` to the long-lived provider process and `stream` to each machine transport process.

`--cloud` runs OpenSSH against `cmux.cloud` by default. `--cloud-host`, `--cloud-user`, `--cloud-port`, and `--cloud-identity` override the destination. The connector uses one private SSH ControlMaster per provider generation and runs exactly `cmux provider control` for the catalog connection and `cmux provider stream` for each machine connection. The SSH server must implement those two commands.

Each connection generation receives a new client-generated bearer. The bearer travels only in the first provider protocol message and later machine transport handshakes. It is never placed in process arguments, environment variables, or diagnostics. Dropping or reconnecting the provider terminates its child processes and removes its private SSH control directory.

See [Configuration](configuration.md#dynamic-machine-provider) for persistent cloud settings and [Machine Provider Contract](../spec/machine-provider.md) for the transport boundary.

## Run with npm

Install cmux on a remote Linux or macOS machine so SSH has a stable executable path, then start a named headless session there:

```bash
npm install --global cmux
command -v cmux
cmux --headless --session agents
```

Keep the headless process under your normal service supervisor when it must survive logout. Put the absolute path printed by `command -v cmux` in the target's `binary` field and set `session` to `agents`. After adding that target to the local config, start the client normally:

```bash
npx cmux
```

The local `npx cmux` process renders both rails and opens `ssh -T` only when that machine is selected. The remote process serves workspaces and terminals through its existing protocol-v9 session.

For a direct transport check, the equivalent relay is:

```bash
ssh -T dev@buildbox /home/dev/.local/bin/cmux relay --session agents
```

This command emits raw JSON-lines protocol traffic, not a second TUI. Normally the machine connector owns it.
