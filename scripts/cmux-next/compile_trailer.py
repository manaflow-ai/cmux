#!/usr/bin/env python3
"""The pre-push compile trailer (lead 2026-10-24): a push that changes Swift names the compile that proves it builds.

Twice on 2026-10-24 an agent pushed Swift it had not compiled after its last change, and the feat-cmux-next tip broke
for everyone (latest: KeyFrameSignpost.swift, a public default argument with an internal Foundation import,
b1433c712d1). So when a pushed range changes a `.swift` file or a `Package.swift`, its newest commit's message must
carry `Compiled: <cmux-ci job id>`, and the build controller must say that job is a compile check of the app and the
CmuxNext package (`cmux-next-swift-check` with `--app` and `--package CmuxNext`) that passed, on a commit whose Swift
matches the pushed head:

(a) the job's commit and the head have the same `.swift` and `Package.swift` content under Packages/ (other files may
    differ), or
(b) the job ran on the head's tree before a rebase: the Swift that differs between the job's commit and the head (the
    upstream side, and any edit made after the compile) changes no `.swift` or `Package.swift` file in a Swift module
    (a Sources/<Module>/ or Tests/<Target>/ folder) that the push's own changes touch, nor in a module those modules
    depend on (their target's dependencies in Package.swift, one level, by name in any package under Packages/, plus
    what those re-export with `@_exported import`), nor the Package.swift of a package that holds such a module.
    Without the module check, an upstream rename the push's files use (the case that broke the tip) would pass.
    Not covered: an upstream change in a module that DEPENDS on the push's modules (a new use of an API the push
    renames); the full compile on CI catches that.

The CEF shim (C++/Objective-C++ under Packages/macOS/CmuxNext/CEFShim/) and the CEF fork pin
(scripts/cmux-next/cef-manifest.json) are built only by the full fleet app build, not by the compile check (PL-cef-layer
2026-10-24: a shim namespace error passed compile-check and failed the app build, job 2577a32f). A push that changes
them must name a passing `cmux-ci build cmux` job (kind `cmux`) of the same shim and pin.

`Compiled-skip: <reason>` on the newest commit lets the push through for an emergency; the gate prints it loudly. The
check fails open: a controller that does not answer within CONTROLLER_TIMEOUT, a git error or a parse error lets the
push through, with a loud `!!! COMPILE TRAILER NOT CHECKED` line that names the reason and a row in the clone's
FAIL_OPEN_LOG. Before it fails open on a silent controller it reads the job record an earlier push of this clone got
from the controller (JOB_CACHE: a finished job and its receipts do not change), so a push refused once is not let
through later because the controller was slow (PL-instant c4a98974c65..8a9d03d646e, 2026-10-24). It is local only
(the pre-push gate's guardrails path), never a CI gate.
"""
from __future__ import annotations

import hashlib
import json
import os
import time
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

CONTROLLER = os.environ.get("CMUX_CI_CONTROLLER_URL", "http://100.89.225.106:18765")
CONTROLLER_TIMEOUT = 5.0  # seconds, retries included: the lead's bound; slower is "down" (fail open)
JOB_CACHE = "cmux-compile-jobs.json"  # in the git common dir: finished jobs and receipts the controller gave this clone
FAIL_OPEN_LOG = "cmux-compile-trailer-fail-open.log"  # in the git common dir: one row per push let through unchecked
CACHE_ROWS = 300
COMPILED = re.compile(r"^Compiled:[ \t]*([0-9a-f]{12,40})[ \t]*$", re.MULTILINE)
COMPILED_SKIP = re.compile(r"^Compiled-skip:[ \t]*(\S.*)$", re.MULTILINE)
PACKAGES = "Packages/"
CHECK_KIND = "cmux-next-swift-check"
BUILD_KIND = "cmux"  # `cmux-ci build cmux`: the full app build, the CEF shim included
MANIFEST = "Package.swift"
CEF_SHIM = "Packages/macOS/CmuxNext/CEFShim/"
CEF_PIN = "scripts/cmux-next/cef-manifest.json"


