#!/usr/bin/env python3
"""A source-keyed cache of CmuxMobileLinkFFI.xcframework for scripts/ci/cmux-next-ios-sim.sh.

Every simulator step built the FFI from a fresh checkout: a cold cargo release build of
cmux-mobile-link-ffi for two iOS targets plus the host bindgen, 285 s of the build phase's
~350 s on an AWS M4 Pro (2026-10-29, at 6bcdfbbe). The FFI's inputs change a few times a day
(6 of 1846 feat-cmux-next commits in three days), so almost every step rebuilt what an earlier
step on the same worker had already built.

    ios_ffi_cache.py key     ROOT INPUTS       print the key of ROOT's FFI inputs and write them to
                                               INPUTS (exit 3: no key, build as before)
    ios_ffi_cache.py restore ROOT KEY          install the cached build for KEY from this worker's cache, else
                                               the fleet's component store (exit 0 hit, 1 miss)
    ios_ffi_cache.py probe   INPUTS TIP        write the same paths' trees on feat-cmux-next's tip to
                                               TIP (run beside the build on a miss)
    ios_ffi_cache.py store   ROOT INPUTS TIP   publish ROOT's fresh build under its key
    ios_ffi_cache.py build   ROOT RC CMD...    run the build CMD (on a miss) in a warm cargo target dir and
                                               write its exit code to RC (no RC: the step builds itself)

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
(2026-10-29), so a worker holds at most about 2.5 GiB. disk-pressure.sh may also remove the
whole cache under low disk: every entry is reproducible.

Every clean build is published under its own key, a landed build and a branch build alike
(2026-11-25: 84 of 133 handoff steps missed, and 44 of those misses were inputs an earlier step had
already built, because only builds of feat-cmux-next's inputs were stored). The key names every
input tree and the toolchain, and restore verifies every byte against the manifest, so a branch's
entry serves only a later step with exactly the same inputs: the same branch rebuilt, a stacked
branch, or feat-cmux-next once that branch lands. It never serves other inputs. probe still runs
beside the build and records in the manifest whether the inputs were the landed ones
(`landed`, `trusted`); a failed probe only means the entry is recorded as a branch build. (Step
code runs as the worker's user either way, as with ensure-web-bundles.sh's cache, so the old
landed-only rule never kept a step's own code out: a step whose FFI inputs matched the tip
could already publish whatever its own scripts built.) Publication is one rename of a private
temp dir, so two steps that miss one key never mix.

A miss no longer builds cold. The key names ~45 input trees, and feat-cmux-next changed one of them
in 263 of its commits over three days (2026-11-23..26, about one every 16 minutes), so a PR's base
rarely matches a key any step on its worker built: fleet step 3f53ebc7e5c403d3b5af5d55, a one-file
Swift edit on feat-cmux-next ab0103ac, missed and paid 227 s (Aziz's earlier steps 416 s) because
the tip had already moved past its base's FFI inputs. Each step's cargo target dir was inside its
fresh checkout, so every miss recompiled all ~445 registry crates for three targets. `build` runs
the build with CARGO_TARGET_DIR in one of TARGET_SLOTS warm per-worker dirs
(CACHE/ios-ffi-target/<n>, held by an exclusive flock for the whole build, so two steps never share
one; with every slot busy the step builds in its checkout as before). Cargo's own fingerprints
decide what is fresh, so a slot only saves work: registry crates compile once per worker and
toolchain, and a miss rebuilds just the path crates. Every step's checkout is a new path, so after
the build `build` removes the path crates' artifacts the build superseded (their names, older than
the build), and empties a slot past TARGET_CAP_BYTES.

The fleet tier (2026-11-27, cmux#13742): a local miss reads the fleet's component store, and a step's fresh build is
left in $CI_JOB_DIR/component-outputs/ios-ffi/<key>/ for the worker to publish (see "The fleet tier" below). The key
is the sha256 of the canonical manifest (`v`, `name`, trees, toolchain, env), which the store checks on write and this
reader checks on read, and every file is checked against its sha256 and size.

Exit codes: 0 done (restore: hit), 1 restore: miss (probe: no tip), 2 usage, 3 no key for an
expected reason (no cache, inputs differ from HEAD), 4 no key because a command it needs failed,
5 any other error, 6 restore: an entry that did not verify, removed; build exits with CMD's code
and writes it to RC, and the step reads RC, so a helper that fails without running CMD only costs
the warm dir. The step builds on every code but 0 from restore, and warns
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

SCHEMA = "ios-ffi-v2"  # v2: the key is the sha256 of a component manifest the fleet store accepts
COMPONENT = "ios-ffi"  # the fleet store's name for this entry (hq build-fleet components.go)
FLEET_NAMESPACE = "dev"
DEFAULT_CONTROLLER = "http://100.89.225.106:18765"
EXPORT_DIR = "component-outputs"  # under $CI_JOB_DIR: the worker publishes what a step leaves here
XCF_TAR = "CmuxMobileLinkFFI.xcframework.tar"
SWIFT_FILE = "CmuxMobileLinkFFI.swift"
FLEET_FILES = (XCF_TAR, SWIFT_FILE)
FLEET_MAX_MANIFEST = 16 << 10  # the controller's limit
FLEET_MAX_FILE = 2 << 30
WORKSPACE = "cmux-next-ios/rust"
XCFRAMEWORK = "cmux-next-ios/CmuxMobileKit/Frameworks/CmuxMobileLinkFFI.xcframework"
SWIFT = "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLinkFFI/CmuxMobileLinkFFI.swift"
OUTPUTS = (XCFRAMEWORK, SWIFT)
TRUSTED_URL = "https://github.com/manaflow-ai/cmux.git"
TRUSTED_BRANCH = "feat-cmux-next"
KEY_CHARS = set("0123456789abcdef")
SHA_CHARS = KEY_CHARS
KEEP_ENTRIES = 16  # branch builds are stored too: room for the branches in flight on a worker
MAX_AGE_SECONDS = 7 * 86400
BUSY_SECONDS = 3600
TARGET_SLOTS = 2  # warm cargo target dirs per worker: two steps on one worker each get one
TARGET_CAP_BYTES = 24 << 30  # a slot past this is emptied after its build (one cold build)
TARGET_ARTIFACT_DIRS = ("deps", ".fingerprint", "build", "incremental")
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
    # A build-xcframework.sh killed mid-build (a CI step timeout) leaves Cargo.lock patched; --locked below
    # would refuse it ("cannot update the lock file"), so put the checked-in lock back first.
    restore = ws / "scripts" / "restore-ios-patch-lock.sh"
    if restore.is_file():
        cmd(["bash", str(restore)], ws)
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
    """Each path's object id at REV ("" when it is not there), from one git process.

    One `git cat-file --batch-check` for every path, not one `git rev-parse` each: in a checkout
    with tens of thousands of packs every git process spends seconds opening them, and the key
    names about 45 paths (2026-11-25, a developer Mac with 50,619 packs: 70 s per key, 2 s batched).
    """
    paths = list(paths)
    if not paths:
        return {}
    for rel in paths:
        if "\n" in rel:
            raise NoKey("path with a newline: %r" % rel)
    p = subprocess.run(["git", "-C", str(root), "cat-file", "--batch-check=%(objectname) %(objecttype)"],
                       input="".join("%s:%s\n" % (rev, rel) for rel in paths), capture_output=True, text=True)
    if p.returncode != 0:
        raise ToolFailed("git cat-file --batch-check: %s" % p.stderr.strip()[:300])
    lines = p.stdout.splitlines()
    if len(lines) != len(paths):
        raise ToolFailed("git cat-file --batch-check answered %d lines for %d paths" % (len(lines), len(paths)))
    out = {}
    for rel, line in zip(paths, lines):
        oid = "" if line.endswith(" missing") else line.split(" ", 1)[0]
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
    """The key and its manifest: canonical JSON of every input, whose sha256 is the key. The manifest names its
    component ("name") and key version ("v"), so the fleet store can check sha256(manifest) == key itself."""
    data = {"v": SCHEMA, "name": COMPONENT, "trees": inputs(root), "toolchain": toolchain(root), "env": build_env()}
    blob = json.dumps(data, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode()).hexdigest(), data, blob


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
    fleet = ""
    if not entry.is_dir():
        fleet = fleet_fetch(cache, key)
        if not fleet:
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
            print("ios-ffi cache: hit %s%s" % (key[:12], " (" + fleet + ")" if fleet else ""))
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


# The fleet tier. The local cache is per worker: in 15 h (2026-11-26 21:45Z..11-27 12:30Z) 44 simulator steps missed
# and paid 31,407 s of FFI builds, and 13 of those misses were keys another worker had already built (a2b7b418 missed
# on 5 hosts). So a local miss asks the fleet's component store (the controller's /v1/components index, objects in its
# artifact store), and a fresh build goes there through the worker:
#   - the key is the sha256 of the manifest (every input tree, the toolchain, the build settings), the controller
#     accepts an entry only when sha256(manifest) == key, and this reader checks it again: an entry serves exactly the
#     inputs it names, never others;
#   - every file is named by its sha256 and size in the index; the download must match both, and the local entry it
#     becomes is verified file by file (verify) before anything is installed;
#   - the step never writes the store. It leaves its build in $CI_JOB_DIR/component-outputs/ios-ffi/<key>/ and the
#     worker uploads it after the step with its worker token, from its own tailnet node; the controller takes ios-ffi
#     entries only from a fleet worker's simulator step it ran (cmux#13742: fleet-wide sharing, all workers ours).
#     Entries are write-once (the first build of a key wins).
# CMUX_CI_COMPONENT_REMOTE=0 turns the tier off (no read, no export), as for the build's components.

def remote_off():
    return os.environ.get("CMUX_CI_COMPONENT_REMOTE", "1") == "0"


def controller_base():
    return (os.environ.get("CMUX_CI_CONTROLLER") or DEFAULT_CONTROLLER).rstrip("/")


def _open(url, timeout):
    """GET. Inside a step the host's tailnet identity authorizes the read; no token is sent or needed."""
    import urllib.request
    # The artifact edge refuses urllib's default User-Agent.
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "cmux-ios-ffi-cache"}),
                                  timeout=timeout)


