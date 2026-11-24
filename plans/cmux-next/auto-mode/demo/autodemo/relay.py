"""A model route for a machine that has none: its agent's calls go out through another machine.

The Cloud machine in this demo cannot reach the models by itself, and no credential is put on
it. Its agent talks to `http://127.0.0.1:<port>` there; each connection is carried back over a
connection that the machine with the route (`auto relay out`) opened to it, and that side puts
its own credential on the request. Only TCP connections *to* the Cloud machine are needed.

  Cloud machine:   auto relay in  --port 7790 --tunnel-port 7791 --token T
  laptop / Mac:    auto relay out HOST:PORT --token T        (uses this shell's ANTHROPIC_* route)

This is a stand-in for the product's own model route for Cloud machines. It means the Cloud
machine can think only while the other side of the relay is up.
"""

import os
import select
import socket
import threading
import time


def pipe(a, b):
    """Bytes both ways until either side closes."""
    socks = [a, b]
    try:
        while True:
            ready, _, _ = select.select(socks, [], [], 300)
            if not ready:
                return
            for s in ready:
                data = s.recv(65536)
                if not data:
                    return
                (b if s is a else a).sendall(data)
    except OSError:
        return
    finally:
        for s in socks:
            try:
                s.close()
            except OSError:
                pass


def read_line(sock, limit=4096):
    data = b""
    while not data.endswith(b"\n") and len(data) < limit:
        chunk = sock.recv(1)
        if not chunk:
            break
        data += chunk
    return data.strip()


def read_head(sock, limit=262144):
    """An HTTP request's head, and whatever of the body came with it."""
    data = b""
    while b"\r\n\r\n" not in data and len(data) < limit:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    head, sep, rest = data.partition(b"\r\n\r\n")
    return head, rest, bool(sep)


# ---- the side with no route ----

def serve_in(port, tunnel_port, token, tunnel_host="0.0.0.0", log=print):
    idle = []
    cv = threading.Condition()

    def accept_tunnels():
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind((tunnel_host, tunnel_port))
        srv.listen(64)
        while True:
            conn, _ = srv.accept()
            threading.Thread(target=greet, args=(conn,), daemon=True).start()

    def greet(conn):
        try:
            conn.settimeout(10)
            if read_line(conn) != b"AUTO-RELAY " + token.encode():
                conn.close()
                return
            conn.settimeout(None)
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        except OSError:
            return
        with cv:
            idle.append((conn, time.monotonic()))
            cv.notify()

    def take():
        end = time.monotonic() + 30
        with cv:
            while True:
                while idle:
                    # The newest one. The other side replaces each after a minute, so one older
                    # than 50 s is not used; one a broken link left behind shows as readable.
                    conn, at = idle.pop()
                    ready, _, _ = select.select([conn], [], [], 0)
                    if ready or time.monotonic() - at > 50:
                        try:
                            conn.close()
                        except OSError:
                            pass
                        continue
                    return conn
                left = end - time.monotonic()
                if left <= 0:
                    return None
                cv.wait(left)

    def serve(client):
        tunnel = take()
        if tunnel is None:
            try:
                client.sendall(b"HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
                client.close()
            except OSError:
                pass
            log("%s no relay connected: a call was refused" % time.strftime("%H:%M:%S"))
            return
        try:
            tunnel.sendall(b"GO\n")
        except OSError:
            client.close()
            return
        pipe(client, tunnel)

    threading.Thread(target=accept_tunnels, daemon=True).start()
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(64)
    log("relay: agents call http://127.0.0.1:%d; the other side connects to port %d" % (port, tunnel_port))
    while True:
        client, _ = srv.accept()
        threading.Thread(target=serve, args=(client,), daemon=True).start()


# ---- the side with the route ----

def route_from_env():
    base = os.environ.get("ANTHROPIC_BASE_URL") or "https://api.anthropic.com"
    headers = []
    if os.environ.get("ANTHROPIC_AUTH_TOKEN"):
        headers.append("authorization: Bearer " + os.environ["ANTHROPIC_AUTH_TOKEN"])
    elif os.environ.get("ANTHROPIC_API_KEY"):
        headers.append("x-api-key: " + os.environ["ANTHROPIC_API_KEY"])
    for line in (os.environ.get("ANTHROPIC_CUSTOM_HEADERS") or "").splitlines():
        if ":" in line:
            headers.append(line.strip())
    return base, headers


def connect_upstream(base):
    from urllib.parse import urlparse
    url = urlparse(base)
    port = url.port or (443 if url.scheme == "https" else 80)
    sock = socket.create_connection((url.hostname, port), timeout=30)
    if url.scheme == "https":
        import ssl
        sock = ssl.create_default_context().wrap_socket(sock, server_hostname=url.hostname)
    sock.settimeout(None)
    host = url.hostname if url.port is None else "%s:%d" % (url.hostname, url.port)
    return sock, host, url.path.rstrip("/")


def serve_out(target, token, pool=6, log=print):
    host, _, port = target.rpartition(":")
    base, own = route_from_env()
    drop = ("authorization", "x-api-key", "host", "connection", "proxy-connection")
    state = {"calls": 0, "up": False}

    def one():
        while True:
            try:
                tunnel = socket.create_connection((host or "127.0.0.1", int(port)), timeout=10)
                tunnel.sendall(b"AUTO-RELAY " + token.encode() + b"\n")
                tunnel.settimeout(60)
                if not state["up"]:
                    state["up"] = True
                    log("%s relay: connected to %s" % (time.strftime("%H:%M:%S"), target))
                try:
                    word = read_line(tunnel)
                except socket.timeout:
                    # Not used for a minute: a new one takes its place.
                    tunnel.close()
                    continue
                if word != b"GO":
                    tunnel.close()
                    raise OSError("the other side closed")
                tunnel.settimeout(None)
            except (OSError, ValueError) as error:
                if state["up"]:
                    state["up"] = False
                    log("%s relay: no link to %s (%s); trying again" % (time.strftime("%H:%M:%S"), target, error))
                time.sleep(2)
                continue
            # A call: put this side's credential on it and send it on. One call per connection.
            threading.Thread(target=one, daemon=True).start()
            try:
                head, rest, whole = read_head(tunnel)
                if not whole:
                    tunnel.close()
                    return
                lines = head.split(b"\r\n")
                method, path, _version = lines[0].decode("latin-1").split(" ", 2)
                upstream, up_host, prefix = connect_upstream(base)
                kept = [l for l in lines[1:] if l.split(b":", 1)[0].strip().lower().decode("latin-1") not in drop]
                out = ["%s %s%s HTTP/1.1" % (method, prefix, path), "host: " + up_host, "connection: close"] + own
                upstream.sendall("\r\n".join(out).encode("latin-1") + b"\r\n" + b"\r\n".join(kept) + b"\r\n\r\n" + rest)
                state["calls"] += 1
                if os.environ.get("AUTO_DEBUG"):
                    log("%s relay: %s %s" % (time.strftime("%H:%M:%S"), method, path.split("?")[0]))
                pipe(tunnel, upstream)
            except (OSError, ValueError) as error:
                log("%s relay: a call failed: %s" % (time.strftime("%H:%M:%S"), error))
                try:
                    tunnel.close()
                except OSError:
                    pass
            return

    for _ in range(pool):
        threading.Thread(target=one, daemon=True).start()
    log("relay: calls from %s go to %s with this shell's credential" % (target, base.split("//")[-1].split("/")[0]))
    while True:
        time.sleep(3600)
