"""The bench contract and the context a bench runs in.

A bench is a module in scripts/bench/benches/ that defines `BENCH`, an instance of a Bench subclass:

    class Launch(Bench):
        name = "launch"
        summary = "Dock launch to main, and first frame"
        units = "ms"
        owner = "perf (CMUX-629)"
        hosts = ("fleet",)
        harness = "scripts/measure/launch-ready.sh"
        version = "1"

        def run(self, ctx):        # measure, then report rows with ctx.row(...)
            res = ctx.fleet_step(self.harness, args=[...], artifact="artifacts/launch.json")
            self.ingest(ctx, res.artifact_path or res.log_path)

        def ingest(self, ctx, path):  # turn the harness's own output into rows (also `--import PATH`)
            ...

Benches wrap the existing harnesses; they never fork them. A harness's own output format stays;
`ingest` reads it. Bump `version` when what a metric means changes, so compare never mixes the two.
"""
from __future__ import annotations

import json
import os
import platform
import re
import shlex
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from . import schema
from .net import open_url

REPO_ROOT = Path(__file__).resolve().parents[3]
NIGHTLY_FEED = os.environ.get("CMUX_BENCH_NIGHTLY_FEED", "https://files-next.cmux.com/nightly-next/appcast-arm64.xml")
JOB_ID = re.compile(r"\b([0-9a-f]{24})\b")


class BenchError(RuntimeError):
    pass


class Bench:
    name: str = ""
    summary: str = ""
    units: str = ""
    owner: str = ""
    hosts: tuple[str, ...] = ("fleet",)  # fleet | local-readonly | anywhere
    harness: str = ""
    version: str = "1"
    # Relative change (percent) a compare calls a regression, per metric; DEFAULT_THRESHOLD otherwise.
    thresholds: dict[str, float] = {}
    # Absolute change (in the metric's unit) below which a delta is noise, per metric; compare.FLOORS by unit otherwise.
    floors: dict[str, float] = {}
    # Benches the nightly runs against each new NIGHTLY (cmux-bench nightly).
    nightly: bool = False
    nightly_args: dict[str, str] = {}

    def run(self, ctx: "Context") -> None:
        raise NotImplementedError

    def ingest(self, ctx: "Context", path: Path) -> None:
        raise BenchError(f"{self.name} cannot import a file")


@dataclass
class FleetResult:
    job_id: str
    exit_code: int
    log_path: Path
    artifact_path: Path | None
    worker: str = ""

    @property
    def log(self) -> str:
        return self.log_path.read_text(encoding="utf-8", errors="replace")


def resolve_nightly(feed: str = NIGHTLY_FEED) -> dict[str, Any]:
    """The newest NIGHTLY in the live feed: version, sha (when the item names one) and the DMG URL."""
    with open_url(feed, timeout=30) as resp:
        xml = resp.read().decode("utf-8", "replace")
    item = xml.split("<item>", 1)[1] if "<item>" in xml else xml
    item = item.split("</item>", 1)[0]
    version = None
    for pat in (r"<sparkle:shortVersionString>([^<]+)<", r'sparkle:shortVersionString="([^"]+)"',
                r"<sparkle:version>([^<]+)<", r'sparkle:version="([^"]+)"'):
        m = re.search(pat, item)
        if m:
            version = m.group(1).strip()
            break
    sha = re.search(r"<cmux:sourceCommit[^>]*>([0-9a-f]{40})<", item)
    url = re.search(r'url="([^"]+)"', item)
    return {"channel": "nightly", "version": version, "sha": sha.group(1) if sha else None,
            "url": url.group(1) if url else None}


