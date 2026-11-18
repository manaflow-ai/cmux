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
NODE_MAJOR = "24"
BUN_VERSION = "1.4.4"
# Idle: no request reached the stack (wrangler's request log lines) and no `up`/`touch` for this long.
IDLE_SECS_DEFAULT = int(os.environ.get("CMUX_WDEV_IDLE_SECS", str(2 * 3600)))
# Hard cap from the last `up`; the database credentials' TTL is this plus an hour.
MAX_SECS = int(os.environ.get("CMUX_WDEV_MAX_SECS", str(12 * 3600)))
MAX_STACKS = int(os.environ.get("CMUX_WDEV_MAX_STACKS", "16"))
MIN_MEM_GIB = float(os.environ.get("CMUX_WDEV_MIN_MEM_GIB", "24"))
MIN_DISK_GIB = float(os.environ.get("CMUX_WDEV_MIN_DISK_GIB", "120"))
REAPED_KEEP_SECS = 7 * 86400
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
    if previous and previous not in classic and serve_target(serve, previous) in (None, own_target(previous)):
        return previous
    serve_ports = {int(k) for k in (serve.get("TCP") or {}).keys() if str(k).isdigit()}
    for port in range(PORT_MAX, PORT_MIN - 1, -1):
        if port in classic or port in serve_ports or port in listening or port in taken_by_us:
            continue
        return port
    raise Refused(f"no free port in {PORT_MIN}-{PORT_MAX}")


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
ExecStart=/bin/bash {base}/stacks/%i/run.sh
StandardOutput=append:{base}/stacks/%i/logs/wrangler.log
StandardError=append:{base}/stacks/%i/logs/wrangler.log
Restart=no
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


def ensure_tools() -> dict[str, str]:
    tools = BASE / "tools"
    nodes = sorted(tools.glob(f"node-v{NODE_MAJOR}.*"))
    if not nodes or not (nodes[-1] / "bin/node").exists():
        with urllib.request.urlopen("https://nodejs.org/dist/index.json", timeout=30) as r:
            version = next(x["version"] for x in json.load(r) if x["version"].startswith(f"v{NODE_MAJOR}."))
        url = f"https://nodejs.org/dist/{version}/node-{version}-linux-x64.tar.xz"
        subprocess.run(f"curl -fsSL {url} | tar -xJ -C {tools} && mv {tools}/node-{version}-linux-x64 {tools}/node-{version}", shell=True, check=True)
        nodes = [tools / f"node-{version}"]
    bun = tools / f"bun-{BUN_VERSION}" / "bun"
    if not bun.exists():
        url = f"https://github.com/oven-sh/bun/releases/download/bun-v{BUN_VERSION}/bun-linux-x64.zip"
        tmp = tools / ".bun.zip"
        subprocess.run(["curl", "-fsSL", "-o", str(tmp), url], check=True)
        import zipfile
        with zipfile.ZipFile(tmp) as z:
            data = z.read("bun-linux-x64/bun")
        bun.parent.mkdir(parents=True, exist_ok=True)
        bun.write_bytes(data)
        bun.chmod(0o755)
        tmp.unlink()
    return {"node": str(nodes[-1] / "bin"), "bun": str(bun.parent)}


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
        "min_mem_gib": MIN_MEM_GIB,
        "min_disk_gib": MIN_DISK_GIB,
        "classic_registered": len(classic_ports()),
    }


def admit(tag: str) -> None:
    cap = cmd_capacity(None)
    others = [e for e in all_entries() if e.get("state") == "running" and e["tag"] != tag]
    if len(others) >= MAX_STACKS:
        raise Refused(f"{len(others)} stacks running (max {MAX_STACKS}); `cloud-dev-stack.sh status` lists them")
    if cap["mem_available_gib"] < MIN_MEM_GIB:
        raise Refused(f"MemAvailable {cap['mem_available_gib']} GiB < {MIN_MEM_GIB} GiB (the classic stacks keep a 16 GiB floor)")
    if cap["disk_free_gib"] < MIN_DISK_GIB:
        raise Refused(f"free disk {cap['disk_free_gib']} GiB < {MIN_DISK_GIB} GiB (the classic GC starts purging at 100)")


