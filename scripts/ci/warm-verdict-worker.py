#!/usr/bin/env python3
"""A resident warm verdict worker: one checked-out cmux tree with warm build state, a verdict per pushed head.

    warm-verdict-worker.py warm    --state DIR --sha SHA [--source URL] [--crates a,b]
    warm-verdict-worker.py verdict --state DIR --head SHA [--base SHA] [--source URL]
    warm-verdict-worker.py serve   --state DIR [--source URL]      # one {"head": SHA, "base"?: SHA} per stdin line

Leo, 2026-11-21: "help 100x ci speed and the decrease of needed minutes aka lower resources and lower wall time and
lower machine time while maintaining a partial semblance of checks. and we can infrequenrly have fuller checks."

A pull request's verdict today waits on a router hop, a fresh checkout, setup and every always-run step of the
linux job (scripts/measure replay: about 48 s of fixed overhead before any check, 333-1313 s for a cold compile).
This worker keeps all of that resident on one idle Linux machine:

  STATE/tree     one cmux checkout (a --shared clone of SOURCE, made once). A head is fetched only when the
                 tree lacks it, then checked out in place (`git checkout --force --detach`), never cloned again.
  STATE/target   one CARGO_TARGET_DIR per Cargo workspace, kept between heads: incremental `cargo check`.
  STATE/tsbuild  tsc's --incremental build info per web package, kept between heads.
  in memory      `cargo metadata` of cmux-tui, refreshed only when a head changes a Cargo manifest or lockfile.

The verdict tier is the partial check Leo named, never the whole suite:

  route    the changed paths (BASE...HEAD), the tests scripts/ci/focused_tests.py maps them to and the cmux-tui
           crates scripts/ci/cargo_affected.py maps them to (owners plus reverse dependencies);
  deps     `bun install --frozen-lockfile` in a web package only when its package.json or lockfile changed;
  compile  `cargo check -p` of the affected cmux-tui crates, `cargo check` of any other Cargo workspace a change
           touches, and `tsc --noEmit --incremental` of a touched web package (webviews/, web/);
  test     the owning crates' unit tests (`cargo test -p CRATE --lib`), the linux-guard Python tests the change
           selects (scripts/ci/run_python_test_lane.py --path), and the webviews tests the import graph selects
           (`bun test FILE`, browser-lane files skip as they do outside CMUX_BROWSER_TESTS).

Rust runs as one chain (check, then tests: one target dir lock); the Python and web lanes run beside it. Swift
cannot build on Linux: a head that touches a Swift package says so in `swift_needs` (the Mac job's targets) and the
verdict is `pass-linux` rather than `pass`. The full tier (ci/steps.toml, pr-pipeline.yml, every always-run step)
is unchanged and is not on this path. Every phase is timed; the verdict is one JSON object.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import cargo_affected  # noqa: E402
import focused_tests  # noqa: E402

DEFAULT_SOURCE = "https://github.com/manaflow-ai/cmux.git"
RUST_WS = "cmux-tui"
LINUX_PYTHON_LANE = "linux-guard"
WEB_PACKAGES = ("webviews", "web")
WEB_DEP_FILES = ("package.json", "bun.lock", "bun.lockb")
TS_SOURCE = (".ts", ".tsx", ".mts", ".cts")
MANIFEST_NAMES = ("Cargo.toml", "Cargo.lock", "rust-toolchain.toml", "rust-toolchain")
SWIFT_ROOTS = ("Packages/", "cmux-next-ios/", "ios/", "App/", "cmux.xcodeproj/")
# Bounds per command (seconds). A command past its bound fails the verdict and says so.
CHECK_TIMEOUT = 1800
TEST_TIMEOUT = 900
WEB_TEST_TIMEOUT = 300
SPARSE_EXCLUDE = ("cmux-next-ios/verify/",)
# Submodules a verdict builds from (ghostty-vt-sys's build script needs ghostty-next's sources). Each is checked out
# at the head's gitlink, from a local mirror (MIRRORS/<name>.git) when one holds it, else from its .gitmodules URL;
# blobs a partial mirror lacks come from the .gitmodules URL.
SUBMODULES = ("ghostty-next",)
MIRRORS = Path(os.environ.get("WARM_VERDICT_MIRRORS", Path.home() / "Projects/.wt-mirrors/manaflow-ai"))
# tsc of webviews/ passes V8's default 4 GB heap on a large head (seen: Mark-Compact at 4082 MB, exit -6).
TSC_NODE_OPTIONS = "--max-old-space-size=8192"
PRE_TSC = {"webviews": ["bun", "run", "protocol:codegen"]}
# A Python test file that took longer than this on this worker is the full tier's (one 1076-case file took 178 s
# and would set every verdict that selects it); the worker learns each file's seconds as it runs them.
PY_BUDGET = 20.0
SECONDS_FILE = "scripts/ci/python-test-lane-seconds.json"


def now() -> float:
    return time.monotonic()


def run(argv: list[str], cwd: Path, timeout: int, env: dict | None = None, keep: bool = False) -> dict:
    """Run one command; its exit, seconds and the tail of its output."""
    t = now()
    try:
        p = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL)
        code, out = p.returncode, (p.stdout or "") + (p.stderr or "")
    except subprocess.TimeoutExpired as e:
        code = 124
        out = f"timed out after {timeout}s\n" + str(e.stdout or "")[-2000:]
    except OSError as e:
        code, out = 127, str(e)
    res = {"argv": argv, "exit": code, "s": round(now() - t, 2), "tail": out[-3000:] if code else ""}
    if keep:
        res["out"] = out
    return res


PY_RESULT = re.compile(r"^==> (\S+\.py) (?:ok|FAILED \(exit -?\d+\)) in ([\d.]+)s$", re.M)


def python_seconds(output: str) -> dict[str, float]:
    """Seconds per test from run_python_test_lane.py's "==> PATH ok in Ns" lines (pure; unit-tested)."""
    return {path: float(sec) for path, sec in PY_RESULT.findall(output)}


