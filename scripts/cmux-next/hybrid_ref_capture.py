#!/usr/bin/env python3
"""Capture the Mac DEV Release compile's build rules for the fleet whole-app build (its REF).

The fleet build of the cmux NEXT DEV app plans its Swift compiles and links from the
recorded rules of one real Mac build of the same shape (the REF): the SwiftDriver lines,
Swift Build's build description and the planning files. Until 2026-10-26 the only REF was
assembled by hand from an old nightly build, so the fleet path stopped as soon as
Package.resolved moved. This records a REF from the per-landing DEV compile itself, at its
own paths, when the inputs that change build lines have no capture yet.

  hybrid_ref_capture.py key REPO
      Prints the REF key: sha256 over Package.resolved, every file of cmux.xcodeproj but
      xcuserdata, the macOS xcconfigs, the local package manifests, the compile recipe
      (KEY_PATHS), the DEV build settings (HYBRID_REF_SETTINGS: the
      compile step's CMUX_NEXT_*) and the toolchain (xcodebuild -version, the SDK build). Most landings share one.

  hybrid_ref_capture.py capture --log LOG --workspace WS --derived-data DD --sha SHA
                                --key KEY --run-id N --out DIR [--lane L] [--upload]
                                [--read-workspace SNAP_WS --read-derived-data SNAP_DD]
      Checks that the log (a build with EMIT_FRONTEND_COMMAND_LINES=YES) has a frontend
      compile line for the module of every SwiftDriver task; a module without one makes the
      capture incomplete (manifest "complete": false, "missing": [...]) and nothing is
      uploaded. A complete capture packs the log, XCBuildData, DerivedData without objects
      or the compilation cache, the workspace without .git or build output, and the
      committed Package.resolved, splits each pack under PART_BYTES, and with --upload puts
      every part in the build fleet's private store (cmux-ci artifact-put --lane L). WS and
      DD are the build's paths (the REF's); the files come from the --read-* snapshot of
      them, cloned while the build still held its host lock (compile-dev-release.sh). It
      writes DIR/manifest.json: names, sizes and sha256 only, never file contents, since the
      manifest goes to this public repository's Actions artifacts.

  hybrid_ref_capture.py have --key KEY --repo OWNER/NAME [--budget SECONDS]
      Prints complete=N, the hybrid-ref-capture-KEY artifacts that are unexpired and under 13
      days old (a capture counts while its packs are readable in the store), and
      recent_incomplete=M, the hybrid-ref-capture-incomplete-KEY ones under a day old (a key
      whose capture comes out incomplete is compiled for it again once a day, not on every
      landing). A rate limit (403 or 429 that says so) waits for its Retry-After or reset,
      other transient failures back off, and once the next wait would pass --budget (default
      600 s, both lookups) it exits 1 with the last error, so the caller never reads "no
      answer" as "a capture exists" (GH_TOKEN: the job's token).
"""
from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

SCHEMA = 1
# cmux-ci artifact-put takes at most 512 MiB a file.
PART_BYTES = 480 * 1024 * 1024
RESOLVED = "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
# What sets a build line: the project, the macOS xcconfigs, the local package manifests (a target or
# dependency added there changes the plan) and the compile recipe with its hardcoded settings.
KEY_PATHS = ("cmux.xcodeproj", "*.xcconfig", "Packages/macOS/**/Package.swift", "Packages/Shared/**/Package.swift",
             "vendor/**/Package.swift", "scripts/cmux-next/check-cmux-scheme-compile.sh",
             "scripts/cmux-next/compile-dev-release.sh", "scripts/cmux-next/lib/compilation-cache.sh")