def cmd_prepare(args) -> dict[str, Any]:
    """Make the stack directory before the Mac rsyncs into it; admission happens here."""
    tag = check_tag(args.tag)
    with registry_lock():
        entry = read_entry(tag)
        if not (entry and entry.get("state") == "running"):
            admit(tag)
        d = stack_dir(tag)
        for sub in ("src", "platform", "state", "logs", "secrets"):
            (d / sub).mkdir(mode=0o700, parents=True, exist_ok=True)
    return {"dir": str(d)}


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
        entry = read_entry(tag) or {"tag": tag, "state": "preparing", "created_at": int(time.time())}
        db = entry.setdefault("db", {})
        db[args.kind] = {"database": args.db_name, "branch": args.branch, "cred_id": raw.get("id"), "cred_name": raw.get("name"),
                         "expires_at": raw.get("expires_at"), "mode": args.mode}
        write_entry(entry)
    return {"stored": args.kind, "cred_id": raw.get("id")}


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
        taken = {e["port"] for e in all_entries() if e["tag"] != tag and e.get("state") == "running" and e.get("port")}
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
    lines = ["#!/bin/bash", "# Generated by vm_stack.py start; the unit cmux-wdev@<tag> runs it.", "set -euo pipefail",
             f"export PATH={path}", "export WRANGLER_SEND_METRICS=false CI=1 NO_COLOR=1 FORCE_COLOR=0",
             f"export WRANGLER_LOG_PATH={d}/logs/wrangler-debug"]
    # Hyperdrive in wrangler dev connects straight to the origin; miniflare's local proxy does the TLS
    # upgrade PlanetScale requires when the string asks for it (sslmode=require, ssl-mode=REQUIRED).
    for kind, bindings, tls in (("pg", ("HYPERDRIVE", "HYPERDRIVE_RO"), ""), ("mysql", ("PS_MYSQL", "PS_MYSQL_RO"), "?ssl-mode=REQUIRED")):
        if (d / "secrets" / f"{kind}.url").exists():
            for b in bindings:
                lines.append(f'export CLOUDFLARE_HYPERDRIVE_LOCAL_CONNECTION_STRING_{b}="$(cat {d}/secrets/{kind}.url){tls}"')
    lines.append(f'echo "== wdev start $(date -u +%FT%TZ) port {port} commit {args.commit}"')
    wrangler = api_dir / "node_modules/.bin/wrangler"
    if with_platform and wrangler_version(d / "platform") > wrangler_version(api_dir):
        # One workerd runs both Workers, so it must know the newer compatibility date of the two.
        wrangler = d / "platform/node_modules/.bin/wrangler"
    lines.append("exec " + " ".join([str(wrangler), "dev", *configs, "--env", "development",
                                     "--ip", "127.0.0.1", "--port", str(port), "--local-protocol", "http",
                                     "--persist-to", str(d / "state"),
                                     "--show-interactive-dev-session=false", "--inspector-port", "0"]))
    write_private(d / "run.sh", "\n".join(lines) + "\n")
    (d / "logs").mkdir(exist_ok=True)
    log = d / "logs/wrangler.log"
    if log.exists() and log.stat().st_size > LOG_MAX_BYTES:
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
                last = r.read().decode()[:400]
                ok = r.status == 200
                if ok:
                    break
        except Exception as e:  # noqa: BLE001 - still booting
            last = str(e)
        time.sleep(2)
    if not ok:
        tail = log.read_text(errors="replace")[-4000:] if log.exists() else ""
        stop_stack(tag, keep_files=True)
        with registry_lock():
            entry = read_entry(tag) or entry
            entry["state"] = "failed"
            write_entry(entry)
        raise Refused(f"wrangler dev did not answer /v1/health on 127.0.0.1:{port} ({last})\n--- log tail ---\n{tail}")

    with serve_lock():
        target = f"http://127.0.0.1:{port}"
        if serve_target(serve_config(), port) != target:
            out = subprocess.run(["sudo", "-n", "tailscale", "serve", "--bg", "--yes", f"--https={port}", target], capture_output=True, text=True, timeout=60)
            if out.returncode != 0:
                raise Refused(f"tailscale serve --https={port} failed: {(out.stderr or out.stdout).strip()[-400:]}")
    with registry_lock():
        entry = read_entry(tag) or entry
        entry.update({"state": "running", "started_at": int(time.time()), "log_offset": log.stat().st_size if log.exists() else 0,
                      "last_request_at": int(time.time())})
        write_entry(entry)
    return {"tag": tag, "url": origin, "port": port, "health": json.loads(last)}