def swift_path(path: str) -> bool:
    """A file whose change can break the Swift build: a `.swift` file or a package manifest, under Packages/."""
    return path.startswith(PACKAGES) and (path.endswith(".swift") or path.rsplit("/", 1)[-1] == MANIFEST)


def shim_path(path: str) -> bool:
    """A file only the full app build compiles: the CEF shim's sources and headers, or the CEF fork pin."""
    return path == CEF_PIN or (path.startswith(CEF_SHIM) and path.endswith((".mm", ".cc", ".cpp", ".h", ".hpp", ".m")))


def git(repo: Path, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env, timeout=30)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:3])} failed: {result.stderr.decode(errors='replace').strip()[:200]}")
    return result.stdout.decode("utf-8", "replace")


def changed(repo: Path, a: str, b: str) -> list[str]:
    return [p for p in git(repo, "diff", "--name-only", "--no-renames", a, b, "--", PACKAGES, CEF_PIN).split("\n") if p]


def command(head: str, shim: bool = False) -> str:
    if shim:
        return (f"cmux-ci build cmux --ref {head} --tag shim-{head[:8]} (the CEF shim and fork pin are built only by the "
                "full app build; then add the trailer line `Compiled: <the job id it prints>` to the newest commit and push "
                "again)")
    return (f'cmux-ci compile-check --app --package CmuxNext --ref {head}'
            " (then add the trailer line `Compiled: <the job id it prints>` to the newest commit and push again)")


class ControllerDown(Exception):
    """The build controller did not answer for the job within CONTROLLER_TIMEOUT (the message says how it failed)."""


def fetch_job(job_id: str, timeout: float = CONTROLLER_TIMEOUT, url: str | None = None) -> dict:
    """The controller's job; {} for a job the controller does not know (refused, not failed open). Raises
    ControllerDown when no attempt got an answer within TIMEOUT (retried while time is left: a refused connection or
    a 5xx is often one busy moment)."""
    deadline, tries, last = time.monotonic() + timeout, 0, "no attempt"
    while True:
        left = deadline - time.monotonic()
        if left <= 0.05:
            raise ControllerDown(f"no answer in {timeout:.1f} s after {tries} attempt(s); last: {last}")
        tries += 1
        started = time.monotonic()
        try:
            with urllib.request.urlopen(f"{url or CONTROLLER}/v1/jobs?id={job_id}", timeout=left) as r:
                value = json.loads(r.read() or b"{}")
            return value if isinstance(value, dict) else {}
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return {}
            last = f"HTTP {error.code}"
        except ValueError as error:
            last = f"unreadable answer ({error})"
        except OSError as error:
            last = f"{type(error).__name__}: {getattr(error, 'reason', error)}"
        if time.monotonic() - started < 0.2:
            time.sleep(min(0.2, max(0.0, deadline - time.monotonic())))  # a refused connection: do not spin


def common_dir(repo: Path) -> Path:
    found = Path(git(repo, "rev-parse", "--git-common-dir").strip())
    return found if found.is_absolute() else repo / found


def read_cache(repo: Path) -> dict:
    try:
        value = json.loads((common_dir(repo) / JOB_CACHE).read_text())
    except (OSError, ValueError, RuntimeError):
        return {}
    return value if isinstance(value, dict) else {}