KEY_SKIP = re.compile(r"(^|/)xcuserdata/|^ios/")
# The compile step's settings that change a build line (check-cmux-scheme-compile.sh reads them);
# the capture steps get them as HYBRID_REF_SETTINGS.
SETTINGS = ("CMUX_NEXT_CONFIGURATION", "CMUX_NEXT_PRODUCT_NAME", "CMUX_NEXT_BUNDLE_ID",
            "CMUX_NEXT_CODE_SIGN_ENTITLEMENTS", "CMUX_NEXT_AUTH_CALLBACK_SCHEME",
            "CMUX_NEXT_BROWSER_DATA_IMPORT", "CMUX_NEXT_SWIFT_COMPILATION_MODE", "CMUX_NEXT_TUI_MODE")
# check-cmux-scheme-compile.sh writes this file for a compiled-out browser-data import and
# restores it after the build; the REF needs the tree the compiler read.
BROWSER_SOURCES = "Packages/macOS/CmuxNext/Sources/CmuxNextBrowserImport/Resources/browser-sources.json"
BROWSER_SOURCES_COMPILED_OUT = "scripts/cmux-next/lib/browser-sources-compiled-out.json"
WS_EXCLUDE = re.compile(r"(^|/)(\.git|target|node_modules|\.build|DerivedData)(/|$)")
DD_EXCLUDE = re.compile(r"(^|/)(\.git|CompilationCache\.noindex|Logs|SourcePackages/repositories)(/|$)"
                        r"|\.(o|app|dSYM)(/|$)|(^|/)Chromium Embedded Framework\.framework(/|$)")
DRIVER = re.compile(r"^SwiftDriver (\S+) normal (\S+) ")


def settings(environ=os.environ) -> dict[str, str]:
    """HYBRID_REF_SETTINGS (NAME=VALUE lines: the compile step's SETTINGS); a name it lacks is empty."""
    given = {}
    for line in environ.get("HYBRID_REF_SETTINGS", "").splitlines():
        name, sep, value = line.strip().partition("=")
        if sep:
            given[name] = value
    unknown = sorted(set(given) - set(SETTINGS))
    if unknown:
        raise SystemExit(f"hybrid_ref_capture: HYBRID_REF_SETTINGS names unknown settings: {', '.join(unknown)}")
    return {name: given.get(name, "") for name in SETTINGS}


def xcode_version(text: str) -> str:
    """'Xcode 26.6' and 'Build version 17F113' as 'Xcode 26.6 / 17F113'."""
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    build = lines[1].split()[-1] if len(lines) > 1 else ""
    return f"{lines[0]} / {build}" if lines else ""


def run(argv: list[str]) -> str:
    return subprocess.run(argv, capture_output=True, text=True, check=True).stdout


