#!/usr/bin/env python3
"""The VM side of scripts/cmux-next/cloud-dev-stack.sh: one `wrangler dev` (workerd, local Durable
Objects) per tag on the dev-backend host, running the tag's three Workers (the cmux API, the mobile
Worker and the device hub) behind a generated front Worker, published on three tailnet-only HTTPS ports.

The Mac side copies this file to <base>/bin/vm_stack.py and runs it over SSH; it never runs on a Mac.
Standard library only (the host has python3, and node/bun live in <base>/tools).

Layout under <base> (default /srv/cmux-dev/wrangler, beside hq's classic Docker stacks in /srv/cmux-dev):
  registry/<tag>.json   the per-tag registry entry (port, url, state, database credentials' ids, never values)
  stacks/<tag>/         src/ (the agent's backend tree), platform/ (optional), front/ (the generated front
                        Worker), state/ (wrangler --persist-to), secrets/ (0700: jwt.jwk, hub.vars, pg.url,
                        mysql.url), logs/wrangler.log, run.sh
  secrets/              the host's team credentials (0700): tunnel.token (public origins) and turn.json (the
                        team's Cloudflare TURN key, put by an up from 1Password: every stack's mobile Worker)
  tools/                node and bun, one pinned version each
  routes.json           every routed stack's authorities (host:port) to its tag and wrangler port, for the router
Units: cmux-wdev@<tag>.service runs stacks/<tag>/run.sh; cmux-wdev-reaper.timer runs `reap` every 5 minutes;
cmux-wdev-router.service runs bin/router.mjs on 127.0.0.1:3790, where Tailscale Serve sends every stack port.

Lifetime: a stack lives as long as a dogfooded build may use it, bounded by the VM. An idle running stack is
stopped (its unit only: its files, data, credentials and ports stay) and wakes on its next request, which the
router holds until the stack answers. A stack is released (files deleted, credentials and branch freed by the
next gc) RETAIN_SECS after its last up, or earlier when the VM runs short: a start or wake that does not fit
stops the least recently used running stacks first (memory, MAX_STACKS), and releases the least recently used
stopped ones when free disk is short or more than MAX_KEPT are kept.

One stack, three origins: the API at https://<vm>:P, the mobile Worker (cmux-next-ios/backend) at P+1 and
the device hub (workers/device-hub) at P+2, three consecutive ports of one stack. Tailscale Serve sends all
three to wrangler's one local port P, where the front Worker (FRONT_JS) picks the Worker by the request's
port and answers the API's /v1/client-config with the stack's own mobile and hub origins, so one API origin
(the Mac's backend.json, the phone's CMUX_NEXT_CLOUD_BACKEND) drives all three with no rebuild.

Coexistence with hq's classic stacks (skills/infra/dev-backend): this never writes /srv/cmux-dev/registry
or touches a container. A port is taken from the same tailnet-reachable range (3800-4799) only when the
classic registry, every Tailscale Serve listener and every listening socket leave it free, searching from
the top of the range down (the classic daemon hashes uniformly and skips listening ports). Serve changes
hold the classic daemon's own tailscale-serve.lock. A start is refused when MemAvailable or free disk would
fall near the classic daemon's floors (16 GiB memory, 100 GiB disk GC trigger).
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import secrets
import shutil
import signal
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

BASE = Path(os.environ.get("CMUX_WDEV_BASE", "/srv/cmux-dev/wrangler"))
CLASSIC_BASE = Path(os.environ.get("CMUX_WDEV_CLASSIC_BASE", "/srv/cmux-dev"))
PORT_MIN, PORT_MAX = (int(p) for p in os.environ.get("CMUX_WDEV_PORTS", "3800-4799").split("-"))
# Pinned toolchain, checked against the publishers' SHASUMS256.txt before it is unpacked.
NODE_VERSION = "v24.22.3"
NODE_SHA256 = "4f2b175a6d53a5c617a80dba2676238a0688cef28c6da4eba35c7d844e66fcfb"  # node-v24.22.3-linux-x64.tar.xz
BUN_VERSION = "1.4.4"
BUN_SHA256 = "bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c"  # bun-v1.4.4/bun-linux-x64.zip
# The Cloudflare Tunnel's connector (public origins), run only when <base>/secrets/tunnel.token exists.
CLOUDFLARED_VERSION = "2026.11.1"
CLOUDFLARED_SHA256 = "97bb3b02d23a5980fc9c15a1a270e692da1923f103f920d5b16d4931d5ab55e7"  # cloudflared-linux-amd64
# Memory and disk a stack that is preparing or starting will take once it runs (measured 1.5-1.9 GiB for the
# API alone; the mobile Worker and the device hub share its workerd).
PENDING_MEM_GIB = 3.0
PENDING_DISK_GIB = 2.0
# Idle: no request reached the stack (the router's heartbeat, wrangler's request log lines) and no `up`/`touch`
# for this long: its unit stops, and the next request wakes it.
IDLE_SECS_DEFAULT = int(os.environ.get("CMUX_WDEV_IDLE_SECS", str(2 * 3600)))
# Retention from the last `up`: then the stack is released. The database credentials' TTL (the Mac's
# CRED_TTL) outlives it, so a stack never runs on an expired credential.
RETAIN_SECS = int(os.environ.get("CMUX_WDEV_RETAIN_SECS", str(7 * 86400)))
# Running (or starting) at once; more stopped ones are kept, up to MAX_KEPT.
MAX_STACKS = int(os.environ.get("CMUX_WDEV_MAX_STACKS", "16"))
MAX_KEPT = int(os.environ.get("CMUX_WDEV_MAX_KEPT", "48"))
# A wake that failed is not retried for this long: every request in between is answered at once.
WAKE_RETRY_SECS = 60
# A wake still starting this long after its own wait ran out is dead (its process was killed): the next request
# starts it again. A wake records its deadline (wake_deadline); entries from before that use WAKE_STALE_SECS.
WAKE_GRACE_SECS = 120  # beyond the router's kill (its wait + 90 s), whose SIGTERM settles the wake first
WAKE_STALE_SECS = 240
ROUTER_PORT = int(os.environ.get("CMUX_WDEV_ROUTER_PORT", "3790"))
# wrangler's own port on 127.0.0.1, one per stack: outside the tailnet range, which the classic daemon allocates
# from without reading Serve, so a stopped stack's tailnet ports can never collide with a classic stack's local one.
LOCAL_MIN, LOCAL_MAX = (int(p) for p in os.environ.get("CMUX_WDEV_LOCAL_PORTS", "23800-24799").split("-"))
# Public origins (cloud-dev-stack/gateway): <svc>.<slot>.<domain>, from the slots public.json lists (written by the
# Mac's `cloud-dev-stack.sh public-setup`, which made their custom domains). No file: tailnet only.
PUBLIC_DOMAIN = "wdev.cmux.dev"
SLOT_RE = re.compile(r"^s[0-9]{1,3}$")
ROUTER_TARGET = f"http://127.0.0.1:{ROUTER_PORT}"
MIN_MEM_GIB = float(os.environ.get("CMUX_WDEV_MIN_MEM_GIB", "24"))
MIN_DISK_GIB = float(os.environ.get("CMUX_WDEV_MIN_DISK_GIB", "120"))
REAPED_KEEP_SECS = 7 * 86400
# A gc's claim on a stopped stack (state releasing) lapses after this, so a gc that died mid-way
# is retried by the next one and does not block the tag's next up for long.
RELEASE_CLAIM_SECS = 600
UP_LOCK_SECS = 1800
LOG_MAX_BYTES = 64 * 1024 * 1024
TAG_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
REQUEST_LINE = re.compile(rb"\[wrangler:info\] (GET|POST|PUT|PATCH|DELETE|HEAD|OPTIONS) \S+ \d{3}")
UNIT_PREFIX = "cmux-wdev"
# A stack's Workers, in port order: the API at its base port P, the mobile Worker at P+1, the device hub at P+2.
SERVICES = ("api", "mobile", "hub")
DEVELOPMENT_API = "https://cmux-api-development.debussy.workers.dev"


class Refused(Exception):
    pass


# ---------------------------------------------------------------- paths and registry

def stack_dir(tag: str) -> Path:
    return BASE / "stacks" / tag


def entry_path(tag: str) -> Path:
    return BASE / "registry" / f"{tag}.json"


def ledger_path() -> Path:
    return BASE / "branches.json"


def ledger() -> dict[str, int]:
    """PlanetScale branches ("db/branch") this host's stacks made, with when it first saw each. The Mac's
    orphan sweep deletes only these, so a branch another --host keeps alive is never touched."""
    try:
        return json.loads(ledger_path().read_text())
    except (OSError, ValueError):
        return {}


def ledger_add(key: str) -> None:
    data = ledger()
    data.setdefault(key, int(time.time()))
    tmp = ledger_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True))
    os.replace(tmp, ledger_path())


def ledger_drop(keys: list[str]) -> None:
    data = ledger()
    for k in keys:
        data.pop(k, None)
    tmp = ledger_path().with_suffix(".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True))
    os.replace(tmp, ledger_path())


def check_tag(tag: str) -> str:
    if not TAG_RE.match(tag):
        raise Refused("tag: lowercase letters, digits and -, at most 40")
    return tag


def read_entry(tag: str) -> dict[str, Any] | None:
    try:
        return json.loads(entry_path(tag).read_text())
    except FileNotFoundError:
        return None


def write_entry(entry: dict[str, Any]) -> None:
    path = entry_path(entry["tag"])
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(entry, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, path)
    write_routes()


def forget_entry(tag: str) -> None:
    entry_path(tag).unlink(missing_ok=True)
    write_routes()


# States whose ports the router serves: a stopped stack wakes on a request, a starting one is waited for.
ROUTED = ("running", "stopped", "starting", "preparing")


def routes_table(entries: list[dict[str, Any]]) -> dict[str, dict[str, Any]]:
    """The router's table: each authority (host:port) a routed stack answers on, to its tag and wrangler port."""
    table = {}
    for e in entries:
        if e.get("state") in ROUTED and e.get("host") and e.get("port"):
            for p in entry_ports(e):
                table[f"{e['host']}:{p}".lower()] = {"tag": e["tag"], "port": local_port(e)}
            if e.get("slot"):
                for svc in SERVICES:
                    table[f"{svc}.{e['slot']}.{e.get('domain') or PUBLIC_DOMAIN}"] = {"tag": e["tag"], "port": local_port(e), "public": True}
    return table


def public_slots() -> tuple[str, list[str]]:
    """The public domain and its provisioned slots (public.json), or (PUBLIC_DOMAIN, []) when there are none."""
    try:
        data = json.loads((BASE / "public.json").read_text())
    except (OSError, ValueError):
        return PUBLIC_DOMAIN, []
    return data.get("domain") or PUBLIC_DOMAIN, [x for x in data.get("slots") or [] if SLOT_RE.match(str(x))]


def assign_slot(tag: str, entry: dict[str, Any]) -> str | None:
    """Under the registry lock: the stack's public slot, kept across ups, stops and wakes; else the first one no
    other stack that is not released holds. None: no free slot (tailnet only)."""
    domain, slots = public_slots()
    held = {e.get("slot") for e in all_entries() if e["tag"] != tag and e.get("state") in HOLDS_PORT}
    if entry.get("slot") in slots and entry.get("slot") not in held:
        return entry["slot"]
    return next((x for x in slots if x not in held), None)


def write_routes() -> None:
    path = BASE / "routes.json"
    tmp = path.with_suffix(f".tmp.{os.getpid()}")
    tmp.write_text(json.dumps(routes_table(all_entries()), indent=1, sort_keys=True))
    os.replace(tmp, path)


def all_entries() -> list[dict[str, Any]]:
    out = []
    for p in sorted((BASE / "registry").glob("*.json")):
        try:
            out.append(json.loads(p.read_text()))
        except (OSError, ValueError):
            continue
    return out


class Lock:
    def __init__(self, path: Path):
        self.path = path

    def __enter__(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.fh = open(self.path, "a+")
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        fcntl.flock(self.fh, fcntl.LOCK_UN)
        self.fh.close()


def registry_lock() -> Lock:
    return Lock(BASE / "registry.lock")


def serve_lock() -> Lock:
    # The classic daemon's own lock (devbackendd.py SERVE_LOCK_PATH): one Serve writer at a time.
    return Lock(CLASSIC_BASE / "tailscale-serve.lock")


# ---------------------------------------------------------------- host facts

def mem_available_gib() -> float:
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) / 1024 / 1024
    return 0.0


def disk_free_gib(path: Path = BASE) -> float:
    return shutil.disk_usage(path if path.exists() else "/").free / 1024**3


def tailscale_json(*args: str) -> dict[str, Any]:
    out = subprocess.run(["tailscale", *args, "--json"], capture_output=True, text=True, timeout=30)
    if out.returncode != 0:
        raise Refused(f"tailscale {' '.join(args)} failed: {out.stderr.strip()[-300:]}")
    return json.loads(out.stdout or "{}")


def dns_name() -> str:
    return tailscale_json("status")["Self"]["DNSName"].rstrip(".")


def serve_config() -> dict[str, Any]:
    return tailscale_json("serve", "status")


def serve_target(cfg: dict[str, Any], port: int) -> str | None:
    """The proxy target of the HTTPS listener on this port, or None."""
    for host, web in (cfg.get("Web") or {}).items():
        if host.endswith(f":{port}"):
            return ((web.get("Handlers") or {}).get("/") or {}).get("Proxy")
    return None