def remember(repo: Path, job: dict, receipts: list | None = None) -> None:
    """Keep a finished JOB (and its RECEIPTS) for a later push whose controller is silent. Best effort."""
    if not job.get("id") or job.get("state") in (None, "", "queued", "running", "leased", "pending"):
        return
    try:
        cache = read_cache(repo)
        row = dict(cache.get(job["id"]) or {})
        row["job"] = {k: job.get(k) for k in ("id", "kind", "state", "ref", "command", "artifact")}
        if receipts is not None:
            row["receipts"] = receipts
        row["seen"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        cache.pop(job["id"], None)
        cache[job["id"]] = row
        keep = dict(list(cache.items())[-CACHE_ROWS:])
        path = common_dir(repo) / JOB_CACHE
        tmp = path.with_suffix(f".{os.getpid()}.tmp")
        tmp.write_text(json.dumps(keep))
        os.replace(tmp, path)
    except (OSError, RuntimeError, TypeError, ValueError):
        pass


def fail_open(repo: Path, head: str, reason: str) -> str:
    """The loud line for a push let through unchecked, after a row in FAIL_OPEN_LOG (best effort)."""
    try:
        with open(common_dir(repo) / FAIL_OPEN_LOG, "a") as f:
            f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())}\t{head}\t{reason}\n")
    except (OSError, RuntimeError):
        pass
    return (f"!!! COMPILE TRAILER NOT CHECKED for {head[:12]}: {reason}. The push goes through UNCHECKED; the tip may "
            "not build. Say so in your report, and check the job's receipts yourself (cmux-ci log ID). !!!")


def passed_compile(job: dict, shim: bool = False) -> str | None:
    """Why JOB is not a passing app + package compile check (or, with SHIM, a passing full app build), or None."""
    words = str(job.get("command") or "").split()
    if shim:
        if job.get("kind") != BUILD_KIND:
            return (f"job {job.get('id')} is a {job.get('kind') or 'unknown'} job; a push that changes the CEF shim or fork "
                    "pin needs a full app build (`cmux-ci build cmux`, kind cmux): the compile check does not build the shim")
        if job.get("state") != "done":
            return f"job {job.get('id')} did not pass (state {job.get('state') or 'unknown'})"
        if not re.fullmatch(r"[0-9a-f]{40}", str(job.get("ref") or "")):
            return f"job {job.get('id')} names no commit"
        return None
    if job.get("kind") != CHECK_KIND:
        return f"job {job.get('id')} is a {job.get('kind') or 'unknown'} job, not a compile check ({CHECK_KIND})"
    if "--app" not in words or not any(w == "CmuxNext" and i > 0 and words[i - 1] == "--package" for i, w in enumerate(words)):
        return f"job {job.get('id')} does not compile both the app (--app) and the package (--package CmuxNext)"
    if job.get("state") != "done":
        return f"job {job.get('id')} did not pass (state {job.get('state') or 'unknown'})"
    if not re.fullmatch(r"[0-9a-f]{40}", str(job.get("ref") or "")):
        return f"job {job.get('id')} names no commit"
    return None


RECEIPTS_TIMEOUT = 5.0  # seconds for the receipts artifact (URL lookup and download): slower is "down" (fail open)


class StoreDown(Exception):
    """The controller or the artifact store did not answer for the receipts in time (fail open)."""


