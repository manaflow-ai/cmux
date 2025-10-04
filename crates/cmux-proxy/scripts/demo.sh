#!/usr/bin/env bash
set -euo pipefail

IMAGE_RUNTIME="cmux-proxy:runtime"

echo "Building minimal runtime image ($IMAGE_RUNTIME)..."
docker build --target runtime -t "$IMAGE_RUNTIME" .

echo "\nLaunching interactive demo container... (proxy runs in background)\n"

docker run --rm -it -p 39379:39379 --name cmux-proxy-demo \
  --entrypoint /bin/bash "$IMAGE_RUNTIME" -lc '
cat <<"DOC"
cmux-proxy demo (LD_PRELOAD enabled globally)

What this container has:
- Proxy listening on 0.0.0.0:39379 (starts in background)
- LD_PRELOAD shim loaded by default (see $LD_PRELOAD)
- Python3 available for quick HTTP servers

Goal: Per-workspace network isolation by IP (127.18.x.y) with same ports.

Try this in separate shells (inside this container):

1) Start a server in workspace-a (binds to workspace-a IP via LD_PRELOAD):
   mkdir -p /root/workspace-a && cd /root/workspace-a
   python3 -m http.server 3000

2) Curl it via the proxy (from another shell):
   curl -v \
     -H "X-Cmux-Workspace-Internal: workspace-a" \
     -H "X-Cmux-Port-Internal: 3000" \
     http://127.0.0.1:39379/

3) Start another server in workspace-b on the same port:
   mkdir -p /root/workspace-b && cd /root/workspace-b
   python3 -m http.server 3000

4) Curl workspace-b (same port, isolated by workspace IP):
   curl -v \
     -H "X-Cmux-Workspace-Internal: workspace-b" \
     -H "X-Cmux-Port-Internal: 3000" \
     http://127.0.0.1:39379/

4b) Or, use subdomains (no custom headers):
   # If *.localhost does not resolve here, use a Host header
   curl -v \
     -H "Host: workspace-a-3000.localhost" \
     http://127.0.0.1:39379/
   curl -v \
     -H "Host: workspace-b-3000.localhost" \
     http://127.0.0.1:39379/

5) Sanity: workspace-a curl should NOT return workspace-b content and vice versa.

Tips:
- Proxy logs: tail -f /tmp/proxy.log
- LD_PRELOAD in effect: echo $LD_PRELOAD
- To force a workspace without changing directories: export CMUX_WORKSPACE_INTERNAL=workspace-a
- From your host, browsers often resolve *.localhost to 127.0.0.1, so this works: http://workspace-a-3000.localhost:39379/

You are now in an interactive shell. Have fun!\n
DOC

echo "Starting cmux-proxy in background..."
/usr/local/bin/cmux-proxy --listen 0.0.0.0:39379 >/tmp/proxy.log 2>&1 &
echo "Proxy PID: $!  | Logs: tail -f /tmp/proxy.log"
exec bash
'
