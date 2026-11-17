"""hot-apply.py's ffi part: a commit's app FFI library swapped into a cmux NEXT app, no app build.

The app carries the Rust it links (CCmuxAppFFI: the remote desktop core, the sidebar layout reducer, motion,
the palette ranker, the daemon connection and launch rules, ...) as one dynamic library,
Contents/Frameworks/libcmux_app_ffi.dylib (scripts/cmux-next/build-app-ffi.sh; Xcode embeds it from the dynamic xcframework). Every
feat-cmux-next push that changes its sources publishes it (app-ffi-release.yml, release
cmux-app-ffi-<commit>). For a commit SHA this part:

  release  finds the release with SHA's FFI sources: the newest commit at or before SHA that changed an FFI input
           (scripts/ci/cmux_next_route.py app_ffi_inputs, less each crate's tests/, benches/, examples/), whose
           cmux-app-ffi-<commit> release must be published.
  pair     checks the app and that library are a pair: SHA's FFI only adds to the FFI the app was built with
           (the release its commit's app-ffi-pin.json pins, compared by scripts/cmux-next/app_ffi_additive.py:
           every declaration, directive and packaging input kept), and the library exports every symbol the app
           imports from it.
  fetch    downloads the release's xcframework zip, checks it against the release's SHA256SUMS, and keeps the
           library under the state folder by that checksum.
  sign     signs it the way the app can load it. An app signed ad hoc (a fleet try, a side instance) takes an
           ad hoc library, and so does a Developer ID app with com.apple.security.cs.disable-library-validation
           (a NIGHTLY: cmux.nightly.entitlements). A Developer ID app without it validates its libraries' team,
           so it takes the library only signed by that team (--sign-identity, an identity in this Mac's
           keychain), or with --reseal, which signs the app's own bundle ad hoc too (as nightly-swap and
           side-instance.sh do; the Keychain group entitlement goes with the Developer ID signature, so the app
           starts signed out); otherwise the part is left, with why.
  swap     quits the app keeping its sessions (`cmux app quit --keep-sessions` from the app's own bin), renames
           the library into place, opens the app again (through launchd's GUI domain where `open` fails: in a
           terminal of the app itself, or over ssh) and waits until its control socket answers from a new pid
           that stays up STAY_SECONDS. The daemon and its terminals never stop.

This is a warm swap, not a live one: the C ABI holds state, so the new library loads with the app. A failed check
after the swap puts the old library (and the old signature) back and opens the app again.
"""
from __future__ import annotations

import hashlib
import io
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import zipfile
from pathlib import Path

DYLIB = "Contents/Frameworks/libcmux_app_ffi.dylib"
ASSET = "CCmuxAppFFI.xcframework.zip"
RELEASES = os.environ.get("CMUX_HOT_APPLY_FFI_BASE") or "https://github.com/manaflow-ai/cmux/releases/download"
PIN_FILE = "Packages/macOS/CmuxNext/app-ffi-pin.json"
STAY_SECONDS = float(os.environ.get("CMUX_HOT_APPLY_FFI_STAY_SECONDS") or 10)
QUIT_SECONDS = 60
LAUNCH_SECONDS = 90


class Left(Exception):
    """The ffi part cannot apply to this app; the message says why (it goes to the plan's `left`)."""


def carries_dylib(app: Path) -> bool:
    return (app / DYLIB).is_file()


def executable(app: Path) -> Path:
    with open(app / "Contents/Info.plist", "rb") as handle:
        return app / "Contents/MacOS" / plistlib.load(handle)["CFBundleExecutable"]


# The app's code, which links the library: CmuxNextApp.framework behind a stub executable (CMUX-629),
# or the executable itself in a static (live code) build.
CODE_FRAMEWORK_BINARY = "Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp"


def code_image(app: Path) -> Path:
    framework = app / CODE_FRAMEWORK_BINARY
    return framework if framework.is_file() else executable(app)