def fetch_receipts(job: dict, timeout: float = RECEIPTS_TIMEOUT, url: str | None = None) -> list:
    """The compile check's receipts (artifacts/receipts.json, the job's content-addressed artifact) as a list, read the
    way ci-client.py's compile_check does: the signed store URL from /v1/artifacts/<digest>/url, else the controller's
    proxy; the SHA-256 is checked. Raises StoreDown when nothing answers within TIMEOUT; a job with no artifact, or an
    artifact that is not receipts, is [] (no verdict: refused)."""
    digest = str(job.get("artifact") or "")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        return []
    base, deadline = url or CONTROLLER, time.monotonic() + timeout

    def left() -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise StoreDown("the receipts did not arrive in time")
        return remaining
    candidates = []
    try:
        with urllib.request.urlopen(f"{base}/v1/artifacts/{digest}/url", timeout=left()) as r:
            direct = json.loads(r.read() or b"{}").get("url")
        if isinstance(direct, str) and direct.startswith(("https://", "http://")):
            candidates.append(direct)
    except urllib.error.HTTPError:
        pass  # no store copy: the proxy below
    except (OSError, ValueError) as error:
        raise StoreDown(f"the controller did not answer for the receipts ({type(error).__name__})") from error
    candidates.append(f"{base}/v1/artifacts/{digest}")
    last = None
    for address in candidates:
        try:
            req = urllib.request.Request(address, headers={"User-Agent": "cmux-ci"})
            with urllib.request.urlopen(req, timeout=left()) as r:
                data = r.read(8 << 20)
        except urllib.error.HTTPError as error:
            last = error
            continue
        except (OSError, ValueError) as error:
            last = error
            continue
        if hashlib.sha256(data).hexdigest() != digest[7:]:
            last = ValueError("receipts SHA-256 mismatch")
            continue
        try:
            value = json.loads(data)
        except ValueError:
            return []
        if isinstance(value, dict):
            value = value.get("receipts", [])
        return value if isinstance(value, list) else []
    if isinstance(last, urllib.error.HTTPError) and last.code == 404:
        return []  # the store and the controller both say there is no such artifact: no verdict
    raise StoreDown(f"the artifact store did not answer ({type(last).__name__ if last else 'no URL'})")


def asked_targets(job: dict) -> list[str]:
    """The targets the compile check was asked for: each `--package NAME` of its command, and "app" for `--app`."""
    words = str(job.get("command") or "").split()
    packages = [words[i + 1] for i, w in enumerate(words[:-1]) if w == "--package"]
    return packages + (["app"] if "--app" in words else [])


def receipt_verdict(job: dict, receipts: list) -> str | None:
    """Why the receipts do not show a pass of EVERY asked target (ci-client.py compile_check_verdict), or None. The
    recipe exits 0 when a check fails, so the job's state alone is no verdict."""
    by_target = {r.get("package"): r for r in receipts if isinstance(r, dict)}
    for target in asked_targets(job):
        receipt = by_target.get(target)
        if receipt is None:
            return f"job {job.get('id')} has no receipt for {target}: no verdict"
        if receipt.get("ok") is not True:
            return f"job {job.get('id')} FAILED to compile {target} (its receipt says ok={receipt.get('ok')!r})"
    return None


TARGET_START = re.compile(r"\.(?:target|executableTarget|testTarget)\(\s*name:\s*\"(?P<name>[A-Za-z0-9_]+)\"")


def _call_end(text: str, start: int) -> int:
    """The index after the `)` that closes the call whose `(` is at START (strings skipped)."""
    depth, i, quoted = 0, start, False
    while i < len(text):
        ch = text[i]
        if quoted:
            if ch == "\\":
                i += 1
            elif ch == '"':
                quoted = False
        elif ch == '"':
            quoted = True
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return len(text)


def module_deps(manifest: str) -> dict[str, set[str]]:
    """{target: the targets and products it depends on (by name)} from a Package.swift text (one level)."""
    deps = {}
    for m in TARGET_START.finditer(manifest):
        call = manifest[m.start():_call_end(manifest, manifest.index("(", m.start()))]
        found = re.search(r"dependencies:\s*\[", call)
        names: set[str] = set()
        if found:
            body = call[found.end() - 1:_call_end(call, found.end() - 1)]
            names = set(re.findall(r"\"([A-Za-z0-9_]+)\"", body))
        deps[m.group("name")] = names
    return deps


def module_of(path: str) -> tuple[str, str] | None:
    """(package folder, module) of a Swift file under a package's Sources/<Module>/ or Tests/<Target>/, else None."""
    parts = path.split("/")
    for folder in ("Sources", "Tests"):
        if folder in parts:
            i = parts.index(folder)
            if i + 1 < len(parts) - 1:
                return "/".join(parts[:i]), parts[i + 1]
    return None