def listening_ports() -> set[int]:
    out = subprocess.run(["ss", "-Htln"], capture_output=True, text=True, timeout=10).stdout
    ports = set()
    for line in out.splitlines():
        parts = line.split()
        if len(parts) >= 4:
            m = re.search(r":(\d+)$", parts[3])
            if m:
                ports.add(int(m.group(1)))
    return ports


def classic_ports() -> set[int]:
    ports = set()
    for p in (CLASSIC_BASE / "registry").glob("*.json"):
        try:
            ports.add(int(p.stem))
        except ValueError:
            pass
    return ports


def stack_ports(base: int) -> list[int]:
    """The ports of one stack: its API at base, then one per other Worker (SERVICES)."""
    return [base + i for i in range(len(SERVICES))]


def pick_port(tag: str, previous: int | None, taken_by_us: set[int], classic: set[int], serve: dict[str, Any], listening: set[int]) -> int:
    """The stack's base port: its previous one when all its ports are still ours, else the highest base whose
    ports are all free on every account. Every port of a stack Serve-proxies to wrangler on the base port."""
    own = (None, ROUTER_TARGET, f"http://127.0.0.1:{previous}")  # the router, or wrangler before the router
    if previous and all(p not in classic and p not in taken_by_us and serve_target(serve, p) in own and PORT_MIN <= p <= PORT_MAX
                        for p in stack_ports(previous)):
        return previous
    serve_ports = {int(k) for k in (serve.get("TCP") or {}).keys() if str(k).isdigit()}
    for base in range(PORT_MAX - len(SERVICES) + 1, PORT_MIN - 1, -1):
        if any(p in classic or p in serve_ports or p in listening or p in taken_by_us for p in stack_ports(base)):
            continue
        return base
    raise Refused(f"no {len(SERVICES)} consecutive free ports in {PORT_MIN}-{PORT_MAX}")


HOLDS_PORT = ("preparing", "starting", "running", "stopped", "failed")


def local_port(entry: dict[str, Any]) -> int | None:
    """The port the stack's wrangler listens on (127.0.0.1): its own local port, or for an entry from before
    local ports, its base tailnet port."""
    return entry.get("local_port") or entry.get("port")


def pick_local_port(tag: str, previous: int | None, listening: set[int]) -> int:
    """Under the registry lock: the stack's local port, kept while no one else listens on it."""
    taken = {e.get("local_port") for e in all_entries() if e["tag"] != tag and e.get("state") in HOLDS_PORT}
    if previous and LOCAL_MIN <= previous <= LOCAL_MAX and previous not in taken and previous not in listening:
        return previous
    for port in range(LOCAL_MIN, LOCAL_MAX + 1):
        if port not in taken and port not in listening:
            return port
    raise Refused(f"no free local port in {LOCAL_MIN}-{LOCAL_MAX}")


def entry_ports(entry: dict[str, Any]) -> list[int]:
    """The ports an entry holds: all of its stack's, or the one port of an entry from before the mobile
    Worker and the hub joined the stack."""
    return list(entry.get("ports") or ([entry["port"]] if entry.get("port") else []))


def ports_held(except_tag: str) -> set[int]:
    """Ports of our other stacks that are not gone: a starting stack is not listening yet, a failed one
    keeps its ports for its next up."""
    return {p for e in all_entries() if e["tag"] != except_tag and e.get("state") in HOLDS_PORT for p in entry_ports(e)}


def unit(tag: str) -> str:
    return f"{UNIT_PREFIX}@{tag}.service"


def systemctl(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["sudo", "-n", "systemctl", *args], capture_output=True, text=True, timeout=120, check=check)


def unit_active(tag: str) -> bool:
    return systemctl("is-active", "--quiet", unit(tag), check=False).returncode == 0


def unit_memory_mib(tag: str) -> int | None:
    out = systemctl("show", unit(tag), "-p", "MemoryCurrent", "--value", check=False).stdout.strip()
    return int(out) // (1024 * 1024) if out.isdigit() else None


# ---------------------------------------------------------------- one-time host setup

UNIT_TEMPLATE = """[Unit]
Description=cmux-next wrangler dev stack %i (scripts/cmux-next/cloud-dev-stack.sh)
After=network-online.target tailscaled.service

[Service]
Type=simple
User={user}
Group={user}
WorkingDirectory={base}/stacks/%i
# run.sh sends its own output to logs/wrangler.log as {user}: a systemd append: target would be opened,
# and created, by root, and the reaper could then not truncate it.
ExecStart=/bin/bash {base}/stacks/%i/run.sh
Environment=HOME={base}/stacks/%i/home
Restart=no
# Sandbox: the stack writes only its own directory; no sudo, no setuid, its own /tmp.
ProtectSystem=strict
ReadWritePaths={base}/stacks/%i
PrivateTmp=yes
NoNewPrivileges=yes
RestrictSUIDSGID=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
MemoryMax=6G
MemorySwapMax=0
CPUQuota=400%
TasksMax=4096
KillMode=control-group
TimeoutStopSec=20
Nice=5
"""

ROUTER_SERVICE = """[Unit]
Description=cmux-next wrangler dev stacks: the router (every stack port; wakes a stopped stack)
After=network-online.target tailscaled.service

[Service]
Type=simple
User={user}
Group={user}
Environment=CMUX_WDEV_BASE={base}
ExecStart={node} {base}/bin/router.mjs
Restart=always
RestartSec=2
# A wake runs `vm_stack.py wake`, which starts the stack's unit with sudo: no NoNewPrivileges here.
PrivateTmp=yes
MemoryMax=1G

[Install]
WantedBy=multi-user.target
"""

TUNNEL_SERVICE = """[Unit]
Description=cmux-next wrangler dev stacks: Cloudflare Tunnel cmux-wdev (public origins; scripts/cmux-next/cloud-dev-stack)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User={user}
Group={user}
ExecStart={base}/tools/cloudflared-{version}/cloudflared tunnel --no-autoupdate run --token-file {base}/secrets/tunnel.token
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ReadOnlyPaths={base}
PrivateTmp=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
MemoryMax=1G

[Install]
WantedBy=multi-user.target
"""

REAPER_SERVICE = """[Unit]
Description=cmux-next wrangler dev stacks: stop idle or expired stacks

[Service]
Type=oneshot
User={user}
ExecStart=/usr/bin/python3 {base}/bin/vm_stack.py reap
# A pass never hangs: it is killed after this, and the next timer tick starts a new one.
TimeoutStartSec=10min
"""

REAPER_TIMER = """[Unit]
Description=cmux-next wrangler dev stacks reaper

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
"""


def install_host() -> dict[str, Any]:
    """Idempotent: tools, unit files, reaper timer. Changes nothing of the classic stacks."""
    user = os.environ.get("USER") or "ubuntu"
    for d in ("bin", "registry", "stacks", "tools", "cache"):
        (BASE / d).mkdir(mode=0o700, parents=True, exist_ok=True)
    files = {
        f"/etc/systemd/system/{UNIT_PREFIX}@.service": UNIT_TEMPLATE.format(user=user, base=BASE),
        f"/etc/systemd/system/{UNIT_PREFIX}-router.service": ROUTER_SERVICE.format(
            user=user, base=BASE, node=BASE / "tools" / f"node-{NODE_VERSION}" / "bin/node"),
        f"/etc/systemd/system/{UNIT_PREFIX}-reaper.service": REAPER_SERVICE.format(user=user, base=BASE),
        f"/etc/systemd/system/{UNIT_PREFIX}-reaper.timer": REAPER_TIMER,
    }
    tunnel = (BASE / "secrets/tunnel.token").exists()
    if tunnel:
        ensure_cloudflared()
        files[f"/etc/systemd/system/{UNIT_PREFIX}-tunnel.service"] = TUNNEL_SERVICE.format(user=user, base=BASE, version=CLOUDFLARED_VERSION)
    changed = []
    for path, body in files.items():
        try:
            same = Path(path).read_text() == body
        except OSError:
            same = False
        if not same:
            subprocess.run(["sudo", "-n", "tee", path], input=body, text=True, capture_output=True, check=True)
            changed.append(path)
    if changed:
        systemctl("daemon-reload")
    if systemctl("is-enabled", "--quiet", f"{UNIT_PREFIX}-reaper.timer", check=False).returncode != 0 or changed:
        systemctl("enable", "--now", f"{UNIT_PREFIX}-reaper.timer")
    tools = ensure_tools()
    with registry_lock():
        write_routes()
        changed += serve_sweep()
    if tunnel and (any("tunnel" in c for c in changed)
                   or systemctl("is-active", "--quiet", f"{UNIT_PREFIX}-tunnel.service", check=False).returncode != 0):
        systemctl("enable", f"{UNIT_PREFIX}-tunnel.service")
        systemctl("restart", f"{UNIT_PREFIX}-tunnel.service")
        changed.append("tunnel restarted")
    # The router: (re)started when its unit or its code changed since it last started.
    router = BASE / "bin/router.mjs"
    stamp = BASE / "bin/.router.sha256"
    want = sha256_file(router) if router.exists() else ""
    have = stamp.read_text().strip() if stamp.exists() else ""
    if router.exists() and (want != have or any("router" in c for c in changed)
                            or systemctl("is-active", "--quiet", f"{UNIT_PREFIX}-router.service", check=False).returncode != 0):
        systemctl("enable", f"{UNIT_PREFIX}-router.service")
        systemctl("restart", f"{UNIT_PREFIX}-router.service")
        stamp.write_text(want)
        changed.append("router restarted")
    return {"units_changed": changed, **tools}


def serve_sweep() -> list[str]:
    """Under the registry lock: move a routed stack's ports that still go straight to its wrangler (a stack from
    before the router) to the router, and turn off router listeners in our range that no stack claims (an older
    helper's leftovers). A classic stack's listener (127.0.0.1:8478) is never touched."""
    claimed = {}
    for e in all_entries():
        if e.get("state") in ROUTED:
            for p in entry_ports(e):
                claimed[p] = e
    done = []
    with serve_lock():
        cfg = serve_config()
        for host_port, web in (cfg.get("Web") or {}).items():
            try:
                p = int(host_port.rsplit(":", 1)[1])
            except (IndexError, ValueError):
                continue
            target = ((web.get("Handlers") or {}).get("/") or {}).get("Proxy")
            if not (PORT_MIN <= p <= PORT_MAX) or p in classic_ports():
                continue
            e = claimed.get(p)
            if e and target == f"http://127.0.0.1:{e.get('port')}" and not e.get("local_port"):
                continue  # a running stack from before the router: its wrangler is on this port; left as it is
            if e and target == f"http://127.0.0.1:{local_port(e)}" and e.get("local_port"):
                subprocess.run(["sudo", "-n", "tailscale", "serve", "--bg", "--yes", f"--https={p}", ROUTER_TARGET], capture_output=True, text=True, timeout=60)
                done.append(f"serve :{p} -> router")
            elif not e and target == ROUTER_TARGET:
                subprocess.run(["sudo", "-n", "tailscale", "serve", f"--https={p}", "off"], capture_output=True, text=True, timeout=60)
                done.append(f"serve :{p} off (no stack)")
    return done


def sha256_file(path: Path) -> str:
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch_verified(url: str, sha256: str, dest: Path) -> None:
    """Download to dest and refuse it unless its SHA-256 is the pinned one."""
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(dest), url], check=True, timeout=600)
    got = sha256_file(dest)
    if got != sha256:
        dest.unlink(missing_ok=True)
        raise Refused(f"{url}: sha256 {got} is not the pinned {sha256}")


def ensure_tools() -> dict[str, str]:
    tools = BASE / "tools"
    node = tools / f"node-{NODE_VERSION}"
    if not (node / "bin/node").exists():
        tmp = tools / f".node-{NODE_VERSION}.tar.xz"
        fetch_verified(f"https://nodejs.org/dist/{NODE_VERSION}/node-{NODE_VERSION}-linux-x64.tar.xz", NODE_SHA256, tmp)
        subprocess.run(["tar", "-xJf", str(tmp), "-C", str(tools)], check=True, timeout=600)
        os.replace(tools / f"node-{NODE_VERSION}-linux-x64", node)
        tmp.unlink()
    bun = tools / f"bun-{BUN_VERSION}" / "bun"
    if not bun.exists():
        tmp = tools / f".bun-{BUN_VERSION}.zip"
        fetch_verified(f"https://github.com/oven-sh/bun/releases/download/bun-v{BUN_VERSION}/bun-linux-x64.zip", BUN_SHA256, tmp)
        import zipfile
        with zipfile.ZipFile(tmp) as z:
            data = z.read("bun-linux-x64/bun")
        bun.parent.mkdir(parents=True, exist_ok=True)
        bun.write_bytes(data)
        bun.chmod(0o755)
        tmp.unlink()
    return {"node": str(node / "bin"), "bun": str(bun.parent)}


def ensure_cloudflared() -> Path:
    path = BASE / "tools" / f"cloudflared-{CLOUDFLARED_VERSION}" / "cloudflared"
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.parent / ".cloudflared.download"
        fetch_verified(f"https://github.com/cloudflare/cloudflared/releases/download/{CLOUDFLARED_VERSION}/cloudflared-linux-amd64", CLOUDFLARED_SHA256, tmp)
        tmp.chmod(0o755)
        os.replace(tmp, path)
    return path


def tool_path() -> str:
    t = ensure_tools()
    return f"{t['node']}:{t['bun']}:/usr/local/bin:/usr/bin:/bin"