def fleet_entry(key):
    """The store's entry for KEY, checked (its manifest hashes to KEY, its files are exactly FLEET_FILES), or None."""
    import urllib.error
    url = "%s/v1/components/%s/%s/%s" % (controller_base(), FLEET_NAMESPACE, COMPONENT, key)
    try:
        with _open(url, 10) as res:
            entry = json.loads(res.read(1 << 20))
    except urllib.error.HTTPError as e:
        if e.code != 404:
            print("ios-ffi cache: fleet store answered %d for %s" % (e.code, key[:12]))
        return None
    except (OSError, ValueError) as e:
        print("ios-ffi cache: fleet store unavailable (%s)" % e)
        return None
    manifest = entry.get("manifest") if isinstance(entry, dict) else None
    if not isinstance(manifest, str) or hashlib.sha256(manifest.encode()).hexdigest() != key:
        print("ios-ffi cache: fleet entry %s does not hash to its key; ignored" % key[:12])
        return None
    files = entry.get("files")
    rows = {}
    for f in files if isinstance(files, list) else []:
        name, digest, size = (f.get("name"), f.get("sha256"), f.get("size")) if isinstance(f, dict) else (None,) * 3
        if (name in FLEET_FILES and name not in rows and isinstance(digest, str) and digest.startswith("sha256:")
                and valid_key(digest[7:]) and type(size) is int and 0 < size <= FLEET_MAX_FILE):
            rows[name] = (digest, size)
    if sorted(rows) != sorted(FLEET_FILES) or len(files) != len(FLEET_FILES):
        print("ios-ffi cache: fleet entry %s has an unexpected file list; ignored" % key[:12])
        return None
    try:
        data = json.loads(manifest)
    except ValueError:
        return None
    if not isinstance(data, dict) or data.get("v") != SCHEMA or data.get("name") != COMPONENT:
        print("ios-ffi cache: fleet entry %s is another schema; ignored" % key[:12])
        return None
    return {"manifest": data, "files": rows, "worker": str(entry.get("worker", ""))[:64]}


