#!/usr/bin/env python3
"""A source-keyed cache of CmuxMobileLinkFFI.xcframework for scripts/ci/cmux-next-ios-sim.sh.

Every simulator step built the FFI from a fresh checkout: a cold cargo release build of
cmux-mobile-link-ffi for two iOS targets plus the host bindgen, 285 s of the build phase's
~350 s on an AWS M4 Pro (2026-10-29, at 6bcdfbbe). The FFI's inputs change a few times a day
(6 of 1846 feat-cmux-next commits in three days), so almost every step rebuilt what an earlier
step on the same worker had already built.

    ios_ffi_cache.py key     ROOT INPUTS       print the key of ROOT's FFI inputs and write them to
                                               INPUTS (exit 3: no key, build as before)
    ios_ffi_cache.py restore ROOT KEY          install the cached build for KEY (exit 0 hit, 1 miss)
    ios_ffi_cache.py probe   INPUTS TIP        write the same paths' trees on feat-cmux-next's tip to
                                               TIP (run beside the build on a miss)
    ios_ffi_cache.py store   ROOT INPUTS TIP   publish ROOT's fresh build, when trusted

The key is a sha256 over:
  - the git tree id at HEAD of every directory cargo builds from: the cmux-next-ios/rust
    workspace (build-xcframework.sh, Cargo.lock and rust-toolchain.toml are in it) and each
    path package `cargo metadata` lists (cmux-tui/crates/...), plus any .cargo/config between
    the workspace and the repository root. Those paths must be clean in the working tree, else
    there is no key and the step builds as before;
  - the toolchain: rustc -vV and cargo -V as the workspace's rust-toolchain.toml selects them,
    xcodebuild -version, the iOS and simulator SDK builds, IPHONEOS_DEPLOYMENT_TARGET, the
    machine architecture, and this file's SCHEMA.

An entry is CACHE/ios-ffi/<key>/ with the xcframework, the generated Swift bindings and
manifest.json (the key, its inputs and every file's sha256 and size). restore verifies the
manifest's key and every file against it before it installs anything; an entry that does not
verify is removed and the step builds. A hit touches the entry's `used` file first.

The cache bounds itself: every store keeps at most KEEP_ENTRIES entries, drops the least
recently used beyond that and any entry unused for MAX_AGE_SECONDS, and never removes one used
or written within BUSY_SECONDS. Removal holds the cache's exclusive lock (.lock, flock) and a
restore holds it shared while it verifies and copies, so no entry goes away mid-copy. One entry is about 157 MiB
(2026-10-29), so a worker holds at most about 1 GiB. disk-pressure.sh may also remove the
whole cache under low disk: every entry is reproducible.

Only trusted builds are published: store writes an entry only when every input tree is the
same tree as on the tip of feat-cmux-next (probe: a one-commit, blob-less clone in TMPDIR, run
while the FFI builds), so an entry is always the build of landed sources. A pull request that
changes the FFI builds it and writes nothing. (Step code runs as the worker's user either way,
as with ensure-web-bundles.sh's cache; the check keeps a pull request's own FFI out of it.)
Publication is one rename of a private temp dir, so two steps that miss one key never mix.

Exit codes: 0 done (restore: hit), 1 restore: miss (probe: no tip), 2 usage, 3 no key for an
expected reason (no cache, inputs differ from HEAD), 4 no key because a command it needs failed,
5 any other error, 6 restore: an entry that did not verify, removed. The step builds on every code but 0 from restore, and warns
(log and SUMMARY.md) on everything but a hit, a miss and 3.

CMUX_CI_CACHE_DIR is the cache root (the fleet worker sets it on every step); unset, there is
no cache and the step builds as before. Test seams: CMUX_IOS_FFI_TOOLCHAIN (the toolchain text),
CMUX_IOS_FFI_PATH_PACKAGES (newline-separated package dirs instead of cargo metadata),
CMUX_IOS_FFI_TRUSTED_URL (the repository probe clones instead of GitHub's).
"""
import hashlib
import contextlib
import fcntl
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time