# ---------------------------------------------------------------- config rendering

def strip_jsonc(text: str) -> str:
    """JSONC to JSON: drop // and /* */ comments outside strings, then trailing commas."""
    out, i, n, in_str = [], 0, len(text), False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
        elif text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        elif text.startswith("/*", i):
            j = text.find("*/", i)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return re.sub(r",(\s*[\]}])", r"\1", "".join(out))


def load_jsonc(path: Path) -> dict[str, Any]:
    return json.loads(strip_jsonc(path.read_text()))


API_DEV_NAME = "cmux-api-development"
PLATFORM_DEV_NAME = "cmux-platform-development"
FRONT_NAME = "cmux-wdev-front"
# Keys an environment inherits from the top level (wrangler's "inheritable keys"); every other key (vars,
# bindings, routes, triggers) is the environment's own, and a top-level one never applies to it.
INHERITABLE = ("main", "compatibility_date", "compatibility_flags", "account_id", "rules", "build", "no_bundle", "minify",
               "find_additional_modules", "preserve_file_names", "base_dir", "tsconfig", "alias", "jsx_factory",
               "jsx_fragment", "upload_source_maps", "limits", "placement", "migrations", "observability", "assets", "node_compat")


def flatten_env(cfg: dict[str, Any], env: str) -> dict[str, Any]:
    """One environment of a wrangler config as a config of its own, as wrangler resolves it: the top level's
    inheritable keys, then everything the environment sets. The stack runs every Worker with no --env (one
    wrangler dev, several configs whose environments have different names: development, dev)."""
    cfg = json.loads(json.dumps(cfg))
    envs = cfg.get("env") or {}
    if env not in envs:
        raise Refused(f"wrangler config has no env.{env} (has: {', '.join(sorted(envs)) or 'none'})")
    flat = {k: cfg[k] for k in INHERITABLE if k in cfg}
    flat.update(envs[env])
    flat.setdefault("name", f"{cfg.get('name', 'worker')}-{env}")
    for key in ("routes", "route", "triggers"):  # never served by wrangler dev; keep the shared crons out of it
        flat.pop(key, None)
    return flat


def render_api_config(cfg: dict[str, Any], tag: str, origin: str, with_platform: bool) -> dict[str, Any]:
    """The API's development env for local workerd: same code, vars, DOs, workflows, R2 (local) and
    Hyperdrive (local connection strings from run.sh). Bindings that only exist remotely go: the AI
    binding, and the platform service and its cross-script CLOUD_DO unless the platform runs in the
    same session (--platform-checkout), where the names resolve to it."""
    dev = flatten_env(cfg, "development")
    dev.pop("ai", None)
    vars_ = dev.setdefault("vars", {})
    vars_.update({"CLOUD_API_ORIGIN": origin, "WDEV_TAG": tag})
    if not with_platform:
        dev.pop("services", None)
        dev["durable_objects"]["bindings"] = [b for b in dev["durable_objects"]["bindings"] if b.get("script_name") != PLATFORM_DEV_NAME]
    return dev


def render_platform_config(cfg: dict[str, Any], origin: str) -> dict[str, Any]:
    dev = flatten_env(cfg, "development")
    vars_ = dev.setdefault("vars", {})
    # The local API is this session's cmux-api-development; its tokens are signed with the stack's own key.
    for key in ("API_ORIGIN", "CLOUD_API_ORIGIN"):
        if key in vars_:
            vars_[key] = origin
    if "CMUX_AUTH_JWKS_URL" in vars_:
        vars_["CMUX_AUTH_JWKS_URL"] = f"{origin}/.well-known/jwks.json"
    local = {API_DEV_NAME, PLATFORM_DEV_NAME}
    dev["services"] = [s for s in dev.get("services", []) if s.get("service") in local]
    dev["durable_objects"]["bindings"] = [b for b in dev["durable_objects"]["bindings"] if b.get("script_name") in (None, *local)]
    return dev


def render_mobile_config(cfg: dict[str, Any]) -> dict[str, Any]:
    """The mobile Worker (cmux-next-ios/backend) as its shared dev deployment runs it (env `dev`): its own
    Durable Objects (local), PS_MYSQL through the stack's Vitess connection string (run.sh), no crons. Its TURN key
    is the host's (write_dev_vars), so /v1/ice relays as the shared one does; APNs, Stack server key and Slack stay
    unset: no push or alert from a stack (membership uses the caller's own token)."""
    return flatten_env(cfg, "dev")


def render_hub_config(cfg: dict[str, Any]) -> dict[str, Any]:
    """The device hub (workers/device-hub, a TOML config) as its dev deployment runs it (env `dev`). Its signal
    URLs come from each request's own origin (PUBLIC_BASE_URL empty): the front rewrites a request to the hub
    origin it arrived on, the tailnet one or the public one, so each client gets URLs it can reach."""
    dev = flatten_env(cfg, "dev")
    dev.setdefault("vars", {})["PUBLIC_BASE_URL"] = ""
    return dev


def stack_origins(host: str, base: int) -> dict[str, str]:
    """The stack's tailnet origins, one per Worker: https://<host>:<port>."""
    return {svc: f"https://{host}:{port}" for svc, port in zip(SERVICES, stack_ports(base))}


def public_origins(slot: str, domain: str = PUBLIC_DOMAIN) -> dict[str, str]:
    """The stack's public origins (cloud-dev-stack/gateway), one per Worker: https://<svc>.<slot>.<domain>."""
    return {svc: f"https://{svc}.{slot}.{domain}" for svc in SERVICES}


def front_routes(host: str, base: int, local: int | None = None, slot: str | None = None, domain: str = PUBLIC_DOMAIN) -> dict[str, list[str]]:
    """The front Worker's routes: the authority a request arrives with (Serve, the router and the gateway keep the
    client's Host) to the Worker that serves it and the origin family it came by (tailnet or public).
    127.0.0.1:<local> is the API, for checks on the VM itself."""
    routes = {f"{host}:{port}".lower(): [svc, "tailnet"] for svc, port in zip(SERVICES, stack_ports(base))}
    routes[f"127.0.0.1:{local or base}"] = ["api", "tailnet"]
    if slot:
        routes.update({f"{svc}.{slot}.{domain}": [svc, "public"] for svc in SERVICES})
    return routes


# The front of one stack: the first Worker of its wrangler dev, so the only one on its port. It sends each
# request to the Worker whose origin the request arrived on, rewritten to that origin (https, the stack's
# host and port), and answers the API's GET /v1/client-config with the stack's own API, mobile and hub
# origins over what the API (or its platform) says, or over the development deployment's when the API has
# no platform to ask (it answers 404 then).
FRONT_JS = r"""// Generated by scripts/cmux-next/cloud-dev-stack/vm_stack.py (FRONT_JS); rewritten on every up.
const BINDINGS = { api: "API", mobile: "MOBILE", hub: "HUB" }

export default {
  async fetch(request, env) {
    const routes = JSON.parse(env.WDEV_ROUTES)
    const url = new URL(request.url)
    const [service, family] = routes[url.host.toLowerCase()] ?? []
    if (!service) return new Response(`no Worker of this stack answers on ${url.host}\n`, { status: 421 })
    // The origins of the family the request came by: a public client is told public origins, a tailnet one tailnet.
    const origins = JSON.parse(env.WDEV_ORIGINS)[family]
    const forwarded = new Request(new URL(url.pathname + url.search, origins[service]), request)
    if (service === "api" && url.pathname === "/v1/client-config" && request.method === "GET") {
      return clientConfig(forwarded, env, origins)
    }
    return env[BINDINGS[service]].fetch(forwarded)
  },
}

async function clientConfig(request, env, origins) {
  let config
  try {
    const response = await env.API.fetch(request)
    if (response.ok) {
      const body = await response.json()
      if (body && body.version === 1) config = body
    }
  } catch {}
  config ??= JSON.parse(env.WDEV_CLIENT_CONFIG)
  config.api_origin = origins.api
  config.mobile_origin = origins.mobile
  config.device_hub_origin = origins.hub
  return Response.json(config, { headers: { "cache-control": "no-store" } })
}
"""


# What the front answers for /v1/client-config when the development deployment cannot be read at start: its
# shape and the development values (cmux-cloud-environment DEVELOPMENT_DEPLOYMENT), the stack's origins over it.
FALLBACK_CLIENT_CONFIG = {
    "version": 1, "name": "development", "api_origin": DEVELOPMENT_API,
    "auth_web_origin": "https://cmux-staging.vercel.app", "vm_origin": "https://vm-staging.cmux.dev",
    "platform_origin": "https://cmux-platform-development.debussy.workers.dev",
    "mobile_origin": "https://cmux-mobile-api-dev.debussy.workers.dev",
    "device_hub_origin": "https://cmux-device-hub-dev.debussy.workers.dev",
    "share_room_origin": "https://cmux-platform-development.debussy.workers.dev", "share_api_origin": DEVELOPMENT_API,
    "stack_origin": "https://api.stack-auth.com", "stack_project_id": "454ecd03-1db2-4050-845e-4ce5b0cd9895",
    "stack_client_key": "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g", "image_channel": "development",
    "capabilities": {},
}


def development_client_config() -> dict[str, Any]:
    """The development deployment's public client-config (no credential), else FALLBACK_CLIENT_CONFIG."""
    try:
        # Cloudflare refuses urllib's default User-Agent (403).
        req = urllib.request.Request(f"{DEVELOPMENT_API}/v1/client-config", headers={"User-Agent": "cmux-wdev/1 (scripts/cmux-next/cloud-dev-stack)"})
        with urllib.request.urlopen(req, timeout=8) as r:
            body = json.loads(r.read().decode())
        if isinstance(body, dict) and body.get("version") == 1 and isinstance(body.get("capabilities"), dict):
            return body
    except Exception:  # noqa: BLE001 - offline or changed: the built-in copy
        pass
    return dict(FALLBACK_CLIENT_CONFIG)


def render_front_config(names: dict[str, str], routes: dict[str, list[str]], origins: dict[str, dict[str, str]], client_config: dict[str, Any]) -> dict[str, Any]:
    """origins: each family's origins ({"tailnet": {...}, "public": {...}})."""
    return {
        "name": FRONT_NAME, "main": "index.js", "compatibility_date": "2026-08-20",
        "services": [{"binding": binding, "service": names[svc]} for svc, binding in (("api", "API"), ("mobile", "MOBILE"), ("hub", "HUB"))],
        "vars": {"WDEV_ROUTES": json.dumps(routes, sort_keys=True), "WDEV_ORIGINS": json.dumps(origins, sort_keys=True),
                 "WDEV_CLIENT_CONFIG": json.dumps(client_config, sort_keys=True)},
    }


EXPORT_CLASS = re.compile(r"^export\s+(?:default\s+)?(?:abstract\s+)?class\s+([A-Za-z_$][\w$]*)", re.M)
EXPORT_LIST = re.compile(r"^export\s*\{([^}]*)\}", re.M)
CLASS_NAME = re.compile(r"^[A-Z][A-Za-z0-9]*[a-z][A-Za-z0-9]*$")


def entry_exports(main_source: str, cfg: dict[str, Any]) -> list[str]:
    """The named exports a Worker of the session keeps: its classes (Durable Objects, workflows,
    entrypoints). workerd runs every named export of an auxiliary Worker's main module as an entrypoint and
    refuses one that is not a class or handler (the mobile Worker exports constants such as
    BUILD_SPACE_HEADER), so the stack runs each Worker from a wrapper that re-exports only these."""
    names = set(EXPORT_CLASS.findall(main_source))
    for group in EXPORT_LIST.findall(main_source):
        for item in group.split(","):
            item = item.strip()
            if not item or item.startswith("type "):
                continue
            name = item.split(" as ")[-1].strip()
            if CLASS_NAME.match(name):
                names.add(name)
    for b in (cfg.get("durable_objects") or {}).get("bindings") or []:
        if not b.get("script_name") and b.get("class_name"):
            names.add(b["class_name"])
    for w in cfg.get("workflows") or []:
        if not w.get("script_name") and w.get("class_name"):
            names.add(w["class_name"])
    names.discard("default")
    return sorted(names)


def write_entry_wrapper(project: Path, cfg: dict[str, Any]) -> dict[str, Any]:
    """Point cfg at a generated main beside it (wdev-entry.generated.ts) that re-exports the real main's
    default and its classes (entry_exports), nothing else."""
    main = cfg["main"]
    spec = "./" + main.lstrip("./") if not main.startswith("../") else main
    names = entry_exports((project / main).read_text(), cfg)
    lines = ["// Generated by scripts/cmux-next/cloud-dev-stack/vm_stack.py (write_entry_wrapper).",
             f'export {{ default }} from "{spec}"']
    if names:
        lines.append(f'export {{ {", ".join(names)} }} from "{spec}"')
    (project / "wdev-entry.generated.ts").write_text("\n".join(lines) + "\n")
    return {**cfg, "main": "wdev-entry.generated.ts"}


def pin_build_cwd(cfg: dict[str, Any], project: Path) -> dict[str, Any]:
    """A Worker's custom build (`build.command`) run in its own project. wrangler passes build.cwd through as is, so
    with none the build runs in wrangler's working directory, which for a stack is the stack's directory, not the
    project's (the API's `bun scripts/gen-chief-vm-source.ts` failed there with Module not found). A relative cwd
    meant the project, where a deploy runs."""
    build = cfg.get("build")
    if isinstance(build, dict) and build.get("command"):
        cfg["build"] = {**build, "cwd": os.path.normpath(str(project / str(build.get("cwd") or ".")))}
    return cfg