def split_by_budget(tests: list[str], seconds: dict[str, float], budget: float) -> tuple[list[str], list[str]]:
    """Tests to run now and tests over BUDGET seconds (by their last known time; unknown runs) (pure)."""
    run_now = [t for t in tests if seconds.get(t, 0.0) <= budget]
    return run_now, [t for t in tests if t not in run_now]


def git(tree: Path, *args: str, check: bool = True) -> str:
    p = subprocess.run(["git", "-C", str(tree), *args], capture_output=True, text=True)
    if check and p.returncode:
        raise RuntimeError(f"git {' '.join(args)}: {p.stderr.strip()}")
    return p.stdout.strip()


def classify(files: list[str]) -> dict:
    """What kinds of work a set of changed paths can need (pure; unit-tested)."""
    out = {"rust_ws": False, "other_rust": [], "web_ts": [], "web_deps": [], "swift": [], "manifests": False}
    for f in files:
        name = f.rsplit("/", 1)[-1]
        if f.startswith(RUST_WS + "/") and (f.endswith(".rs") or name in MANIFEST_NAMES or "/build.rs" in f):
            out["rust_ws"] = True
            if name in MANIFEST_NAMES:
                out["manifests"] = True
        elif f.endswith(".rs") or name in ("Cargo.toml", "Cargo.lock"):
            out["other_rust"].append(f)
        for pkg in WEB_PACKAGES:
            if f.startswith(pkg + "/"):
                rest = f[len(pkg) + 1:]
                if rest in WEB_DEP_FILES and pkg not in out["web_deps"]:
                    out["web_deps"].append(pkg)
                if (f.endswith(TS_SOURCE) or rest.startswith("tsconfig")) and pkg not in out["web_ts"]:
                    out["web_ts"].append(pkg)
        if f.endswith(".swift") or (f.startswith(SWIFT_ROOTS) and name == "Package.swift"):
            out["swift"].append(f)
    return out