def stop_stack(tag: str, keep_files: bool) -> list[str]:
    actions = []
    if systemctl("is-active", "--quiet", unit(tag), check=False).returncode == 0 or systemctl("is-failed", "--quiet", unit(tag), check=False).returncode == 0:
        systemctl("stop", unit(tag), check=False)
        systemctl("reset-failed", unit(tag), check=False)
        actions.append("unit stopped")
    entry = read_entry(tag) or {}
    port = entry.get("port")
    if port:
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
    actions = stop_stack(tag, keep_files=False)
    with registry_lock():
        entry = read_entry(tag) or entry
        entry.update({"state": "down", "down_at": int(time.time()), "reason": args.reason})
        write_entry(entry)
    return {**entry, "actions": actions}


def cmd_forget(args) -> dict[str, Any]:
    tag = check_tag(args.tag)
    entry = read_entry(tag)
    if entry and entry.get("state") == "running":
        raise Refused(f"{tag} is running; run down first")
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


def cmd_reap(_args) -> dict[str, Any]:
    now = int(time.time())
    out = []
    for entry in all_entries():
        tag = entry["tag"]
        if entry.get("state") in ("down", "reaped", "failed"):
            if now - entry.get("down_at", entry.get("reaped_at", entry.get("last_up_at", now))) > REAPED_KEEP_SECS:
                stop_stack(tag, keep_files=False)
                entry_path(tag).unlink(missing_ok=True)
                out.append({"tag": tag, "action": "purged old entry"})
            elif entry.get("state") == "failed" and now - entry.get("last_up_at", now) > 3600:
                stop_stack(tag, keep_files=False)
            continue
        if entry.get("state") != "running":
            if now - entry.get("last_up_at", entry.get("created_at", now)) < 1800:
                continue  # a start in progress
            reason = "never started"
        else:
            with registry_lock():
                entry = read_entry(tag) or entry
                scan_requests(entry)
                write_entry(entry)
            hb = stack_dir(tag) / "heartbeat"
            reason = idle_verdict(entry, now, hb.stat().st_mtime if hb.exists() else None, unit_active(tag))
        if reason:
            actions = stop_stack(tag, keep_files=False)
            with registry_lock():
                entry = read_entry(tag) or entry
                entry.update({"state": "reaped", "reaped_at": now, "reason": reason})
                write_entry(entry)
            out.append({"tag": tag, "action": "reaped", "reason": reason, "steps": actions})
            print(f"reaped {tag}: {reason}", file=sys.stderr)
    return {"reaped": out}


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
        rows.append({k: e.get(k) for k in ("tag", "state", "url", "port", "commit", "dirty", "platform", "reason", "last_up_at")}
                    | {"active": unit_active(e["tag"]) if e.get("state") == "running" else False,
                       "idle_min": (now - last) // 60 if last else None, "idle_limit_min": e.get("idle_secs", IDLE_SECS_DEFAULT) // 60,
                       "mem_mib": unit_memory_mib(e["tag"]) if e.get("state") == "running" else None,
                       "db": {k: {kk: v.get(kk) for kk in ("mode", "database", "branch", "cred_id", "cred_name", "expires_at")} for k, v in (e.get("db") or {}).items()}})
    return {"capacity": cmd_capacity(None), "stacks": rows}


def cmd_logs(args) -> dict[str, Any]:
    log = stack_dir(check_tag(args.tag)) / "logs/wrangler.log"
    text = log.read_text(errors="replace") if log.exists() else ""
    sys.stdout.write("\n".join(text.splitlines()[-args.lines:]) + "\n")
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
    s = sub.add_parser("logs"); s.add_argument("--tag", required=True); s.add_argument("-n", "--lines", type=int, default=80)
    args = p.parse_args()
    handlers = {"install": lambda a: install_host(), "capacity": cmd_capacity, "reap": cmd_reap, "status": cmd_status,
                "prepare": cmd_prepare, "touch": cmd_touch, "forget": cmd_forget, "prune": cmd_prune, "put-cred": cmd_put_cred,
                "migrate": cmd_migrate, "start": cmd_start, "down": cmd_down, "logs": cmd_logs}
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