def load_wrangler_config(path: Path) -> dict[str, Any]:
    if path.suffix == ".toml":
        import tomllib
        return tomllib.loads(path.read_text())
    return load_jsonc(path)


# ---------------------------------------------------------------- commands

def cmd_capacity(_args) -> dict[str, Any]:
    entries = all_entries()
    running = [e for e in entries if e.get("state") == "running"]
    return {
        "mem_available_gib": round(mem_available_gib(), 1),
        "disk_free_gib": round(disk_free_gib(), 1),
        "stacks_running": len(running),
        "max_stacks": MAX_STACKS,
        "retain_secs": RETAIN_SECS,
        "stacks_stopped": sum(1 for e in entries if e.get("state") == "stopped"),
        "max_kept": MAX_KEPT,
        "min_mem_gib": MIN_MEM_GIB,
        "min_disk_gib": MIN_DISK_GIB,
        "classic_registered": len(classic_ports()),
        "turn_key": host_turn() is not None,
    }


def last_activity(entry: dict[str, Any]) -> int:
    """When the stack was last used: a request (the router's heartbeat, wrangler's log), an up, a start or a touch."""
    hb = stack_dir(entry["tag"]) / "heartbeat"
    beat = int(hb.stat().st_mtime) if hb.exists() else 0
    return max(entry.get("last_request_at", 0), entry.get("last_up_at", 0), entry.get("started_at", 0), beat)


def dir_gib(path: Path) -> float:
    """A directory's size on disk, in GiB (du; 0 when it cannot be read)."""
    out = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True, timeout=120)
    try:
        return int(out.stdout.split()[0]) / 1024 / 1024
    except (IndexError, ValueError):
        return 0.0


def stop_unit(tag: str) -> None:
    """Stop the stack's workerd only: its files, Durable Object data, credentials, ports and Serve stay, and its
    next request wakes it (the router)."""
    systemctl("stop", unit(tag), check=False)
    systemctl("reset-failed", unit(tag), check=False)


def up_in_progress(entry: dict[str, Any], now: int) -> bool:
    """An up of this tag holds its lock (prepare to up-done): its stopped stack is never released under it."""
    return bool(entry.get("up_token")) and now - entry.get("up_started", 0) < UP_LOCK_SECS


def park(entry: dict[str, Any], now: int, reason: str) -> None:
    """Under the registry lock: stop a running stack's unit and keep everything else (state stopped)."""
    stop_unit(entry["tag"])
    entry.update({"state": "stopped", "stopped_at": now, "reason": reason})
    for k in WAKE_KEYS:
        entry.pop(k, None)
    write_entry(entry)


def release(entry: dict[str, Any], now: int, reason: str) -> list[str]:
    """Under the registry lock: stop the stack and delete its files; the entry stays (state reaped) for the next
    gc from a Mac, which deletes its credentials and branch."""
    steps = stop_stack(entry["tag"], keep_files=False)
    entry.update({"state": "reaped", "reaped_at": now, "reason": reason})
    entry.pop("served_at", None)  # its files are gone: a later up starts a new stack
    write_entry(entry)
    return steps


def admit(tag: str, now: int | None = None) -> list[str]:
    """Called under the registry lock, which also records the caller as preparing or starting, so two
    ups at once are counted against each other. A stack that is preparing or starting has not taken its
    memory yet: it is reserved here, beside the floor. When the stack does not fit, the least recently used
    running stacks are stopped (they wake on their next request) until it does, and the least recently used
    stopped ones released while free disk is short; never one that is preparing or starting. Returns what it
    made room with."""
    now = now or int(time.time())
    made_room: list[str] = []
    while True:
        others = [e for e in all_entries() if e["tag"] != tag and e.get("state") in ("preparing", "starting", "running")]
        pending = sum(1 for e in others if e.get("state") != "running")
        need_mem = MIN_MEM_GIB + PENDING_MEM_GIB * (pending + 1)
        mem = mem_available_gib()
        if len(others) < MAX_STACKS and mem >= need_mem:
            break
        running = [e for e in others if e.get("state") == "running"]
        if not made_room and len(others) < MAX_STACKS and running:
            # Memory short: stop stacks only when all of them together would cover it (a shortfall from outside
            # the tag stacks, the classic ones, must not stop every stack and still refuse).
            freeable = sum(unit_memory_mib(e["tag"]) or 0 for e in running) / 1024
            if mem + freeable < need_mem:
                raise Refused(f"MemAvailable {mem:.1f} GiB < {need_mem:.1f} GiB and stopping every running stack frees only {freeable:.1f} GiB")
        if not running:
            if len(others) >= MAX_STACKS:
                raise Refused(f"{len(others)} stacks starting (max {MAX_STACKS}); `cloud-dev-stack.sh status` lists them")
            raise Refused(f"MemAvailable {mem:.1f} GiB < {need_mem:.1f} GiB ({MIN_MEM_GIB} floor + {PENDING_MEM_GIB} for this and each of {pending} starting stacks; the classic stacks keep a 16 GiB floor) and no running stack to stop")
        victim = min(running, key=last_activity)
        park(victim, now, f"stopped to make room for {tag} (least recently used)")
        made_room.append(f"stopped {victim['tag']}")
        time.sleep(1)  # MemAvailable takes the stopped workerd's memory back
    while True:
        pending = sum(1 for e in all_entries() if e["tag"] != tag and e.get("state") in ("preparing", "starting"))
        need_disk = MIN_DISK_GIB + PENDING_DISK_GIB * (pending + 1)
        disk = disk_free_gib()
        if disk >= need_disk:
            break
        stopped = [e for e in all_entries() if e["tag"] != tag and e.get("state") == "stopped" and not up_in_progress(e, now)]
        if not stopped:
            raise Refused(f"free disk {disk:.1f} GiB < {need_disk:.1f} GiB (the classic GC starts purging at 100) and no stopped stack to release")
        if not any(m.startswith("released") for m in made_room):
            freeable = sum(dir_gib(stack_dir(e["tag"])) for e in stopped)
            if disk + freeable < need_disk:
                raise Refused(f"free disk {disk:.1f} GiB < {need_disk:.1f} GiB and releasing every stopped stack frees only {freeable:.1f} GiB")
        victim = min(stopped, key=last_activity)
        release(victim, now, f"released for disk room for {tag} (least recently used)")
        made_room.append(f"released {victim['tag']}")
    return made_room


def cmd_prepare(args) -> dict[str, Any]:
    """Make the stack directory before the Mac rsyncs into it; admission happens here."""
    tag = check_tag(args.tag)
    now = int(time.time())
    with registry_lock():
        entry = read_entry(tag)
        state = (entry or {}).get("state")
        if state == "releasing" and now - entry.get("releasing_at", now) < RELEASE_CLAIM_SECS:
            raise Refused(f"{tag}: a gc is deleting its stopped stack's credentials and branch; run up again in a minute")
        # One up of a tag at a time: two would sync into, install in and restart the same directory.
        # The Mac clears this when its up ends, pass or fail (up-done); a crashed Mac's lapses.
        if entry and entry.get("up_token") and now - entry.get("up_started", 0) < UP_LOCK_SECS:
            raise Refused(f"{tag}: another up of this tag has been running for {now - entry['up_started']} s; wait for it, then run up again")
        d = stack_dir(tag)
        for sub in ("src", "platform", "state", "logs", "secrets", "home"):
            (d / sub).mkdir(mode=0o700, parents=True, exist_ok=True)
        token = secrets.token_hex(8)
        if state in ("stopped", "running"):
            entry.setdefault("served_at", entry.get("started_at") or now)  # an entry from before the mark served
        waking = state == "starting" and bool(entry.get("wake_token")) and entry.get("served_at") and (d / "run.sh").exists()
        if (state == "stopped" or waking) and (d / "run.sh").exists():
            # A re-up of a stopped stack, or of one a request is waking: it stays as it is (and the wake settles
            # it) until start restarts it, so a re-up that fails before start leaves it as it was, files and data
            # included. Never a fresh stack, which a failed up would turn into one gc releases.
            entry["reup_at"] = now
        elif state == "running":
            # A re-up of a running stack: it stays running (and keeps serving) until start restarts it.
            # The marker keeps the reaper from treating a unit restart in progress as a crash, and a
            # re-up that fails before start leaves the stack as it was.
            entry["reup_at"] = now
        else:
            admit(tag)
            # Recorded before the sync and the branch creation: gc and the reaper leave a young
            # preparing entry alone, so an up in progress is never cleaned up under it.
            entry = entry or {"tag": tag, "created_at": now}
            if state in ("down", "reaped", "releasing"):
                entry.pop("port", None)
                entry.pop("ports", None)
            entry.pop("served_at", None)  # not a stack that served (a first up, or one after a release or a failure)
            entry.update({"state": "preparing", "last_up_at": now})
        entry.update({"up_token": token, "up_started": now})
        write_entry(entry)
    (d / "heartbeat").touch()
    return {"dir": str(d), "state": entry["state"], "token": token}


def wait_healthy(tag: str, port: int, host: str, timeout: float, local: int | None = None,
                 log: Path | None = None, log_start: int = 0) -> tuple[bool, str]:
    """Wait until every Worker of the stack answers /v1/health on wrangler's port (local; port for a stack from
    before local ports), each asked as its own tailnet authority (host:port, host:port+1, ...)."""
    authorities = [f"{host}:{p}" for p in stack_ports(port)]
    deadline, healthy, last = time.time() + timeout, set(), ""
    while time.time() < deadline:
        if not unit_active(tag):
            return False, "its unit stopped"
        if log is not None and log.exists():  # wrangler keeps running after a failed build, waiting for a change
            with open(log, "rb") as f:
                f.seek(log_start)
                if b"Build failed" in f.read():
                    return False, "build failed"
        for a in authorities:
            if a not in healthy:
                ok, body = probe(local or port, a)
                if ok:
                    healthy.add(a)
                else:
                    last = f"{a}: {body}"
        if len(healthy) == len(authorities):
            return True, ""
        time.sleep(1)
    return False, last or "timed out"


WAKE_KEYS = ("wake_started_at", "wake_deadline", "wake_token")


def wake_is_stale(entry: dict[str, Any], now: int) -> bool:
    """A wake marked on the entry whose process is past its own wait and grace: it was killed or died."""
    started = entry.get("wake_started_at")
    return bool(started) and now > entry.get("wake_deadline", started + WAKE_STALE_SECS)


def cmd_wake(args) -> dict[str, Any]:
    """Start a stopped stack again (the router calls this on its first request): the same run.sh, ports, files and
    Durable Object data, admitted like an up (the least recently used running stacks stop when it does not fit).
    A running one returns at once; one an up or another live wake is starting is waited for. A wake that dies
    (killed, an error) leaves the stack stopped, never starting: the next request wakes it again."""
    tag = check_tag(args.tag)
    now = int(time.time())
    with registry_lock():
        entry = read_entry(tag)
        state = (entry or {}).get("state")
        if state == "running" and unit_active(tag):
            return {"tag": tag, "state": "running", "woke": False}
        stale_wake = state == "starting" and wake_is_stale(entry, now)
        if state in ("preparing", "starting") and not stale_wake:
            waiting = True
        elif state in ("stopped", "running") or stale_wake:  # running with no unit: it crashed under its entry
            waiting = False
            if now - entry.get("wake_failed_at", 0) < WAKE_RETRY_SECS:
                raise Refused(f"{tag}: its last wake failed {now - entry['wake_failed_at']} s ago ({entry.get('wake_error', '')}); retry in a minute, or cloud-dev-stack.sh up --tag {tag}")
            if not (stack_dir(tag) / "run.sh").exists():
                raise Refused(f"{tag}: no run.sh (released); cloud-dev-stack.sh up --tag {tag}")
            if entry.get("start_failed_at"):
                # Its run.sh is the code whose start failed: a wake would fail the same way after up to 150 s, and
                # might stop a healthy stack for room first. An up with a fix brings it back.
                raise Refused(f"{tag}: its last up did not start ({entry.get('reason', '')}); fix it and run cloud-dev-stack.sh up --tag {tag}")
            # Its tailnet ports must still be ours: a classic stack never takes one (wrangler listens on its own
            # local port), but a hand-made Serve entry might.
            with serve_lock():
                cfg = serve_config()
                foreign = [p for p in entry_ports(entry) if p in classic_ports() or serve_target(cfg, p) not in (None, ROUTER_TARGET)]
            if foreign:
                raise Refused(f"{tag}: its ports {foreign} now belong to something else; cloud-dev-stack.sh up --tag {tag} picks new ones")
            made_room = admit(tag, now)
            token = secrets.token_hex(6)
            entry.update({"state": "starting", "wake_started_at": now, "wake_deadline": now + args.wait + WAKE_GRACE_SECS,
                          "wake_token": token, "made_room": made_room})
            write_entry(entry)
        else:
            raise Refused(f"{tag} is {state or 'absent'}; cloud-dev-stack.sh up --tag {tag} brings it back")
    if waiting:
        deadline = time.time() + args.wait
        while time.time() < deadline:
            e = read_entry(tag) or {}
            if e.get("state") == "running":
                return {"tag": tag, "state": "running", "woke": False, "waited": True}
            if e.get("state") not in ("preparing", "starting"):
                raise Refused(f"{tag}: the up or wake it waited for ended {e.get('state')}")
            time.sleep(1)
        raise Refused(f"{tag}: still {state} after {args.wait} s")

    def settle(ok: bool, why: str = "", log_offset: int = 0) -> dict[str, Any] | None:
        """This wake's last write, only while the entry is still this wake's (a down or an up may have taken it)."""
        with registry_lock():
            e = read_entry(tag)
            if not e or e.get("state") != "starting" or e.get("wake_token") != token:
                return None  # its new owner (a down stops the unit, an up restarts it) decides; the unit is left alone
            t = int(time.time())
            if ok:
                e.update({"state": "running", "started_at": t, "last_request_at": t, "woke_at": t, "log_offset": log_offset, "served_at": t})
                for k in ("wake_failed_at", "wake_error", "reason", "stopped_at", *WAKE_KEYS):
                    e.pop(k, None)
            else:
                stop_unit(tag)
                e.update({"state": "stopped", "wake_failed_at": t, "wake_error": why[:200]})
                for k in WAKE_KEYS:
                    e.pop(k, None)
            write_entry(e)
            return e

    previous = signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(KeyboardInterrupt("SIGTERM")))
    log = stack_dir(tag) / "logs/wrangler.log"
    try:
        own_log(log)
        log_start = log.stat().st_size
        write_dev_vars(stack_dir(tag), bool(entry.get("platform")))
        systemctl("reset-failed", unit(tag), check=False)
        systemctl("start", unit(tag))
        (stack_dir(tag) / "heartbeat").touch()
        ok, why = wait_healthy(tag, entry["port"], entry["host"], args.wait, local=local_port(entry), log=log, log_start=log_start)
    except BaseException as err:  # noqa: BLE001 - killed or failed: back to stopped
        settle(False, f"the wake was interrupted: {type(err).__name__}: {err}")
        raise
    finally:
        signal.signal(signal.SIGTERM, previous)
    if not ok:
        settle(False, why)
        tail = redact(log.read_text(errors="replace")[log_start:][-3000:], stack_dir(tag)) if log.exists() else ""
        raise Refused(f"{tag}: did not wake ({why})\n--- log tail ---\n{tail}")
    e = settle(True, log_offset=log.stat().st_size if log.exists() else 0)
    if e is None:
        raise Refused(f"{tag}: a down or an up took the stack while it woke")
    return {"tag": tag, "state": "running", "woke": True, "secs": int(time.time()) - now, "made_room": e.get("made_room", [])}