def key(repo: Path, environ=os.environ, toolchain: str | None = None) -> str:
    h = hashlib.sha256()

    def add(label: str, data: bytes) -> None:
        h.update(label.encode() + b"\0" + hashlib.sha256(data).hexdigest().encode() + b"\n")

    files = run(["git", "-C", str(repo), "ls-files", "-z", "--", *KEY_PATHS]).split("\0")
    for name in sorted(f for f in files if f and not KEY_SKIP.search(f)):
        add(name, (repo / name).read_bytes())
    for name, value in settings(environ).items():
        add("env:" + name, value.encode())
    if toolchain is None:
        toolchain = run(["xcodebuild", "-version"]) + run(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"])
    add("toolchain", toolchain.encode())
    return h.hexdigest()


def drivers_and_lines(log: Path) -> tuple[list[str], set[str], str]:
    """The SwiftDriver task modules, the modules with a frontend compile line, and the xcodebuild line."""
    # A driver task names its target ("SwiftDriver cmux-next ..."), and its module is the
    # -module-name of the builtin-SwiftDriver line under it: they differ for the app (target
    # cmux-next, module cmux), and the frontend lines name the module.
    modules, compiled, command, target = [], set(), "", None
    with log.open(errors="replace") as lines:
        for raw in lines:
            line = raw.rstrip("\n")
            if line.startswith("xcodebuild command: ") and not command:
                command = line.removeprefix("xcodebuild command: ")
            match = DRIVER.match(line)
            if match:
                if target is not None:
                    modules.append(target)
                target = match.group(1)
                continue
            text = line.strip()
            if target is not None and text.startswith("builtin-SwiftDriver "):
                try:
                    argv = shlex.split(text)
                except ValueError:
                    argv = []
                name = argv[argv.index("-module-name") + 1] if "-module-name" in argv[:-1] else target
                modules.append(name)
                target = None
                continue
            if "/swift-frontend " not in text or " -frontend " not in text:
                continue
            try:
                argv = shlex.split(text)
            except ValueError:
                continue
            if argv and argv[0].endswith("swift-frontend") and "-c" in argv and "-module-name" in argv[:-1]:
                compiled.add(argv[argv.index("-module-name") + 1])
    if target is not None:
        modules.append(target)
    return modules, compiled, command


def write_tar(root: Path, out: Path, skip: re.Pattern, replace: dict[str, bytes] | None = None) -> None:
    """A gzip tar of root, paths relative to it, sorted, with fixed owners and mtimes: the same tree
    gives the same bytes. Symlinks stay links; replace swaps a file's content."""
    replace = replace or {}
    with open(out, "wb") as raw, gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=1, mtime=0) as gz, \
            tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for dirpath, dirnames, filenames in os.walk(root):
            rel_dir = os.path.relpath(dirpath, root)
            rel_dir = "" if rel_dir == "." else rel_dir
            dirnames[:] = sorted(d for d in dirnames if not skip.search(os.path.join(rel_dir, d)))
            # A directory link is added as a link and not walked; an empty folder is kept.
            links = [d for d in dirnames if os.path.islink(os.path.join(dirpath, d))]
            dirnames[:] = [d for d in dirnames if d not in links]
            for name in dirnames + sorted(filenames) + links:
                rel = os.path.join(rel_dir, name)
                if skip.search(rel):
                    continue
                path = os.path.join(dirpath, name)
                info = tar.gettarinfo(path, arcname=rel)
                info.uid = info.gid = 0
                info.uname = info.gname = ""
                info.mtime = 0
                if info.isfile() and rel in replace:
                    data = replace[rel]
                    info.size = len(data)
                    tar.addfile(info, io.BytesIO(data))
                elif info.isfile():
                    with open(path, "rb") as f:
                        tar.addfile(info, f)
                elif info.issym() or info.isdir():
                    info.mode = info.mode & 0o7777
                    tar.addfile(info)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def split(path: Path) -> list[Path]:
    """path itself when it fits a store file, else path.partNN pieces; their bytes in order are path's."""
    if path.stat().st_size <= PART_BYTES:
        return [path]
    parts = []
    with path.open("rb") as f:
        while chunk := f.read(PART_BYTES):
            part = path.with_name(f"{path.name}.part{len(parts):02d}")
            part.write_bytes(chunk)
            parts.append(part)
    path.unlink()
    return parts