EXPORTED = re.compile(r"^[ \t]*@_exported[ \t]+(?:(?:public|package|internal)[ \t]+)?import[ \t]+(?:[a-z]+[ \t]+)?"
                      r"([A-Za-z0-9_]+)", re.MULTILINE)


def exported_by(repo: Path, head: str) -> dict[str, set[str]]:
    """{module: the modules it re-exports with `@_exported import`} in HEAD's Swift under Packages/."""
    try:
        out = git(repo, "grep", "-I", "-E", "@_exported", head, "--", PACKAGES)
    except RuntimeError:
        return {}  # git grep exits 1 when nothing matches
    found: dict[str, set[str]] = {}
    for line in out.splitlines():
        _rev, _, rest = line.partition(":")
        path, _, text = rest.partition(":")
        module = module_of(path)
        hit = EXPORTED.match(text)
        if module and hit and path.endswith(".swift"):
            found.setdefault(module[1], set()).add(hit.group(1))
    return found


def rebase_safe(repo: Path, job_commit: str, head: str, own: list[str]) -> str | None:
    """Rule (b): why the Swift that differs between JOB_COMMIT (what was compiled) and HEAD can change what the push's
    own Swift changes (OWN: the paths the pushed range changes) compile against, or None when it cannot. A differing
    file in a module the push touches, or in a module one of those depends on (its Package.swift target, one level),
    refuses; so does a differing Package.swift of such a module's package. An edit made after the compile is in a
    touched module, so it refuses too."""
    delta = [p for p in changed(repo, job_commit, head) if swift_path(p)]
    touched = {module_of(p) for p in own if swift_path(p)} - {None}
    packages = {package for package, _ in touched} | {p.rsplit("/", 1)[0] for p in own if p.endswith("/" + MANIFEST)}
    manifests = [p for p in delta if p.endswith("/" + MANIFEST) and p.rsplit("/", 1)[0] in packages]
    if manifests:
        return f"{manifests[0]} differs"
    # A dependency is named, not placed: `"Base"` is a target of the same package, `.product(name: "CmuxShared",
    # package: "CmuxShared")` one of another package under Packages/. Match a differing file's module by name in any
    # package (an extra match only refuses), then add what those modules re-export (`@_exported import`).
    uses: set[str] = set()
    for package, module in touched:
        try:
            manifest = git(repo, "show", f"{head}:{package}/{MANIFEST}")
        except RuntimeError:
            continue
        uses |= module_deps(manifest).get(module, set())
    exports = exported_by(repo, head) if uses else {}
    frontier = set(uses)
    while frontier:
        frontier = set().union(*(exports.get(name, set()) for name in frontier)) - uses
        uses |= frontier
    uses -= {module for _, module in touched}

    def needed(path: str) -> bool:
        module = module_of(path)
        return module is not None and (module in touched or module[1] in uses)
    for path in delta:
        if path.endswith("/" + MANIFEST) and path.rsplit("/", 1)[0] not in packages:
            try:
                theirs = set(module_deps(git(repo, "show", f"{head}:{path}")))
            except RuntimeError:
                theirs = set()
            if theirs & uses:
                return f"{path} differs (it declares {sorted(theirs & uses)[0]}, which the push's modules use)"
    hit = sorted(p for p in delta if needed(p))
    if hit:
        return (f"{len(hit)} Swift file(s) differ in a module the push's files are or use "
                f"({module_of(hit[0])[1]}: {hit[0]})")
    return None