def cmd_put_public(_args) -> dict[str, Any]:
    """Store the public slots the Mac provisioned (JSON {domain, slots} on stdin) and rewrite the routes."""
    data = json.loads(sys.stdin.read())
    domain = str(data.get("domain") or "")
    if domain != PUBLIC_DOMAIN:
        raise Refused(f"public domain {domain!r}: only {PUBLIC_DOMAIN} (the gateway's and the apps' allowlist)")
    slots = sorted({str(x) for x in data.get("slots") or [] if SLOT_RE.match(str(x))}, key=lambda x: int(x[1:]))
    with registry_lock():
        tmp = BASE / "public.json.tmp"
        tmp.write_text(json.dumps({"domain": domain, "slots": slots}))
        os.replace(tmp, BASE / "public.json")
        write_routes()
    return {"domain": domain, "slots": len(slots)}


def cmd_stop(args) -> dict[str, Any]:
    """Stop a running stack now, as an idle one is (`cloud-dev-stack.sh stop`): it wakes on its next request."""
    tag = check_tag(args.tag)
    with registry_lock():
        entry = read_entry(tag)
        if not entry or entry.get("state") != "running":
            raise Refused(f"{tag} is {(entry or {}).get('state', 'absent')}, not running")
        park(entry, int(time.time()), "stopped by cloud-dev-stack.sh stop; wakes on its next request")
    return {"tag": tag, "state": "stopped"}


def cmd_up_done(args) -> dict[str, Any]:
    """The end of one up (the Mac's EXIT trap). A failed up leaves a running stack running, and turns a
    stack that never started into failed, so gc releases it after an hour and the next up may start."""
    tag = check_tag(args.tag)
    with registry_lock():
        entry = read_entry(tag)
        if not entry or entry.get("up_token") != args.token:
            return {"tag": tag, "cleared": False}
        entry.pop("up_token", None)
        entry.pop("up_started", None)
        if args.failed:
            entry.pop("reup_at", None)
            if entry.get("state") == "preparing":
                entry["state"] = "failed"
            elif (entry.get("state") == "starting" and entry.get("served_at") and not entry.get("wake_token")
                  and (stack_dir(tag) / "run.sh").exists()):
                # A re-up of a stack that already served, whose Mac side died after start took the stack (start may
                # still be running on the VM, and settles the entry itself when it ends): the stack keeps its ports,
                # Serve and data. Still up, it is running; else stopped, and its next request wakes it. Never failed,
                # which gc would release with its data. A wake in progress settles its own entry.
                if unit_active(tag):
                    entry["state"] = "running"
                else:
                    entry.update({"state": "stopped", "stopped_at": int(time.time()), "reason": "a re-up failed; the stack wakes on its next request"})
        write_entry(entry)
    return {"tag": tag, "cleared": True, "state": entry.get("state")}


def cmd_prune(args) -> dict[str, Any]:
    """Delete files under src/ (or platform/) that the Mac's manifest (stdin) no longer lists, so a
    deleted file does not linger. node_modules and generated files are kept."""
    tag = check_tag(args.tag)
    root = stack_dir(tag) / args.tree
    keep = {line for line in sys.stdin.read().splitlines() if line}
    removed = 0
    for path in root.rglob("*"):
        rel = path.relative_to(root).as_posix()
        if "node_modules" in path.parts or ".wrangler" in path.parts or ".generated." in path.name or path.name == ".dev.vars":
            continue
        if path.is_file() and rel not in keep:
            path.unlink()
            removed += 1
    return {"removed": removed}


def cmd_put_cred(args) -> dict[str, Any]:
    """Store one database credential (pscale JSON on stdin) in secrets/, mode 0600. Prints only ids."""
    tag = check_tag(args.tag)
    raw = json.loads(sys.stdin.read())
    secrets_dir = stack_dir(tag) / "secrets"
    secrets_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    if args.kind == "pg":
        url = raw.get("database_url")
        if not url:
            raise Refused("pscale role JSON has no database_url (keys: %s)" % ",".join(sorted(raw)))
        url = url if "sslmode=" in url else url + ("&" if "?" in url else "?") + "sslmode=require"
    else:
        user, pw, host = raw.get("username"), raw.get("plain_text"), raw.get("access_host_url")
        if not (user and pw and host):
            raise Refused("pscale password JSON lacks username/plain_text/access_host_url")
        from urllib.parse import quote
        url = f"mysql://{quote(user, safe='')}:{quote(pw, safe='')}@{host}:3306/{args.database}"
    target = secrets_dir / f"{args.kind}.url"
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(url)
    with registry_lock():
        if args.mode == "branch":
            ledger_add(f"{args.db_name}/{args.branch}")
        entry = read_entry(tag) or {"tag": tag, "state": "preparing", "created_at": int(time.time())}
        db = entry.setdefault("db", {})
        replaced = db.get(args.kind) or {}
        db[args.kind] = {"database": args.db_name, "branch": args.branch, "cred_id": raw.get("id"), "cred_name": raw.get("name"),
                         "expires_at": raw.get("expires_at"), "mode": args.mode}
        write_entry(entry)
    old = {k: replaced.get(k) for k in ("database", "branch", "cred_id", "mode")} if replaced.get("cred_id") not in (None, raw.get("id")) else None
    return {"stored": args.kind, "cred_id": raw.get("id"), "replaced": old}


def run_quiet(cmd: list[str], cwd: Path, env: dict[str, str], what: str) -> str:
    out = subprocess.run(cmd, cwd=cwd, env=env, capture_output=True, text=True, timeout=900)
    if out.returncode != 0:
        tail = (out.stdout + out.stderr)[-3000:]
        from urllib.parse import unquote, urlsplit
        for v in env.values():  # never echo a credential that reached a child's output
            if "://" in v:
                secret = unquote(urlsplit(v).password or "")
                for s in (v, secret):
                    if len(s) > 8:
                        tail = tail.replace(s, "<redacted>")
        raise Refused(f"{what} failed (exit {out.returncode}):\n{tail}")
    return out.stdout[-2000:]


# A Vitess branch copies development's schema but not its rows, so its schema_migrations is empty and the
# runner would apply 0000_baseline onto tables that exist. Before the first run, copy development's history
# rows for the files this tree has (a file development ran that this tree lacks stays out: the runner
# refuses a history row it has no file for).
SEED_MYSQL_HISTORY = """import mysql from "mysql2/promise"
import { loadMigrations } from "./migrate-mysql.ts"
const opts = { timezone: "Z" as const, dateStrings: true }
const parent = await mysql.createConnection({ uri: process.env.CMUX_WDEV_PARENT_URL ?? "", ...opts })
const branch = await mysql.createConnection({ uri: process.env.CMUX_WDEV_MIGRATE_URL ?? "", ...opts })
await branch.query("CREATE TABLE IF NOT EXISTS schema_migrations (name varchar(128) CHARACTER SET ascii COLLATE ascii_bin NOT NULL PRIMARY KEY, checksum char(64) CHARACTER SET ascii NOT NULL, applied_at datetime(3) NOT NULL DEFAULT (CURRENT_TIMESTAMP(3)))")
const [have] = (await branch.query("SELECT COUNT(*) AS n FROM schema_migrations")) as unknown as [Array<{ n: number }>]
let copied = 0
if (Number(have[0]?.n ?? 0) === 0) {
  const local = new Set(loadMigrations().map((m) => m.name))
  const [rows] = (await parent.query("SELECT name, checksum FROM schema_migrations ORDER BY name")) as unknown as [Array<{ name: string; checksum: string }>]
  for (const r of rows) if (local.has(r.name)) { await branch.query("INSERT INTO schema_migrations (name, checksum) VALUES (?, ?)", [r.name, r.checksum]); copied++ }
}
console.log(`history: ${copied} rows copied from development`)
await parent.end(); await branch.end()
"""


def cmd_migrate(args) -> dict[str, Any]:
    """Apply the tag tree's migrations to the stack's own branch (only in branch mode)."""
    tag = check_tag(args.tag)
    d = stack_dir(tag)
    entry = read_entry(tag) or {}
    env = {**os.environ, "PATH": tool_path()}
    done = {}
    tls = '?ssl={"rejectUnauthorized":true}'
    for kind, runner in (("pg", "migrate.ts"), ("mysql", "migrate-mysql.ts")):
        info = (entry.get("db") or {}).get(kind) or {}
        if info.get("mode") != "branch":
            continue
        url = (d / "secrets" / f"{kind}.url").read_text().strip()
        lines = []
        if kind == "mysql":
            url += tls
            parent = d / "secrets" / "mysql-parent.url"
            if parent.exists():
                env["CMUX_WDEV_PARENT_URL"] = parent.read_text().strip() + tls
                env["CMUX_WDEV_MIGRATE_URL"] = url
                seed = d / "src/backend/db/wdev-seed-history.generated.ts"
                seed.write_text(SEED_MYSQL_HISTORY)
                lines += run_quiet(["bun", seed.name], seed.parent, env, "copy development's migration history").strip().splitlines()[-1:]
                parent.unlink()
                env.pop("CMUX_WDEV_PARENT_URL")
        env["CMUX_WDEV_MIGRATE_URL"] = url
        lines += run_quiet(["bun", runner, "--url-env", "CMUX_WDEV_MIGRATE_URL"], d / "src/backend/db", env, f"{runner} on {info.get('branch')}").strip().splitlines()[-5:]
        done[kind] = lines
    return {"migrated": done}


def ensure_jwk(d: Path, tag: str, env: dict[str, str]) -> str:
    """The stack's own ES256 signing key (JWT_PRIVATE_JWK), made once per stack and kept with it."""
    path = d / "secrets" / "jwt.jwk"
    if not path.exists():
        js = ("const {generateKeyPairSync}=require('crypto');const k=generateKeyPairSync('ec',{namedCurve:'P-256'}).privateKey.export({format:'jwk'});"
              f"k.kid='wdev-{tag}-'+Date.now().toString(36);k.alg='ES256';k.use='sig';process.stdout.write(JSON.stringify(k))")
        jwk = subprocess.run(["node", "-e", js], env=env, capture_output=True, text=True, check=True).stdout
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            f.write(jwk)
    return path.read_text()


def wrangler_version(project: Path) -> tuple[int, ...]:
    try:
        version = json.loads((project / "node_modules/wrangler/package.json").read_text())["version"]
        return tuple(int(x) for x in re.findall(r"\d+", version)[:3])
    except (OSError, ValueError, KeyError):
        return (0,)


