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
(b) the job ran on the head's tree before a rebase (per symbol, 2026-10-28). The head joins two sides that each
    compiled: upstream's change since the job's fork point (merge-base(job, base)..base) and the push's own change
    (base..head). It is refused when
    - the push's own change differs from the one the job compiled (its -/+ lines in any Swift file or Package.swift:
      an edit after the compile, or a rebase conflict resolved), or
    - a Package.swift of a package the push touches differs upstream outside its target calls, or in the call of a
      target the push's modules are or use other than one that only gained dependencies (2026-10-28, a803: any
      target's edit refused), or another
      package's declares a module the push's modules use, or
    - upstream changed Swift in a module the push's files are in or use (their targets' dependencies, transitively,
      by name in any package under Packages/, plus `@_exported import`s) and that change meets the push's files, or
      upstream changed Swift in a module that is or uses the push's modules and the push's change meets upstream's
      new lines. Two changes meet where one side changed or removed a declaration (its signature line, a header
      continuation, an attribute, a struct's stored property without a default, an enum case changed or removed, a
      protocol requirement, an initializer, a conformance) or added one, and the other side's new lines name it: a changed or
      new member only where that code also names a type it sits in, a removed or top-level one by name alone, a
      private one only in its own file. An enum whose cases changed (a new case too) also meets a `switch` the
      other side adds in a file that names the enum or one of its cases. A side's unchanged lines are the other side's base, which built with that side's change, so
      only its new lines (and the types they sit in) count (2026-10-28, a803: a file both sides edited held
      upstream's own new declaration, and that refused).
    A body-only change (a function or accessor body, a comment) meets nothing. A file the light Swift reader cannot
    follow refuses (upstream) or counts every identifier in it (the push's). Before 2026-10-28 any upstream Swift in
    those modules refused, so a push to the app module was refused almost every time (a751: 11 of 15 rebased pushes;
    1 of 15 now, a conflict it resolved after the compile). Not covered: a line neither side changed that uses both
    sides' changed declarations, in a file the push did not change, and type-inferred uses of a changed member whose
    type the push's file never names; the full compile on CI catches those.

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
import tempfile
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


MANIFEST_COMMENT = re.compile(r"(?m)(^|[ \t])//[^\n]*")


def manifest_parts(manifest: str) -> tuple[str, dict[str, str]]:
    """(the text outside the target calls, {target: its call}), comments left out and whitespace collapsed."""
    text = MANIFEST_COMMENT.sub(r"\1", manifest)
    targets, rest, at = {}, [], 0
    for m in TARGET_START.finditer(text):
        if m.start() < at:
            continue  # inside a call already taken
        end = _call_end(text, text.index("(", m.start()))
        targets[m.group("name")] = " ".join(text[m.start():end].split())
        rest.append(text[at:m.start()])
        at = end
    rest.append(text[at:])
    return " ".join("".join(rest).split()), targets


def _without_dependencies(call: str) -> str:
    """CALL (a collapsed target call) without its `dependencies:` and `linkerSettings:` lists (what links, not what the
    push's Swift compiles against; growth of the dependencies is checked apart)."""
    for label in ("dependencies", "linkerSettings"):
        found = re.search(rf"{label}:\s*\[", call)
        if found:
            end = _call_end(call, found.end() - 1)
            call = call[:found.start()] + call[end:].lstrip(" ,")
    call = "".join(call.split())  # compared, not shown: spacing the cut left does not count
    return re.sub(r",\)", ")", re.sub(r",+", ",", call))  # nor the commas it left (`path:"x",)`)


def manifest_meets(old: str | None, new: str | None, scope: set[str]) -> str | None:
    """Why an upstream change of a package manifest (OLD -> NEW text) can change what the push compiled against: text
    outside the target calls (platforms, products, settings, a computed target list), or a target in SCOPE (the push's
    modules and what they use: a module that uses them compiles its own lines, which the symbol check reads); None when only other targets changed."""
    if old is None or new is None:
        return "it was added or removed"
    old_rest, old_targets = manifest_parts(old)
    new_rest, new_targets = manifest_parts(new)
    if old_rest != new_rest:
        return "outside its targets"
    for name in sorted(set(old_targets) | set(new_targets)):
        before, after = old_targets.get(name), new_targets.get(name)
        if before == after or name not in scope:
            continue
        if (before is not None and after is not None
                and _without_dependencies(before) == _without_dependencies(after)
                and module_deps(before).get(name, set()) <= module_deps(after).get(name, set())):
            continue  # only gained dependencies: imports are explicit, and the push's lines compiled without them
        return f"in target {name}, which the push's modules are or use"
    return None


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


# ---- Rule (b), per symbol (2026-10-28) -------------------------------------------------------------------------
# A rebased push combines two sides that each compiled: upstream (merge-base(job, base)..base, compiled by its own
# pushers) and the push's own change (compiled by the job). The combination fails to compile only where they meet: a
# declaration one side changed or removed that the other side's files name, a new declaration both could see (an
# ambiguity), or the push's own change differing from the one compiled. A light Swift reader (comments and string
# text dropped, interpolations kept, braces tracked) finds the declarations each changed line belongs to.

DECL_SCAN = re.compile(r"""
    (?P<brace>[{}])
  | (?<![.\w])(?P<kind>struct|enum|protocol|actor|typealias|associatedtype|macro)\s+`?(?P<name>[A-Za-z_]\w*)
  | (?<![.\w])class\s+(?!(?:func|var|let|subscript|init|override|final|public|private|internal|fileprivate|open|static|
        convenience|required|nonisolated|isolated|dynamic|lazy|weak|unowned|mutating|nonmutating|package)\b)`?(?P<cname>[A-Za-z_]\w*)
  | (?<![.\w])extension\s+(?P<ename>[A-Za-z_][\w.]*)
  | (?<![.\w])func\s+(?:`?(?P<fname>[A-Za-z_]\w*)|(?P<fop>[^\s(<`]+))
  | (?<![.\w])(?P<vkind>var|let)\s+`?(?P<vname>[A-Za-z_]\w*)
  | (?<![.\w])(?P<special>init|deinit|subscript)(?!\w)
  | (?<![.\w])(?P<case>case)(?!\w)
  | (?<![.\w])(?P<ctl>if|else|for|while|switch|guard|do|catch|repeat|defer|get|set|willSet|didSet|_modify|_read)(?!\w)
""", re.X)
TYPE_KINDS = {"struct", "class", "enum", "protocol", "actor", "extension"}
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
STRING_OPEN = re.compile(r'(#*)("""(?=[ \t]*\n)|")')  # a multi-line literal's `"""` ends its line
ATTRIBUTE_LINE = re.compile(r"^\s*@[A-Za-z_]\w*(?:\([^)]*\))?\s*$")


def swift_code(text: str) -> list[str] | None:
    """TEXT's lines with comments and string literal text blanked (interpolations kept as code), or None when the
    reader loses its place (an unterminated string or comment)."""
    out: list[str] = []
    buf: list[str] = []
    stack: list[list] = []  # ["str", multiline, hashes] or ["interp", paren depth]
    block, i, n = 0, 0, len(text)
    while i < n:
        c = text[i]
        top = stack[-1] if stack else None
        if c == "\n":
            if top and top[0] == "str" and not top[1]:
                return None
            out.append("".join(buf))
            buf = []
            i += 1
            continue
        if block:
            if text.startswith("/*", i):
                block, i = block + 1, i + 2
            elif text.startswith("*/", i):
                block, i = block - 1, i + 2
                buf.append(" ")
            else:
                i += 1
            continue
        if top and top[0] == "str":
            hashes = top[2]
            if c == "\\":
                if text.startswith("#" * hashes + "(", i + 1):
                    stack.append(["interp", 1])
                    buf.append(" (")
                    i += 2 + hashes
                elif hashes == 0 and i + 1 < n and text[i + 1] != "\n":
                    i += 2
                else:
                    i += 1
                continue
            close = ('"""' if top[1] else '"') + "#" * hashes
            if text.startswith(close, i):
                stack.pop()
                buf.append('"')
                i += len(close)
            else:
                i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            i = n if j < 0 else j
            continue
        if text.startswith("/*", i):
            block, i = 1, i + 2
            continue
        if c in '#"':
            m = STRING_OPEN.match(text, i)
            if m:
                stack.append(["str", m.group(2) == '"""', len(m.group(1))])
                buf.append('"')
                i = m.end()
                continue
        if top and top[0] == "interp":
            if c == "(":
                top[1] += 1
            elif c == ")":
                top[1] -= 1
                if top[1] == 0:
                    stack.pop()
        buf.append(c)
        i += 1
    out.append("".join(buf))
    return None if stack or block else out


def type_name(frames: tuple) -> str | None:
    """The innermost type or extension FRAMES sit in, or None at the top level."""
    for frame in reversed(frames):
        if frame[0] in TYPE_KINDS:
            return frame[1]
    return None


class SwiftFile:
    """One Swift file read for rule (b): per line its code, the declarations it makes (kind, name, enclosing
    frames), the frames and the open declaration (a header not yet at its `{`) it starts in."""

    def __init__(self, code: list[str]):
        self.code = code
        self.decls: list[list[tuple]] = []
        self.frames: list[tuple] = []
        self.pending: list[tuple | None] = []
        stack: list[tuple] = []
        pending: tuple | None = None
        self.ok = True
        for line in code:
            self.frames.append(tuple(stack))
            self.pending.append(pending)
            found: list[tuple] = []
            for m in DECL_SCAN.finditer(line):
                if m.group("brace") == "{":
                    stack.append(pending if pending and pending[0] != "ctl" else ("block", None, (), False))
                    pending = None
                elif m.group("brace") == "}":
                    if not stack:
                        self.ok = False
                        break
                    stack.pop()
                    pending = None
                elif m.group("ctl"):
                    pending = ("ctl", None, (), False)
                elif m.group("case"):
                    inner = stack[-1] if stack else None
                    if inner and inner[0] == "enum":
                        for name in enum_case_names(line[m.end():]):
                            found.append(("case", name, tuple(stack), hidden(stack, "")))
                    pending = ("ctl", None, (), False)
                else:
                    kind, name = decl_of(m)
                    decl = (kind, name, tuple(stack), hidden(stack, line[:m.start()]))
                    found.append(decl)
                    pending = decl
            self.decls.append(found)
            if not self.ok:
                break
        self.ok = self.ok and not stack

    def member(self, frames: tuple) -> bool:
        """True when FRAMES hold only type and extension bodies: a declaration there is visible outside a body."""
        return all(f[0] in TYPE_KINDS for f in frames)


PRIVATE = re.compile(r"(?<![\w.])(?:private|fileprivate)(?![\w(])")


def hidden(stack: list, before: str) -> bool:
    """True for a declaration other files cannot see: `private`/`fileprivate` before it on its line (BEFORE), or
    inside a type that is."""
    return bool(PRIVATE.search(before)) or any(frame[3] for frame in stack if frame[0] in TYPE_KINDS)


def decl_of(m: re.Match) -> tuple[str, str]:
    if m.group("kind"):
        return m.group("kind"), m.group("name")
    if m.group("cname"):
        return "class", m.group("cname")
    if m.group("ename"):
        return "extension", m.group("ename").rsplit(".", 1)[-1]
    if m.group("fname"):
        return "func", m.group("fname")
    if m.group("fop"):
        return "operator", m.group("fop")
    if m.group("vkind"):
        return m.group("vkind"), m.group("vname")
    return m.group("special"), m.group("special")


def enum_case_names(rest: str) -> list[str]:
    """The case names of an enum `case a, b(Int), c = 1` line (REST is the text after `case`)."""
    names, depth, start = [], 0, True
    for m in re.finditer(r"[A-Za-z_]\w*|[(\[)\],=]", rest):
        t = m.group(0)
        if t in "([":
            depth += 1
        elif t in ")]":
            depth -= 1
        elif t == "," and depth == 0:
            start = True
        elif t == "=":
            start = False
        elif start and depth == 0 and t not in ("indirect",):
            names.append(t)
            start = False
    return names


def read_swift(text: str | None) -> SwiftFile | None:
    code = swift_code(text) if text is not None else None
    if code is None:
        return None
    file = SwiftFile(code)
    return file if file.ok else None


class Change(tuple):
    """One declaration a side's change alters: (name, path, scope: the enclosing type names, strict: removed with
    no declaration of the name left on that side's new lines, private: visible only in PATH, internal: visible only
    in PATH's module and to `@testable import`s of it)."""

    def __new__(cls, name: str, path: str, scope: frozenset, strict: bool, private: bool, internal: bool = False):
        return super().__new__(cls, (name, path, scope, strict, private, internal))


PUBLIC = re.compile(r"(?<![\w.])(?:public|open|package)(?![\w(])")
TESTABLE = re.compile(r"^[ \t]*@testable[ \t]+import[ \t]+([A-Za-z0-9_]+)", re.MULTILINE)


def other_modules_see(kind: str, frames: tuple, code: str) -> bool:
    """Whether a declaration can be seen from another module without `@testable`: `public`, `open` or `package` on its
    line, or one whose access the light reader cannot tell from its line (an enum case, a member of an extension or a
    protocol, an initializer, a conformance): those count as seen."""
    if kind in ("case", "extension", "init", "deinit", "subscript", "operator"):
        return True
    if any(f[0] in ("extension", "protocol") for f in frames if f[0] in TYPE_KINDS):
        return True
    return bool(PUBLIC.search(code))


class Effect:
    """What one side's changed lines do to declarations: CHANGED (a declaration changed or removed, or a type whose
    shape changed: a stored property its memberwise initializer takes, an enum case, a protocol requirement, an
    attribute, a conformance) and NEW declarations, as ``Change`` rows, plus the paths whose enums changed cases."""

    def __init__(self):
        self.changed: list[Change] = []
        self.new: list[Change] = []
        self.cases: list[Change] = []
        self.case_names: dict[str, set[str]] = {}  # enum -> its case names on either side (a `switch` lists them)

    def extend(self, other: "Effect") -> None:
        self.changed += other.changed
        self.new += other.new
        self.cases += other.cases
        for enum, names in other.case_names.items():
            self.case_names.setdefault(enum, set()).update(names)


def scope_of(frames: tuple) -> frozenset:
    """The names of the types and extensions FRAMES sit in."""
    return frozenset(f[1] for f in frames if f[0] in TYPE_KINDS)


def owners(file: SwiftFile, index: int) -> list[tuple[tuple, bool]]:
    """The declarations line INDEX is part of, as far as callers can see, each with True when the line is only part
    of it (an attribute line, or a continuation of its header): its own member or top-level declarations, the
    declaration an attribute line annotates, or the header a continuation line belongs to. A line in a function or
    accessor body belongs to none: a body change does not change what callers compile against."""
    own = [d for d in file.decls[index] if file.member(d[2])]
    if own:
        return [(d, False) for d in own]
    if file.decls[index]:
        return []  # a local declaration
    code = file.code[index]
    if not IDENT.search(code):
        return []
    if ATTRIBUTE_LINE.match(code):
        for j in range(index + 1, min(index + 8, len(file.code))):
            if file.decls[j]:
                return [(d, True) for d in file.decls[j] if file.member(d[2])]
        return []
    pending = file.pending[index]
    if pending and pending[0] not in ("ctl", "block") and file.member(pending[2]) and file.member(file.frames[index]):
        return [(pending, True)]
    return []


def signature(code: str) -> str:
    """A declaration line as callers see it: the text before its body's `{`, whitespace collapsed."""
    return " ".join(code.split("{", 1)[0].split())


def side_effect(path: str, old: SwiftFile | None, new: SwiftFile | None, removed: list[int], added: list[int]) -> Effect:
    """The ``Effect`` of one file's change: REMOVED lines of OLD and ADDED lines of NEW (indexes; a missing side is
    None). A declaration whose line changed only after its signature (a body moved onto its line) is not a change."""
    effect = Effect()
    seen: list[dict] = [{}, {}]  # per side: (kind, name, scope) -> set of signatures (None: a partial line)
    outside: set = set()  # the keys another module can see on either side
    existed = {d[1] for row in (old.decls if old else []) for d in row if d[0] in TYPE_KINDS}
    shape: list[tuple] = []  # (type decl, why) a member change alters
    for side, (file, lines) in enumerate(((old, removed), (new, added))):
        if file is None:
            continue
        for index in lines:
            if index >= len(file.code):
                continue
            code = file.code[index]
            for decl, partial in owners(file, index):
                kind, name, frames, private = decl
                if kind in ("init", "deinit", "subscript", "operator"):
                    name = type_name(frames) or name  # callers name the type: `Kit(...)`, `kit[0]`
                key = (kind, name, scope_of(frames), private)
                if partial:
                    text = None
                elif kind == "case":
                    found = re.search(rf"(?<!\w){re.escape(name)}(?!\w)(\s*\([^)]*\))?(\s*=\s*[^,]+)?", code)
                    text = " ".join((found.group(0) if found else code).split())
                else:
                    text = signature(code)
                seen[side].setdefault(key, set()).add(text)
                if partial or other_modules_see(kind, frames, code):
                    outside.add(key)
                inner = frames[-1] if frames else None
                if inner is None or inner[0] not in TYPE_KINDS or partial or inner[1] not in existed:
                    continue
                if kind == "case" and inner[0] == "enum":
                    shape.append((inner, "case", file))
                elif inner[0] == "protocol":
                    shape.append((inner, "requirement", file))
                elif (inner[0] == "struct" and kind in ("var", "let") and "=" not in code and "{" not in code
                      and not re.search(r"(?<!\w)static(?!\w)", code)):
                    shape.append((inner, "stored", file))
    before, after = seen
    for key in sorted(set(before) | set(after), key=str):
        kind, name, scope, private = key
        if kind in ("init", "deinit", "subscript", "operator"):
            if key in before and key in after and before[key] == after[key] and None not in before[key]:
                continue
            if key in after and key not in before and name not in existed:
                effect.new.append(Change(name, path, scope - {name}, False, private))  # part of a new type
            else:
                # A changed initializer, or a new one in a type that existed: a struct loses its memberwise one.
                effect.changed.append(Change(name, path, frozenset(), False, private))
            continue
        internal = key not in outside
        if key in before and key in after:
            if before[key] == after[key] and None not in before[key]:
                continue  # the same signature: a body or a comment changed
            effect.changed.append(Change(name, path, scope, False, private, internal))
        elif key in before:
            effect.changed.append(Change(name, path, scope, True, private, internal))
        elif kind == "extension":
            if any(":" in (text or ":") for text in after[key]):
                effect.changed.append(Change(name, path, frozenset(), False, private))  # a new conformance
        else:
            effect.new.append(Change(name, path, scope, False, private, internal))
    def only_gains_cases(enum: str) -> bool:
        """Every case ENUM had is still there, the same: code that names the enum still compiles (a `switch` over it
        may not, which ``Effect.cases`` covers)."""
        return all(key in after and after[key] == before[key] and None not in before[key]
                   for key in before if key[0] == "case" and enum in key[2])

    def type_internal(inner: tuple, file: SwiftFile) -> bool:
        """The type INNER is module-internal: its declaration line in FILE has no public/open/package (and it does not
        sit in an extension or protocol); a type whose line is not found counts as seen."""
        for index, row in enumerate(file.decls):
            if inner in row:
                return not other_modules_see(inner[0], inner[2], file.code[index])
        return False

    for inner, why, file in shape:
        row = Change(inner[1], path, scope_of(inner[2]), False, inner[3], type_internal(inner, file))
        if why == "case":
            effect.cases.append(row)
            effect.case_names.setdefault(inner[1], set()).update(
                key[1] for key in set(before) | set(after) if key[0] == "case" and inner[1] in key[2])
            if only_gains_cases(inner[1]):
                continue
        effect.changed.append(row)
    return effect


def tokens_of(text: str | None) -> set[str]:
    """The identifiers a Swift file names in code (comments and string text left out; on a file the reader cannot
    follow, every identifier in the text: more names only refuse more)."""
    if text is None:
        return set()
    code = swift_code(text)
    return set(IDENT.findall("\n".join(code) if code is not None else text))


def added_tokens(text: str, added: list[int]) -> set[str]:
    """The identifiers TEXT's ADDED lines name in code, plus the types and extensions those lines sit in (on a file the
    reader cannot follow, every identifier in it)."""
    file = read_swift(text)
    if file is None:
        return tokens_of(text)
    found: set[str] = set()
    for index in added:
        if index < len(file.code):
            found |= set(IDENT.findall(file.code[index]))
            found |= scope_of(file.frames[index])
    return found


def meets(effect: Effect, files: dict[str, set[str]], switches: dict[str, bool],
          testable: dict[str, set[str]] | None = None) -> tuple[str, str] | None:
    """(why, the file) a side with EFFECT can break among FILES {path: the names it uses} (SWITCHES {path: its change
    adds a `switch`}), or None. A changed or new member counts where the file also names a type it sits in (a removed
    one, and a top-level one, by name alone); a private one only in its own file."""
    home = module_of
    def where(row: Change, need_scope: bool):
        for path, tokens in sorted(files.items()):
            if row[4] and path != row[1]:
                continue
            if (len(row) > 5 and row[5] and home(path) != home(row[1])
                    and (home(row[1]) or ("", ""))[1] not in (testable or {}).get(path, set())):
                continue  # internal to another module, and this file has no `@testable import` of it
            if row[0] in tokens and (not need_scope or not row[2] or row[2] & tokens):
                return path
        return None
    for row in effect.changed:
        hit = where(row, not row[3])
        if hit:
            return f"`{row[0]}` {'was removed' if row[3] else 'changed'} in {row[1]}", hit
    for row in effect.new:
        hit = where(row, True)
        if hit:
            return f"`{row[0]}` is new in {row[1]}", hit
    for row in effect.cases:
        # A switch the other side adds meets the enum where its file names the enum or a case of it (a switch over it
        # lists them); any switch counted before 2026-10-28 (a803: six refusals over switches on other enums).
        names = {row[0]} | effect.case_names.get(row[0], set())
        for path, adds in sorted(switches.items()):
            if (len(row) > 5 and row[5] and module_of(path) != module_of(row[1])
                    and (module_of(row[1]) or ("", ""))[1] not in (testable or {}).get(path, set())):
                continue  # an enum internal to another module this file does not `@testable import`
            if adds and (not row[4] or path == row[1]) and names & files.get(path, set()):
                return f"enum `{row[0]}` changed its cases in {row[1]}", path
    return None


def blobs(repo: Path, specs: list[str]) -> dict[str, str | None]:
    """{"rev:path": text, or None when there is no such file} through one `git cat-file --batch`."""
    if not specs:
        return {}
    env = {k: v for k, v in os.environ.items() if k not in ("GIT_INDEX_FILE", "GIT_WORK_TREE")}
    # Through a file, never `input=`: a write into a pipe can block in the kernel past any timeout (git_batch.py).
    with tempfile.TemporaryFile() as stdin:
        stdin.write("\n".join(specs).encode() + b"\n")
        stdin.seek(0)
        result = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], stdin=stdin, capture_output=True,
                                env=env, timeout=60)
    if result.returncode != 0:
        raise RuntimeError(f"git cat-file failed: {result.stderr.decode(errors='replace').strip()[:200]}")
    out, data, at = {}, result.stdout, 0
    for spec in specs:
        end = data.index(b"\n", at)
        header = data[at:end].decode()
        at = end + 1
        if header.endswith(" missing") or header.endswith(" ambiguous"):
            out[spec] = None
            continue
        size = int(header.rsplit(" ", 1)[1])
        out[spec] = data[at:at + size].decode("utf-8", "replace")
        at += size + 1
    return out


HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def hunks(repo: Path, a: str, b: str, manifests: bool = False) -> dict[str, tuple[list[int], list[int], list[str]]]:
    """{path: (removed line indexes in A, added line indexes in B, the -/+ lines)} of A..B for the `.swift` files
    under Packages/ (with MANIFESTS, for the Package.swift files instead)."""
    out: dict[str, tuple[list[int], list[int], list[str]]] = {}
    current, header = None, False
    for line in git(repo, "diff", "-U0", "--no-renames", "--no-color", "--no-ext-diff", a, b, "--", PACKAGES).split("\n"):
        if line.startswith("diff --git "):
            current, header = None, True
        elif header and (line.startswith("--- ") or line.startswith("+++ ")):
            path = line[4:]
            if path != "/dev/null" and current is None:
                path = path[2:]
                wanted = path.endswith("/" + MANIFEST) if manifests else path.endswith(".swift")
                current = path if swift_path(path) and wanted else "-"
                if current != "-":
                    out.setdefault(current, ([], [], []))
        elif line.startswith("@@"):
            header = False
            m = HUNK.match(line)
            if m and current not in (None, "-"):
                a0, an, b0, bn = int(m.group(1)), int(m.group(2) or 1), int(m.group(3)), int(m.group(4) or 1)
                out[current][0].extend(range(a0 - 1, a0 - 1 + an))
                out[current][1].extend(range(b0 - 1, b0 - 1 + bn))
        elif not header and line[:1] in "+-" and current not in (None, "-"):
            out[current][2].append(line)
    return out