def _git(repo: Path, *args: str) -> str:
    done = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, errors="replace")
    if done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {done.stderr.strip()[:300]}")
    return done.stdout.strip()


def ffi_paths(repo: Path) -> tuple[list[str], list[str]]:
    import cmux_next_route as route  # scripts/ci, on hot-apply.py's path
    return list(route.app_ffi_inputs(repo)), list(route.app_ffi_excluded(repo))


def source_commit(repo: Path, sha: str) -> str:
    """The newest commit at or before SHA that changed an app FFI input: its release has SHA's FFI sources."""
    inputs, excluded = ffi_paths(repo)
    found = _git(repo, "log", "-1", "--format=%H", sha, "--", *inputs, *[f":(exclude){d}" for d in excluded])
    if not found:
        raise Left(f"no commit at or before {sha} changed the app FFI")
    return found


def app_pin_source(repo: Path, base: str) -> str:
    """The source commit of the release the app's commit pins (what the app was built against)."""
    import app_ffi_pin  # scripts/ci
    return app_ffi_pin.read(_git(repo, "show", f"{base}:{PIN_FILE}") + "\n")[0]


def additive(repo: Path, old: str, new: str) -> list[str]:
    """The ways the FFI at NEW drops or changes what the app built against OLD calls ([] when it only adds)."""
    if old == new:
        return []
    inputs, _ = ffi_paths(repo)
    done = subprocess.run([sys.executable, "-I", str(repo / "scripts/cmux-next/app_ffi_additive.py"), old, new, "--",
                           *inputs], cwd=repo, capture_output=True, text=True, errors="replace")
    if done.returncode == 0:
        return []
    lines = [line.strip() for line in done.stdout.splitlines()[1:] if line.strip()]
    return lines or [(done.stdout + done.stderr).strip()[:300] or f"app_ffi_additive.py exited {done.returncode}"]


def plan(repo: Path, app: Path | None, sha: str, base: str) -> dict:
    """What the ffi part would put in: {"source", "release", "app_pin_source"}; Left when it cannot."""
    if app is not None and not carries_dylib(app):
        raise Left(f"{app} links the app FFI statically (no {DYLIB}): it needs a new app")
    source = source_commit(repo, sha)
    pinned = app_pin_source(repo, base)
    changed = additive(repo, pinned, source)
    if changed:
        raise Left(f"the app FFI at {source[:12]} is not additive to the app's ({pinned[:12]}): " + "; ".join(changed[:3]))
    return {"source": source, "release": f"cmux-app-ffi-{source}", "app_pin_source": pinned}


def pin_moved(repo: Path, base: str, sha: str) -> bool:
    """SHA's commit pins another app FFI release than the app's commit BASE (False when either is not in REPO)."""
    try:
        return app_pin_source(repo, base) != app_pin_source(repo, sha)
    except Exception:
        return False


def pin_plan(repo: Path, app: Path | None, sha: str, base: str) -> dict | None:
    """The ffi part for SHA when no FFI source changed after the app's commit but SHA pins a newer release.

    An app links the release its commit pins, and the pin lags the FFI sources until app-ffi-repin lands, so a
    NIGHTLY's library is usually older than its commit's FFI sources: the commit that moves the pin is then the
    one that brings the app's library up to date. None when SHA pins the app's release; Left when it cannot."""
    try:
        pinned, want = app_pin_source(repo, base), app_pin_source(repo, sha)
    except RuntimeError:
        return None  # a commit from before app-ffi-pin.json: no pin to compare, nothing for this part
    if pinned == want:
        return None
    if app is not None and not carries_dylib(app):
        raise Left(f"{app} links the app FFI statically (no {DYLIB}): it needs a new app")
    # No ancestry check: an older pin (a reverted re-pin) is refused here when it drops what the app calls, and a
    # shallow checkout cannot tell ancestry anyway.
    changed = additive(repo, pinned, want)
    if changed:
        raise Left(f"the app FFI at {want[:12]} is not additive to the app's ({pinned[:12]}): " + "; ".join(changed[:3]))
    return {"source": want, "release": f"cmux-app-ffi-{want}", "app_pin_source": pinned, "via": "pin"}


