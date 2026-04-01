# Docker + Codex over `cmux ssh`

This document explains how to keep local cmux notifications working when `Codex` runs inside a Docker container on a remote host reached through `cmux ssh`.

## Short Answer

- Running `codex` directly in the remote shell started by `cmux ssh` works automatically.
- Running `codex` inside a Docker container does not work automatically.
- To make it work inside a container, the container must:
  - reach the relay address published by `cmux ssh`
  - receive `CMUX_SOCKET_PATH`, `CMUX_WORKSPACE_ID`, and `CMUX_SURFACE_ID`
  - have the `cmux` wrapper available in `PATH`
  - have Codex hooks installed in the container's `~/.codex`

## Recommended Approach

The simplest and most reliable setup is:

1. Start the remote workspace with `cmux ssh <host>`.
2. Run `codex` in that remote shell.
3. Let Codex call `docker exec` or `docker run` only for the commands that actually need the container.

This keeps notifications working without extra container plumbing.

## When You Must Run `codex` Inside a Container

### Recommended: `docker run --network host` on Linux

On Linux remote hosts, `--network host` is the easiest way to preserve the relay path created by `cmux ssh`.

```bash
docker run --rm -it \
  --network host \
  -e CMUX_SOCKET_PATH \
  -e CMUX_WORKSPACE_ID \
  -e CMUX_SURFACE_ID \
  -v "$HOME/.cmux:$HOME/.cmux" \
  -v "$HOME/.codex:$HOME/.codex" \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  <image> bash
```

Inside the container:

```bash
export PATH="$HOME/.cmux/bin:$PATH"
cmux codex install-hooks
codex
```

Notes:

- Mounting `~/.cmux` makes the remote `cmux` wrapper and relay metadata visible inside the container.
- Mounting `~/.codex` shares the already-installed Codex hook config with the container.
- Re-running `cmux codex install-hooks` is safe. If nothing changed, it becomes a no-op.

### Bridge-Network Containers Need a Rewritten Relay Address

In a normal bridge-network container, the inherited:

```bash
CMUX_SOCKET_PATH=127.0.0.1:<relay-port>
```

points to the container itself, not the remote host. In that case, `cmux codex-hook` will not be able to reach the relay.

Use one of these options:

1. Prefer `--network host`.
2. Or expose the host gateway to the container and rewrite `CMUX_SOCKET_PATH`.

Example:

```bash
relay_port="${CMUX_SOCKET_PATH##*:}"

docker run --rm -it \
  --add-host host.docker.internal:host-gateway \
  -e CMUX_WORKSPACE_ID \
  -e CMUX_SURFACE_ID \
  -e CMUX_SOCKET_PATH="host.docker.internal:${relay_port}" \
  -v "$HOME/.cmux:$HOME/.cmux" \
  -v "$HOME/.codex:$HOME/.codex" \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  <image> bash
```

Inside the container:

```bash
export PATH="$HOME/.cmux/bin:$PATH"
cmux codex install-hooks
codex
```

If your Docker setup does not support `host.docker.internal` on Linux, use the remote host's reachable bridge/gateway IP instead and rewrite `CMUX_SOCKET_PATH` to that address.

## Attaching to an Existing Container

`docker exec` only works if the container already has the right network path and mounted state.

Example for a container that was started with host networking and the required mounts:

```bash
docker exec -it \
  -e CMUX_SOCKET_PATH="$CMUX_SOCKET_PATH" \
  -e CMUX_WORKSPACE_ID="$CMUX_WORKSPACE_ID" \
  -e CMUX_SURFACE_ID="$CMUX_SURFACE_ID" \
  <container> bash
```

Inside the container:

```bash
export PATH="$HOME/.cmux/bin:$PATH"
cmux codex install-hooks
codex
```

If the container was created without host networking and without mounted `~/.cmux` and `~/.codex`, `docker exec` alone is not enough. Recreate the container with the required settings.

## Compose Example

For Docker Compose on a Linux remote host:

```yaml
services:
  codex:
    network_mode: host
    environment:
      CMUX_SOCKET_PATH: ${CMUX_SOCKET_PATH}
      CMUX_WORKSPACE_ID: ${CMUX_WORKSPACE_ID}
      CMUX_SURFACE_ID: ${CMUX_SURFACE_ID}
    volumes:
      - ${HOME}/.cmux:${HOME}/.cmux
      - ${HOME}/.codex:${HOME}/.codex
      - ${PWD}:${PWD}
    working_dir: ${PWD}
```

Then inside the service container:

```bash
export PATH="$HOME/.cmux/bin:$PATH"
cmux codex install-hooks
codex
```

Adjust `HOME`, user IDs, and mount paths if the container runs as a different user.

## Verification

Inside the container, verify the required state first:

```bash
echo "$CMUX_SOCKET_PATH"
echo "$CMUX_WORKSPACE_ID"
echo "$CMUX_SURFACE_ID"
command -v cmux
grep -n "cmux codex-hook" ~/.codex/hooks.json
grep -n "codex_hooks = true" ~/.codex/config.toml
```

Then run a smoke test:

```bash
printf '{"session_id":"docker-smoke-1","cwd":"%s"}\n' "$PWD" | cmux codex-hook session-start
printf '{"session_id":"docker-smoke-1","cwd":"%s"}\n' "$PWD" | cmux codex-hook prompt-submit
printf '{"session_id":"docker-smoke-1","cwd":"%s","last_assistant_message":"docker smoke test"}\n' "$PWD" | cmux codex-hook stop
```

Expected result:

- the local cmux workspace status changes for Codex
- a macOS notification appears on the local machine

## Troubleshooting

### `cmux codex-hook ...` prints `{}` and nothing happens

Usually one of these is missing inside the container:

- `CMUX_SURFACE_ID`
- `CMUX_WORKSPACE_ID`
- the `cmux` wrapper in `PATH`

It can also mean the hook is running outside a shell started by `cmux ssh`.

### `cmux: unknown command "codex"`

The container is likely using a different or older `cmux` binary instead of the wrapper from the mounted `~/.cmux/bin`.

Check:

```bash
command -v cmux
ls -la "$HOME/.cmux/bin/cmux"
```

### Hook commands exit successfully but no notification appears

The most common cause is bridge networking with an unchanged:

```bash
CMUX_SOCKET_PATH=127.0.0.1:<relay-port>
```

Inside a bridge-network container, that address points at the container, not the remote host. Use `--network host` or rewrite `CMUX_SOCKET_PATH` to a host-reachable address.

### `docker exec` still does not work

`docker exec` cannot fix missing container startup state. If the existing container lacks:

- host networking or a host-reachable relay address
- mounted `~/.cmux`
- mounted `~/.codex`

recreate the container instead of trying to patch it after the fact.