def module_graph(repo: Path, head: str) -> dict[str, set[str]]:
    """{target: the targets and products it depends on} over every Package.swift under Packages/ at HEAD (a name in
    two packages gets both lists: an extra edge only widens what is checked)."""
    manifests = [p for p in git(repo, "ls-tree", "-r", "--name-only", head, "--", PACKAGES).split("\n")
                 if p.endswith("/" + MANIFEST)]
    graph: dict[str, set[str]] = {}
    for text in blobs(repo, [f"{head}:{p}" for p in manifests]).values():
        for target, deps in module_deps(text or "").items():
            graph.setdefault(target, set()).update(deps)
    return graph


def closure(start: set[str], edges: dict[str, set[str]]) -> set[str]:
    seen, frontier = set(start), set(start)
    while frontier:
        frontier = set().union(*(edges.get(n, set()) for n in frontier)) - seen
        seen |= frontier
    return seen


def rebase_safe(repo: Path, job_commit: str, head: str, own: list[str], base: str | None = None) -> str | None:
    """Rule (b): why the push's own change (BASE..HEAD; OWN its paths) and the upstream change since the compile
    (merge-base(JOB_COMMIT, BASE)..BASE) can meet so the head need not build, or None when they cannot (see
    the module docstring)."""
    base = base or git(repo, "rev-parse", f"{head}^").strip()
    fork = git(repo, "merge-base", job_commit, base).strip()
    own_hunks = hunks(repo, base, head)
    compiled_hunks = hunks(repo, fork, job_commit)
    for path in sorted(set(own_hunks) | set(compiled_hunks)):
        if own_hunks.get(path, ([], [], []))[2] != compiled_hunks.get(path, ([], [], []))[2]:
            module = module_of(path)
            return (f"the push's change to {path} ({module[1] if module else 'no module'}) is not the one the compile "
                    "job compiled (edited after the compile, or a rebase conflict resolved)")
    own_manifest, compiled_manifest = hunks(repo, base, head, manifests=True), hunks(repo, fork, job_commit, manifests=True)
    for path in sorted(set(own_manifest) | set(compiled_manifest)):
        if own_manifest.get(path, ([], [], []))[2] != compiled_manifest.get(path, ([], [], []))[2]:
            return f"the push's change to {path} is not the one the compile job compiled"
    upstream = [p for p in changed(repo, fork, base) if swift_path(p)]
    if not upstream:
        return None
    touched = {module_of(p) for p in own if swift_path(p)} - {None}
    packages = {package for package, _ in touched} | {p.rsplit("/", 1)[0] for p in own if p.endswith("/" + MANIFEST)}
    graph = module_graph(repo, head)
    exports = exported_by(repo, head)
    names = {module for _, module in touched}
    forward = closure(names, {k: graph.get(k, set()) | exports.get(k, set()) for k in set(graph) | set(exports)})
    users: dict[str, set[str]] = {}
    for target, deps in graph.items():
        for dep in deps:
            users.setdefault(dep, set()).add(target)
    reverse = closure(names, users)
    # A manifest of a package the push touches: only a change to a target in the push's reach, or outside the
    # targets, counts (a803, 2026-10-28: another target's dependency list refused its compiled change).
    manifests = [p for p in upstream if p.endswith("/" + MANIFEST) and p.rsplit("/", 1)[0] in packages]
    if manifests:
        texts = blobs(repo, [f"{fork}:{p}" for p in manifests] + [f"{base}:{p}" for p in manifests])
        for path in manifests:
            why = manifest_meets(texts[f"{fork}:{path}"], texts[f"{base}:{path}"], forward)
            if why:
                return f"{path} differs upstream ({why})"
    for path in upstream:
        if path.endswith("/" + MANIFEST) and path.rsplit("/", 1)[0] not in packages:
            theirs = set(module_deps(blobs(repo, [f"{head}:{path}"]).get(f"{head}:{path}") or ""))
            if theirs & forward:
                return f"{path} differs (it declares {sorted(theirs & forward)[0]}, which the push's modules use)"
    up_hunks = hunks(repo, fork, base)
    scoped = [p for p in up_hunks if module_of(p) and module_of(p)[1] in forward | reverse]
    if not scoped:
        return None
    own_swift = list(own_hunks)
    texts = blobs(repo, [f"{fork}:{p}" for p in scoped] + [f"{base}:{p}" for p in scoped]
                  + [f"{base}:{p}" for p in own_swift] + [f"{head}:{p}" for p in own_swift])

    def adds_switch(lines: list[str]) -> bool:
        return any(line.startswith("+") and re.search(r"(?<![.\w])switch(?!\w)", line) for line in lines)

    def effect(path: str, old_rev: str, new_rev: str, rows: tuple) -> Effect | None:
        old_text, new_text = texts[f"{old_rev}:{path}"], texts[f"{new_rev}:{path}"]
        old, new = read_swift(old_text), read_swift(new_text)
        if (old is None and old_text is not None) or (new is None and new_text is not None):
            return None
        return side_effect(path, old, new, rows[0], rows[1])
    # Upstream's change against the push's files (they compile against it). The push's unchanged lines are the
    # base's, which compile with upstream's change: only its new lines (and the types they sit in) can name what
    # upstream changed without a compile having seen both (a803, 2026-10-28: a file both sides edited held upstream's
    # own new declaration, so "the push names it" matched upstream's own line).
    own_files = {p: added_tokens(texts[f"{head}:{p}"], own_hunks[p][1]) for p in own_swift
                 if texts[f"{head}:{p}"] is not None}
    own_switches = {p: adds_switch(own_hunks[p][2]) for p in own_files}
    own_testable = {p: set(TESTABLE.findall(texts[f"{head}:{p}"])) for p in own_files}
    for path in scoped:
        if module_of(path)[1] not in forward:
            continue
        found = effect(path, fork, base, up_hunks[path])
        if found is None:
            return f"upstream changed {path}, in a module the push is in or uses, and the gate could not read it"
        hit = meets(found, own_files, own_switches, own_testable)
        if hit:
            return f"upstream: {hit[0]}, and the push's {hit[1]} names it"
    # The push's change against upstream's changed files in modules that see the push's (they compile against it).
    reverse_paths = [p for p in scoped if module_of(p)[1] in reverse]
    if not reverse_paths:
        return None
    own_effect = Effect()
    for path in own_swift:
        found = effect(path, base, head, own_hunks[path])
        if found is None:
            return f"the gate could not read the push's {path}, and upstream changed {reverse_paths[0]}"
        own_effect.extend(found)
    # Upstream's unchanged lines are the fork's, which the job compiled with the push's change: only its new lines
    # (and the types they sit in) can name what the push changed without the job having seen it.
    up_files = {p: added_tokens(texts[f"{base}:{p}"], up_hunks[p][1]) for p in reverse_paths
                if texts[f"{base}:{p}"] is not None}
    hit = meets(own_effect, up_files, {p: adds_switch(up_hunks[p][2]) for p in up_files},
                {p: set(TESTABLE.findall(texts[f"{base}:{p}"])) for p in up_files})
    if hit:
        return f"the push: {hit[0]}, and upstream's {hit[1]} names it"
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
                    unsafe = rebase_safe(repo, ran, head, own, base)
                    if unsafe:
                        return True, [f"prepush-gate: compile job {job['id']} ran on {ran[:12]}, and its Swift differs "
                                      f"from the push's: {unsafe}. Run: " + command(head, shim)]
            lines.append(f"prepush-gate: compile job {job['id']} passed on {ran[:12]} (Compiled trailer)")
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
        return False, lines + [fail_open(repo, head or "?", f"the compile trailer check failed ({type(error).__name__}: "
                                                            f"{error})")]
    return False, lines