def check(repo: Path, ranges: list[tuple[str, str]], fetch=fetch_job, receipts=fetch_receipts) -> tuple[bool, list[str]]:
    """(refused, lines to print) for the pushed RANGES. Refuses only on a definite answer; fails open otherwise, loudly
    (fail_open). A silent controller is answered from JOB_CACHE when an earlier push of this clone read the job."""
    lines: list[str] = []
    head = ""
    try:
        for base, head in ranges:
            own = changed(repo, base, head)
            shim = any(shim_path(p) for p in own)
            if not shim and not any(swift_path(p) for p in own):
                continue
            message = git(repo, "log", "-1", "--format=%B", head)
            skip = COMPILED_SKIP.search(message)
            if skip:
                lines.append("prepush-gate: !!! COMPILE CHECK SKIPPED for this push (Compiled-skip: "
                             f"{skip.group(1).strip()[:120]}) !!! The tip may not build; say so in your report.")
                continue
            named = COMPILED.search(message)
            if not named:
                what = next(p for p in own if shim_path(p) or swift_path(p))
                return True, [f"prepush-gate: this push changes {'the CEF shim or fork pin' if shim else 'Swift'} ({what}) and "
                              "its newest commit names no passing " + ("app build" if shim else "compile") + ". Run: "
                              + command(head, shim)]
            cached = None
            try:
                job = fetch(named.group(1))
                if job is None:
                    raise ControllerDown("no answer")
            except ControllerDown as error:
                cached = read_cache(repo).get(named.group(1))
                if not cached or not isinstance(cached.get("job"), dict):
                    lines.append(fail_open(repo, head, f"the build controller did not answer for compile job "
                                                       f"{named.group(1)} ({error}), and this clone has no record of it"))
                    continue
                job = cached["job"]
                lines.append(f"prepush-gate: the build controller did not answer ({error}); compile job {job.get('id')} "
                             f"is judged from the record this clone read at {cached.get('seen')}.")
            if not job:
                return True, [f"prepush-gate: compile job {named.group(1)} is not known to the build controller. Run: "
                              + command(head, shim)]
            remember(repo, job)
            why = passed_compile(job, shim)
            if why:
                return True, [f"prepush-gate: {why}. Run: " + command(head, shim)]
            if job.get("kind") == CHECK_KIND:
                silent = cached is not None  # the controller was silent: its artifact proxy is unlikely to answer
                if cached is None:
                    cached = read_cache(repo).get(job.get("id")) or {}
                try:
                    if silent and isinstance(cached.get("receipts"), list):
                        raise StoreDown("the build controller did not answer")
                    got = receipts(job)
                    remember(repo, job, got)
                    verdict = receipt_verdict(job, got)
                except StoreDown as error:
                    if isinstance(cached.get("receipts"), list):
                        verdict = receipt_verdict(job, cached["receipts"])
                        lines.append(f"prepush-gate: {error}; compile job {job.get('id')}'s receipts are the ones this "
                                     f"clone read at {cached.get('seen')}.")
                    else:
                        lines.append(fail_open(repo, head, f"{error}, so compile job {job.get('id')}'s receipts (its "
                                                           "verdict) were not read"))
                        verdict = None
                if verdict:
                    return True, [f"prepush-gate: {verdict}. Run: " + command(head, shim)]
            ran = job["ref"]
            if ran != head:
                delta = changed(repo, ran, head)
                shim_delta = [p for p in delta if shim_path(p)]
                if shim and shim_delta:
                    # The shim builds as one unit with the fork: any shim or pin difference needs a build of the head.
                    return True, [f"prepush-gate: build job {job['id']} ran on {ran[:12]}, and the CEF shim or fork pin "
                                  f"differs from the push's ({shim_delta[0]}). Run: " + command(head, shim)]
                if any(swift_path(p) for p in delta):
                    unsafe = rebase_safe(repo, ran, head, own)
                    if unsafe:
                        return True, [f"prepush-gate: compile job {job['id']} ran on {ran[:12]}, and its Swift differs "
                                      f"from the push's: {unsafe}. Run: " + command(head, shim)]
            lines.append(f"prepush-gate: compile job {job['id']} passed on {ran[:12]} (Compiled trailer)")
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        return False, lines + [fail_open(repo, head or "?", f"the compile trailer check failed ({type(error).__name__}: "
                                                            f"{error})")]
    return False, lines