def parse_build(spec: str | None) -> dict[str, Any]:
    """--build nightly | DEV | <sha> | sha:<sha> | release:<version> | local."""
    if not spec or spec == "nightly":
        return {"channel": "nightly", "version": None, "sha": None, "pending": True}
    if spec == "DEV":
        return {"channel": "DEV", "version": None, "sha": None}
    if spec == "local":
        return {"channel": "local", "version": None, "sha": None}
    if spec.startswith("release:"):
        return {"channel": "release", "version": spec.split(":", 1)[1], "sha": None}
    sha = spec.split(":", 1)[1] if spec.startswith("sha:") else spec
    if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
        raise BenchError(f"--build {spec!r}: expected nightly, DEV, local, release:VERSION or a commit sha")
    if len(sha) < 40:
        full = subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", "--verify", "-q", f"{sha}^{{commit}}"],
                              text=True, capture_output=True)
        if full.returncode != 0:
            raise BenchError(f"--build {spec}: not a commit here; pass all 40 characters")
        sha = full.stdout.strip()
    return {"channel": "sha", "version": None, "sha": sha}


def base_tip() -> str:
    """The feat-cmux-next tip: the ref fleet steps check the harness out at (the controller runs only
    reviewed scripts as they are on the base)."""
    out = subprocess.run(["git", "ls-remote", "https://github.com/manaflow-ai/cmux.git", "refs/heads/feat-cmux-next"],
                         text=True, capture_output=True, timeout=60)
    m = re.match(r"([0-9a-f]{40})", out.stdout)
    if not m:
        raise BenchError(f"cannot read the feat-cmux-next tip: {out.stderr.strip()}")
    return m.group(1)


def local_host() -> dict[str, Any]:
    os_name, chip = platform.system(), platform.machine()
    if os_name == "Darwin":
        ver = subprocess.run(["sw_vers", "-productVersion"], text=True, capture_output=True).stdout.strip()
        os_name = f"macOS {ver}"
        brand = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], text=True, capture_output=True)
        chip = brand.stdout.strip() or chip
    elif os_name == "Linux":
        os_name = f"Linux {platform.release()}"
    return {"name": platform.node().split(".")[0], "role": "local-readonly", "os": os_name, "chip": chip}