SCHEMA = "ios-ffi-v1"
WORKSPACE = "cmux-next-ios/rust"
XCFRAMEWORK = "cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework"
SWIFT = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift"
OUTPUTS = (XCFRAMEWORK, SWIFT)
TRUSTED_URL = "https://github.com/manaflow-ai/cmux.git"
TRUSTED_BRANCH = "feat-cmux-next"
KEY_CHARS = set("0123456789abcdef")
SHA_CHARS = KEY_CHARS
KEEP_ENTRIES = 6
MAX_AGE_SECONDS = 7 * 86400
BUSY_SECONDS = 3600
# Build settings that change the FFI's bytes besides the sources and the toolchain.
# Build settings that change the FFI's bytes besides the sources and the toolchain: every
# variable cargo, rustc or the C toolchain reads for a build (CARGO_*, RUST*, the iOS target and
# SDK, compiler and linker flags). Paths that only say where things live are left out, so the key
# stays the same from step to step; CARGO_HOME's config files are keyed by their content.
# cc-rs reads each of its names bare and as NAME_<target>, NAME_<target_with_underscores>,
# HOST_NAME and TARGET_NAME, so a prefix match covers them all. Keying an unrelated variable that
# shares a prefix costs at most a miss; leaving one out could restore another build's bytes.
BUILD_ENV_PREFIXES = ("CARGO_", "RUST", "IPHONEOS_", "CC", "CXX", "AR", "RANLIB", "CFLAGS",
                      "CXXFLAGS", "CPPFLAGS", "LDFLAGS", "HOST_", "TARGET_", "CRATE_CC_", "SDKROOT",
                      "DEVELOPER_DIR", "MACOSX_DEPLOYMENT_TARGET", "LIBCLANG", "CLANG_PATH",
                      "BINDGEN_", "OBJC", "SWIFT")
BUILD_ENV_NAMES = {"LD", "NM", "STRIP"}
BUILD_ENV_LOCATIONS = {"CARGO_HOME", "RUSTUP_HOME", "CARGO_TARGET_DIR", "CARGO_TERM_COLOR",
                       "CARGO_TERM_PROGRESS_WHEN", "CARGO_TERM_QUIET", "CARGO_TERM_VERBOSE",
                       "CARGO_BUILD_JOBS", "CARGO_INCREMENTAL", "CARGO_NET_RETRY", "CARGO_HTTP_TIMEOUT",
                       "CARGO_NET_GIT_FETCH_WITH_CLI", "RUST_BACKTRACE", "RUST_LOG"}


class NoKey(Exception):
    """An expected reason for no key (no cache, inputs differ from HEAD): exit 3, build quietly."""


class ToolFailed(Exception):
    """A command the key needs failed (cargo, rustc, xcodebuild, xcrun): exit 4, a warning."""


def git(root, *args, check=True):
    p = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True)
    if check and p.returncode != 0:
        raise ToolFailed("git %s: %s" % (" ".join(args), p.stderr.strip()[:300]))
    return p


