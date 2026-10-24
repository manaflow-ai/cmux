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
(b) the job ran on the head's tree before a rebase: the commits the head brought in over the job's commit (the
    upstream side) change no `.swift` or `Package.swift` file in a Swift module (target folder) that the push's own
    changes touch, nor in a module those modules depend on (their target's dependencies in Package.swift, one level).
    Without the module check, an upstream rename the push's files use (the case that broke the tip) would pass.

The CEF shim (C++/Objective-C++ under Packages/macOS/CmuxNext/CEFShim/) and the CEF fork pin
(scripts/cmux-next/cef-manifest.json) are built only by the full fleet app build, not by the compile check (PL-cef-layer
2026-10-24: a shim namespace error passed compile-check and failed the app build, job 2577a32f). A push that changes
them must name a passing `cmux-ci build cmux` job (kind `cmux`) of the same shim and pin.

`Compiled-skip: <reason>` on the newest commit lets the push through for an emergency; the gate prints it loudly. The
check fails open: a controller that does not answer within CONTROLLER_TIMEOUT, a git error or a parse error lets the
push through with a warning. It is local only (the pre-push gate's guardrails path), never a CI gate.
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
CONTROLLER_TIMEOUT = 2.0  # seconds: the lead's bound; slower is "down" (fail open)
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


def fetch_job(job_id: str, timeout: float = CONTROLLER_TIMEOUT, url: str | None = None) -> dict | None:
    """The controller's job, or None when the controller does not answer in time (down: fail open). A job the
    controller does not know is {} (refused, not failed open)."""
    try:
        with urllib.request.urlopen(f"{url or CONTROLLER}/v1/jobs?id={job_id}", timeout=timeout) as r:
            value = json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as error:
        return {} if error.code == 404 else None
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else {}


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


TARGET_START = re.compile(r"\.(?:target|executableTarget)\(\s*name:\s*\"(?P<name>[A-Za-z0-9_]+)\"")


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
    """(package folder, module) of a Swift file under a package's Sources/<Module>/, else None."""
    parts = path.split("/")
    if "Sources" in parts:
        i = parts.index("Sources")
        if i + 1 < len(parts) - 1:
            return "/".join(parts[:i]), parts[i + 1]
    return None


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
    needed = set(touched)
    for package, module in touched:
        try:
            manifest = git(repo, "show", f"{head}:{package}/{MANIFEST}")
        except RuntimeError:
            continue
        needed |= {(package, dep) for dep in module_deps(manifest).get(module, set())}
    hit = sorted(p for p in delta if module_of(p) in needed)
    if hit:
        return (f"{len(hit)} Swift file(s) differ in a module the push's files are or use "
                f"({module_of(hit[0])[1]}: {hit[0]})")
    return None


def check(repo: Path, ranges: list[tuple[str, str]], fetch=fetch_job, receipts=fetch_receipts) -> tuple[bool, list[str]]:
    """(refused, lines to print) for the pushed RANGES. Refuses only on a definite answer; fails open otherwise."""
    lines: list[str] = []
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
            job = fetch(named.group(1))
            if job is None:
                lines.append(f"prepush-gate: WARNING: the build controller did not answer within {CONTROLLER_TIMEOUT:.0f} s, "
                             f"so compile job {named.group(1)} was not checked (allowed).")
                continue
            if not job:
                return True, [f"prepush-gate: compile job {named.group(1)} is not known to the build controller. Run: "
                              + command(head, shim)]
            why = passed_compile(job, shim)
            if why:
                return True, [f"prepush-gate: {why}. Run: " + command(head, shim)]
            if job.get("kind") == CHECK_KIND:
                try:
                    verdict = receipt_verdict(job, receipts(job))
                except StoreDown as error:
                    lines.append(f"prepush-gate: WARNING: {error}, so compile job {job.get('id')}'s verdict was not "
                                 "checked (allowed).")
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
        return False, [f"prepush-gate: WARNING: the compile trailer check failed ({type(error).__name__}: {error}); "
                       "not applied to this push."]
    return False, lines