def download(name, digest, size, target):
    """One object through the controller's signed URL; its bytes must match DIGEST and SIZE."""
    with _open("%s/v1/artifacts/%s/url" % (controller_base(), digest), 30) as res:
        url = json.loads(res.read(64 << 10)).get("url", "")
    if not isinstance(url, str) or not url.startswith(("https://", "http://")):
        raise OSError("no download URL for " + name)
    h, total = hashlib.sha256(), 0
    with _open(url, 600) as res, open(target, "wb") as out:
        while True:
            chunk = res.read(1 << 20)
            if not chunk:
                break
            total += len(chunk)
            if total > size:
                raise ValueError("%s is larger than its index entry" % name)
            h.update(chunk)
            out.write(chunk)
    if total != size or "sha256:" + h.hexdigest() != digest:
        raise ValueError("%s does not match its sha256 and size" % name)


def unpack(tar_path, dest):
    """The xcframework archive into DEST: regular files and directories only, every name inside the xcframework."""
    import tarfile
    top = pathlib.PurePosixPath(XCFRAMEWORK).name
    with tarfile.open(tar_path, "r:") as tar:
        members = tar.getmembers()
        for m in members:
            parts = pathlib.PurePosixPath(m.name).parts
            if (not parts or parts[0] != top or ".." in parts or m.name.startswith("/")
                    or not (m.isreg() or m.isdir())):
                raise ValueError("archive member %r is not a file or directory of the xcframework" % m.name)
        for m in members:
            target = dest / m.name
            if m.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with tar.extractfile(m) as src, open(target, "wb") as out:
                shutil.copyfileobj(src, out)
            os.chmod(target, 0o755 if m.mode & 0o111 else 0o644)