def capture(a: argparse.Namespace, environ=os.environ) -> int:
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    # The build's paths go in the manifest; the files are read from the snapshot of them.
    ws, dd, log = Path(a.workspace), Path(a.derived_data), Path(a.log)
    read_ws, read_dd = Path(a.read_workspace or ws), Path(a.read_derived_data or dd)
    modules, compiled, command = drivers_and_lines(log)
    missing = sorted(set(modules) - compiled)
    manifest = {
        "schema": SCHEMA, "key": a.key, "sha": a.sha, "run_id": a.run_id, "lane": a.lane,
        "complete": bool(modules) and not missing, "modules": len(set(modules)), "missing": missing,
        "workspace": str(ws), "derived_data": str(dd),
        "tmpdir": environ.get("TMPDIR", ""), "runner": environ.get("RUNNER_NAME", ""),
        "os_build": run(["sw_vers", "-buildVersion"]).strip() if platform.system() == "Darwin" else "",
        "toolchain": {"xcode": xcode_version(run(["xcodebuild", "-version"])),
                      "developer_dir": run(["xcode-select", "-p"]).strip(),
                      "sdk_build": run(["xcrun", "--sdk", "macosx", "--show-sdk-build-version"]).strip()}
        if platform.system() == "Darwin" else {},
        # The diagnostics wrapper prints the line shell-quoted: OTHER_SWIFT_FLAGS=... stays one argument.
        "xcodebuild_command": command, "xcodebuild_args": shlex.split(command) if command else [],
        "settings": settings(environ),
        "blobs": {},
    }
    if manifest["complete"]:
        replace = {}
        if settings(environ)["CMUX_NEXT_BROWSER_DATA_IMPORT"] == "compiled-out":
            replace[BROWSER_SOURCES] = (read_ws / BROWSER_SOURCES_COMPILED_OUT).read_bytes()
        packs = out / "packs"
        packs.mkdir(exist_ok=True)
        with log.open("rb") as src, open(packs / "xcodebuild.log.gz", "wb") as raw, \
                gzip.GzipFile(fileobj=raw, mode="wb", compresslevel=6, mtime=0) as dst:
            shutil.copyfileobj(src, dst)
        write_tar(read_dd / "Build/Intermediates.noindex", packs / "xcbuilddata.tgz",
                  re.compile(r"^(?!XCBuildData(/|$))"))
        write_tar(read_dd, packs / "build-noobj.tgz", DD_EXCLUDE)
        write_tar(read_ws, packs / "ws-src.tgz", WS_EXCLUDE, replace)
        shutil.copyfile(read_ws / RESOLVED, packs / "Package.resolved")
        for pack in sorted(packs.iterdir()):
            whole = {"sha256": sha256_file(pack), "size": pack.stat().st_size}
            parts = split(pack)
            whole["parts"] = [{"name": p.name, "sha256": sha256_file(p) if len(parts) > 1 else whole["sha256"],
                               "size": p.stat().st_size} for p in parts]
            manifest["blobs"][pack.name] = whole
            for p in whole["parts"]:
                if a.upload:
                    client = environ.get("CMUX_CI_CLIENT") or str(Path.home() / ".local/bin/cmux-ci")
                    subprocess.run([client, "artifact-put", str(packs / p["name"]), "--sha256", p["sha256"],
                                    "--lane", a.lane], check=True, stdout=subprocess.DEVNULL)
    (out / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    if environ.get("GITHUB_OUTPUT"):
        with open(environ["GITHUB_OUTPUT"], "a") as f:
            f.write(f"manifest={out / 'manifest.json'}\ncomplete={str(manifest['complete']).lower()}\n")
    sizes = sum(b["size"] for b in manifest["blobs"].values())
    print(f"hybrid-ref capture {a.key[:12]}: {'complete' if manifest['complete'] else 'INCOMPLETE'}, "
          f"{manifest['modules']} modules, {len(missing)} without a frontend line, {sizes >> 20} MiB packed"
          + ("" if not missing else ": " + ", ".join(missing[:20])))
    return 0


class LookupFailed(Exception):
    pass


def retry_wait(status: int, headers, body: str, attempt: int, now: float) -> float | None:
    """Seconds to wait before retrying a failed artifact lookup; None when retrying cannot help."""
    limited = status == 429 or (status == 403 and (headers.get("x-ratelimit-remaining") == "0"
                                                    or headers.get("retry-after") is not None
                                                    or "rate limit" in body.lower()))
    if limited:
        if (headers.get("retry-after") or "").isdigit():
            return max(1.0, float(headers["retry-after"]))
        if headers.get("x-ratelimit-remaining") == "0" and (headers.get("x-ratelimit-reset") or "").isdigit():
            return max(1.0, float(headers["x-ratelimit-reset"]) - now + 1)
        # A secondary limit with no header: GitHub asks for at least a minute.
        return 60.0 * (attempt + 1)
    if status == 0 or status >= 500:
        return min(15.0 * 2 ** attempt, 120.0)
    return None


def incomplete_name(key: str) -> str:
    """The artifact name of an incomplete capture's manifest (the workflow's upload step)."""
    return f"hybrid-ref-capture-incomplete-{key}"


def have(key: str, repo: str, token: str, budget: float = 600, opener=urllib.request.urlopen,
         sleep=time.sleep, clock=time.time) -> tuple[int, int]:
    """(complete, recent_incomplete) captures of KEY (see the module doc); raises LookupFailed."""
    start = clock()
    complete = _count(f"hybrid-ref-capture-{key}", 13 * 24, repo, token, start + budget, opener, sleep, clock)
    incomplete = _count(incomplete_name(key), 24, repo, token, start + budget, opener, sleep, clock)
    return complete, incomplete


def _count(name: str, hours: float, repo: str, token: str, deadline: float, opener, sleep, clock) -> int:
    url = f"https://api.github.com/repos/{repo}/actions/artifacts?name={name}&per_page=100"
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}", "User-Agent": "cmux-hybrid-ref",
                                                   "Accept": "application/vnd.github+json"})
    for attempt in range(1000):
        try:
            with opener(request, timeout=30) as response:
                artifacts = json.load(response)["artifacts"]
            since = (datetime.fromtimestamp(clock(), timezone.utc) - timedelta(hours=hours)).strftime("%Y-%m-%dT%H:%M:%SZ")
            return sum(1 for a in artifacts if a.get("expired") is False and a.get("created_at", "") >= since)
        except urllib.error.HTTPError as e:
            status, headers = e.code, {k.lower(): v for k, v in (e.headers or {}).items()}
            try:
                body = e.read().decode(errors="replace")
            except Exception as read_error:  # a truncated error body (IncompleteRead) is still this status
                body = f"(error body unreadable: {read_error!r})"
            finally:
                e.close()
        except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
            status, headers, body = 0, {}, str(e)
        reason = f"HTTP {status}: {body.strip()[:200]}" if status else body
        wait = retry_wait(status, headers, body, attempt, clock())
        if wait is None or clock() + wait > deadline:
            raise LookupFailed(f"artifact lookup {name[:40]} failed after {attempt + 1} attempt(s): {reason}")
        print(f"hybrid-ref have: {reason}; retrying in {wait:.0f} s", file=sys.stderr)
        sleep(wait)
    raise LookupFailed("unreachable")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    k = sub.add_parser("key")
    k.add_argument("repo")
    c = sub.add_parser("capture")
    for name in ("--log", "--workspace", "--derived-data", "--sha", "--key", "--out"):
        c.add_argument(name, required=True)
    c.add_argument("--run-id", type=int, required=True)
    c.add_argument("--read-workspace", help="where to read the workspace from (a snapshot of --workspace)")
    c.add_argument("--read-derived-data", help="where to read DerivedData from (a snapshot of --derived-data)")
    c.add_argument("--lane", default="hybrid-ref-dev")
    c.add_argument("--upload", action="store_true")
    h = sub.add_parser("have")
    h.add_argument("--key", required=True)
    h.add_argument("--repo", required=True)
    h.add_argument("--budget", type=float, default=600)
    a = parser.parse_args(argv)
    if a.cmd == "key":
        print(key(Path(a.repo)))
        return 0
    if a.cmd == "have":
        try:
            complete, incomplete = have(a.key, a.repo, os.environ["GH_TOKEN"], a.budget)
            print(f"complete={complete}\nrecent_incomplete={incomplete}")
        except LookupFailed as e:
            print(f"hybrid_ref_capture: {e}", file=sys.stderr)
            return 1
        return 0
    return capture(a)


if __name__ == "__main__":
    sys.exit(main())