PIN_CHECKSUM_LINE = "// app-ffi-pin-checksum:"
PACKAGE_SWIFT = "Packages/macOS/CmuxNext/Package.swift"


def pin_packaging(repo: Path, since: str, sha: str) -> set[str]:
    """The changed paths between SINCE and SHA that only move the pin: app-ffi-pin.json, and Package.swift when
    its only changed line is the pin checksum (repin-app-ffi.sh moves the two together). The ffi part covers them."""
    out = {PIN_FILE}
    diff = _git(repo, "diff", "-U0", since, sha, "--", PACKAGE_SWIFT)
    changed = [line[1:].strip() for line in diff.splitlines()
               if line[:1] in "+-" and not line.startswith(("+++", "---"))]
    if all(line.startswith(PIN_CHECKSUM_LINE) for line in changed):
        out.add(PACKAGE_SWIFT)
    return out


# ---------------------------------------------------------------- fetch


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def fetch_library(source: str, state: Path, fetch, fetch_kept) -> tuple[Path, str]:
    """(the release's libcmux_app_ffi.dylib under STATE, the archive checksum it came from)."""
    tag = f"cmux-app-ffi-{source}"
    try:
        sums = fetch_kept(f"{RELEASES}/{tag}/SHA256SUMS").decode()
    except urllib.error.URLError as error:  # an HTTPError 404, or a file:// release that is not there
        if getattr(error, "code", None) == 404 or isinstance(error.reason, FileNotFoundError):
            raise Left(f"release {tag} is not published (yet): app-ffi-release.yml publishes it after the push")
        raise
    want = next((line.split()[0] for line in sums.splitlines() if line.strip().endswith(f"  {ASSET}")), "")
    if len(want) != 64:
        raise RuntimeError(f"{tag}'s SHA256SUMS names no {ASSET}")
    kept = state / "ffi" / want / "libcmux_app_ffi.dylib"
    if kept.is_file():
        return kept, want
    archive = fetch(f"{RELEASES}/{tag}/{ASSET}")
    if sha256_bytes(archive) != want:
        raise RuntimeError(f"{tag}/{ASSET} does not hash to its SHA256SUMS ({want})")
    with zipfile.ZipFile(io.BytesIO(archive)) as zipped:
        names = [n for n in zipped.namelist() if n.endswith("/libcmux_app_ffi.dylib") and "/macos-" in n]
        if not names:
            raise Left(f"{tag} carries no libcmux_app_ffi.dylib (a release from before the app FFI was a dylib)")
        data = zipped.read(names[0])
    kept.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=kept.parent, delete=False) as part:
        part.write(data)
    os.chmod(part.name, 0o755)
    os.replace(part.name, kept)
    return kept, want


# ---------------------------------------------------------------- pair, sign