def verdict_word(results: list[dict], swift: list[str]) -> str:
    if any(r["exit"] != 0 for r in results):
        return "fail"
    return "pass-linux" if swift else "pass"


class Worker:
    def __init__(self, state: Path, source: str = DEFAULT_SOURCE, jobs: int | None = None):
        self.state = state.resolve()
        self.tree = self.state / "tree"
        self.source = source
        self.jobs = jobs or max(2, (os.cpu_count() or 4) // 2)
        self.meta: dict | None = None
        self.meta_sha = ""
        self.seconds_path = self.state / "python-test-seconds.json"
        self.seconds: dict[str, float] = {}
        if self.seconds_path.is_file():
            self.seconds = json.loads(self.seconds_path.read_text())
        self._refs: dict[str, set[str]] = {}
        self._refs_key = ""
        self.installed: dict[str, str] = {}  # web package -> head whose deps were installed
        self.env = dict(os.environ, CARGO_INCREMENTAL="1", CARGO_TERM_COLOR="never", CARGO_BUILD_JOBS=str(self.jobs))

    # --- tree -------------------------------------------------------------------------------------------------
    def ensure_tree(self) -> float:
        if (self.tree / ".git").exists():
            return 0.0
        t = now()
        self.state.mkdir(parents=True, exist_ok=True)
        shared = ["--shared"] if Path(self.source).is_dir() else ["--filter=blob:none"]
        subprocess.run(["git", "clone", "--quiet", "--no-checkout", *shared, self.source, str(self.tree)], check=True)
        git(self.tree, "sparse-checkout", "set", "--no-cone", "/*", *(f"!/{p}" for p in SPARSE_EXCLUDE))
        return now() - t

    def fetch(self, sha: str) -> tuple[float, bool]:
        """Fetch SHA only when the tree does not hold it yet."""
        if subprocess.run(["git", "-C", str(self.tree), "cat-file", "-e", f"{sha}^{{commit}}"],
                          capture_output=True).returncode == 0:
            return 0.0, False
        t = now()
        git(self.tree, "fetch", "--quiet", "--no-tags", "origin", sha)
        return now() - t, True

    def checkout(self, sha: str) -> float:
        t = now()
        git(self.tree, "checkout", "--quiet", "--force", "--detach", sha)
        self.sync_submodules(sha)
        return now() - t

    def sync_submodules(self, sha: str) -> None:
        """Check each of SUBMODULES out at SHA's gitlink, only when it is not there already."""
        for path in SUBMODULES:
            entry = git(self.tree, "ls-tree", sha, "--", path).split()
            if len(entry) < 3 or entry[1] != "commit":
                continue
            want, sub = entry[2], self.tree / path
            have = subprocess.run(["git", "-C", str(sub), "rev-parse", "HEAD"], capture_output=True, text=True)
            if (sub / ".git").exists() and have.returncode == 0 and have.stdout.strip() == want \
                    and not git(sub, "ls-files", "--deleted", check=False):
                continue
            url = git(self.tree, "config", "-f", ".gitmodules", f"submodule.{path}.url", check=False).strip()
            mirror = MIRRORS / (url.rstrip("/").rsplit("/", 1)[-1].removesuffix(".git") + ".git")
            for src in ([str(mirror)] if mirror.is_dir() else []) + ([url] if url else []):
                git(self.tree, "config", f"submodule.{path}.url", src)
                done = subprocess.run(["git", "-C", str(self.tree), "-c", "protocol.file.allow=always", "submodule",
                                       "update", "--init", "--force", "--quiet", "--", path], capture_output=True)
                if done.returncode == 0:
                    break
            if url and not url.startswith(("/", "file:")) and Path(str(mirror)).is_dir():
                # The local mirror is itself a partial clone and serves no blob it lacks, so the checkout can come
                # out with files missing (seen: ghostty-next without build.zig). Make the upstream URL the
                # submodule's promisor remote and restore: what the mirror lacked is fetched from upstream.
                git(sub, "remote", "set-url", "origin", url)
                git(sub, "config", "remote.origin.promisor", "true")
                git(sub, "config", "remote.origin.partialclonefilter", "blob:none")
                if git(sub, "ls-files", "--deleted", check=False):
                    git(sub, "checkout", "--force", want, "--", ".", check=False)

    def target(self, ws: str) -> Path:
        return self.state / "target" / ws.replace("/", "__")

    # --- route ------------------------------------------------------------------------------------------------
    def changed(self, base: str, head: str) -> list[str]:
        out = git(self.tree, "diff", "--name-only", "--no-renames", f"{base}...{head}")
        return sorted({line for line in out.splitlines() if line})

    def manifest_key(self, head: str) -> str:
        """The blob ids of cmux-tui's manifests and lockfile at HEAD: cargo metadata changes only with them."""
        out = git(self.tree, "ls-tree", "-r", head, "--", RUST_WS)
        return "\n".join(line for line in out.splitlines() if line.rsplit("/", 1)[-1] in MANIFEST_NAMES)

    def metadata(self, head: str, manifests_changed: bool = False) -> dict:
        key = self.manifest_key(head)
        if self.meta is None or manifests_changed or key != self.meta_sha:
            p = subprocess.run(["cargo", "metadata", "--no-deps", "--format-version", "1", "--manifest-path",
                                str(self.tree / RUST_WS / "Cargo.toml")], cwd=self.tree / RUST_WS, env=self.env,
                               capture_output=True, text=True, check=True)
            self.meta, self.meta_sha = json.loads(p.stdout), key
        return self.meta

    def crate_refs(self, head: str, meta: dict) -> dict[str, set[str]]:
        """cargo_affected.crate_references (a walk of every crate's sources), cached by cmux-tui's tree id."""
        key = git(self.tree, "rev-parse", f"{head}:{RUST_WS}")
        if self._refs_key != key:
            self._refs = cargo_affected.crate_references(self.tree, cargo_affected.load_members(meta, RUST_WS))
            self._refs_key = key
        return self._refs

    def workspace_of(self, path: str) -> str | None:
        """The Cargo workspace root (repo-relative) owning PATH, outside cmux-tui."""
        d = (self.tree / path).parent
        while d != self.tree and d != d.parent:
            if (d / "Cargo.toml").is_file():
                p = subprocess.run(["cargo", "locate-project", "--workspace", "--message-format", "plain"],
                                   cwd=d, env=self.env, capture_output=True, text=True)
                if p.returncode == 0 and p.stdout.strip():
                    return str(Path(p.stdout.strip()).parent.relative_to(self.tree))
                return str(d.relative_to(self.tree))
            d = d.parent
        return None

    def route(self, base: str, head: str) -> dict:
        files = self.changed(base, head)
        kinds = classify(files)
        focused = focused_tests.plan(self.tree, files)
        crates: list[str] = []
        direct: list[str] = []
        rust_reason = ""
        root_readers: set[str] = set()
        if files and (self.tree / RUST_WS / "Cargo.toml").is_file():
            meta = self.metadata(head)
            refs = self.crate_refs(head, meta)
            root_readers = set(refs.get(".", ()))
            # A crate whose sources name the repository root ("../../..") reads the whole tree at run time (a
            # walk, a guard): every change reaches it, but its compile does not change. Its tests are the full
            # tier's; the verdict compiles and tests what a change names by path.
            specific = {k: v for k, v in refs.items() if k != "."}
            real = cargo_affected.crate_references
            cargo_affected.crate_references = lambda _root, _crates: specific
            try:
                cp = cargo_affected.plan(self.tree, meta, files)
            finally:
                cargo_affected.crate_references = real
            if cp.workspace:
                rust_reason = "; ".join(cp.reasons[:3])
                direct = sorted({c.name for c in cargo_affected.load_members(meta, RUST_WS)
                                 for f in files if f.startswith(c.dir + "/")})
                crates = direct or []
            else:
                crates, direct = sorted(cp.crates), sorted(cp.direct)
        other_ws = sorted({ws for f in kinds["other_rust"] if (ws := self.workspace_of(f)) and ws != RUST_WS})
        lanes = {p: lane for p, (lane, _serial) in focused_tests.lanes(self.tree).items()}
        python = [i["path"] for i in focused["python"] if lanes.get(i["path"]) == LINUX_PYTHON_LANE]
        python, slow = split_by_budget(python, self.known_seconds(), PY_BUDGET)
        not_run = [{"what": i["path"], "why": f"Python lane {lanes.get(i['path']) or 'none'!r} is not linux-guard"}
                   for i in focused["python"] if lanes.get(i["path"]) != LINUX_PYTHON_LANE]
        not_run += [{"what": p, "why": f"took {self.known_seconds()[p]:.0f} s here (over {PY_BUDGET:.0f} s): full tier"}
                    for p in slow]
        web = [i["path"] for i in focused["web"] if not i.get("browser")]
        not_run += [{"what": f"webviews/{i['path']}", "why": "browser lane: the web-browser job runs it"}
                    for i in focused["web"] if i.get("browser")]
        swift = sorted({f"{i['package']}:{i['filter']}" for i in focused["swift"]})
        if focused.get("swift_deferred"):
            swift.append(focused["swift_deferred"])
        if kinds["swift"] and not swift:
            swift.append(f"{len(kinds['swift'])} Swift file(s): compile on the Mac job")
        skipped = sorted(root_readers - set(crates))
        if skipped and files:
            not_run.append({"what": f"{len(skipped)} cmux-tui crates that read the whole tree ({', '.join(skipped[:4])})",
                            "why": "full tier: they read every path at run time; no source of theirs changed"})
        if rust_reason:
            not_run.append({"what": "cmux-tui --workspace", "why": f"full tier: {rust_reason}"})
        return {"files": files, "crates": crates, "direct": direct, "other_ws": other_ws,
                "web_ts": kinds["web_ts"], "web_deps": kinds["web_deps"], "python": python, "web": web,
                "swift": swift, "not_run": not_run}

    # --- lanes ------------------------------------------------------------------------------------------------
    def rust_lane(self, r: dict) -> tuple[list[dict], dict]:
        results, t = [], {"rust_check": 0.0, "rust_test": 0.0}
        ws_dir = self.tree / RUST_WS
        env = dict(self.env, CARGO_TARGET_DIR=str(self.target(RUST_WS)))
        if r["crates"]:
            args = [a for c in r["crates"] for a in ("-p", c)]
            res = run(["cargo", "check", "--locked", *args], ws_dir, CHECK_TIMEOUT, env)
            results.append(res)
            t["rust_check"] += res["s"]
            if res["exit"] == 0 and r["direct"]:
                args = [a for c in r["direct"] for a in ("-p", c)]
                res = run(["cargo", "test", "--locked", "--lib", *args], ws_dir, TEST_TIMEOUT, env)
                results.append(res)
                t["rust_test"] += res["s"]
        for ws in r["other_ws"]:
            env = dict(self.env, CARGO_TARGET_DIR=str(self.target(ws)))
            res = run(["cargo", "check", "--manifest-path", str(self.tree / ws / "Cargo.toml")], self.tree / ws,
                      CHECK_TIMEOUT, env)
            results.append(res)
            t["rust_check"] += res["s"]
        return results, t

    def ts_lane(self, r: dict, head: str) -> tuple[list[dict], dict]:
        results, t = [], {"deps": 0.0, "ts_check": 0.0, "web_test": 0.0}
        pkgs = sorted(set(r["web_ts"]) | ({"webviews"} if r["web"] else set()))
        for pkg in pkgs:
            d = self.tree / pkg
            if pkg in r["web_deps"] or pkg not in self.installed or not (d / "node_modules").is_dir():
                res = run(["bun", "install", "--frozen-lockfile"], d, CHECK_TIMEOUT, self.env)
                results.append(res)
                t["deps"] += res["s"]
                if res["exit"] == 0:
                    self.installed[pkg] = head
        for pkg in r["web_ts"]:
            d = self.tree / pkg
            if pkg in PRE_TSC:
                # Generated, gitignored types (webviews' protocol codegen) follow the head, as `bun run typecheck`
                # regenerates them first; a stale copy fails tsc on a head that changed the protocol.
                res = run(PRE_TSC[pkg], d, CHECK_TIMEOUT, self.env)
                results.append(res)
                t["ts_check"] += res["s"]
            tsc = d / "node_modules" / ".bin" / "tsc"
            info = self.state / "tsbuild" / f"{pkg}.tsbuildinfo"
            info.parent.mkdir(parents=True, exist_ok=True)
            res = run([str(tsc), "--noEmit", "--incremental", "--tsBuildInfoFile", str(info), "-p", "tsconfig.json"],
                      d, CHECK_TIMEOUT, dict(self.env, NODE_OPTIONS=TSC_NODE_OPTIONS))
            results.append(res)
            t["ts_check"] += res["s"]
        if r["web"]:
            start = now()
            with concurrent.futures.ThreadPoolExecutor(self.jobs) as pool:
                futs = [pool.submit(run, ["bun", "test", "--timeout", "30000", f"./{f}"], self.tree / "webviews",
                                    WEB_TEST_TIMEOUT, self.env) for f in r["web"]]
                results += [f.result() for f in futs]
            t["web_test"] += now() - start
        return results, t

    def known_seconds(self) -> dict[str, float]:
        """This worker's own seconds per Python test, over the repository's recorded ones."""
        recorded = {}
        path = self.tree / SECONDS_FILE
        if path.is_file():
            try:
                recorded = json.loads(path.read_text())
            except ValueError:
                recorded = {}
        return {**recorded, **self.seconds}

    def python_lane(self, r: dict) -> tuple[list[dict], dict]:
        if not r["python"]:
            return [], {"py_test": 0.0}
        argv = ["python3", "scripts/ci/run_python_test_lane.py", "--lane", LINUX_PYTHON_LANE, "--jobs", str(self.jobs)]
        for p in r["python"]:
            argv += ["--path", p]
        res = run(argv, self.tree, TEST_TIMEOUT, self.env, keep=True)
        learned = python_seconds(res.pop("out", ""))
        if learned:
            self.seconds.update(learned)
            self.state.mkdir(parents=True, exist_ok=True)
            self.seconds_path.write_text(json.dumps(self.seconds, indent=1, sort_keys=True))
        return [res], {"py_test": res["s"]}

    # --- entry points -----------------------------------------------------------------------------------------
    def warm(self, sha: str, crates: list[str] = (), direct: list[str] = (), other_ws: list[str] = (),
             python: list[str] = ()) -> dict:
        """Make the tree and its build state warm at SHA, as the traffic a resident worker has seen leaves it: web
        deps and tsc of every web package, `cargo check` of CRATES and OTHER_WS, unit-test builds of DIRECT, and one
        run of PYTHON to learn each test's seconds."""
        t0 = now()
        clone = self.ensure_tree()
        fetch, _ = self.fetch(sha)
        co = self.checkout(sha)
        r = {"files": [], "crates": list(crates), "direct": list(direct), "other_ws": list(other_ws), "web_ts": list(WEB_PACKAGES),
             "web_deps": list(WEB_PACKAGES), "python": list(python), "web": [], "swift": [], "not_run": []}
        if (self.tree / RUST_WS / "Cargo.toml").is_file():
            self.metadata(sha)
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            rust = pool.submit(self.rust_lane, r)
            ts = pool.submit(self.ts_lane, r, sha)
            py = pool.submit(self.python_lane, r)
            results = rust.result()[0] + ts.result()[0] + py.result()[0]
        return {"sha": sha, "clone_s": round(clone, 2), "fetch_s": round(fetch, 2), "checkout_s": round(co, 2),
                "wall_s": round(now() - t0, 2),
                "steps": [{"argv": " ".join(x["argv"][:6]), "exit": x["exit"], "s": x["s"]} for x in results]}

    def verdict(self, head: str, base: str | None = None) -> dict:
        t0 = now()
        self.ensure_tree()
        fetch_s, fetched = self.fetch(head)
        if base:
            self.fetch(base)
        else:
            base = git(self.tree, "rev-parse", f"{head}^")
        checkout_s = self.checkout(head)
        t = now()
        r = self.route(base, head)
        route_s = now() - t
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            fr = pool.submit(self.rust_lane, r)
            ft = pool.submit(self.ts_lane, r, head)
            fp = pool.submit(self.python_lane, r)
            lanes = {"rust": fr.result(), "ts": ft.result(), "python": fp.result()}
        results = [x for res, _ in lanes.values() for x in res]
        phases = {"fetch": round(fetch_s, 2), "checkout": round(checkout_s, 2), "route": round(route_s, 2)}
        for _, times in lanes.values():
            phases.update({k: round(v, 2) for k, v in times.items()})
        lane_s = {name: sum(times.values()) for name, (_, times) in lanes.items()}
        out = {
            "schema": "warm-verdict/v1", "head": head, "base": base, "fetched": fetched,
            "verdict": verdict_word(results, r["swift"]),
            "wall_s": round(now() - t0, 2),
            "phases": phases, "lanes": {k: round(v, 2) for k, v in lane_s.items()},
            "files": len(r["files"]), "crates": r["crates"], "tested_crates": r["direct"], "other_ws": r["other_ws"],
            "web_ts": r["web_ts"], "python_tests": len(r["python"]), "web_tests": len(r["web"]),
            "swift_needs": r["swift"], "not_run": r["not_run"],
            "failures": [{"argv": " ".join(x["argv"][:8]), "exit": x["exit"], "tail": x["tail"][-1500:]}
                         for x in results if x["exit"]],
        }
        return out

    def disk(self) -> dict:
        def size(p: Path) -> int:
            p2 = subprocess.run(["du", "-sb", str(p)], capture_output=True, text=True)
            return int(p2.stdout.split()[0]) if p2.returncode == 0 and p2.stdout else 0
        return {"target_bytes": size(self.state / "target"), "tree_bytes": size(self.tree)}


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("cmd", choices=["warm", "verdict", "serve"])
    ap.add_argument("--state", type=Path, default=Path(os.environ.get("WARM_VERDICT_STATE",
                                                                         Path.home() / ".cache/warm-verdict-worker")))
    ap.add_argument("--source", default=DEFAULT_SOURCE)
    ap.add_argument("--sha")
    ap.add_argument("--head")
    ap.add_argument("--base")
    ap.add_argument("--crates", default="")
    ap.add_argument("--jobs", type=int)
    a = ap.parse_args(argv)
    if not shutil.which("git"):
        print("warm-verdict-worker: git is not on PATH", file=sys.stderr)
        return 2
    w = Worker(a.state, a.source, a.jobs)
    if a.cmd == "warm":
        print(json.dumps(w.warm(a.sha, [c for c in a.crates.split(",") if c])))
        return 0
    if a.cmd == "verdict":
        v = w.verdict(a.head, a.base)
        print(json.dumps(v))
        return 0 if v["verdict"] != "fail" else 1
    for line in sys.stdin:
        if line.strip():
            req = json.loads(line)
            print(json.dumps(w.verdict(req["head"], req.get("base"))), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