def cmd(argv, cwd):
    p = subprocess.run(argv, cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        raise ToolFailed("%s: %s" % (" ".join(argv), (p.stderr or p.stdout).strip()[:300]))
    return p.stdout.strip()


def path_packages(root):
    """Repository-relative directories of the path packages the FFI workspace builds."""
    seam = os.environ.get("CMUX_IOS_FFI_PATH_PACKAGES")
    if seam is not None:
        return sorted({line.strip() for line in seam.splitlines() if line.strip()})
    ws = root / WORKSPACE
    cmd(["cargo", "fetch", "--locked"], ws)
    meta = json.loads(cmd(["cargo", "metadata", "--format-version", "1", "--locked", "--offline"], ws))
    real = root.resolve()
    dirs = set()
    for pkg in meta.get("packages", []):
        if pkg.get("source") is not None:
            continue  # a registry or git dependency: pinned by Cargo.lock's checksum
        d = pathlib.Path(pkg["manifest_path"]).resolve().parent
        try:
            rel = d.relative_to(real)
        except ValueError:
            raise ToolFailed("path package %s is outside the repository" % d)
        dirs.add(rel.as_posix())
    return sorted(dirs)


def input_paths(root):
    """The workspace, each path package outside it, and any .cargo config above the workspace."""
    paths = {WORKSPACE}
    for d in path_packages(root):
        if d != WORKSPACE and not d.startswith(WORKSPACE + "/"):
            paths.add(d)
    parts = WORKSPACE.split("/")
    for i in range(len(parts)):
        base = "/".join(parts[:i])
        for name in ("config", "config.toml"):
            rel = (base + "/" if base else "") + ".cargo/" + name
            if (root / rel).exists():
                paths.add(rel)
    return sorted(paths)


def trees(root, rev, paths):
    out = {}
    for rel in paths:
        p = git(root, "rev-parse", "--verify", "--quiet", "%s:%s" % (rev, rel), check=False)
        oid = p.stdout.strip() if p.returncode == 0 else ""
        if oid and (len(oid) != 40 or not set(oid) <= SHA_CHARS):
            raise NoKey("%s:%s is not a full object id: %r" % (rev, rel, oid))
        out[rel] = oid
    return out


def toolchain(root):
    seam = os.environ.get("CMUX_IOS_FFI_TOOLCHAIN")
    if seam is not None:
        return seam
    ws = root / WORKSPACE
    lines = [
        cmd(["rustc", "-vV"], ws),
        cmd(["cargo", "-V"], ws),
        cmd(["xcodebuild", "-version"], ws),
        "iphoneos " + cmd(["xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"], ws),
        "iphonesimulator " + cmd(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-build-version"], ws),
        "arch " + os.uname().machine,
    ]
    return "\n".join(lines)


def build_env():
    env = {name: value for name, value in os.environ.items()
           if (name in BUILD_ENV_NAMES or name.startswith(BUILD_ENV_PREFIXES)) and name not in BUILD_ENV_LOCATIONS}
    env.setdefault("IPHONEOS_DEPLOYMENT_TARGET", "17.0")
    cargo_home = pathlib.Path(os.environ.get("CARGO_HOME") or pathlib.Path.home() / ".cargo")
    for name in ("config", "config.toml"):
        f = cargo_home / name
        if f.is_file():
            env["cargo-home/" + name] = hashlib.sha256(f.read_bytes()).hexdigest()
    return env


def inputs(root):
    paths = input_paths(root)
    dirty = git(root, "status", "--porcelain", "--untracked-files=all", "--", *paths).stdout.strip()
    if dirty:
        raise NoKey("FFI inputs differ from HEAD: " + dirty.splitlines()[0])
    t = trees(root, "HEAD", paths)
    missing = [p for p, tree in t.items() if not tree]
    if missing:
        raise NoKey("not tracked at HEAD: " + ", ".join(missing))
    return t


def compute_key(root):
    data = {"schema": SCHEMA, "trees": inputs(root), "toolchain": toolchain(root), "env": build_env()}
    blob = json.dumps(data, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(blob).hexdigest(), data


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def listing(base):
    """Every regular file under base (relative path -> (sha256, size)); a link is refused."""
    files = {}
    for dirpath, dirnames, filenames in os.walk(base):
        for name in dirnames + filenames:
            p = os.path.join(dirpath, name)
            if os.path.islink(p):
                raise ValueError("link in cache entry: %s" % p)
        for name in filenames:
            p = os.path.join(dirpath, name)
            rel = os.path.relpath(p, base)
            files[pathlib.PurePath(rel).as_posix()] = [sha256(p), os.path.getsize(p)]
    return files


def cache_root():
    base = os.environ.get("CMUX_CI_CACHE_DIR")
    return pathlib.Path(base) / "ios-ffi" if base else None


def valid_key(key):
    return len(key) == 64 and set(key) <= KEY_CHARS


def verify(entry, key):
    """The entry's manifest names KEY and its payload is exactly the manifest's files."""
    try:
        manifest = json.loads((entry / "manifest.json").read_text())
    except (OSError, ValueError):
        return False, "no readable manifest"
    if manifest.get("schema") != SCHEMA or manifest.get("key") != key:
        return False, "manifest is for another key"
    try:
        got = listing(entry / "payload")
    except (OSError, ValueError) as e:
        return False, str(e)
    if got != manifest.get("files"):
        return False, "payload does not match its manifest"
    for out in OUTPUTS:
        if not (entry / "payload" / out).exists():
            return False, "payload lacks " + out
    return True, ""


def install(src, dst):
    if dst.is_dir() and not dst.is_symlink():
        shutil.rmtree(dst)
    elif dst.exists() or dst.is_symlink():
        dst.unlink()
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_dir():
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst)


@contextlib.contextmanager
def cache_lock(cache, exclusive, wait=True):
    """The cache's lock: restore holds it shared while it verifies and copies an entry, and
    prune and a dropped entry's removal hold it exclusive, so nothing is removed mid-copy.
    Yields False when wait is False and another step holds it."""
    cache.mkdir(parents=True, exist_ok=True)
    with open(cache / ".lock", "a") as f:
        flags = (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | (0 if wait else fcntl.LOCK_NB)
        try:
            fcntl.flock(f, flags)
        except BlockingIOError:
            yield False
            return
        try:
            yield True
        finally:
            fcntl.flock(f, fcntl.LOCK_UN)


def restore(root, key):
    cache = cache_root()
    if cache is None or not valid_key(key):
        print("ios-ffi cache: off (no CMUX_CI_CACHE_DIR)" if cache is None else "ios-ffi cache: bad key")
        return 1
    entry = cache / key
    if not entry.is_dir():
        print("ios-ffi cache: miss %s" % key[:12])
        return 1
    with cache_lock(cache, exclusive=False):
        if not entry.is_dir():
            print("ios-ffi cache: miss %s" % key[:12])
            return 1
        ok, why = verify(entry, key)
        if ok:
            # A use, for least-recently-used pruning and the busy window.
            (entry / "used").write_text(str(int(time.time())) + "\n")
            for out in OUTPUTS:
                install(entry / "payload" / out, root / out)
            print("ios-ffi cache: hit %s" % key[:12])
            return 0
    print("ios-ffi cache: dropped %s (%s)" % (key[:12], why))
    with cache_lock(cache, exclusive=True):
        if entry.is_dir() and not verify(entry, key)[0]:
            shutil.rmtree(entry, ignore_errors=True)
    return 6


def probe(inputs_file, out_file):
    paths = sorted(json.loads(pathlib.Path(inputs_file).read_text())["trees"])
    url = os.environ.get("CMUX_IOS_FFI_TRUSTED_URL", TRUSTED_URL)
    tmp = tempfile.mkdtemp(prefix="ios-ffi-tip.")
    try:
        p = subprocess.run(["git", "clone", "--quiet", "--bare", "--depth=1", "--filter=blob:none",
                            "--single-branch", "--branch", TRUSTED_BRANCH, url, tmp + "/tip.git"],
                           capture_output=True, text=True)
        if p.returncode != 0:
            print("ios-ffi cache: no %s tip (%s)" % (TRUSTED_BRANCH, p.stderr.strip()[:300]))
            return 1
        tip = pathlib.Path(tmp) / "tip.git"
        sha = git(tip, "rev-parse", "HEAD").stdout.strip()
        if len(sha) != 40 or not set(sha) <= SHA_CHARS:
            print("ios-ffi cache: %s tip is not a full commit sha: %r" % (TRUSTED_BRANCH, sha))
            return 1
        data = {"branch": TRUSTED_BRANCH, "sha": sha, "trees": trees(tip, "HEAD", paths)}
        pathlib.Path(out_file).write_text(json.dumps(data, sort_keys=True) + "\n")
        return 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def last_use(entry):
    """When an entry was last restored or written (its `used` file, else its manifest)."""
    for name in ("used", "manifest.json"):
        try:
            return (entry / name).stat().st_mtime
        except OSError:
            pass
    try:
        return entry.stat().st_mtime
    except OSError:
        return 0.0


def prune(cache, now=None):
    """Keep at most KEEP_ENTRIES entries, none unused for MAX_AGE_SECONDS; never a busy one.
    Runs under the exclusive lock, so no restore is copying; skipped when another step holds it."""
    now = time.time() if now is None else now
    removed = []
    with cache_lock(cache, exclusive=True, wait=False) as held:
        if not held:
            return removed
        entries = sorted((p for p in cache.iterdir() if p.is_dir() and valid_key(p.name)),
                         key=last_use, reverse=True)
        for i, entry in enumerate(entries):
            idle = now - last_use(entry)
            if idle < BUSY_SECONDS:
                continue
            if i >= KEEP_ENTRIES or idle >= MAX_AGE_SECONDS:
                shutil.rmtree(entry, ignore_errors=True)
                removed.append(entry.name)
    # Temp dirs a killed step left behind (a day old: no build takes that long).
    for stale in cache.glob(".tmp.*"):
        try:
            if now - stale.lstat().st_mtime > 86400:
                shutil.rmtree(stale, ignore_errors=True)
        except OSError:
            pass
    return removed


def store(root, inputs_file, tip_file):
    cache = cache_root()
    if cache is None:
        return 0
    recorded = json.loads(pathlib.Path(inputs_file).read_text())
    key, want = recorded["key"], recorded["trees"]
    if not valid_key(key) or (cache / key).is_dir():
        return 0
    try:
        tip = json.loads(pathlib.Path(tip_file).read_text())
    except (OSError, ValueError):
        print("ios-ffi cache: not stored, no %s tip to compare with" % TRUSTED_BRANCH)
        return 0
    # The checkout still holds the inputs the key names (the build changed none of them) ...
    paths = sorted(want)
    dirty = git(root, "status", "--porcelain", "--untracked-files=all", "--", *paths).stdout.strip()
    if dirty or trees(root, "HEAD", paths) != want:
        print("ios-ffi cache: not stored, the FFI inputs changed during the build")
        return 0
    # ... and they are the landed ones.
    if tip.get("trees") != want:
        changed = sorted(p for p in want if tip.get("trees", {}).get(p) != want[p])
        print("ios-ffi cache: not stored, inputs differ from %s %s (%s)"
              % (TRUSTED_BRANCH, str(tip.get("sha", ""))[:12], ", ".join(changed)))
        return 0
    for out in OUTPUTS:
        if not (root / out).exists():
            print("ios-ffi cache: not stored, no " + out)
            return 0
    cache.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix=".tmp.", dir=cache))
    try:
        for out in OUTPUTS:
            install(root / out, tmp / "payload" / out)
        manifest = {"schema": SCHEMA, "key": key, "inputs": want, "trusted": {k: tip.get(k) for k in ("branch", "sha")},
                    "files": listing(tmp / "payload"), "created_at": int(time.time())}
        (tmp / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
        try:
            os.rename(tmp, cache / key)
        except OSError as e:
            shutil.rmtree(tmp, ignore_errors=True)
            if verify(cache / key, key)[0]:
                return 0  # another step published the key first; either build serves
            raise RuntimeError("could not publish %s: %s" % (key[:12], e))
    except BaseException:
        shutil.rmtree(tmp, ignore_errors=True)
        raise
    print("ios-ffi cache: stored %s (inputs as on %s %s)" % (key[:12], TRUSTED_BRANCH, str(tip.get("sha", ""))[:12]))
    removed = prune(cache)
    if removed:
        print("ios-ffi cache: pruned %d old entries (%s)" % (len(removed), ", ".join(k[:12] for k in removed)))
    return 0


USAGE = """usage: ios_ffi_cache.py key ROOT INPUTS | restore ROOT KEY | probe INPUTS TIP | store ROOT INPUTS TIP"""


def main(argv):
    arity = {"key": 3, "restore": 3, "probe": 3, "store": 4}
    if not argv or arity.get(argv[0]) != len(argv):
        print(USAGE, file=sys.stderr)
        return 2
    try:
        if argv[0] == "key":
            if cache_root() is None:
                print("ios-ffi cache: off (no CMUX_CI_CACHE_DIR)", file=sys.stderr)
                return 3
            key, data = compute_key(pathlib.Path(argv[1]).resolve())
            pathlib.Path(argv[2]).write_text(json.dumps({"key": key, "trees": data["trees"]}, sort_keys=True) + "\n")
            print(key)
            return 0
        if argv[0] == "restore":
            return restore(pathlib.Path(argv[1]).resolve(), argv[2])
        if argv[0] == "probe":
            return probe(argv[1], argv[2])
        return store(pathlib.Path(argv[1]).resolve(), argv[2], argv[3])
    except NoKey as e:
        print("ios-ffi cache: no key (%s)" % e, file=sys.stderr)
        return 3
    except ToolFailed as e:
        print("ios-ffi cache: no key, a command failed (%s)" % e, file=sys.stderr)
        return 4
    except Exception as e:  # a bug: never a silent miss (an uncaught exception exits 1, a miss)
        print("ios-ffi cache: %s failed: %s: %s" % (argv[0], type(e).__name__, e), file=sys.stderr)
        return 5


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