def fleet_fetch(cache, key):
    """Install the fleet store's entry for KEY as a local entry; a description of it on success, else ""."""
    if remote_off():
        return ""
    entry = fleet_entry(key)
    if entry is None:
        return ""
    started = time.monotonic()
    cache.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix=".tmp.", dir=cache))
    try:
        total = 0
        for name, (digest, size) in sorted(entry["files"].items()):
            download(name, digest, size, tmp / name)
            total += size
        payload = tmp / "payload"
        unpack(tmp / XCF_TAR, payload / pathlib.PurePosixPath(XCFRAMEWORK).parent)
        swift = payload / SWIFT
        swift.parent.mkdir(parents=True, exist_ok=True)
        os.rename(tmp / SWIFT_FILE, swift)
        (tmp / XCF_TAR).unlink()
        for out in OUTPUTS:
            if not (payload / out).exists():
                raise ValueError("the fleet entry lacks " + out)
        trees = entry["manifest"].get("trees")
        manifest = {"schema": SCHEMA, "key": key, "inputs": trees if isinstance(trees, dict) else {},
                    "landed": False, "trusted": None, "fleet": {"worker": entry["worker"]},
                    "files": listing(payload), "created_at": int(time.time())}
        (tmp / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
        try:
            os.rename(tmp, cache / key)
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)  # another step installed the key first; restore verifies it
    except Exception as e:  # never fatal: a miss builds
        shutil.rmtree(tmp, ignore_errors=True)
        print("ios-ffi cache: fleet entry %s not used (%s: %s)" % (key[:12], type(e).__name__, e))
        return ""
    built = " built on " + entry["worker"] if entry["worker"] else ""
    return "fleet store%s, %d MiB in %.1f s" % (built, total >> 20, time.monotonic() - started)


def write_tar(src, target):
    """SRC (a directory) as an uncompressed archive whose bytes depend only on the files: sorted, no owner, mtime 0."""
    import tarfile

    def clean(info):
        info.uid = info.gid = 0
        info.uname = info.gname = ""
        info.mtime = 0
        info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
        return info

    with tarfile.open(target, "w", format=tarfile.PAX_FORMAT) as tar:
        tar.add(src, arcname=src.name, recursive=False, filter=clean)
        for dirpath, dirnames, filenames in os.walk(src):
            dirnames.sort()
            for name in dirnames + sorted(filenames):
                p = pathlib.Path(dirpath) / name
                if p.is_symlink():
                    raise ValueError("link in the xcframework: %s" % p)
                tar.add(p, arcname=str(pathlib.PurePosixPath(src.name) / p.relative_to(src).as_posix()),
                        recursive=False, filter=clean)