def _run(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    done = subprocess.run(list(args), capture_output=True, text=True, errors="replace")
    if check and done.returncode != 0:
        raise RuntimeError(f"{' '.join(args[:3])}: {(done.stderr or done.stdout).strip()[:300]}")
    return done


def host_arch() -> str:
    return "arm64" if os.uname().machine in ("arm64", "aarch64") else "x86_64"


def archs(path: Path) -> list[str]:
    return _run("lipo", "-archs", str(path)).stdout.split()


def imports(app: Path) -> set[str]:
    """The symbols the app's code binds to libcmux_app_ffi (nm -m: `(from libcmux_app_ffi)`). The stub
    executable binds none, so it is the code image's, or every library would pass this check."""
    out = _run("nm", "-m", "-u", "-arch", host_arch(), str(code_image(app))).stdout
    return {line.split()[2] for line in out.splitlines() if line.rstrip().endswith("(from libcmux_app_ffi)")}


def exports(dylib: Path) -> set[str]:
    out = _run("nm", "-gU", "-arch", host_arch(), str(dylib)).stdout
    return {line.split()[-1] for line in out.splitlines() if line.strip()}


def signature(path: Path) -> dict:
    """codesign's view of PATH: {"team": id or None, "runtime": bool, "adhoc": bool}."""
    out = _run("codesign", "-dvv", str(path), check=False).stderr
    info = {"team": None, "runtime": False, "adhoc": False}
    for line in out.splitlines():
        if line.startswith("TeamIdentifier=") and line.split("=", 1)[1] != "not set":
            info["team"] = line.split("=", 1)[1]
        if line.startswith("CodeDirectory") and "runtime" in line:
            info["runtime"] = True
        if line.startswith("Signature=adhoc") or ("flags=" in line and "adhoc" in line):
            info["adhoc"] = True
    return info


def validates_no_libraries(app: Path) -> bool:
    """The app's signature carries com.apple.security.cs.disable-library-validation set to true: under the
    hardened runtime it then loads a library of any signer, an ad hoc one included."""
    for form in (["--entitlements", "-", "--xml"], ["--entitlements", ":-"]):
        out = _run("codesign", "-d", *form, str(app), check=False).stdout
        try:
            return plistlib.loads(out.encode()).get("com.apple.security.cs.disable-library-validation") is True
        except Exception:  # noqa: BLE001 - no entitlements, or a form this codesign does not print
            continue
    return False


def how_to_sign(app: Path, identity: str | None, reseal: bool) -> str:
    """`adhoc`, `identity` or `reseal`: Left when the app cannot load a library this Mac can sign."""
    app_sig = signature(app)
    if not app_sig["team"] or validates_no_libraries(app):
        return "adhoc"
    if identity:
        return "identity"
    if reseal:
        return "reseal"
    raise Left(f"the app is signed by team {app_sig['team']}{' with the hardened runtime' if app_sig['runtime'] else ''}, "
               "which loads only libraries of that team: pass --sign-identity with that team's identity, or "
               "--reseal to sign the app ad hoc too (it starts signed out of its Keychain items)")


def prepare(new: Path, app: Path, how: str, identity: str | None, work: Path) -> Path:
    """NEW thinned to the archs of the library the app carries and signed for HOW, as a file in WORK."""
    out = work / "libcmux_app_ffi.dylib"
    have = archs(app / DYLIB)
    if sorted(archs(new)) != sorted(have) and len(have) == 1:
        _run("lipo", "-thin", have[0], str(new), "-output", str(out))
    else:
        shutil.copy2(new, out)
    os.chmod(out, 0o755)
    if how == "identity":
        _run("codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity, str(out))
    else:
        _run("codesign", "--force", "--sign", "-", "--timestamp=none", str(out))
    return out


def reseal(app: Path, work: Path) -> None:
    """The app's own bundle signed ad hoc, keeping only the entitlements an ad hoc signature may carry
    (side-instance.sh's rule: com.apple.security.*); nested code keeps its signatures."""
    raw = _run("codesign", "-d", "--entitlements", ":-", str(app), check=False).stdout.encode()
    kept = {k: v for k, v in (plistlib.loads(raw) if raw.strip() else {}).items() if k.startswith("com.apple.security.")}
    entitlements = work / "entitlements.plist"
    entitlements.write_bytes(plistlib.dumps(kept))
    _run("codesign", "--force", "--sign", "-", "--timestamp=none", "--entitlements", str(entitlements), str(app))


# ---------------------------------------------------------------- quit, swap, launch


def app_pid(app: Path) -> int | None:
    exe = str(executable(app))
    real = os.path.realpath(exe)
    ps = subprocess.run(["ps", "-axww", "-o", "pid=,comm="], capture_output=True, text=True).stdout
    for line in ps.splitlines():
        pid, _, comm = line.strip().partition(" ")
        if comm.strip() in (exe, real):
            return int(pid)
    return None


def answering_pid(app: Path) -> int | None:
    """The pid of the app behind its control socket, as its own CLI reads it (`cmux version --json`)."""
    try:
        done = subprocess.run([str(app / "Contents/Resources/bin/cmux"), "version", "--json"], capture_output=True,
                              text=True, errors="replace", timeout=20)
        return int((json.loads(done.stdout).get("app") or {}).get("pid") or 0) or None
    except (subprocess.TimeoutExpired, ValueError, AttributeError, TypeError):
        return None


def app_answers(app: Path) -> bool:
    return answering_pid(app) is not None


def quit_keeping_sessions(app: Path) -> int | None:
    """Quits the app with `cmux app quit --keep-sessions` and waits for its pid to end; returns that pid."""
    pid = app_pid(app)
    if pid is None:
        return None
    done = subprocess.run([str(app / "Contents/Resources/bin/cmux"), "app", "quit", "--keep-sessions"],
                          capture_output=True, text=True, errors="replace", timeout=QUIT_SECONDS)
    if done.returncode != 0:
        raise RuntimeError(f"cmux app quit --keep-sessions failed: {(done.stderr or done.stdout).strip()[:300]}")
    deadline = time.monotonic() + QUIT_SECONDS
    while time.monotonic() < deadline:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return pid
        time.sleep(0.05)
    raise RuntimeError(f"the app (pid {pid}) did not quit within {QUIT_SECONDS} s of quit --keep-sessions")


def open_app(app: Path) -> dict:
    """Opens APP: `open`, or, where LaunchServices does not answer, a one-shot agent in the user's GUI domain.

    `open` fails in the two places hot-apply runs from most: a terminal of the app itself, which outlives
    `cmux app quit --keep-sessions` but whose LaunchServices connection went with the app (error -600), and an
    ssh session, which has no window server. launchd's gui/<uid> domain opens the app in the console session from
    both. Returns {"via": "open"} or {"via": "launchd", "label", "plist"} for close_opener()."""
    done = _run("open", str(app), check=False)
    if done.returncode == 0:
        return {"via": "open"}
    label = f"com.cmux.hot-apply-ffi.open.{os.getpid()}.{time.monotonic_ns()}"
    plist = Path(tempfile.mkdtemp(prefix="hot-apply-ffi-open.")) / f"{label}.plist"
    with open(plist, "wb") as handle:
        plistlib.dump({"Label": label, "ProgramArguments": ["/usr/bin/open", str(app)], "RunAtLoad": True,
                       "LaunchOnlyOnce": True}, handle)
    boot = _run("launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist), check=False)
    if boot.returncode != 0:
        shutil.rmtree(plist.parent, ignore_errors=True)
        raise RuntimeError(f"open {app}: {(done.stderr or done.stdout).strip()[:200]}; launchctl bootstrap "
                           f"gui/{os.getuid()}: {(boot.stderr or boot.stdout).strip()[:200]}")
    return {"via": "launchd", "label": label, "plist": str(plist), "open_error": (done.stderr or done.stdout).strip()[:200]}


def close_opener(opener: dict) -> None:
    """Removes the one-shot agent open_app() bootstrapped; the app it opened keeps running."""
    if opener.get("via") != "launchd":
        return
    _run("launchctl", "bootout", f"gui/{os.getuid()}/{opener['label']}", check=False)
    shutil.rmtree(Path(opener["plist"]).parent, ignore_errors=True)


def launch(app: Path, old_pid: int | None) -> dict:
    """Opens APP and waits until a new pid's control socket answers, then that it stays up STAY_SECONDS."""
    t0 = time.monotonic()
    opener = open_app(app)
    try:
        deadline = t0 + LAUNCH_SECONDS
        pid = None
        while time.monotonic() < deadline:
            pid = answering_pid(app)
            if pid and pid != old_pid:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"the app did not answer within {LAUNCH_SECONDS} s of opening it ({opener['via']})")
    finally:
        close_opener(opener)
    answered = time.monotonic() - t0
    time.sleep(STAY_SECONDS)
    if app_pid(app) != pid:
        raise RuntimeError(f"the app (pid {pid}) did not stay up {STAY_SECONDS:g} s")
    return {"pid": pid, "answered_seconds": round(answered, 3), "stayed_seconds": STAY_SECONDS, "opened_via": opener["via"]}


def place(src: Path, dest: Path) -> None:
    part = dest.with_name(f".{dest.name}.hot-apply")
    try:
        shutil.copy2(src, part)
    except PermissionError as error:
        # macOS App Management: only processes macOS lets manage apps (the app's own team, its terminals, a
        # terminal or sshd with that permission) may write into a signed app bundle.
        raise RuntimeError(f"cannot write into {dest.parent} ({error.strerror}): macOS lets this process change "
                           "no signed app; run hot-apply from a terminal of the app, over ssh, or from a terminal "
                           "with App Management (System Settings, Privacy & Security)") from error
    os.replace(part, dest)


def keep_signature(app: Path, state: Path) -> dict:
    """Copies of what a reseal rewrites (the main executable and the bundle seal), for the way back."""
    out = {}
    for rel in (str(executable(app).relative_to(app)), "Contents/_CodeSignature/CodeResources"):
        src = app / rel
        digest = sha256_file(src)
        copy = state / "blobs" / digest
        if not copy.is_file():
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, copy)
        out[rel] = {"copy": str(copy), "sha256": digest}
    return out


def restore_signature(app: Path, kept: dict) -> None:
    for rel, item in kept.items():
        place(Path(item["copy"]), app / rel)


def swap(app: Path, new: Path, state: Path, how: str, identity: str | None, phases) -> tuple[dict, dict]:
    """(the step's receipt, its undo). The app's library becomes NEW (prepared for HOW) across a quit with
    sessions kept and a relaunch; any failure after the quit is raised with the undo filled in."""
    dest = app / DYLIB
    prior = sha256_file(dest)
    copy = state / "blobs" / prior
    with phases("backup"):
        if not copy.is_file():
            copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(dest, copy)
        undo = {"copy": str(copy), "sha256": prior, "how": how}
        if how == "reseal":
            undo["signature"] = keep_signature(app, state)
    with tempfile.TemporaryDirectory(prefix="hot-apply-ffi.") as work:
        with phases("verify"):
            missing = sorted(imports(app) - exports(new))
            if missing:
                raise Left(f"the library lacks {len(missing)} symbol(s) the app imports: {', '.join(missing[:5])}")
            ready = prepare(new, app, how, identity, Path(work))
            to = sha256_file(ready)
        step = {"from": prior, "to": to, "signed": how}
        with phases("quit"):
            started = time.monotonic()
            step["quit_pid"] = quit_keeping_sessions(app)
            step["quit_seconds"] = round(time.monotonic() - started, 3)
        try:
            with phases("swap"):
                place(ready, dest)
                if how == "reseal":
                    reseal(app, Path(work))
            if sha256_file(dest) != to:
                raise RuntimeError(f"{DYLIB} does not hash to the library put in ({to})")
            with phases("launch"):
                step["launch"] = launch(app, step["quit_pid"])
        except Exception as error:
            error.undo = undo  # type: ignore[attr-defined]
            raise
    return step, undo


def put_back(app: Path, undo: dict) -> dict:
    """The library (and signature) the app had, and the app opened on it again."""
    dest = app / DYLIB
    if sha256_file(dest) == undo["sha256"] and "signature" not in undo:
        running = app_pid(app)
        if running and app_answers(app):
            return {"ok": True, "running_sha256": undo["sha256"], "app": "unchanged"}
    old = quit_keeping_sessions(app) if app_pid(app) else None
    place(Path(undo["copy"]), dest)
    if undo.get("signature"):
        restore_signature(app, undo["signature"])
    if sha256_file(dest) != undo["sha256"]:
        raise RuntimeError(f"{DYLIB} does not hash to the library put back ({undo['sha256']})")
    return {"ok": True, "running_sha256": undo["sha256"], "launch": launch(app, old)}
