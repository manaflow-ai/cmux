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

`Compiled-skip: <reason>` on the newest commit lets the push through for an emergency; the gate prints it loudly. The
check fails open: a controller that does not answer within CONTROLLER_TIMEOUT, a git error or a parse error lets the
push through with a warning. It is local only (the pre-push gate's guardrails path), never a CI gate.
"""
from __future__ import annotations

import json
import os
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
MANIFEST = "Package.swift"


def swift_path(path: str) -> bool:
    """A file whose change can break the Swift build: a `.swift` file or a package manifest, under Packages/."""
    return path.startswith(PACKAGES) and (path.endswith(".swift") or path.rsplit("/", 1)[-1] == MANIFEST)


def git(repo: Path, *args: str) -> str:
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    result = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, env=env, timeout=30)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args[:3])} failed: {result.stderr.decode(errors='replace').strip()[:200]}")
    return result.stdout.decode("utf-8", "replace")


def changed(repo: Path, a: str, b: str) -> list[str]:
    return [p for p in git(repo, "diff", "--name-only", "--no-renames", a, b, "--", PACKAGES).split("\n") if p]


def command(head: str) -> str:
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


def passed_compile(job: dict) -> str | None:
    """Why JOB is not a passing app + package compile check, or None when it is."""
    words = str(job.get("command") or "").split()
    if job.get("kind") != CHECK_KIND:
        return f"job {job.get('id')} is a {job.get('kind') or 'unknown'} job, not a compile check ({CHECK_KIND})"
    if "--app" not in words or not any(w == "CmuxNext" and i > 0 and words[i - 1] == "--package" for i, w in enumerate(words)):
        return f"job {job.get('id')} does not compile both the app (--app) and the package (--package CmuxNext)"
    if job.get("state") != "done":
        return f"job {job.get('id')} did not pass (state {job.get('state') or 'unknown'})"
    if not re.fullmatch(r"[0-9a-f]{40}", str(job.get("ref") or "")):
        return f"job {job.get('id')} names no commit"
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


def check(repo: Path, ranges: list[tuple[str, str]], fetch=fetch_job) -> tuple[bool, list[str]]:
    """(refused, lines to print) for the pushed RANGES. Refuses only on a definite answer; fails open otherwise."""
    lines: list[str] = []
    try:
        for base, head in ranges:
            own = changed(repo, base, head)
            if not any(swift_path(p) for p in own):
                continue
            message = git(repo, "log", "-1", "--format=%B", head)
            skip = COMPILED_SKIP.search(message)
            if skip:
                lines.append("prepush-gate: !!! COMPILE CHECK SKIPPED for this push (Compiled-skip: "
                             f"{skip.group(1).strip()[:120]}) !!! The tip may not build; say so in your report.")
                continue
            named = COMPILED.search(message)
            if not named:
                return True, [f"prepush-gate: this push changes Swift ({next(p for p in own if swift_path(p))}) and its "
                              "newest commit names no passing compile. Run: " + command(head)]
            job = fetch(named.group(1))
            if job is None:
                lines.append(f"prepush-gate: WARNING: the build controller did not answer within {CONTROLLER_TIMEOUT:.0f} s, "
                             f"so compile job {named.group(1)} was not checked (allowed).")
                continue
            if not job:
                return True, [f"prepush-gate: compile job {named.group(1)} is not known to the build controller. Run: "
                              + command(head)]
            why = passed_compile(job)
            if why:
                return True, [f"prepush-gate: {why}. Run: " + command(head)]
            ran = job["ref"]
            if ran != head:
                same = not any(swift_path(p) for p in changed(repo, ran, head))
                if not same:
                    unsafe = rebase_safe(repo, ran, head, own)
                    if unsafe:
                        return True, [f"prepush-gate: compile job {job['id']} ran on {ran[:12]}, and its Swift differs "
                                      f"from the push's: {unsafe}. Run: " + command(head)]
            lines.append(f"prepush-gate: compile job {job['id']} passed on {ran[:12]} (Compiled trailer)")
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        return False, [f"prepush-gate: WARNING: the compile trailer check failed ({type(error).__name__}: {error}); "
                       "not applied to this push."]
    return False, lines