def export(entry, key, manifest):
    """Leave ENTRY (a build this step published locally) for the worker to publish to the fleet store. Never fatal."""
    job = os.environ.get("CI_JOB_DIR", "")
    if not job or remote_off() or not isinstance(manifest, str):
        return
    if hashlib.sha256(manifest.encode()).hexdigest() != key or len(manifest.encode()) > FLEET_MAX_MANIFEST:
        print("ios-ffi cache: %s not exported for the fleet store (manifest is not its key or too large)" % key[:12])
        return
    out = pathlib.Path(job) / EXPORT_DIR / COMPONENT / key
    if out.exists():
        return
    try:
        out.parent.mkdir(parents=True, exist_ok=True)
        staging = pathlib.Path(tempfile.mkdtemp(prefix=".incoming.", dir=out.parent))
        try:
            write_tar(entry / "payload" / XCFRAMEWORK, staging / XCF_TAR)
            shutil.copyfile(entry / "payload" / SWIFT, staging / SWIFT_FILE)
            (staging / "manifest.json").write_bytes(manifest.encode())
            os.rename(staging, out)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
    except (OSError, ValueError) as e:
        print("ios-ffi cache: %s not exported for the fleet store (%s)" % (key[:12], e))
        return
    print("ios-ffi cache: %s left for the fleet store" % key[:12])


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
        tip = {}
    # The checkout still holds the inputs the key names (the build changed none of them).
    paths = sorted(want)
    dirty = git(root, "status", "--porcelain", "--untracked-files=all", "--", *paths).stdout.strip()
    if dirty or trees(root, "HEAD", paths) != want:
        print("ios-ffi cache: not stored, the FFI inputs changed during the build")
        return 0
    # Landed or a branch's: either is stored under its own key (see the module doc).
    landed = tip.get("trees") == want
    if not tip:
        how = "branch build, no %s tip to compare with" % TRUSTED_BRANCH
    elif landed:
        how = "inputs as on %s %s" % (TRUSTED_BRANCH, str(tip.get("sha", ""))[:12])
    else:
        changed = sorted(p for p in want if tip.get("trees", {}).get(p) != want[p])
        how = "branch build, inputs differ from %s %s (%s)" % (
            TRUSTED_BRANCH, str(tip.get("sha", ""))[:12], ", ".join(changed))
    for out in OUTPUTS:
        if not (root / out).exists():
            print("ios-ffi cache: not stored, no " + out)
            return 0
    cache.mkdir(parents=True, exist_ok=True)
    tmp = pathlib.Path(tempfile.mkdtemp(prefix=".tmp.", dir=cache))
    try:
        for out in OUTPUTS:
            install(root / out, tmp / "payload" / out)
        manifest = {"schema": SCHEMA, "key": key, "inputs": want, "landed": landed,
                    "trusted": {k: tip.get(k) for k in ("branch", "sha")} if landed else None,
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
    print("ios-ffi cache: stored %s (%s)" % (key[:12], how))
    export(cache / key, key, recorded.get("manifest"))
    removed = prune(cache)
    if removed:
        print("ios-ffi cache: pruned %d old entries (%s)" % (len(removed), ", ".join(k[:12] for k in removed)))
    return 0


def tree_bytes(base):
    total = 0
    for dirpath, dirnames, filenames in os.walk(base):
        for name in filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_size
            except OSError:
                pass
    return total


def crate_of(entry):
    """The crate an artifact under deps/, .fingerprint/, build/ or incremental/ belongs to,
    '-' as '_' (libcmux_wg-0123abcd.rlib, cmux-wg-0123abcd -> cmux_wg); "" for other names."""
    name = entry.split(".", 1)[0] if not entry.startswith(".") else ""
    if name.startswith("lib"):
        name = name[3:]
    if "-" not in name:
        return ""
    return name.rsplit("-", 1)[0].replace("-", "_")


def local_crates(root):
    """The names of the path packages the FFI workspace builds ('-' as '_')."""
    names = set()
    for d in path_packages(root):
        try:
            text = (root / d / "Cargo.toml").read_text()
        except OSError:
            continue
        section = ""
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("["):
                section = line
            elif section == "[package]" and line.startswith("name") and "=" in line:
                names.add(line.split("=", 1)[1].strip().strip('"\'').replace("-", "_"))
                break
    return names


def trim_target(slot, root, started):
    """Remove the path crates' artifacts this build superseded: every step's checkout is a new
    path, so cargo builds them under a new hash each step and the old ones are never used again.
    Registry crates' artifacts stay (that is the point of the slot). Then empty a slot past
    TARGET_CAP_BYTES. Returns (files removed, slot bytes after)."""
    names = local_crates(root)
    removed = 0
    for dirpath, dirnames, _ in os.walk(slot):
        if os.path.basename(dirpath) not in TARGET_ARTIFACT_DIRS:
            continue
        dirnames[:] = []  # an artifact dir's entries are artifacts, not more profile dirs
        entries = []
        for name in os.listdir(dirpath):
            crate = crate_of(name)
            if crate in names:
                try:
                    entries.append((crate, name, os.lstat(os.path.join(dirpath, name)).st_mtime))
                except OSError:
                    pass
        fresh = {crate for crate, _, mtime in entries if mtime >= started}
        for crate, name, mtime in entries:
            if crate in fresh and mtime < started:
                p = os.path.join(dirpath, name)
                if os.path.isdir(p) and not os.path.islink(p):
                    shutil.rmtree(p, ignore_errors=True)
                else:
                    with contextlib.suppress(OSError):
                        os.unlink(p)
                removed += 1
    size = tree_bytes(slot)
    if size > TARGET_CAP_BYTES:
        for child in list(slot.iterdir()):
            if child.is_dir() and not child.is_symlink():
                shutil.rmtree(child, ignore_errors=True)
            elif child.name != "toolchain.txt":
                with contextlib.suppress(OSError):
                    child.unlink()
        print("ios-ffi target: emptied %s (%d GiB, past %d GiB)" % (slot.name, size >> 30, TARGET_CAP_BYTES >> 30))
        size = 0
    return removed, size


def run_build(argv, rc_file, env=None):
    """Run the build and record its exit code at once, before anything else can fail."""
    rc = subprocess.call(argv, env=env)
    pathlib.Path(rc_file).write_text("%d\n" % rc)
    return rc


def build(root, rc_file, argv):
    """Run the FFI build ARGV with CARGO_TARGET_DIR in a free warm slot (see the module doc)."""
    base = os.environ.get("CMUX_CI_CACHE_DIR")
    if not base:
        return run_build(argv, rc_file)
    slots = pathlib.Path(base) / "ios-ffi-target"
    slots.mkdir(parents=True, exist_ok=True)
    for n in range(TARGET_SLOTS):
        with open(slots / ("%d.lock" % n), "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                continue
            slot = slots / str(n)
            slot.mkdir(exist_ok=True)
            # cargo's fingerprints name rustc but not Xcode or the SDKs the C code builds against.
            try:
                tools = toolchain(root)
            except ToolFailed as e:
                print("ios-ffi target: no toolchain (%s), building in the checkout" % e, flush=True)
                return run_build(argv, rc_file)
            stamp = slot / "toolchain.txt"
            try:
                same = stamp.read_text() == tools
            except OSError:
                same = False
            if not same:
                for child in list(slot.iterdir()):
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child, ignore_errors=True)
                    else:
                        child.unlink()
                stamp.write_text(tools)
            warm = any(c.name != "toolchain.txt" for c in slot.iterdir())
            print("ios-ffi target: slot %d (%s)" % (n, "warm" if warm else "cold"), flush=True)
            started = time.time() - 2  # mtime granularity
            rc = run_build(argv, rc_file, env=dict(os.environ, CARGO_TARGET_DIR=str(slot)))
            try:
                removed, size = trim_target(slot, root, started)
                print("ios-ffi target: slot %d holds %.1f GiB after removing %d superseded artifacts"
                      % (n, size / (1 << 30), removed))
            except Exception as e:  # trimming only bounds the slot; never fail the build for it
                print("ios-ffi target: trim failed: %s: %s" % (type(e).__name__, e))
            return rc
    print("ios-ffi target: every slot busy, building in the checkout", flush=True)
    return run_build(argv, rc_file)


USAGE = """usage: ios_ffi_cache.py key ROOT INPUTS | restore ROOT KEY | probe INPUTS TIP | store ROOT INPUTS TIP
       | build ROOT RC CMD..."""


def main(argv):
    arity = {"key": 3, "restore": 3, "probe": 3, "store": 4}
    if argv and argv[0] == "build" and len(argv) >= 4:
        return build(pathlib.Path(argv[1]).resolve(), argv[2], argv[3:])
    if not argv or arity.get(argv[0]) != len(argv):
        print(USAGE, file=sys.stderr)
        return 2
    try:
        if argv[0] == "key":
            if cache_root() is None:
                print("ios-ffi cache: off (no CMUX_CI_CACHE_DIR)", file=sys.stderr)
                return 3
            key, data, blob = compute_key(pathlib.Path(argv[1]).resolve())
            pathlib.Path(argv[2]).write_text(
                json.dumps({"key": key, "trees": data["trees"], "manifest": blob}, sort_keys=True) + "\n")
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
