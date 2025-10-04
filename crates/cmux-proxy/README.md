# cmux-proxy

Header-based reverse proxy that routes to different local ports based on the `X-Cmux-Port-Internal` header. Now also supports per-workspace routing via `X-Cmux-Workspace-Internal` to choose a distinct upstream IP for network isolation. Supports:

- HTTP requests (streaming)
- WebSocket upgrades (transparent tunneling)
- Generic TCP via HTTP CONNECT tunneling

This is useful for multiplexing multiple local services behind a single port while choosing the target by header.

## Installation (Linux)

- One-liner (latest release):
  - `curl -fsSL https://raw.githubusercontent.com/lawrencecchen/cmux-proxy/main/scripts/install.sh | bash`
  - Optionally pin a version: `CMUX_PROXY_VERSION=v0.0.1 curl -fsSL https://raw.githubusercontent.com/lawrencecchen/cmux-proxy/main/scripts/install.sh | bash`
- Docker (multi-arch):
  - `docker run --rm -p 8080:8080 ghcr.io/lawrencecchen/cmux-proxy:latest`

Notes:
- The installer puts `cmux-proxy` in `/usr/local/bin` by default. Override with `CMUX_PROXY_BIN_DIR`.
- Architectures supported by the installer: `x86_64` and `aarch64`.

## Build and Run

- Build: `cargo build --release`
- Run: `./target/release/cmux-proxy --listen 0.0.0.0:8080` (default)

Env/flags:

- `--listen` or `CMUX_LISTEN` (accepts multiple or comma-separated). Defaults to `0.0.0.0:8080,127.0.0.1:8080`.
  - Note: binding to `0.0.0.0:<port>` already covers `127.0.0.1:<port>`; duplicate binds are deduped to avoid conflicts.
- `--upstream-host` or `CMUX_UPSTREAM_HOST` (default `127.0.0.1`)
  - If `X-Cmux-Workspace-Internal` is present on a request, it overrides this host per-request using the mapping below.

## Test in Docker (Linux)

- Build and run tests inside Linux: `docker build -t cmux-proxy-test .`
- Or use helper: `./scripts/run-tests-in-docker.sh`

End-to-end (E2E) bash tests that validate workspace isolation and proxy routing from host:

- `./scripts/e2e.sh`
  - Builds the runtime image, starts a container exposing `:8080`.
  - Inside the container, starts HTTP servers bound in `/root/workspace-a` and `/root/workspace-b` on the same port via LD_PRELOAD isolation.
  - Verifies isolation inside the container (A works in A, fails in B).
  - From the host, curls the proxy using both header-based routing and subdomain Host routing.
  - Requires Docker and curl on the host.
  - Stress mode: launches many servers across distinct workspaces and verifies isolation in parallel.
    - Tunables: `STRESS_N` (default 32), `STRESS_PORT` (default 3200), `STRESS_CONC` (default 16).

This runs `cargo test` in a Debian-based Rust image and pre-adds example loopback IPs in `127.18.0.0/8`.

## Usage

- HTTP
  - `curl -v -H 'X-Cmux-Port-Internal: 3000' http://127.0.0.1:8080/api`
  - Proxies to `http://127.0.0.1:3000/api`.

  - With workspace: `curl -v -H 'X-Cmux-Workspace-Internal: workspace-1' -H 'X-Cmux-Port-Internal: 3000' http://127.0.0.1:8080/api`
  - Proxies to `http://127.18.0.1:3000/api` (see mapping below).

- WebSocket (client must send the header)
  - Example with websocat: `websocat -H 'X-Cmux-Port-Internal: 3001' ws://127.0.0.1:8080/ws`
  - Proxies to `ws://127.0.0.1:3001/ws` (upgrade tunneled).
  - With workspace: `websocat -H 'X-Cmux-Workspace-Internal: workspace-2' -H 'X-Cmux-Port-Internal: 3001' ws://127.0.0.1:8080/ws`
  - Proxies to `ws://127.18.0.2:3001/ws`.

- TCP via CONNECT (create a raw TCP tunnel)
  - The proxy will ignore the CONNECT target host/port and use the header port.
  - Example (Redis tunnel): `curl --http1.1 -x http://127.0.0.1:8080 -H 'X-Cmux-Port-Internal: 6379' -v https://example` (establishes CONNECT then tunnels). A better test is to script a `CONNECT` request with `nc`.

## Notes

- The header `X-Cmux-Port-Internal` is required on every request; value must be a valid TCP port (1-65535).
- Optional header `X-Cmux-Workspace-Internal` selects a per-workspace loopback IP. If omitted, `--upstream-host` is used.
- Workspace to IP mapping: for a workspace name `workspace-N` where `N` is a positive integer, the upstream host is `127.18.(N>>8).(N&255)`.
  - Examples: `workspace-1 -> 127.18.0.1`, `workspace-256 -> 127.18.1.0`.
  - If the name does not end in digits, a stable hash may be used in the future; currently non-numeric names return 400.
- This enables running identical services on the same ports in different workspaces, each bound to a unique loopback IP.
- Only HTTP/1.1 is supported on the front-end. HTTP/2 is not supported (WebSocket over H2 is not handled).
- Hop-by-hop headers are stripped where appropriate; upgrade is handled specially to preserve handshake headers.
- Upstream host defaults to `127.0.0.1`. If you need another host, pass `--upstream-host`. The header only specifies the port.

## Caveats

- This proxy does not terminate TLS; inbound must be plain HTTP/WS. If you need TLS, put a TLS terminator in front.
- For CONNECT, the client and upstream protocols are opaque to the proxy. The proxy just tunnels bytes.
- Per-workspace IPs live in `127/8` which is loopback on Linux. Binding to `127.18.x.y` typically works without adding the address, but you can also add it explicitly: `ip addr add 127.18.0.1/8 dev lo`.

## Linux LD_PRELOAD shim (optional)

If you want processes started inside a workspace directory (e.g., `/root/workspace-1`) to automatically bind/connect to their per-workspace IP without changing the app code, you can use the provided LD_PRELOAD shim in `ldpreload/`:

- It intercepts `bind(2)` and `connect(2)` and rewrites `0.0.0.0`/`127.0.0.1` to the workspace IP computed from the directory name.
- Detection: if CWD is under `/root/workspace-N`, the workspace name is `workspace-N`.
- Usage (Linux):
  - Build: `make -C ldpreload`
  - Run a command in a workspace: `cd /root/workspace-1 && LD_PRELOAD=./ldpreload/libworkspace_net.so your-app`
  - Optional overrides: set `CMUX_WORKSPACE_INTERNAL=workspace-2` to force a workspace, or `CMUX_PRELOAD_DISABLE=1` to disable.

Note: creating Linux network namespaces requires root/capabilities; this shim focuses on per-IP isolation on loopback.

## License

MIT
