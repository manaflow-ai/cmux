#!/usr/bin/env python3
"""The VM side of scripts/cmux-next/cloud-dev-stack.sh: one `wrangler dev` (workerd, local Durable
Objects) per tag on the dev-backend host, published on a tailnet-only HTTPS port.

The Mac side copies this file to <base>/bin/vm_stack.py and runs it over SSH; it never runs on a Mac.
Standard library only (the host has python3, and node/bun live in <base>/tools).

Layout under <base> (default /srv/cmux-dev/wrangler, beside hq's classic Docker stacks in /srv/cmux-dev):
  registry/<tag>.json   the per-tag registry entry (port, url, state, database credentials' ids, never values)
  stacks/<tag>/         src/ (the agent's backend tree), platform/ (optional), state/ (wrangler --persist-to),
                        secrets/ (0700: jwt.jwk, pg.url, mysql.url), logs/wrangler.log, run.sh
  tools/                node and bun, one pinned version each
Units: cmux-wdev@<tag>.service runs stacks/<tag>/run.sh; cmux-wdev-reaper.timer runs `reap` every 5 minutes.

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
import subprocess
import sys
import time
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
# Memory and disk a stack that is preparing or starting will take once it runs (measured 1.5-1.9 GiB).
PENDING_MEM_GIB = 2.0
PENDING_DISK_GIB = 2.0
# Idle: no request reached the stack (wrangler's request log lines) and no `up`/`touch` for this long.
IDLE_SECS_DEFAULT = int(os.environ.get("CMUX_WDEV_IDLE_SECS", str(2 * 3600)))
# Hard cap from the last `up`; the database credentials' TTL is this plus an hour.
MAX_SECS = int(os.environ.get("CMUX_WDEV_MAX_SECS", str(12 * 3600)))
MAX_STACKS = int(os.environ.get("CMUX_WDEV_MAX_STACKS", "16"))
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


def pick_port(tag: str, previous: int | None, taken_by_us: set[int], classic: set[int], serve: dict[str, Any], listening: set[int]) -> int:
    """Our previous port when it is still ours, else the highest port free on every account."""
    own_target = lambda p: f"http://127.0.0.1:{p}"
    if previous and previous not in classic and previous not in taken_by_us and serve_target(serve, previous) in (None, own_target(previous)):
        return previous
    serve_ports = {int(k) for k in (serve.get("TCP") or {}).keys() if str(k).isdigit()}
    for port in range(PORT_MAX, PORT_MIN - 1, -1):
        if port in classic or port in serve_ports or port in listening or port in taken_by_us:
            continue
        return port
    raise Refused(f"no free port in {PORT_MIN}-{PORT_MAX}")


HOLDS_PORT = ("preparing", "starting", "running", "failed")


def ports_held(except_tag: str) -> set[int]:
    """Ports of our other stacks that are not gone: a starting stack is not listening yet, a failed one
    keeps its port for its next up."""
    return {e["port"] for e in all_entries() if e["tag"] != except_tag and e.get("state") in HOLDS_PORT and e.get("port")}


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
RuntimeMaxSec={max_secs}
MemoryMax=4G
MemorySwapMax=0
CPUQuota=400%
TasksMax=4096
KillMode=control-group
TimeoutStopSec=20
Nice=5
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
        f"/etc/systemd/system/{UNIT_PREFIX}@.service": UNIT_TEMPLATE.format(user=user, base=BASE, max_secs=MAX_SECS + 600),
        f"/etc/systemd/system/{UNIT_PREFIX}-reaper.service": REAPER_SERVICE.format(user=user, base=BASE),
        f"/etc/systemd/system/{UNIT_PREFIX}-reaper.timer": REAPER_TIMER,
    }
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
    return {"units_changed": changed, **ensure_tools()}


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


def render_api_config(cfg: dict[str, Any], tag: str, origin: str, with_platform: bool) -> dict[str, Any]:
    """The API's development env for local workerd: same code, vars, DOs, workflows, R2 (local) and
    Hyperdrive (local connection strings from run.sh). Bindings that only exist remotely go: the AI
    binding, and the platform service and its cross-script CLOUD_DO unless the platform runs in the
    same session (--platform-checkout), where the names resolve to it."""
    cfg = json.loads(json.dumps(cfg))
    dev = cfg["env"]["development"]
    dev.pop("ai", None)
    dev.pop("routes", None)
    dev.pop("triggers", None)  # wrangler dev never runs crons; keep the shared dev schedule out of it
    vars_ = dev.setdefault("vars", {})
    vars_.update({"CLOUD_API_ORIGIN": origin, "WDEV_TAG": tag})
    if not with_platform:
        dev.pop("services", None)
        dev["durable_objects"]["bindings"] = [b for b in dev["durable_objects"]["bindings"] if b.get("script_name") != PLATFORM_DEV_NAME]
    return cfg


def render_platform_config(cfg: dict[str, Any], origin: str) -> dict[str, Any]:
    cfg = json.loads(json.dumps(cfg))
    dev = cfg["env"]["development"]
    dev.pop("routes", None)
    dev.pop("triggers", None)
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
    return cfg


# ---------------------------------------------------------------- commands

def cmd_capacity(_args) -> dict[str, Any]:
    entries = all_entries()
    running = [e for e in entries if e.get("state") == "running"]
    return {
        "mem_available_gib": round(mem_available_gib(), 1),
        "disk_free_gib": round(disk_free_gib(), 1),
        "stacks_running": len(running),
        "max_stacks": MAX_STACKS,
        "max_secs": MAX_SECS,
        "min_mem_gib": MIN_MEM_GIB,
        "min_disk_gib": MIN_DISK_GIB,
        "classic_registered": len(classic_ports()),
    }


def admit(tag: str) -> None:
    """Called under the registry lock, which also records the caller as preparing or starting, so two
    ups at once are counted against each other. A stack that is preparing or starting has not taken its
    memory yet: it is reserved here, beside the floor."""
    others = [e for e in all_entries() if e["tag"] != tag and e.get("state") in ("preparing", "starting", "running")]
    pending = sum(1 for e in others if e.get("state") != "running")
    if len(others) >= MAX_STACKS:
        raise Refused(f"{len(others)} stacks running or starting (max {MAX_STACKS}); `cloud-dev-stack.sh status` lists them")
    mem, disk = mem_available_gib(), disk_free_gib()
    need_mem = MIN_MEM_GIB + PENDING_MEM_GIB * (pending + 1)
    if mem < need_mem:
        raise Refused(f"MemAvailable {mem:.1f} GiB < {need_mem:.1f} GiB ({MIN_MEM_GIB} floor + {PENDING_MEM_GIB} for this and each of {pending} starting stacks; the classic stacks keep a 16 GiB floor)")
    need_disk = MIN_DISK_GIB + PENDING_DISK_GIB * (pending + 1)
    if disk < need_disk:
        raise Refused(f"free disk {disk:.1f} GiB < {need_disk:.1f} GiB (the classic GC starts purging at 100)")


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
        if state == "running":
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
            entry.update({"state": "preparing", "last_up_at": now})
        entry.update({"up_token": token, "up_started": now})
        write_entry(entry)
    (d / "heartbeat").touch()
    return {"dir": str(d), "state": entry["state"], "token": token}


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


def cmd_start(args) -> dict[str, Any]:
    tag = check_tag(args.tag)
    d = stack_dir(tag)
    path = tool_path()
    env = {**os.environ, "PATH": path, "BUN_INSTALL_CACHE_DIR": str(BASE / "cache/bun")}
    api_dir = d / "src/backend/apps/api"
    if not (api_dir / "wrangler.jsonc").exists():
        raise Refused(f"{api_dir}/wrangler.jsonc missing: sync the worktree first")
    with_platform = bool(args.platform)
    run_quiet(["bun", "install", "--frozen-lockfile"], d / "src/backend", env, "bun install (backend)")
    if with_platform:
        run_quiet(["bun", "install", "--frozen-lockfile"], d / "platform", env, "bun install (platform)")

    with registry_lock():
        entry = read_entry(tag) or {"tag": tag, "created_at": int(time.time())}
        if entry.get("state") != "running":
            admit(tag)
        taken = ports_held(tag)
        with serve_lock():
            port = pick_port(tag, entry.get("port"), taken, classic_ports(), serve_config(), listening_ports() - ({entry["port"]} if entry.get("port") and unit_active(tag) else set()))
        host = dns_name()
        origin = f"https://{host}:{port}"
        entry.update({"port": port, "url": origin, "state": "starting", "host": host, "platform": with_platform,
                      "commit": args.commit, "dirty": bool(args.dirty), "idle_secs": args.idle or IDLE_SECS_DEFAULT,
                      "max_secs": MAX_SECS, "last_up_at": int(time.time())})
        write_entry(entry)

    api_cfg = render_api_config(load_jsonc(api_dir / "wrangler.jsonc"), tag, origin, with_platform)
    (api_dir / "wrangler.wdev.generated.jsonc").write_text(json.dumps(api_cfg, indent=1))
    configs = ["-c", str(api_dir / "wrangler.wdev.generated.jsonc")]
    if with_platform:
        pcfg = render_platform_config(load_jsonc(d / "platform/wrangler.jsonc"), origin)
        (d / "platform/wrangler.wdev.generated.jsonc").write_text(json.dumps(pcfg, indent=1))
        configs += ["-c", str(d / "platform/wrangler.wdev.generated.jsonc")]

    jwk = ensure_jwk(d, tag, env)
    # dotenv: a single-quoted value is literal (the JWK's double quotes stay as they are).
    # The platform verifies the API's install tokens with the same key outside production (its
    # CallerAuth.ts), so each Worker of the session reads it from a .dev.vars beside its config.
    for project in [api_dir] + ([d / "platform"] if with_platform else []):
        write_private(project / ".dev.vars", f"JWT_PRIVATE_JWK='{jwk}'\n")
    wrangler = api_dir / "node_modules/.bin/wrangler"
    if with_platform and wrangler_version(d / "platform") > wrangler_version(api_dir):
        # One workerd runs both Workers, so it must know the newer compatibility date of the two.
        wrangler = d / "platform/node_modules/.bin/wrangler"
    run_sh = render_run_sh(d, path, port, args.commit, wrangler, configs)
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
    ok, last = False, ""
    while time.time() < deadline:
        if not unit_active(tag):
            break
        if log.exists():  # wrangler keeps running after a failed build, waiting for a file change
            with open(log, "rb") as f:
                f.seek(log_start)
                if b"Build failed" in f.read():
                    last = "build failed"
                    break
        try:
            with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/health", timeout=5) as r:
                body = r.read().decode()
                last = body[:400]
                ok = r.status == 200
                if ok:
                    break
        except Exception as e:  # noqa: BLE001 - still booting
            last = str(e)
        time.sleep(2)
    if not ok:
        tail = redact(log.read_text(errors="replace")[-4000:], d) if log.exists() else ""
        stop_stack(tag, keep_files=True)
        with registry_lock():
            entry = read_entry(tag) or entry
            entry["state"] = "failed"
            write_entry(entry)
        raise Refused(f"wrangler dev did not answer /v1/health on 127.0.0.1:{port} ({last})\n--- log tail ---\n{tail}")

    if not publish(port):
        # Outside the Serve lock: every path takes the registry lock before the Serve lock, never after.
        stop_stack(tag, keep_files=True, serve=False)
        with registry_lock():
            entry = read_entry(tag) or entry
            entry.update({"state": "failed", "port": None})
            write_entry(entry)
        raise Refused(f"port {port} was taken by a classic stack while this one booted; run up again for another port")
    with registry_lock():
        entry = read_entry(tag) or entry
        entry.update({"state": "running", "started_at": int(time.time()), "log_offset": log.stat().st_size if log.exists() else 0,
                      "last_request_at": int(time.time())})
        entry.pop("reup_at", None)
        write_entry(entry)
    try:
        health = json.loads(body)
    except ValueError:
        health = last
    return {"tag": tag, "url": origin, "port": port, "health": health}


def publish(port: int) -> bool:
    """Publish 127.0.0.1:port on the tailnet, under the classic daemon's Serve lock and holding nothing
    else. False (nothing changed) when a classic stack took the port while this one booted."""
    target = f"http://127.0.0.1:{port}"
    with serve_lock():
        current = serve_target(serve_config(), port)
        if port in classic_ports() or current not in (None, target):
            return False
        if current != target:
            out = subprocess.run(["sudo", "-n", "tailscale", "serve", "--bg", "--yes", f"--https={port}", target], capture_output=True, text=True, timeout=60)
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
    # upgrade PlanetScale requires when the string asks for it (sslmode=require, ssl-mode=REQUIRED).
    for kind, bindings, tls in (("pg", ("HYPERDRIVE", "HYPERDRIVE_RO"), ""), ("mysql", ("PS_MYSQL", "PS_MYSQL_RO"), "?ssl-mode=REQUIRED")):
        if (d / "secrets" / f"{kind}.url").exists():
            for b in bindings:
                lines.append(f'export CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_{b}="$(cat {d}/secrets/{kind}.url){tls}"')
    lines.append(f'echo "== wdev start $(date -u +%FT%TZ) port {port} commit {commit}"')
    lines.append("exec " + " ".join([str(wrangler), "dev", *configs, "--env", "development",
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
    return SECRET_URL.sub(r"\1<redacted>@", text)


def stop_stack(tag: str, keep_files: bool, serve: bool = True) -> list[str]:
    actions = []
    if systemctl("is-active", "--quiet", unit(tag), check=False).returncode == 0 or systemctl("is-failed", "--quiet", unit(tag), check=False).returncode == 0:
        systemctl("stop", unit(tag), check=False)
        systemctl("reset-failed", unit(tag), check=False)
        actions.append("unit stopped")
    entry = read_entry(tag) or {}
    port = entry.get("port")
    if serve and port and port not in ports_held(tag):
        with serve_lock():
            if serve_target(serve_config(), port) == f"http://127.0.0.1:{port}":  # ours only, never a classic stack's
                subprocess.run(["sudo", "-n", "tailscale", "serve", f"--https={port}", "off"], capture_output=True, text=True, timeout=60)
                actions.append(f"serve :{port} off")
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
        entry_path(tag).unlink(missing_ok=True)
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


def idle_verdict(entry: dict[str, Any], now: int, heartbeat: float | None, active: bool) -> str | None:
    """Why a running stack should stop now, or None."""
    if not active:
        return "unit not running (crashed, VM reboot or hard cap)"
    if now - entry.get("last_up_at", now) > entry.get("max_secs", MAX_SECS):
        return f"older than {entry.get('max_secs', MAX_SECS) // 3600} h since the last up"
    last = max(entry.get("last_request_at", 0), int(heartbeat or 0), entry.get("started_at", 0))
    if now - last > entry.get("idle_secs", IDLE_SECS_DEFAULT):
        return f"idle {(now - last) // 60} min (limit {entry.get('idle_secs', IDLE_SECS_DEFAULT) // 60})"
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
                entry_path(tag).unlink(missing_ok=True)
                return {"tag": tag, "action": "purged old entry"}
            if state == "failed" and not entry.get("cleaned") and now - entry.get("last_up_at", now) > 3600:
                steps = stop_stack(tag, keep_files=False)
                entry.update({"cleaned": True, "port": None})  # its port goes back to the pool
                write_entry(entry)
                return {"tag": tag, "action": "cleaned failed stack", "steps": steps}
            return None
        if state != "running":
            if now - entry.get("last_up_at", entry.get("created_at", now)) < 1800:
                return None  # an up in progress
            reason = "never started"
        elif entry.get("reup_at") and now - entry["reup_at"] < 1800:
            return None  # a re-up in progress restarts the unit; it is not a crash
        else:
            scan_requests(entry)
            write_entry(entry)
            hb = stack_dir(tag) / "heartbeat"
            reason = idle_verdict(entry, now, hb.stat().st_mtime if hb.exists() else None, unit_active(tag))
        if not reason:
            return None
        steps = stop_stack(tag, keep_files=False)
        entry.update({"state": "reaped", "reaped_at": now, "reason": reason})
        write_entry(entry)
        print(f"reaped {tag}: {reason}", file=sys.stderr)
        return {"tag": tag, "action": "reaped", "reason": reason, "steps": steps}


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
    return {"reaped": out}


CRED_MARGIN_SECS = 15 * 60


def cred_fresh(entry: dict[str, Any], kind: str, mode: str, file_present: bool, now: float) -> bool:
    """Whether an up may keep the stack's credential: same mode, its file still on the VM (a reap deletes
    it), and valid past the hard cap this up starts (MAX_SECS from now) plus a margin."""
    import datetime
    c = (entry.get("db") or {}).get(kind) or {}
    exp = c.get("expires_at") or ""
    if not (file_present and c.get("mode") == mode and exp):
        return False
    try:
        expires = datetime.datetime.fromisoformat(exp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return False
    return expires > now + MAX_SECS + CRED_MARGIN_SECS


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
        rows.append({k: e.get(k) for k in ("tag", "state", "url", "port", "commit", "dirty", "platform", "reason", "last_up_at", "reup_at", "releasing_at")}
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
    s = sub.add_parser("up-done"); s.add_argument("--tag", required=True); s.add_argument("--token", required=True); s.add_argument("--failed", action="store_true")
    s = sub.add_parser("cred-fresh"); s.add_argument("--tag", required=True); s.add_argument("--kind", required=True); s.add_argument("--mode", required=True)
    s = sub.add_parser("ledger"); s.add_argument("--drop", action="append", default=[])
    s = sub.add_parser("logs"); s.add_argument("--tag", required=True); s.add_argument("-n", "--lines", type=int, default=80)
    args = p.parse_args()
    handlers = {"install": lambda a: install_host(), "capacity": cmd_capacity, "reap": cmd_reap, "status": cmd_status,
                "prepare": cmd_prepare, "touch": cmd_touch, "forget": cmd_forget, "prune": cmd_prune, "put-cred": cmd_put_cred,
                "migrate": cmd_migrate, "start": cmd_start, "down": cmd_down, "logs": cmd_logs,
                "claim-release": cmd_claim_release, "up-done": cmd_up_done, "cred-fresh": cmd_cred_fresh, "ledger": cmd_ledger}
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