def write_private(path: Path, body: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(body)


# The device hub's two signing keys (workers/device-hub scripts/gen-dev-secrets.mjs: P-256 private JWKs).
HUB_KEYS_JS = """const gen = async () => { const p = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const j = await crypto.subtle.exportKey("jwk", p.privateKey); return JSON.stringify({ kty: j.kty, crv: j.crv, x: j.x, y: j.y, d: j.d }) };
process.stdout.write(`SESSION_KEY='${await gen()}'\\nTICKET_KEY='${await gen()}'\\n`)"""


def write_public_jwks(d: Path) -> None:
    """The public halves of the keys the stack signs tokens with (the API's JWT_PRIVATE_JWK, the hub's SESSION_KEY
    and TICKET_KEY), for the gateway to verify a stack-issued token (the router's GET /__wdev/jwks)."""
    keys = []
    texts = []
    for name in ("jwt.jwk",):
        if (d / "secrets" / name).exists():
            texts.append((d / "secrets" / name).read_text())
    if (d / "secrets/hub.vars").exists():
        texts += re.findall(r"^[A-Z_]+='(\{.*\})'$", (d / "secrets/hub.vars").read_text(), re.M)
    for t in texts:
        try:
            k = json.loads(t)
        except ValueError:
            continue
        if k.get("kty") == "EC" and k.get("x") and k.get("y"):
            keys.append({f: k[f] for f in ("kty", "crv", "x", "y", "kid") if f in k})
    (d / "public-jwks.json").write_text(json.dumps({"keys": keys}))


def ensure_hub_keys(d: Path, env: dict[str, str]) -> str:
    """The stack's own device hub keys (SESSION_KEY, TICKET_KEY) as .dev.vars lines, made once per stack."""
    path = d / "secrets" / "hub.vars"
    if not path.exists():
        body = subprocess.run(["node", "--input-type=module", "-e", HUB_KEYS_JS], env=env, capture_output=True, text=True, check=True).stdout
        write_private(path, body)
    return path.read_text()


# The team's Cloudflare TURN key (1Password "Cloudflare TURN Server API Key"), one per host for every stack's mobile
# Worker: without it a stack's /v1/ice is STUN only, and a phone on another network than its Mac never links (live,
# tag gcp-default-1121, 2026-11-21). An up sends it from 1Password over SSH stdin (put-turn) when turn-status says
# the host has none or Cloudflare refuses the one it has, as an up makes a database credential when it lapses.
TURN_KEY_ID_RE = re.compile(r"[0-9a-f]{32}")
TURN_TOKEN_RE = re.compile(r"[A-Za-z0-9._-]{20,256}")
TURN_API = "https://rtc.live.cloudflare.com/v1/turn/keys/{}/credentials/generate-ice-servers"
# The development Stack project's server key, which this host's classic dev backend already keeps
# (cmuxterm-hq skills/infra/dev-backend: <classic base>/secrets/runtime.json, 0600, this user's). The stack's API
# needs it to learn a team from Stack: a stack's TeamDO never gets Stack's webhooks, so without it every
# team-scoped /v1/auth/token is refused as "not a member of this team" (403; 78 of them from one Mac, same run).
STACK_KEY_RE = re.compile(r"[A-Za-z0-9_-]{16,256}")


def turn_path() -> Path:
    return BASE / "secrets/turn.json"


def host_turn() -> dict[str, str] | None:
    """The host's TURN key as the mobile Worker's two secrets, or None."""
    try:
        data = json.loads(turn_path().read_text())
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    key_id, token = data.get("key_id"), data.get("api_token")
    if not (isinstance(key_id, str) and TURN_KEY_ID_RE.fullmatch(key_id) and isinstance(token, str) and TURN_TOKEN_RE.fullmatch(token)):
        return None
    return {"TURN_KEY_ID": key_id, "TURN_KEY_API_TOKEN": token}


def turn_probe(key_id: str, token: str) -> int | None:
    """Cloudflare's HTTP status for one short TURN credential request with this key; None when it could not be asked."""
    # A named User-Agent: Cloudflare answers urllib's default one with error 1010 (403), which reads as a refused key.
    req = urllib.request.Request(TURN_API.format(key_id), data=b'{"ttl": 300}', method="POST",
                                 headers={"authorization": f"Bearer {token}", "content-type": "application/json",
                                          "user-agent": "cmux-wdev-stack/1 (scripts/cmux-next/cloud-dev-stack)"})
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            return res.status
    except urllib.error.HTTPError as e:
        return e.code
    except (OSError, ValueError):
        return None


def turn_verdict(status: int | None) -> str:
    """ok: Cloudflare minted credentials; refused: the key is revoked or rotated (send it again); unverified: Cloudflare
    could not say (unreachable, 429, 5xx), so the key is kept."""
    if status is not None and 200 <= status < 300:
        return "ok"
    return "refused" if status in (400, 401, 403, 404) else "unverified"


def cmd_put_turn(_args) -> dict[str, Any]:
    """Store the team's TURN key (stdin: the key id, then its API token, one per line) at <base>/secrets/turn.json,
    mode 0600, after Cloudflare accepts it. Anything else (a failed op pipes nothing) is refused and the key the host
    has stays. Prints no part of it."""
    lines = sys.stdin.read().splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if len(lines) != 2:
        raise Refused(f"expected the TURN key id and its API token, one per line; got {len(lines)} line(s). Nothing stored (is op signed in?)")
    key_id, token = lines[0].strip(), lines[1].strip()
    if not TURN_KEY_ID_RE.fullmatch(key_id):
        raise Refused("the first line is not a TURN key id (32 hex digits). Nothing stored")
    if not TURN_TOKEN_RE.fullmatch(token):
        raise Refused("the second line is not a TURN API token. Nothing stored")
    status = turn_probe(key_id, token)
    if turn_verdict(status) == "refused":
        raise Refused(f"Cloudflare refused this TURN key (HTTP {status}). Nothing stored; check the 1Password item")
    secrets_dir = BASE / "secrets"
    secrets_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(secrets_dir, 0o700)
    tmp = secrets_dir / f".turn.{os.getpid()}.tmp"
    write_private(tmp, json.dumps({"key_id": key_id, "api_token": token, "stored_at": int(time.time())}))
    os.replace(tmp, turn_path())
    return {"stored": "turn", "verified": turn_verdict(status) == "ok", "status": status}


def cmd_turn_status(_args) -> dict[str, Any]:
    """Whether an up must send the TURN key again: missing, refused (send), ok or unverified (keep)."""
    turn = host_turn()
    if turn is None:
        return {"state": "missing", "why": "no TURN key on this host"}
    status = turn_probe(turn["TURN_KEY_ID"], turn["TURN_KEY_API_TOKEN"])
    state = turn_verdict(status)
    return {"state": state, "why": f"Cloudflare answered {status}" if status is not None else "Cloudflare not reached"}


def classic_runtime() -> dict[str, Any]:
    try:
        data = json.loads((CLASSIC_BASE / "secrets/runtime.json").read_text())
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def stack_server_key(project_id: str | None) -> str | None:
    """The Stack server key the classic dev backend keeps, only when it is the key of the project the stack's API
    runs against."""
    data = classic_runtime()
    key = data.get("STACK_SECRET_SERVER_KEY")
    if not project_id or data.get("NEXT_PUBLIC_STACK_PROJECT_ID") != project_id or not isinstance(key, str) or not STACK_KEY_RE.fullmatch(key):
        return None
    return key


def host_secret_values() -> list[str]:
    """The host keys a stack's Workers hold, for redact."""
    values = [(host_turn() or {}).get("TURN_KEY_API_TOKEN"), classic_runtime().get("STACK_SECRET_SERVER_KEY")]
    return [x for x in values if isinstance(x, str) and len(x) > 8]


def dotenv(values: dict[str, str]) -> str:
    """dotenv lines; a single-quoted value is literal (a JWK's double quotes stay as they are)."""
    return "".join(f"{k}='{val}'\n" for k, val in values.items())


def write_dev_vars(d: Path, with_platform: bool) -> dict[str, bool]:
    """Each Worker's .dev.vars (mode 0600, beside its generated config; wrangler dev reads it at start), from the
    stack's own keys and the host's: the API (and the platform, which verifies the API's install tokens with the same
    key outside production) JWT_PRIVATE_JWK and, for the API, the Stack server key; the mobile Worker the TURN key;
    the hub its two keys. Rewritten at every start and wake, so a key the host got or lost since applies."""
    jwk_path, hub_path = d / "secrets/jwt.jwk", d / "secrets/hub.vars"
    jwk = jwk_path.read_text() if jwk_path.exists() else None
    api_dir, mobile_dir, hub_dir = (d / PROJECTS[s][0] for s in ("api", "mobile", "hub"))
    try:
        project = json.loads((api_dir / "wrangler.wdev.generated.json").read_text()).get("vars", {}).get("STACK_PROJECT_ID")
    except (OSError, ValueError, AttributeError):
        project = None
    stack_key = stack_server_key(project)
    turn = host_turn()
    if api_dir.is_dir():
        write_private(api_dir / ".dev.vars", dotenv({**({"JWT_PRIVATE_JWK": jwk} if jwk else {}),
                                                     **({"STACK_SECRET_SERVER_KEY": stack_key} if stack_key else {})}))
    if with_platform and (d / "platform").is_dir():
        write_private(d / "platform/.dev.vars", dotenv({"JWT_PRIVATE_JWK": jwk} if jwk else {}))
    if mobile_dir.is_dir():
        write_private(mobile_dir / ".dev.vars", dotenv(turn or {}))
    if hub_dir.is_dir() and hub_path.exists():
        write_private(hub_dir / ".dev.vars", hub_path.read_text())
    return {"turn": turn is not None, "stack_teams": stack_key is not None}


# Where each Worker of a stack lives in the synced tree, and how its dependencies are installed.
PROJECTS = {
    "api": ("src/backend/apps/api", "wrangler.jsonc"),
    "mobile": ("src/cmux-next-ios/backend", "wrangler.jsonc"),
    "hub": ("src/workers/device-hub", "wrangler.toml"),
}


def install_deps(d: Path, env: dict[str, str], with_platform: bool) -> None:
    """Each project's dependencies at its own lockfile: bun for the backend workspace and the mobile Worker,
    npm for the device hub (package-lock.json)."""
    run_quiet(["bun", "install", "--frozen-lockfile"], d / "src/backend", env, "bun install (backend)")
    run_quiet(["bun", "install", "--frozen-lockfile"], d / PROJECTS["mobile"][0], env, "bun install (mobile Worker)")
    npm_env = {**env, "npm_config_cache": str(BASE / "cache/npm"), "npm_config_update_notifier": "false"}
    run_quiet(["npm", "ci", "--no-audit", "--no-fund", "--loglevel=error"], d / PROJECTS["hub"][0], npm_env, "npm ci (device hub)")
    if with_platform:
        run_quiet(["bun", "install", "--frozen-lockfile"], d / "platform", env, "bun install (platform)")


def newest_wrangler(projects: list[Path]) -> Path:
    """One workerd runs every Worker of the stack, so it must know the newest compatibility date of them:
    the newest wrangler any project installed."""
    return max(projects, key=wrangler_version) / "node_modules/.bin/wrangler"


def probe(port: int, authority: str, path: str = "/v1/health") -> tuple[bool, str]:
    """GET path on wrangler's local port, as the Worker that answers `authority` (the front routes by it)."""
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", headers={"Host": authority})
    try:
        with urllib.request.urlopen(req, timeout=5) as r:  # user-agent: wrangler on 127.0.0.1, no CDN in front
            return r.status == 200, r.read().decode(errors="replace")[:400]
    except Exception as e:  # noqa: BLE001 - still booting
        return False, str(e)[:400]


def cmd_start(args) -> dict[str, Any]:
    tag = check_tag(args.tag)
    d = stack_dir(tag)
    path = tool_path()
    env = {**os.environ, "PATH": path, "BUN_INSTALL_CACHE_DIR": str(BASE / "cache/bun")}
    for svc, (rel, cfg_name) in PROJECTS.items():
        if not (d / rel / cfg_name).exists():
            raise Refused(f"{d / rel / cfg_name} missing: sync the worktree first (the stack runs the {svc} Worker from it)")
    with_platform = bool(args.platform)
    install_deps(d, env, with_platform)

    with registry_lock():
        entry = read_entry(tag) or {"tag": tag, "created_at": int(time.time())}
        if entry.get("state") != "running":
            admit(tag)
        taken = ports_held(tag)
        listening = listening_ports()
        mine = {local_port(entry)} | set(entry_ports(entry)) if entry.get("port") and unit_active(tag) else set()
        with serve_lock():
            port = pick_port(tag, entry.get("port"), taken, classic_ports(), serve_config(), listening - mine)
        local = pick_local_port(tag, entry.get("local_port"), listening - mine)
        host = dns_name()
        origins = stack_origins(host, port)
        slot = assign_slot(tag, entry)
        domain = public_slots()[0]
        public = public_origins(slot, domain) if slot else {}
        entry.update({"slot": slot, "domain": domain if slot else None, "public_urls": public})
        entry.update({"port": port, "ports": stack_ports(port), "local_port": local, "url": origins["api"], "urls": origins, "state": "starting", "host": host,
                      "platform": with_platform, "commit": args.commit, "dirty": bool(args.dirty), "idle_secs": args.idle or IDLE_SECS_DEFAULT,
                      "retain_secs": RETAIN_SECS, "last_up_at": int(time.time())})
        for k in WAKE_KEYS:  # a wake in progress is no longer the stack's owner: it leaves the stack to this start
            entry.pop(k, None)
        write_entry(entry)

    configs, names, projects = ["-c", str(d / "front/wrangler.wdev.generated.json")], {}, []
    rendered = {
        "api": lambda c: render_api_config(c, tag, origins["api"], with_platform),
        "mobile": render_mobile_config,
        "hub": render_hub_config,
    }
    for svc, (rel, cfg_name) in PROJECTS.items():
        project = d / rel
        cfg = pin_build_cwd(write_entry_wrapper(project, rendered[svc](load_wrangler_config(project / cfg_name))), project)
        names[svc] = cfg["name"]
        (project / "wrangler.wdev.generated.json").write_text(json.dumps(cfg, indent=1))
        configs += ["-c", str(project / "wrangler.wdev.generated.json")]
        projects.append(project)
    if with_platform:
        pcfg = pin_build_cwd(write_entry_wrapper(d / "platform", render_platform_config(load_jsonc(d / "platform/wrangler.jsonc"), origins["api"])), d / "platform")
        (d / "platform/wrangler.wdev.generated.json").write_text(json.dumps(pcfg, indent=1))
        configs += ["-c", str(d / "platform/wrangler.wdev.generated.json")]
        projects.append(d / "platform")
    (d / "front").mkdir(mode=0o700, exist_ok=True)
    (d / "front/index.js").write_text(FRONT_JS)
    front = render_front_config(names, front_routes(host, port, local, slot, domain), {"tailnet": origins, "public": public},
                                development_client_config())
    (d / "front/wrangler.wdev.generated.json").write_text(json.dumps(front, indent=1))

    ensure_jwk(d, tag, env)
    ensure_hub_keys(d, env)
    keys = write_dev_vars(d, with_platform)
    write_public_jwks(d)
    wrangler = newest_wrangler(projects)
    run_sh = render_run_sh(d, path, local, args.commit, wrangler, configs)
    write_private(d / "run.sh", run_sh)
    (d / "logs").mkdir(exist_ok=True)
    log = d / "logs/wrangler.log"
    (d / "home").mkdir(mode=0o700, exist_ok=True)
    own_log(log)
    if log.stat().st_size > LOG_MAX_BYTES:
        log.write_text("")
    log_start = log.stat().st_size if log.exists() else 0
    systemctl("restart", unit(tag))
    (d / "heartbeat").touch()

    deadline = time.time() + args.wait
    authorities = {svc: f"{host}:{p}" for svc, p in zip(SERVICES, stack_ports(port))}
    healthy: dict[str, str] = {}
    last = ""
    while time.time() < deadline and len(healthy) < len(SERVICES):
        if not unit_active(tag):
            break
        if log.exists():  # wrangler keeps running after a failed build, waiting for a file change
            with open(log, "rb") as f:
                f.seek(log_start)
                if b"Build failed" in f.read():
                    last = "build failed"
                    break
        for svc in SERVICES:
            if svc not in healthy:
                ok, body = probe(local, authorities[svc])
                if ok:
                    healthy[svc] = body
                else:
                    last = f"{svc}: {body}"
        if len(healthy) < len(SERVICES):
            time.sleep(2)
    if len(healthy) < len(SERVICES):
        tail = redact(log.read_text(errors="replace")[-4000:], d) if log.exists() else ""
        with registry_lock():
            settle_failed_start(read_entry(tag) or entry)
        raise Refused(f"wrangler dev did not answer /v1/health for {', '.join(s for s in SERVICES if s not in healthy)} on 127.0.0.1:{local} ({last})\n--- log tail ---\n{tail}")

    if not publish(stack_ports(port), port):
        # Outside the Serve lock: every path takes the registry lock before the Serve lock, never after.
        stop_stack(tag, keep_files=True, serve=False)
        with registry_lock():
            entry = read_entry(tag) or entry
            entry.update({"state": "failed", "port": None, "ports": []})
            write_entry(entry)
        raise Refused(f"a port of {stack_ports(port)} was taken by a classic stack while this one booted; run up again for others")
    with registry_lock():
        entry = read_entry(tag) or entry
        entry.update({"state": "running", "started_at": int(time.time()), "log_offset": log.stat().st_size if log.exists() else 0,
                      "last_request_at": int(time.time())})
        entry["served_at"] = entry["started_at"]
        for k in ("reup_at", "reason", "stopped_at", "start_failed_at"):  # a running stack carries no stop reason from before
            entry.pop(k, None)
        write_entry(entry)
    health = {}
    for svc, body in healthy.items():
        try:
            health[svc] = json.loads(body)
        except ValueError:
            health[svc] = body
    return {"tag": tag, "url": origins["api"], "urls": origins, "public_urls": public, "port": port, "health": health,
            "retain_days": RETAIN_SECS // 86400, "keys": keys}


def settle_failed_start(entry: dict[str, Any]) -> str:
    """Under the registry lock: a start whose Workers never answered. A re-up of a stack that already served keeps
    its ports, Serve, files and Durable Object data, stopped: its next request tries the new code again, and an up
    with a fix brings it back. Any other start fails (Serve off, files kept), and gc releases it later."""
    tag = entry["tag"]
    if entry.get("served_at") and (stack_dir(tag) / "run.sh").exists() and serve_on_router(entry):
        # served_at, not the up's re-up mark: the Mac's up-done may have cleared that while this start ran on.
        stop_unit(tag)
        now = int(time.time())
        entry.update({"state": "stopped", "stopped_at": now, "start_failed_at": now, "reason": "the last up did not start; fix it and run up again"})
        entry.pop("reup_at", None)
    else:
        stop_stack(tag, keep_files=True)
        entry["state"] = "failed"
    write_entry(entry)
    return entry["state"]


def publish(ports: list[int], wrangler_port: int) -> bool:
    """Publish every port of the stack on the tailnet, to the router (ROUTER_TARGET, which proxies to wrangler on
    wrangler_port by the client's Host and wakes a stopped stack), under the classic daemon's Serve lock and
    holding nothing else. A port still on wrangler directly (a stack from before the router) moves. False
    (nothing changed) when a classic stack took one of them while this one booted."""
    own = (None, ROUTER_TARGET, f"http://127.0.0.1:{wrangler_port}")
    if systemctl("is-active", "--quiet", f"{UNIT_PREFIX}-router.service", check=False).returncode != 0:
        systemctl("start", f"{UNIT_PREFIX}-router.service", check=False)
        if systemctl("is-active", "--quiet", f"{UNIT_PREFIX}-router.service", check=False).returncode != 0:
            raise Refused(f"{UNIT_PREFIX}-router.service is not running (journalctl -u {UNIT_PREFIX}-router); the stack would be unreachable")
    with serve_lock():
        cfg = serve_config()
        if any(port in classic_ports() or serve_target(cfg, port) not in own for port in ports):
            return False
        for port in ports:
            if serve_target(cfg, port) != ROUTER_TARGET:
                out = subprocess.run(["sudo", "-n", "tailscale", "serve", "--bg", "--yes", f"--https={port}", ROUTER_TARGET], capture_output=True, text=True, timeout=60)
                if out.returncode != 0:
                    raise Refused(f"tailscale serve --https={port} failed: {(out.stderr or out.stdout).strip()[-400:]}")
    return True


def render_run_sh(d: Path, path: str, port: int, commit: str, wrangler: Path, configs: list[str]) -> str:
    lines = ["#!/bin/bash", "# Generated by vm_stack.py start; the unit cmux-wdev@<tag> runs it.", "set -euo pipefail",
             # The stack user owns its log (a systemd append: target would be root's), so start and the
             # reaper can truncate it.
             f'exec >>"{d}/logs/wrangler.log" 2>&1',
             f"export PATH={path}", "export WRANGLER_SEND_METRICS=false CI=1 NO_COLOR=1 FORCE_COLOR=0",
             f"export WRANGLER_LOG_PATH={d}/logs/wrangler-debug", f"export HOME={d}/home"]
    # Hyperdrive in wrangler dev connects straight to the origin; miniflare's local proxy does the TLS
    # upgrade PlanetScale requires when the string asks for it (sslmode=require, ssl-mode=REQUIRED). A
    # binding name applies to every Worker of the session that has it: the API's and the mobile Worker's
    # PS_MYSQL are the same Vitess database, as on the shared dev deployment.
    for kind, bindings, tls in (("pg", ("HYPERDRIVE", "HYPERDRIVE_RO"), ""), ("mysql", ("PS_MYSQL", "PS_MYSQL_RO"), "?ssl-mode=REQUIRED")):
        if (d / "secrets" / f"{kind}.url").exists():
            for b in bindings:
                lines.append(f'export CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_{b}="$(cat {d}/secrets/{kind}.url){tls}"')
    lines.append(f'echo "== wdev start $(date -u +%FT%TZ) port {port} commit {commit}"')
    # No --env: each config is already one environment (flatten_env), and their names differ.
    lines.append("exec " + " ".join([str(wrangler), "dev", *configs,
                                     "--ip", "127.0.0.1", "--port", str(port), "--local-protocol", "http",
                                     "--persist-to", str(d / "state"),
                                     "--show-interactive-dev-session=false", "--inspector-port", "0"]))
    return "\n".join(lines) + "\n"


def own_log(log: Path) -> None:
    """Make the log the stack user's: a log an older unit opened through systemd append: is root's."""
    if log.exists() and log.stat().st_uid != os.getuid():
        subprocess.run(["sudo", "-n", "rm", "-f", str(log)], check=True, timeout=30)
    log.touch()


SECRET_URL = re.compile(r"([a-z][a-z0-9+.-]*://)[^\s:/@]+:[^\s@]+@", re.I)


def redact(text: str, d: Path) -> str:
    """A log tail with the stack's credentials taken out: each stored URL, its password, and any
    user:password@ that looks like one."""
    from urllib.parse import unquote, urlsplit
    for f in sorted((d / "secrets").glob("*.url")) if (d / "secrets").exists() else []:
        try:
            url = f.read_text().strip()
        except OSError:
            continue
        for secret in (url, unquote(urlsplit(url).password or ""), urlsplit(url).password or ""):
            if len(secret) > 8:
                text = text.replace(secret, "<redacted>")
    for secret in host_secret_values():
        text = text.replace(secret, "<redacted>")
    return SECRET_URL.sub(r"\1<redacted>@", text)


def stop_stack(tag: str, keep_files: bool, serve: bool = True) -> list[str]:
    actions = []
    if systemctl("is-active", "--quiet", unit(tag), check=False).returncode == 0 or systemctl("is-failed", "--quiet", unit(tag), check=False).returncode == 0:
        systemctl("stop", unit(tag), check=False)
        systemctl("reset-failed", unit(tag), check=False)
        actions.append("unit stopped")
    entry = read_entry(tag) or {}
    port = entry.get("port")
    ports = [p for p in entry_ports(entry) if p not in ports_held(tag)]
    if serve and port and ports:
        with serve_lock():
            cfg = serve_config()
            for p in ports:
                if serve_target(cfg, p) in (ROUTER_TARGET, f"http://127.0.0.1:{port}"):  # ours only, never a classic stack's
                    subprocess.run(["sudo", "-n", "tailscale", "serve", f"--https={p}", "off"], capture_output=True, text=True, timeout=60)
                    actions.append(f"serve :{p} off")
    if not keep_files and stack_dir(tag).exists():
        shutil.rmtree(stack_dir(tag), ignore_errors=True)
        actions.append("stack dir removed")
    return actions


def cmd_down(args) -> dict[str, Any]:
    """Stop and delete one stack; returns its registry entry (database credential and branch names, no
    values) for the Mac to delete them, then `forget` drops the entry."""
    tag = check_tag(args.tag)
    entry = read_entry(tag)
    if not entry:
        return {"tag": tag, "state": "absent", "actions": []}
    with registry_lock():
        actions = stop_stack(tag, keep_files=False)
        entry = read_entry(tag) or entry
        # down is its own release claim: no gc releases this entry while the Mac deletes its databases.
        now = int(time.time())
        entry.update({"state": "releasing", "down_at": now, "releasing_at": now, "reason": args.reason})
        write_entry(entry)
    return {**entry, "actions": actions}


def claimable(entry: dict[str, Any], now: int) -> bool:
    """Whether a gc may release this entry's credentials and branch now."""
    state = entry.get("state")
    if state in ("reaped", "down"):
        return True
    if state == "failed":
        return now - entry.get("last_up_at", now) > 3600
    if state == "releasing":  # a claim whose gc died
        return now - entry.get("releasing_at", now) > RELEASE_CLAIM_SECS
    return False


def cmd_claim_release(args) -> dict[str, Any]:
    """A gc's claim on a stopped stack, taken under the registry lock before any branch or credential is
    deleted: an up of the same tag in between makes the entry unclaimable (prepare refuses a claimed
    one), so a branch is never deleted under an up that reuses it."""
    tag = check_tag(args.tag)
    now = int(time.time())
    with registry_lock():
        entry = read_entry(tag)
        if not entry or not claimable(entry, now):
            raise Refused(f"{tag} is {(entry or {}).get('state', 'absent')}; not released")
        stop_stack(tag, keep_files=False)
        entry.update({"state": "releasing", "releasing_at": now})
        write_entry(entry)
    return entry


def cmd_forget(args) -> dict[str, Any]:
    tag = check_tag(args.tag)
    entry = read_entry(tag)
    with registry_lock():
        entry = read_entry(tag)
        if entry and entry.get("state") not in ("releasing", "down", "reaped", "failed"):
            raise Refused(f"{tag} is {entry['state']}; run down first")
        if entry:
            stop_stack(tag, keep_files=False)  # a failed stack's files, if the reaper has not cleaned them yet
        forget_entry(tag)
    return {"tag": tag, "forgotten": bool(entry)}


def scan_requests(entry: dict[str, Any]) -> None:
    """Advance last_request_at when wrangler logged a request since the last pass."""
    log = stack_dir(entry["tag"]) / "logs/wrangler.log"
    if not log.exists():
        return
    size = log.stat().st_size
    offset = entry.get("log_offset", 0)
    if size < offset:
        offset = 0
    if size > offset:
        with open(log, "rb") as f:
            f.seek(offset)
            chunk = f.read(size - offset)
        if REQUEST_LINE.search(chunk):
            entry["last_request_at"] = int(time.time())
        entry["log_offset"] = size
    if size > LOG_MAX_BYTES:
        log.write_bytes(b"")
        entry["log_offset"] = 0


def idle_verdict(entry: dict[str, Any], now: int, heartbeat: float | None, active: bool) -> tuple[str, str] | None:
    """What the reaper does with a running stack now, and why: ("release", why) past its retention, ("stop", why)
    when its unit is gone (a crash, a VM reboot) or it sat idle; None to leave it running."""
    retain = entry.get("retain_secs", RETAIN_SECS)
    if now - entry.get("last_up_at", now) > retain:
        return "release", f"{retain // 86400} d since the last up (retention)"
    if not active:
        return "stop", "unit not running (crashed or VM reboot); wakes on its next request"
    last = max(entry.get("last_request_at", 0), int(heartbeat or 0), entry.get("started_at", 0))
    if now - last > entry.get("idle_secs", IDLE_SECS_DEFAULT):
        return "stop", f"idle {(now - last) // 60} min (limit {entry.get('idle_secs', IDLE_SECS_DEFAULT) // 60}); wakes on its next request"
    return None


def reap_one(tag: str, now: int) -> dict[str, Any] | None:
    """One entry, decided and acted on under the registry lock, so an up that starts meanwhile (prepare
    marks it preparing with a fresh last_up_at) is never cleaned up under it."""
    with registry_lock():
        entry = read_entry(tag)
        if not entry:
            return None
        state = entry.get("state")
        if state in ("down", "reaped", "failed", "releasing"):
            since = entry.get("down_at") or entry.get("reaped_at") or entry.get("releasing_at") or entry.get("last_up_at") or now
            if now - since > REAPED_KEEP_SECS:
                stop_stack(tag, keep_files=False)
                forget_entry(tag)
                return {"tag": tag, "action": "purged old entry"}
            if state == "failed" and not entry.get("cleaned") and now - entry.get("last_up_at", now) > 3600:
                steps = stop_stack(tag, keep_files=False)
                entry.update({"cleaned": True, "port": None, "ports": []})  # its ports go back to the pool
                write_entry(entry)
                return {"tag": tag, "action": "cleaned failed stack", "steps": steps}
            return None
        if state == "stopped":
            if up_in_progress(entry, now):
                return None  # a re-up is syncing into it: never released under it
            retain = entry.get("retain_secs", RETAIN_SECS)
            if now - entry.get("last_up_at", now) > retain:
                steps = release(entry, now, f"{retain // 86400} d since the last up (retention)")
                return {"tag": tag, "action": "released", "reason": entry["reason"], "steps": steps}
            return None
        if state == "starting" and entry.get("wake_started_at"):
            if not wake_is_stale(entry, now):
                return None  # a wake in progress
            park(entry, now, "a wake died before the stack answered; it wakes on its next request")
            return {"tag": tag, "action": "stopped", "reason": entry["reason"]}
        if state == "starting" and entry.get("reup_at") and (stack_dir(tag) / "run.sh").exists():
            if now - entry["reup_at"] < 1800:
                return None  # a re-up of a stopped stack in progress
            park(entry, now, "a re-up never finished; it wakes on its next request")
            return {"tag": tag, "action": "stopped", "reason": entry["reason"]}
        if state != "running":
            if now - entry.get("last_up_at", entry.get("created_at", now)) < 1800:
                return None  # an up in progress
            verdict = ("release", "never started")
        elif entry.get("reup_at") and now - entry["reup_at"] < 1800:
            return None  # a re-up in progress restarts the unit; it is not a crash
        elif not serve_on_router(entry):
            # A stack from before the router: its ports still go straight to wrangler, so it could never wake.
            # It keeps running until idle, then it is released as before.
            scan_requests(entry)
            write_entry(entry)
            hb = stack_dir(tag) / "heartbeat"
            verdict = idle_verdict(entry, now, hb.stat().st_mtime if hb.exists() else None, unit_active(tag))
            verdict = verdict and ("release", verdict[1].replace("; wakes on its next request", " (a stack from before the router)"))
        else:
            scan_requests(entry)
            write_entry(entry)
            hb = stack_dir(tag) / "heartbeat"
            verdict = idle_verdict(entry, now, hb.stat().st_mtime if hb.exists() else None, unit_active(tag))
        if not verdict:
            return None
        action, reason = verdict
        if action == "stop":
            park(entry, now, reason)
            print(f"stopped {tag}: {reason}", file=sys.stderr)
            return {"tag": tag, "action": "stopped", "reason": reason}
        steps = release(entry, now, reason)
        print(f"released {tag}: {reason}", file=sys.stderr)
        return {"tag": tag, "action": "released", "reason": reason, "steps": steps}


def serve_on_router(entry: dict[str, Any]) -> bool:
    """Whether the stack's tailnet ports go to the router (so a request can wake it). True when Serve cannot be
    read: the reaper then stops rather than releases."""
    try:
        cfg = serve_config()
    except Refused:
        return True
    return all(serve_target(cfg, p) in (None, ROUTER_TARGET) for p in entry_ports(entry))


def trim_kept(now: int) -> list[dict[str, Any]]:
    """Release the least recently used stopped stacks beyond MAX_KEPT, and while free disk is under its floor."""
    out = []
    with registry_lock():
        while True:
            stopped = sorted((e for e in all_entries() if e.get("state") == "stopped" and not up_in_progress(e, now)), key=last_activity)
            if not stopped or (len(stopped) <= MAX_KEPT and disk_free_gib() >= MIN_DISK_GIB):
                return out
            if len(stopped) <= MAX_KEPT and disk_free_gib() + sum(dir_gib(stack_dir(e["tag"])) for e in stopped) < MIN_DISK_GIB:
                return out  # releasing every stopped stack would not lift disk over its floor: release none
            victim = stopped[0]
            why = f"more than {MAX_KEPT} stopped stacks" if len(stopped) > MAX_KEPT else f"free disk under {MIN_DISK_GIB} GiB"
            release(victim, now, f"released: {why} (least recently used)")
            out.append({"tag": victim["tag"], "action": "released", "reason": victim["reason"]})


def cmd_reap(_args) -> dict[str, Any]:
    now = int(time.time())
    out = []
    for e in all_entries():
        try:  # one stack's error never ends the pass for the others
            r = reap_one(e["tag"], now)
        except Exception as err:  # noqa: BLE001
            r = {"tag": e["tag"], "action": "error", "error": f"{type(err).__name__}: {err}"[:300]}
            print(f"reap {e['tag']}: {r['error']}", file=sys.stderr)
        if r:
            out.append(r)
    try:
        out += trim_kept(now)
    except Exception as err:  # noqa: BLE001
        print(f"reap trim: {type(err).__name__}: {err}"[:300], file=sys.stderr)
    return {"reaped": out}


CRED_MARGIN_SECS = 15 * 60


def cred_fresh(entry: dict[str, Any], kind: str, mode: str, file_present: bool, now: float) -> bool:
    """Whether an up may keep the stack's credential: same mode, its file still on the VM (a release deletes
    it), and valid past the retention this up starts (RETAIN_SECS from now) plus a margin, so a stopped stack
    that wakes days later never runs on an expired credential."""
    import datetime
    c = (entry.get("db") or {}).get(kind) or {}
    exp = c.get("expires_at") or ""
    if not (file_present and c.get("mode") == mode and exp):
        return False
    try:
        expires = datetime.datetime.fromisoformat(exp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return False
    return expires > now + RETAIN_SECS + CRED_MARGIN_SECS


def cmd_cred_fresh(args) -> dict[str, Any]:
    tag = check_tag(args.tag)
    entry = read_entry(tag) or {}
    fresh = cred_fresh(entry, args.kind, args.mode, (stack_dir(tag) / "secrets" / f"{args.kind}.url").exists(), time.time())
    return {"fresh": fresh}


def cmd_ledger(args) -> dict[str, Any]:
    if args.drop:
        with registry_lock():
            ledger_drop(args.drop)
    return {"branches": ledger()}


def cmd_touch(args) -> dict[str, Any]:
    tag = check_tag(args.tag)
    hb = stack_dir(tag) / "heartbeat"
    if not hb.parent.exists():
        raise Refused(f"no stack {tag}")
    hb.touch()
    return {"tag": tag, "touched": int(time.time())}


def cmd_status(args) -> dict[str, Any]:
    now = int(time.time())
    rows = []
    for e in all_entries():
        if args.tag and e["tag"] != args.tag:
            continue
        hb = stack_dir(e["tag"]) / "heartbeat"
        last = max(e.get("last_request_at", 0), int(hb.stat().st_mtime) if hb.exists() else 0, e.get("started_at", 0))
        rows.append({k: e.get(k) for k in ("tag", "state", "url", "urls", "public_urls", "slot", "port", "ports", "commit", "dirty", "platform", "reason", "last_up_at", "reup_at", "releasing_at")}
                    | {"active": unit_active(e["tag"]) if e.get("state") == "running" else False,
                       "idle_min": (now - last) // 60 if last else None, "idle_limit_min": e.get("idle_secs", IDLE_SECS_DEFAULT) // 60,
                       "mem_mib": unit_memory_mib(e["tag"]) if e.get("state") == "running" else None,
                       "secrets": {k: (stack_dir(e["tag"]) / "secrets" / f"{k}.url").exists() for k in (e.get("db") or {})},
                       "db": {k: {kk: v.get(kk) for kk in ("mode", "database", "branch", "cred_id", "cred_name", "expires_at")} for k, v in (e.get("db") or {}).items()}})
    return {"capacity": cmd_capacity(None), "stacks": rows}


def cmd_logs(args) -> dict[str, Any]:
    d = stack_dir(check_tag(args.tag))
    log = d / "logs/wrangler.log"
    text = log.read_text(errors="replace") if log.exists() else ""
    sys.stdout.write(redact("\n".join(text.splitlines()[-args.lines:]), d) + "\n")
    return {}


def main() -> int:
    p = argparse.ArgumentParser(prog="vm_stack.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install")
    sub.add_parser("capacity")
    sub.add_parser("reap")
    s = sub.add_parser("status"); s.add_argument("--tag")
    for name in ("prepare", "touch", "forget"):
        s = sub.add_parser(name); s.add_argument("--tag", required=True)
    s = sub.add_parser("prune"); s.add_argument("--tag", required=True); s.add_argument("--tree", choices=("src", "platform"), default="src")
    s = sub.add_parser("put-cred"); s.add_argument("--tag", required=True); s.add_argument("--kind", choices=("pg", "mysql", "mysql-parent"), required=True)
    s.add_argument("--db-name", required=True); s.add_argument("--branch", required=True); s.add_argument("--database", default="")
    s.add_argument("--mode", choices=("shared", "branch"), required=True)
    s = sub.add_parser("migrate"); s.add_argument("--tag", required=True)
    s = sub.add_parser("start"); s.add_argument("--tag", required=True); s.add_argument("--platform", action="store_true")
    s.add_argument("--commit", default=""); s.add_argument("--dirty", action="store_true"); s.add_argument("--idle", type=int, default=0)
    s.add_argument("--wait", type=int, default=240)
    s = sub.add_parser("down"); s.add_argument("--tag", required=True); s.add_argument("--reason", default="down")
    s = sub.add_parser("claim-release"); s.add_argument("--tag", required=True)
    s = sub.add_parser("stop"); s.add_argument("--tag", required=True)
    sub.add_parser("put-public")
    sub.add_parser("put-turn")
    sub.add_parser("turn-status")
    s = sub.add_parser("wake"); s.add_argument("--tag", required=True); s.add_argument("--wait", type=int, default=150)
    s = sub.add_parser("up-done"); s.add_argument("--tag", required=True); s.add_argument("--token", required=True); s.add_argument("--failed", action="store_true")
    s = sub.add_parser("cred-fresh"); s.add_argument("--tag", required=True); s.add_argument("--kind", required=True); s.add_argument("--mode", required=True)
    s = sub.add_parser("ledger"); s.add_argument("--drop", action="append", default=[])
    s = sub.add_parser("logs"); s.add_argument("--tag", required=True); s.add_argument("-n", "--lines", type=int, default=80)
    args = p.parse_args()
    handlers = {"install": lambda a: install_host(), "capacity": cmd_capacity, "reap": cmd_reap, "status": cmd_status,
                "prepare": cmd_prepare, "touch": cmd_touch, "forget": cmd_forget, "prune": cmd_prune, "put-cred": cmd_put_cred,
                "migrate": cmd_migrate, "start": cmd_start, "down": cmd_down, "logs": cmd_logs,
                "claim-release": cmd_claim_release, "up-done": cmd_up_done, "wake": cmd_wake, "stop": cmd_stop, "put-public": cmd_put_public, "cred-fresh": cmd_cred_fresh, "ledger": cmd_ledger,
                "put-turn": cmd_put_turn, "turn-status": cmd_turn_status}
    try:
        result = handlers[args.cmd](args)
    except Refused as e:
        print(f"vm_stack {args.cmd}: {e}", file=sys.stderr)
        return 3
    if result:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