@dataclass
class Context:
    bench: Bench
    build: dict[str, Any]
    host_role: str
    args: dict[str, str] = field(default_factory=dict)
    run_id: str = ""
    timestamp: str = ""
    workdir: Path = field(default_factory=lambda: Path(tempfile.mkdtemp(prefix="cmux-bench-")))
    host: dict[str, Any] = field(default_factory=dict)
    harness_version: str = ""
    rows: list[dict[str, Any]] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    dry_run: bool = False

    def __post_init__(self) -> None:
        self.run_id = self.run_id or schema.new_run_id(self.bench.name)
        self.timestamp = self.timestamp or schema.now_iso()
        if not self.host:
            self.host = local_host() if self.host_role != "fleet" else {"name": "fleet", "role": "fleet", "os": "", "chip": ""}
            self.host["role"] = self.host_role
        if not self.harness_version:
            self.harness_version = f"{self.bench.name}@{self.bench.version}"

    def arg(self, key: str, default: str | None = None) -> str | None:
        return self.args.get(key, default)

    # --- rows -----------------------------------------------------------------------------------
    def row(self, metric: str, value: float | None = None, unit: str = "ms", *, better: str = "lower",
            samples: list[float] | None = None, p50: float | None = None, p95: float | None = None,
            n: int | None = None, labels: dict[str, Any] | None = None) -> dict[str, Any] | None:
        """Add one metric. With samples, value/p50/p95/n come from them (value = median)."""
        if samples is not None:
            samples = [float(s) for s in samples if s is not None]
            if not samples:
                self.notes.append(f"{metric}: no samples")
                return None
            stats = schema.summarize(samples)
            value, p50, p95, n = stats["value"], stats["p50"], stats["p95"], stats["n"]
        if value is None:
            self.notes.append(f"{metric}: no value")
            return None
        row = {
            "schema": schema.SCHEMA, "run_id": self.run_id, "bench": self.bench.name, "metric": metric,
            "value": float(value), "unit": unit, "better": better,
            "p50": None if p50 is None else float(p50), "p95": None if p95 is None else float(p95), "n": n,
            "labels": {k: str(v) for k, v in (labels or {}).items()},
            "build": {k: self.build.get(k) for k in ("channel", "version", "sha")},
            "host": dict(self.host), "harness": {"name": self.bench.harness or self.bench.name,
                                                 "version": self.harness_version},
            "timestamp": self.timestamp,
        }
        schema.validate(row)
        self.rows.append(row)
        return row

    # --- fleet ----------------------------------------------------------------------------------
    def fleet_step(self, script: str, args: list[str] | None = None, artifact: str | None = None, *,
                   step_class: str = "exclusive", labels: tuple[str, ...] = ("bench",), timeout: int | None = None,
                   target_worker: str | None = None, ref: str | None = None,
                   env: dict[str, str] | None = None, display: bool = False) -> FleetResult:
        """Run one harness on a fleet Mac with `cmux-ci run` (as a measurement, alone on its worker) and
        fetch its log and artifact. Never runs anything on this machine."""
        if self.host_role != "fleet":
            raise BenchError(f"{self.bench.name}: a fleet step needs --host fleet")
        ref = ref or self.args.get("ref") or base_tip()
        if len(ref) < 40:  # cmux-ci run --ref takes all 40 characters
            ref = parse_build(ref)["sha"]
        target_worker = target_worker or self.args.get("worker")
        cmd = ["cmux-ci", "run", "--class", step_class, "--measurement", "--script", script, "--ref", ref]
        for label in labels:
            cmd += ["--label", label]
        for a in args or []:
            cmd.append(f"--arg={a}")
        for k, v in (env or {}).items():
            cmd += ["--env", f"{k}={v}"]
        if display or self.args.get("display") == "1":
            cmd.append("--display")  # a GUI harness: a display worker's console session
        if artifact:
            cmd += ["--artifact", artifact]
        if target_worker:
            cmd += ["--target-worker", target_worker]
        if timeout:
            cmd += ["--timeout", str(timeout)]
        rev = subprocess.run(["git", "-C", str(REPO_ROOT), "rev-parse", "--short=9", f"{ref}:{script}"],
                             text=True, capture_output=True)
        if rev.returncode == 0:
            self.harness_version = f"{self.bench.name}@{self.bench.version}+{rev.stdout.strip()}"
        if self.dry_run:
            print("dry run:", shlex.join(cmd))
            raise BenchError("dry run")
        log_path = self.workdir / f"{Path(script).stem}.log"
        with log_path.open("w", encoding="utf-8") as log:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            assert proc.stdout is not None
            job_id = ""
            for line in proc.stdout:
                log.write(line)
                if not job_id:
                    m = JOB_ID.search(line)
                    job_id = m.group(1) if m else ""
            code = proc.wait()
        result = FleetResult(job_id=job_id, exit_code=code, log_path=log_path, artifact_path=None)
        if job_id:
            status = subprocess.run(["cmux-ci", "status", job_id], text=True, capture_output=True)
            try:
                info = json.loads(status.stdout)
                info = info[0] if isinstance(info, list) else info
                result.worker = info.get("worker", "") or ""
            except (json.JSONDecodeError, IndexError, AttributeError):
                pass
            if artifact and code == 0:
                out = self.workdir / Path(artifact).name
                got = subprocess.run(["cmux-ci", "artifact", job_id, str(out)], text=True, capture_output=True)
                if got.returncode == 0 and out.exists():
                    result.artifact_path = out
        if result.worker:
            self.host.update({"name": result.worker, "role": "fleet"})
        for pat, key in ((r"macOS[ -](\d+(?:\.\d+)*)", "os"), (r"(Apple M\d[\w ]*?)(?:\s{2}|,|$)", "chip")):
            m = re.search(pat, result.log, re.M)
            if m and not self.host.get(key):
                self.host[key] = (f"macOS {m.group(1)}" if key == "os" else m.group(1).strip())
        if code != 0:
            self.notes.append(f"fleet step {job_id or '?'} exited {code}; log {log_path}")
        return result
