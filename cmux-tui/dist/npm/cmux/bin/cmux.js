#!/usr/bin/env node
"use strict";

// Launcher for `npx cmux` / a global `cmux` install. The actual TUI is a
// prebuilt Rust binary published as per-platform npm packages
// (cmux-tui-<platform>). This shim resolves that binary and execs it,
// forwarding argv, stdio, exit code, and signals.
//
// The platform packages are NOT optionalDependencies. npm's npx cache has a
// long-standing ENOTEMPTY reify bug that fires when `npx cmux@latest`
// upgrades a cached tree containing per-platform binary packages
// (https://github.com/npm/cli/issues/4622). Instead, the shim downloads the
// platform package tarball from the npm registry on first run, verifies the
// registry's sha512 integrity for it, and extracts the binaries into a
// versioned launcher cache outside npm's control. `cmux update` moves that
// cache to the latest published version without npm ever reifying anything,
// so routine upgrades cannot hit the npx cache bug.
//
// Resolve order for the binary:
//   1. CMUX_TUI_BIN (explicit override, development and debugging)
//   2. an installed platform package (require.resolve) whose version matches
//      the wanted version exactly -- this keeps offline installs working:
//      `npm install -g cmux cmux-tui-<platform>` never needs the network
//   3. the launcher cache entry for the wanted version
//   4. download the wanted version into the launcher cache
//   5. fail closed when the requested version cannot be obtained
//
// Wanted version = max(shim's own package version, version recorded by
// `cmux update`) within the same release channel. A stable update record must
// never satisfy a nightly (or another prerelease-channel) shim.

const { spawnSync } = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const zlib = require("zlib");

const PACKAGE_BY_PLATFORM = {
  "darwin-arm64": "cmux-tui-darwin-arm64",
  "darwin-x64": "cmux-tui-darwin-x64",
  "linux-x64": "cmux-tui-linux-x64",
  "linux-arm64": "cmux-tui-linux-arm64",
  "win32-x64": "cmux-tui-win32-x64",
};

const EXE = process.platform === "win32" ? ".exe" : "";
const BIN_NAME = `cmux-tui${EXE}`;
const PUBLISHED_VERSION = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/;
const MAX_TARBALL_BYTES = 256 * 1024 * 1024;
const MAX_METADATA_BYTES = 1024 * 1024;
const REGISTRY_TIMEOUT_MS = 30_000;
const STAGING_MAX_AGE_MS = 60 * 60 * 1000;
const CACHE_LOCK_ATTEMPTS = 3;
const CACHE_LOCK_RETRY_INITIAL_MS = 25;
const CACHE_LOCK_RETRY_MAX_MS = 250;
const CACHE_LOCK_WAIT_MAX_MS = 2_000;
// A process can be interrupted between creating the lock directory and
// publishing its owner file. Reclaim only an ownerless lock that has been
// quiet for long enough that the creator cannot still be in that window.
const CACHE_LOCK_EMPTY_MAX_AGE_MS = 5 * 60 * 1000;
// Leases are published by renaming a fully initialized temporary directory.
// Keep the same bounded recovery window for legacy or interrupted leases.
const CACHE_LEASE_EMPTY_MAX_AGE_MS = 5 * 60 * 1000;
// Keep the requested version and one newest managed predecessor. This bounds
// disk use while retaining one rollback target after an update.
const MAX_PREVIOUS_MANAGED_VERSIONS = 1;
const MIN_NODE_MAJOR = 18;

class LauncherError extends Error {
  constructor(message) {
    super(message);
    this.name = "LauncherError";
  }
}

function fail(message) {
  throw new LauncherError(message);
}

function platformPackage() {
  const key = `${process.platform}-${process.arch}`;
  const pkg = PACKAGE_BY_PLATFORM[key];
  if (!pkg) {
    fail(
      `no prebuilt binary for ${key}. Supported: ${Object.keys(PACKAGE_BY_PLATFORM).join(", ")}.`
    );
  }
  return pkg;
}

function shimVersion() {
  const version = require("../package.json").version;
  if (process.env.CMUX_TUI_LAUNCHER_VERSION) {
    return process.env.CMUX_TUI_LAUNCHER_VERSION;
  }
  return version;
}

function validVersion(version) {
  return typeof version === "string" && PUBLISHED_VERSION.test(version);
}

function versionChannel(version) {
  if (typeof version !== "string") return null;
  const match = /^\d+\.\d+\.\d+-([0-9A-Za-z]+)/.exec(version);
  return match ? match[1].toLowerCase() : "stable";
}

function stateVersionChannel(state) {
  if (!state || !validVersion(state.version)) return null;
  const inferred = versionChannel(state.version);
  if (
    typeof state.channel === "string" &&
    state.channel.toLowerCase() !== inferred
  ) {
    return null;
  }
  return inferred;
}

function latestDistTag(version) {
  const channel = versionChannel(version);
  if (!channel) return null;
  return channel === "stable" ? "latest" : channel;
}

function isManagedPlaceholder(version) {
  return version === "0.0.0-managed";
}

// Minimal semver comparison, enough for the version shapes this repo
// publishes (X.Y.Z, X.Y.Z-rc.N, X.Y.Z-nightly.YYYYMMDD.N). Returns
// negative/zero/positive like a comparator. Prerelease sorts before the
// release with the same triple.
function compareVersions(a, b) {
  const parse = (v) => {
    const m = /^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?/.exec(v);
    if (!m) return null;
    return {
      nums: [Number(m[1]), Number(m[2]), Number(m[3])],
      pre: m[4] ? m[4].split(".") : null,
    };
  };
  const pa = parse(a);
  const pb = parse(b);
  if (!pa || !pb) return String(a).localeCompare(String(b));
  for (let i = 0; i < 3; i++) {
    if (pa.nums[i] !== pb.nums[i]) return pa.nums[i] - pb.nums[i];
  }
  if (!pa.pre && !pb.pre) return 0;
  if (!pa.pre) return 1;
  if (!pb.pre) return -1;
  for (let i = 0; i < Math.max(pa.pre.length, pb.pre.length); i++) {
    const x = pa.pre[i];
    const y = pb.pre[i];
    if (x === undefined) return -1;
    if (y === undefined) return 1;
    const xn = /^\d+$/.test(x);
    const yn = /^\d+$/.test(y);
    if (xn && yn) {
      if (Number(x) !== Number(y)) return Number(x) - Number(y);
    } else if (xn !== yn) {
      return xn ? -1 : 1;
    } else if (x !== y) {
      return x < y ? -1 : 1;
    }
  }
  return 0;
}

function cacheRoot() {
  if (process.env.CMUX_TUI_LAUNCHER_CACHE) {
    return process.env.CMUX_TUI_LAUNCHER_CACHE;
  }
  if (process.platform === "win32") {
    const base = process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
    return path.join(base, "cmux-tui-launcher");
  }
  if (process.platform === "darwin") {
    return path.join(os.homedir(), "Library", "Caches", "cmux-tui-launcher");
  }
  const base = process.env.XDG_CACHE_HOME || path.join(os.homedir(), ".cache");
  return path.join(base, "cmux-tui-launcher");
}

function platformRoot() {
  return path.join(cacheRoot(), `${process.platform}-${process.arch}`);
}

const STATE_CHANNEL = /^[a-z0-9]+$/;

function statePath(channel) {
  if (typeof channel !== "string" || !STATE_CHANNEL.test(channel)) return null;
  return path.join(platformRoot(), "state", `${channel}.json`);
}

function legacyStatePath() {
  return path.join(platformRoot(), "state.json");
}

function readStateFile(target) {
  try {
    const state = JSON.parse(fs.readFileSync(target, "utf8"));
    if (state && validVersion(state.version)) return state;
  } catch {}
  return null;
}

function readLegacyState() {
  return readStateFile(legacyStatePath());
}

function readState(channel) {
  const target = statePath(channel);
  if (!target) return null;
  const state = readStateFile(target);
  if (state && stateVersionChannel(state) === channel) return state;
  // Migrate state written by older launchers lazily. A legacy record is only
  // eligible for the channel encoded by its version, so a stable record can
  // never satisfy a nightly launcher (or the reverse).
  const legacy = readLegacyState();
  return legacy && stateVersionChannel(legacy) === channel ? legacy : null;
}

function readUnambiguousManagedState() {
  const candidates = [];
  const legacy = readLegacyState();
  if (legacy && stateVersionChannel(legacy)) candidates.push(legacy);
  const stateRoot = path.join(platformRoot(), "state");
  try {
    for (const entry of fs.readdirSync(stateRoot, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
      const state = readStateFile(path.join(stateRoot, entry.name));
      if (state && stateVersionChannel(state)) candidates.push(state);
    }
  } catch {}
  const unique = new Map(
    candidates.map((state) => [
      `${stateVersionChannel(state)}:${state.version}`,
      state,
    ])
  );
  return unique.size === 1 ? unique.values().next().value : null;
}

function writeState(state) {
  const channel =
    typeof state?.channel === "string"
      ? state.channel.toLowerCase()
      : versionChannel(state?.version);
  if (
    !channel ||
    !STATE_CHANNEL.test(channel) ||
    stateVersionChannel({ ...state, channel }) !== channel
  ) {
    fail("cannot persist launcher state for an invalid release channel");
  }
  const target = statePath(channel);
  if (!target) fail("cannot persist launcher state for an invalid release channel");
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(
    tmp,
    JSON.stringify({ ...state, channel }, null, 2) + "\n"
  );
  fs.renameSync(tmp, target);
}

function cachedBinDir(version) {
  return path.join(platformRoot(), "v", version, "bin");
}

function cacheManifestPath(version) {
  return path.join(platformRoot(), "v", version, "manifest.json");
}

function digestHex(buffer) {
  return crypto.createHash("sha512").update(buffer).digest("hex");
}

function sameFileIdentity(left, right) {
  // Windows does not expose stable dev/inode values through every Node
  // version. Unix launchers have the descriptor identity needed for the
  // symlink and replacement checks below.
  return (
    process.platform === "win32" ||
    (left.dev === right.dev && left.ino === right.ino)
  );
}

function openCachedBinary(bin) {
  let fd;
  try {
    const linkStat = fs.lstatSync(bin);
    if (!linkStat.isFile()) return null;
    const noFollow = process.platform === "win32" ? 0 : fs.constants.O_NOFOLLOW;
    if (process.platform !== "win32" && typeof noFollow !== "number") return null;
    fd = fs.openSync(bin, fs.constants.O_RDONLY | noFollow);
    const openedStat = fs.fstatSync(fd);
    if (!openedStat.isFile() || !sameFileIdentity(linkStat, openedStat)) {
      fs.closeSync(fd);
      fd = undefined;
      return null;
    }
    return { fd, stat: openedStat };
  } catch (error) {
    if (fd !== undefined) {
      try {
        fs.closeSync(fd);
      } catch {}
    }
    throw error;
  }
}

function readCachedManifest(version) {
  const bin = path.join(cachedBinDir(version), BIN_NAME);
  try {
    const manifest = JSON.parse(fs.readFileSync(cacheManifestPath(version), "utf8"));
    const expected = manifest?.binaries?.[BIN_NAME];
    if (
      manifest?.version !== version ||
      typeof expected !== "string" ||
      !/^[a-f0-9]{128}$/.test(expected)
    ) {
      return null;
    }
    return { bin, expected };
  } catch {
    return null;
  }
}

function readVerifiedCachedBinary(fd, expected) {
  const before = fs.fstatSync(fd);
  if (!before.isFile()) return null;
  const data = fs.readFileSync(fd);
  const after = fs.fstatSync(fd);
  if (!after.isFile() || !sameFileIdentity(before, after) || after.size !== data.length) {
    return null;
  }
  const actual = Buffer.from(digestHex(data), "hex");
  const expectedBytes = Buffer.from(expected, "hex");
  if (!crypto.timingSafeEqual(actual, expectedBytes)) return null;
  return { stat: after, data };
}

function cachedBinaryPathIsUnchanged(bin, expectedStat) {
  const finalStat = fs.lstatSync(bin);
  return finalStat.isFile() && sameFileIdentity(finalStat, expectedStat);
}

function cachedBinary(version, candidate = null) {
  const resolvedCandidate = candidate || readCachedManifest(version);
  if (!resolvedCandidate) return null;
  let opened = null;
  try {
    opened = openCachedBinary(resolvedCandidate.bin);
    if (!opened) return null;
    let verified = readVerifiedCachedBinary(opened.fd, resolvedCandidate.expected);
    if (!verified) return null;
    let verifiedStat = verified.stat;
    if (process.platform !== "win32") {
      if ((verifiedStat.mode & 0o111) === 0) {
        const versionRoot = path.dirname(cachedBinDir(version));
        if (!isManagedCacheVersion(versionRoot)) return null;
        // A trusted cache copy can lose its mode bits during transfer. Repair
        // them only on the open descriptor of a managed entry, then reopen and
        // revalidate the digest and path identity before accepting it.
        fs.fchmodSync(opened.fd, 0o755);
        fs.closeSync(opened.fd);
        opened = null;
        opened = openCachedBinary(resolvedCandidate.bin);
        if (!opened) return null;
        verified = readVerifiedCachedBinary(opened.fd, resolvedCandidate.expected);
        if (!verified || (verified.stat.mode & 0o111) === 0) return null;
        verifiedStat = verified.stat;
      }
      fs.accessSync(resolvedCandidate.bin, fs.constants.X_OK);
    }
    if (!cachedBinaryPathIsUnchanged(resolvedCandidate.bin, verifiedStat)) return null;
    return resolvedCandidate.bin;
  } catch {
    return null;
  } finally {
    if (opened) fs.closeSync(opened.fd);
  }
}

// Check only cheap metadata before lease setup. Full digest verification is
// performed once after the lease, or while making a private read-only snapshot.
function cachedBinaryCandidate(version) {
  const candidate = readCachedManifest(version);
  if (!candidate) return null;
  try {
    const stat = fs.lstatSync(candidate.bin);
    if (!stat.isFile()) return null;
    if (process.platform !== "win32") {
      if ((stat.mode & 0o111) === 0) return null;
      fs.accessSync(candidate.bin, fs.constants.X_OK);
    }
    return candidate;
  } catch {
    return null;
  }
}

function snapshotVerifiedCachedBinary(candidate) {
  let opened = null;
  let snapshotDirectory = null;
  let snapshotFd;
  let snapshot = null;
  let complete = false;
  try {
    opened = openCachedBinary(candidate.bin);
    if (!opened) return null;
    const verified = readVerifiedCachedBinary(opened.fd, candidate.expected);
    if (!verified) return null;
    if (
      process.platform !== "win32" &&
      (verified.stat.mode & 0o111) === 0
    ) {
      return null;
    }
    if (!cachedBinaryPathIsUnchanged(candidate.bin, verified.stat)) return null;
    snapshotDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-tui-launch-"));
    snapshot = path.join(snapshotDirectory, BIN_NAME);
    snapshotFd = fs.openSync(
      snapshot,
      fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL,
      0o700
    );
    fs.writeFileSync(snapshotFd, verified.data);
    if (process.platform !== "win32") fs.fchmodSync(snapshotFd, 0o700);
    fs.closeSync(snapshotFd);
    snapshotFd = undefined;
    if (process.platform !== "win32") fs.accessSync(snapshot, fs.constants.X_OK);
    complete = true;
    return { path: snapshot, directory: snapshotDirectory };
  } catch {
    return null;
  } finally {
    if (opened) {
      try {
        fs.closeSync(opened.fd);
      } catch {}
    }
    if (snapshotFd !== undefined) {
      try {
        fs.closeSync(snapshotFd);
      } catch {}
    }
    if (snapshotDirectory && !complete) {
      try {
        fs.rmSync(snapshotDirectory, { recursive: true, force: true });
      } catch {}
    }
  }
}

function removeLaunchSnapshot(snapshot) {
  if (!snapshot) return;
  try {
    fs.rmSync(snapshot.directory, { recursive: true, force: true });
  } catch {}
}

// A verified cache entry can be launched from a centrally provisioned
// read-only cache. Check every directory and trusted file that could let a
// routine launcher publish a lease or prune or replace the version before
// using that path. A partially writable cache stays on the leased path so
// pruning remains serialized.
function cacheVersionIsReadOnly(version) {
  const versionRoot = path.dirname(cachedBinDir(version));
  const binDir = cachedBinDir(version);
  const leaseRoot = path.join(versionRoot, ".active");
  const directories = [
    cacheRoot(),
    platformRoot(),
    path.dirname(versionRoot),
    versionRoot,
    binDir,
  ];
  try {
    if (fs.existsSync(leaseRoot)) directories.push(leaseRoot);
  } catch {
    return false;
  }
  for (const directory of directories) {
    try {
      if (!fs.statSync(directory).isDirectory()) return false;
      fs.accessSync(directory, fs.constants.W_OK);
      // Any writable directory could publish a lease or remove a version
      // through its parent, so do not use an unleased launch path.
      return false;
    } catch (error) {
      // EACCES/EPERM is the expected result for a read-only provisioned tree.
      // Unknown failures are not enough to prove that routine mutation is
      // impossible, so fail closed instead.
      if (!error || (error.code !== "EACCES" && error.code !== "EPERM")) {
        return false;
      }
    }
  }
  const trustedFiles = [
    path.join(versionRoot, "manifest.json"),
    path.join(binDir, BIN_NAME),
  ];
  const marker = path.join(versionRoot, "managed");
  try {
    if (fs.existsSync(marker)) trustedFiles.push(marker);
  } catch {
    return false;
  }
  for (const file of trustedFiles) {
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile()) return false;
      if (process.platform !== "win32" && (stat.mode & 0o222) !== 0) {
        return false;
      }
      fs.accessSync(file, fs.constants.W_OK);
      return false;
    } catch (error) {
      if (!error || (error.code !== "EACCES" && error.code !== "EPERM")) {
        return false;
      }
    }
  }
  return true;
}

function cacheLockPath() {
  return path.join(platformRoot(), ".update.lock");
}

// Keep update serialization separate from the cache lock. Launches must still
// publish version leases while an update is downloading, so prune can honor
// those leases instead of failing every launch for the whole network request.
function updateOperationLockPath() {
  return path.join(platformRoot(), ".update-operation.lock");
}

function waitForCacheLockRetry(delayMs, signal) {
  if (signal?.aborted) return Promise.resolve(false);
  return new Promise((resolve) => {
    let timer;
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      resolve(result);
    };
    const onAbort = () => finish(false);
    timer = setTimeout(() => finish(true), delayMs);
    if (signal) {
      if (signal.aborted) {
        finish(false);
        return;
      }
      signal.addEventListener("abort", onAbort, { once: true });
    }
  });
}

function lockWaitCancellation() {
  const controller = new AbortController();
  const handlers = new Map();
  for (const signalName of ["SIGINT", "SIGTERM", "SIGHUP"]) {
    const handler = () => controller.abort();
    handlers.set(signalName, handler);
    process.once(signalName, handler);
  }
  return {
    signal: controller.signal,
    dispose() {
      for (const [signalName, handler] of handlers) {
        process.removeListener(signalName, handler);
      }
    },
  };
}

function cacheLockOwnerPath(lockPath = cacheLockPath()) {
  return path.join(lockPath, "owner");
}

function newCacheLockOwner() {
  const token = `${process.pid}-${Date.now().toString(36)}-${crypto
    .randomBytes(16)
    .toString("hex")}`;
  return {
    pid: process.pid,
    token,
    raw: `${process.pid}\n${token}\n`,
  };
}

function parseCacheLockOwner(raw) {
  if (typeof raw !== "string") return null;
  const lines = raw.trim().split(/\s+/);
  const pid = Number.parseInt(lines[0], 10);
  const token = lines[1];
  if (!Number.isInteger(pid) || pid <= 0 || !token) return null;
  return { pid, token, raw };
}

function readCacheLockOwnerAt(ownerPath) {
  try {
    const raw = fs.readFileSync(ownerPath, "utf8");
    return parseCacheLockOwner(raw);
  } catch {
    return null;
  }
}

function readCacheLockOwner(lockPath = cacheLockPath()) {
  return readCacheLockOwnerAt(cacheLockOwnerPath(lockPath));
}

function processIsAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return !error || error.code !== "ESRCH";
  }
}

// A pending owner file is written before it is atomically renamed to `owner`.
// If the writer dies before the rename, a live pending owner proves that an
// apparently empty lock is still being initialized and must not be reclaimed.
function emptyCacheLockCanBeReclaimed(lockPath = cacheLockPath()) {
  let entries;
  try {
    entries = fs.readdirSync(lockPath, { withFileTypes: true });
  } catch {
    return false;
  }
  for (const entry of entries) {
    if (entry.name === "owner") {
      let size;
      try {
        size = fs.statSync(path.join(lockPath, entry.name)).size;
      } catch {
        return false;
      }
      // An interrupted legacy direct write can leave an empty owner file.
      if (!entry.isFile() || size !== 0) return false;
      continue;
    }
    if (!entry.isFile() || !entry.name.startsWith(".owner-") || !entry.name.endsWith(".tmp")) {
      return false;
    }
    const pending = readCacheLockOwnerAt(path.join(lockPath, entry.name));
    if (pending && processIsAlive(pending.pid)) return false;
  }
  return true;
}

function emptyCacheLockIsStale(lockPath = cacheLockPath()) {
  let stat;
  try {
    stat = fs.statSync(lockPath);
  } catch {
    return false;
  }
  if (!stat.isDirectory() || !Number.isFinite(stat.mtimeMs)) return false;
  if (Date.now() - stat.mtimeMs < CACHE_LOCK_EMPTY_MAX_AGE_MS) return false;
  return emptyCacheLockCanBeReclaimed(lockPath);
}

// Remove a lock only when its owner file still matches the observed token.
// Rename the directory first, so the compare and delete cannot race a newer
// owner that acquires the path after stale-lock cleanup starts.
function removeCacheLockIfOwned(owner, allowEmpty = false, lockPath = cacheLockPath()) {
  let observed;
  try {
    observed = fs.readFileSync(cacheLockOwnerPath(lockPath), "utf8");
  } catch {
    if (!allowEmpty) return false;
  }
  const observedEmpty = observed === undefined || observed === "";
  if (!observedEmpty && observed !== owner.raw) return false;
  if (observedEmpty && !allowEmpty && owner.raw !== undefined) return false;

  const quarantine = `${lockPath}.reclaim-${process.pid}-${Date.now().toString(36)}-${crypto
    .randomBytes(8)
    .toString("hex")}`;
  let removed = false;
  try {
    // rename is atomic within the cache directory. A competing stale-lock
    // cleaner either loses the rename or sees the replacement owner.
    fs.renameSync(lockPath, quarantine);
    let actual;
    try {
      actual = fs.readFileSync(path.join(quarantine, "owner"), "utf8");
    } catch {
      actual = undefined;
    }
    const actualEmpty = actual === undefined || actual === "";
    if (!actualEmpty && actual !== owner.raw) return false;
    if (actualEmpty && !allowEmpty && owner.raw !== undefined) return false;
    fs.rmSync(quarantine, { recursive: true, force: false });
    removed = true;
    return true;
  } catch {
    return false;
  } finally {
    if (!removed) {
      // Restore the lock only when the path is still vacant. If a new owner
      // won the path, leave its lock untouched and retain this quarantine for
      // conservative operator cleanup.
      try {
        fs.renameSync(quarantine, lockPath);
      } catch {}
    }
  }
}

function tryAcquireCacheLock(lockPath = cacheLockPath()) {
  try {
    fs.mkdirSync(path.dirname(lockPath), { recursive: true });
  } catch {
    return null;
  }

  for (let attempt = 0; attempt < CACHE_LOCK_ATTEMPTS; attempt++) {
    const owner = newCacheLockOwner();
    let created = false;
    try {
      fs.mkdirSync(lockPath, { recursive: false });
      created = true;
      // Publish the complete owner record with rename so readers never see a
      // partially written PID/token pair.
      const ownerTempPath = path.join(lockPath, `.owner-${owner.token}.tmp`);
      fs.writeFileSync(ownerTempPath, owner.raw, {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      fs.renameSync(ownerTempPath, cacheLockOwnerPath(lockPath));
      return owner;
    } catch {
      // If this attempt created the directory but could not publish its owner,
      // clean up only that lock. Never remove an owner published by a different
      // process.
      if (created) {
        removeCacheLockIfOwned(owner, true, lockPath);
        return null;
      }
    }

    const current = readCacheLockOwner(lockPath);
    if (current) {
      if (processIsAlive(current.pid)) return null;
      if (!removeCacheLockIfOwned(current, false, lockPath)) return null;
      continue;
    }
    // Unknown or malformed lock state is retained conservatively unless it is
    // an ownerless directory left behind by an interrupted acquisition. The
    // age gate plus atomic quarantine prevents deleting a fresh initializer.
    if (!emptyCacheLockIsStale(lockPath)) return null;
    if (!removeCacheLockIfOwned({ raw: undefined }, true, lockPath)) return null;
  }
  return null;
}

function releaseCacheLock(owner, lockPath = cacheLockPath()) {
  if (!owner) return;
  removeCacheLockIfOwned(owner, false, lockPath);
}

function tryAcquireVersionLease(version) {
  const leaseRoot = path.join(platformRoot(), "v", version, ".active");
  for (let attempt = 0; attempt < CACHE_LOCK_ATTEMPTS; attempt++) {
    const lock = tryAcquireCacheLock();
    if (!lock) continue;
    let lease = null;
    let pendingLease = null;
    try {
      lease = path.join(
        leaseRoot,
        `${process.pid}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
      );
      pendingLease = `${lease}.pending`;
      fs.mkdirSync(leaseRoot, { recursive: true });
      // Build the lease away from the directory scanned by prune. Publish it
      // only after its PID record is complete, using an atomic directory
      // rename so an interruption cannot expose an empty active lease.
      fs.mkdirSync(pendingLease, { recursive: false });
      const pidTemp = path.join(pendingLease, ".pid.tmp");
      fs.writeFileSync(pidTemp, `${process.pid}\n`, {
        encoding: "utf8",
        flag: "wx",
        mode: 0o600,
      });
      fs.renameSync(pidTemp, path.join(pendingLease, "pid"));
      fs.renameSync(pendingLease, lease);
      pendingLease = null;
      return lease;
    } catch {
      for (const pathToRemove of [pendingLease, lease]) {
        if (!pathToRemove) continue;
        try {
          fs.rmSync(pathToRemove, { recursive: true, force: true });
        } catch {}
      }
    } finally {
      releaseCacheLock(lock);
    }
  }
  return null;
}

// Lease creation is normally short, but another launcher can briefly own the
// cache lock while it publishes a lease or prunes old versions. Retry without
// blocking the event loop, and stop waiting at a bounded deadline or signal.
async function acquireVersionLease(version, signal) {
  const deadline = Date.now() + CACHE_LOCK_WAIT_MAX_MS;
  let delayMs = CACHE_LOCK_RETRY_INITIAL_MS;
  while (!signal?.aborted) {
    const lease = tryAcquireVersionLease(version);
    if (lease) return lease;
    const remainingMs = deadline - Date.now();
    if (remainingMs <= 0) return null;
    const waited = await waitForCacheLockRetry(
      Math.min(delayMs, remainingMs),
      signal
    );
    if (!waited) return null;
    delayMs = Math.min(delayMs * 2, CACHE_LOCK_RETRY_MAX_MS);
  }
  return null;
}

async function acquireVersionLeaseForProcess(version) {
  const cancellation = lockWaitCancellation();
  try {
    return await acquireVersionLease(version, cancellation.signal);
  } finally {
    cancellation.dispose();
  }
}

function releaseVersionLease(lease) {
  if (!lease) return;
  try {
    fs.rmSync(lease, { recursive: true, force: true });
    const leaseRoot = path.dirname(lease);
    if (path.basename(leaseRoot) === ".active") fs.rmdirSync(leaseRoot);
  } catch {}
}

// Returns "live" or "dead" for a PID owner, "missing" or "malformed" for a
// recoverable interrupted record, and "unknown" for an unreadable record.
function leaseActivity(lease) {
  let raw;
  try {
    raw = fs.readFileSync(path.join(lease, "pid"), "utf8");
  } catch (error) {
    return error && (error.code === "ENOENT" || error.code === "EISDIR")
      ? "missing"
      : "unknown";
  }
  const pid = Number.parseInt(raw, 10);
  if (!Number.isInteger(pid) || pid <= 0) return "malformed";
  try {
    process.kill(pid, 0);
    return "live";
  } catch (error) {
    return error && error.code === "ESRCH" ? "dead" : "unknown";
  }
}

function leaseIsStale(lease) {
  try {
    const stat = fs.statSync(lease);
    return (
      Number.isFinite(stat.mtimeMs) &&
      Date.now() - stat.mtimeMs >= CACHE_LEASE_EMPTY_MAX_AGE_MS
    );
  } catch {
    return false;
  }
}

function leaseCanBeReclaimed(lease) {
  const activity = leaseActivity(lease);
  if (activity === "live" || activity === "unknown") return false;
  if (activity === "dead") return true;
  return leaseIsStale(lease);
}

function versionHasActiveLease(versionDir) {
  const leaseRoot = path.join(versionDir, ".active");
  if (!fs.existsSync(leaseRoot)) return false;
  try {
    const entries = fs.readdirSync(leaseRoot, { withFileTypes: true });
    let active = false;
    for (const entry of entries) {
      const lease = path.join(leaseRoot, entry.name);
      if (entry.isDirectory()) {
        if (leaseCanBeReclaimed(lease)) {
          fs.rmSync(lease, { recursive: true, force: true });
        } else {
          active = true;
        }
      } else if (entry.name === "pid") {
        // Read leases written by older launchers, before leases became
        // per-process directories.
        const activity = leaseActivity(leaseRoot);
        if (activity === "live" || activity === "unknown") {
          active = true;
        } else if (activity === "dead" || leaseIsStale(leaseRoot)) {
          fs.rmSync(path.join(leaseRoot, "pid"), { recursive: false, force: true });
        } else {
          // A fresh malformed legacy record may belong to a process that is
          // still publishing its PID. Retain the version until it is stale.
          active = true;
        }
      } else {
        // Unknown lease state is retained conservatively.
        active = true;
      }
    }
    if (!active && fs.readdirSync(leaseRoot).length === 0) {
      fs.rmdirSync(leaseRoot);
    }
    return active;
  } catch {
    // Cleanup must never remove a version when lease state is unreadable.
    return true;
  }
}

function cleanupStaging() {
  const root = path.join(platformRoot(), "tmp");
  let entries;
  try {
    entries = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return;
  }
  const now = Date.now();
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const staging = path.join(root, entry.name);
    let stat;
    try {
      stat = fs.statSync(staging);
    } catch {
      continue;
    }
    const age = now - stat.mtimeMs;
    const match = /-(\d+)-[a-z0-9]+$/.exec(entry.name);
    let active = false;
    if (match) {
      const pid = Number.parseInt(match[1], 10);
      try {
        process.kill(pid, 0);
        active = true;
      } catch (error) {
        active = !error || error.code !== "ESRCH";
      }
    }
    if (active) continue;
    if (match && age < STAGING_MAX_AGE_MS) continue;
    try {
      fs.rmSync(staging, { recursive: true, force: true });
    } catch {}
  }
}

// Resolve an installed cmux-tui-<platform> package (global or local install).
// Returns { binPath, version } or null.
function installedPackage(pkg) {
  try {
    const packageJsonPath = require.resolve(`${pkg}/package.json`);
    const binPath = path.join(path.dirname(packageJsonPath), "bin", BIN_NAME);
    if (!fs.existsSync(binPath)) return null;
    const version = require(packageJsonPath).version;
    return { binPath, version };
  } catch {
    return null;
  }
}

function normalizeRegistryValue(value) {
  if (!configValueIsPresent(value)) return null;
  let raw = String(value).trim();
  // npm accepts quoted ini values and environment substitutions in .npmrc.
  if (
    raw.length >= 2 &&
    ((raw.startsWith('"') && raw.endsWith('"')) ||
      (raw.startsWith("'") && raw.endsWith("'")))
  ) {
    raw = raw.slice(1, -1).trim();
  }
  raw = raw.replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] || "");
  if (!configValueIsPresent(raw)) return null;
  try {
    const parsed = new URL(raw);
    if (parsed.protocol !== "http:" && parsed.protocol !== "https:") return null;
    return parsed.toString().replace(/\/+$/, "");
  } catch {
    return null;
  }
}

function npmrcRegistry(contents) {
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    const match = /^registry\s*=\s*(.*?)\s*$/i.exec(line);
    if (!match) continue;
    // Keep URL fragments intact, but accept the inline comment form used by
    // npm's ini parser when a comment is separated by whitespace.
    const value = match[1].replace(/\s+[;#].*$/, "").trim();
    const registry = normalizeRegistryValue(value);
    if (registry) return registry;
  }
  return null;
}

function readNpmrcRegistry(configPath) {
  try {
    return npmrcRegistry(fs.readFileSync(configPath, "utf8"));
  } catch {
    return null;
  }
}

function npmRegistryFromConfigFiles() {
  // npm's precedence is project, user, then global. A project file nearest to
  // the launch cwd wins over broader project files, which also covers nested
  // workspaces without requiring npm to be installed on PATH.
  const projectPaths = [];
  let directory = process.cwd();
  while (true) {
    projectPaths.push(path.join(directory, ".npmrc"));
    const parent = path.dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  for (const configPath of projectPaths) {
    const registry = readNpmrcRegistry(configPath);
    if (registry) return registry;
  }

  const userConfig = npmConfigEnvironmentValue("userconfig");
  const userPaths = userConfig
    ? [userConfig]
    : [path.join(os.homedir(), ".npmrc")];
  for (const configPath of userPaths) {
    const registry = readNpmrcRegistry(configPath);
    if (registry) return registry;
  }

  const nodePrefix = path.dirname(path.dirname(process.execPath));
  const globalConfig = npmConfigEnvironmentValue("globalconfig");
  const globalPaths = globalConfig
    ? [globalConfig]
    : [path.join(nodePrefix, "etc", "npmrc")];
  if (process.platform !== "win32") globalPaths.push("/etc/npmrc");
  for (const configPath of globalPaths) {
    const registry = readNpmrcRegistry(configPath);
    if (registry) return registry;
  }
  return null;
}

function registryBase() {
  const explicit = normalizeRegistryValue(process.env.CMUX_NPM_REGISTRY);
  if (explicit) return explicit;
  const environment = normalizeRegistryValue(
    npmConfigEnvironmentValue("registry")
  );
  if (environment) return environment;
  return npmRegistryFromConfigFiles() || "https://registry.npmjs.org";
}

// Node's built-in fetch does not consume npm's proxy, CA, or client
// certificate settings. When one of those settings is present, delegate the
// registry operation to npm itself, which owns the supported config contract.
const NPM_NETWORK_CONFIG_KEYS = [
  "proxy",
  "https-proxy",
  "http-proxy",
  "noproxy",
  "cafile",
  "ca",
  "cert",
  "key",
  "certfile",
  "keyfile",
  "strict-ssl",
];
let npmNetworkConfigPresent;

function configValueIsPresent(value) {
  if (value === undefined || value === null) return false;
  const normalized = String(value).trim().toLowerCase();
  return normalized !== "" && normalized !== "null";
}

function npmConfigEnvironmentValue(key) {
  const normalized = key.replace(/-/g, "_");
  for (const name of [
    `npm_config_${normalized}`,
    `npm_config_${key}`,
    `NPM_CONFIG_${normalized}`,
    `NPM_CONFIG_${key}`,
  ]) {
    if (configValueIsPresent(process.env[name])) return process.env[name];
  }
  return undefined;
}

function npmEnvironmentHasScopedNetworkConfig() {
  return Object.entries(process.env).some(([name, value]) => {
    if (/^npm_config_ca\[\]$/i.test(name)) return configValueIsPresent(value);
    if (!/^npm_config_\/\/[^/]+\/:/i.test(name)) return false;
    const key = name.slice(name.lastIndexOf(":") + 1).toLowerCase();
    return (
      ["ca", "cafile", "cert", "certfile", "key", "keyfile"].includes(key) &&
      configValueIsPresent(value)
    );
  });
}

function npmConfigFilePaths() {
  const paths = new Set();
  const add = (candidate) => {
    if (candidate) paths.add(path.resolve(candidate));
  };
  add(npmConfigEnvironmentValue("userconfig"));
  add(npmConfigEnvironmentValue("globalconfig"));

  // npm reads a project .npmrc, then the user and global files. Walking to the
  // nearest root also covers launchers started from a nested project folder.
  let directory = process.cwd();
  while (true) {
    add(path.join(directory, ".npmrc"));
    const parent = path.dirname(directory);
    if (parent === directory) break;
    directory = parent;
  }
  add(path.join(os.homedir(), ".npmrc"));
  const nodePrefix = path.dirname(path.dirname(process.execPath));
  add(path.join(nodePrefix, "etc", "npmrc"));
  if (process.platform !== "win32") add("/etc/npmrc");
  return paths;
}

function npmrcContainsNetworkConfig(contents) {
  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#") || line.startsWith(";")) continue;
    // Scoped client certificate settings use
    // `//registry.example/:certfile=/path/to/cert.pem`.
    const scoped = /:(certfile|keyfile)\s*=/i.exec(line);
    if (scoped) {
      const value = line.slice(scoped.index + scoped[0].length);
      if (configValueIsPresent(value)) return true;
      continue;
    }
    const match = /^(?:@[^:]+:)?([a-z-]+)(\[\])?\s*=\s*(.*)$/i.exec(line);
    if (!match) continue;
    const key = match[1].toLowerCase();
    if (NPM_NETWORK_CONFIG_KEYS.includes(key) && configValueIsPresent(match[3])) {
      return true;
    }
    // `ca[]=` is npm's documented way to provide more than one CA value.
    if (key === "ca" && match[2] === "[]" && configValueIsPresent(match[3])) {
      return true;
    }
  }
  return false;
}

function registryIsLoopback() {
  try {
    const hostname = new URL(registryBase()).hostname.toLowerCase();
    return (
      hostname === "localhost" ||
      hostname === "127.0.0.1" ||
      hostname === "::1" ||
      hostname === "[::1]"
    );
  } catch {
    return false;
  }
}

function hasNpmNetworkConfig() {
  if (npmNetworkConfigPresent !== undefined) return npmNetworkConfigPresent;
  npmNetworkConfigPresent = NPM_NETWORK_CONFIG_KEYS.some((key) =>
    configValueIsPresent(npmConfigEnvironmentValue(key))
  );
  if (!npmNetworkConfigPresent) {
    npmNetworkConfigPresent = npmEnvironmentHasScopedNetworkConfig();
  }
  if (!npmNetworkConfigPresent) {
    for (const configPath of npmConfigFilePaths()) {
      let contents;
      try {
        contents = fs.readFileSync(configPath, "utf8");
      } catch {
        continue;
      }
      if (npmrcContainsNetworkConfig(contents)) {
        npmNetworkConfigPresent = true;
        break;
      }
    }
  }
  // npm's registry fetch honors the conventional proxy variables even when
  // they are not duplicated into an .npmrc file. Keep ambient CI proxy
  // variables from changing explicitly loopback fixture registries.
  if (!npmNetworkConfigPresent) {
    const proxyConfigured = [
      "HTTPS_PROXY",
      "https_proxy",
      "HTTP_PROXY",
      "http_proxy",
    ].some((name) => configValueIsPresent(process.env[name]));
    npmNetworkConfigPresent = proxyConfigured && !registryIsLoopback();
  }
  return npmNetworkConfigPresent;
}

function npmChildEnvironment() {
  const env = { ...process.env };
  // npm's config loader uses lower-case npm_config_* names on Unix. Preserve
  // the user's upper-case spelling while making its meaning explicit to the
  // delegated process.
  for (const key of ["userconfig", "globalconfig", ...NPM_NETWORK_CONFIG_KEYS]) {
    const value = npmConfigEnvironmentValue(key);
    if (value === undefined) continue;
    const normalized = key.replace(/-/g, "_");
    if (!configValueIsPresent(env[`npm_config_${normalized}`])) {
      env[`npm_config_${normalized}`] = value;
    }
  }
  for (const [name, value] of Object.entries(process.env)) {
    const match = /^NPM_CONFIG_(\/\/.*)$/i.exec(name);
    if (!match || !configValueIsPresent(value)) continue;
    const lowerName = `npm_config_${match[1]}`;
    if (!configValueIsPresent(env[lowerName])) env[lowerName] = value;
  }
  return env;
}

function npmInvocation() {
  const configured = process.env.npm_execpath;
  if (configured) {
    const candidate = path.isAbsolute(configured)
      ? configured
      : path.resolve(process.cwd(), configured);
    try {
      if (fs.statSync(candidate).isFile()) {
        if (/\.(?:c?m?js)$/i.test(candidate)) {
          return { command: process.execPath, prefix: [candidate] };
        }
        return { command: candidate, prefix: [] };
      }
    } catch {}
  }
  return {
    command: process.platform === "win32" ? "npm.cmd" : "npm",
    prefix: [],
  };
}

function runNpm(args) {
  const invocation = npmInvocation();
  const result = spawnSync(invocation.command, [...invocation.prefix, ...args], {
    cwd: process.cwd(),
    env: npmChildEnvironment(),
    encoding: "buffer",
    timeout: REGISTRY_TIMEOUT_MS,
    killSignal: "SIGTERM",
    maxBuffer: MAX_METADATA_BYTES,
    windowsHide: true,
  });
  if (result.error || result.status !== 0 || result.signal) {
    throw new Error("npm registry request failed");
  }
  const output = Buffer.isBuffer(result.stdout)
    ? result.stdout
    : Buffer.from(result.stdout || "");
  if (output.length > MAX_METADATA_BYTES) {
    throw new Error("npm registry response is too large");
  }
  return output;
}

function parseNpmJson(output) {
  try {
    return JSON.parse(output.toString("utf8").trim());
  } catch {
    throw new Error("npm registry response was invalid");
  }
}

function npmPackageSpec(packageName, selector) {
  const validSelector =
    validVersion(selector) || /^[a-z0-9][a-z0-9._-]*$/i.test(selector);
  if (!/^[a-z0-9][a-z0-9._-]*$/i.test(packageName) || !validSelector) {
    throw new Error("invalid npm package selector");
  }
  return `${packageName}@${selector}`;
}

function npmView(packageName, selector, field) {
  const spec = npmPackageSpec(packageName, selector);
  if (!/^[a-z][a-z0-9._-]*$/i.test(field)) {
    throw new Error("invalid npm metadata field");
  }
  return parseNpmJson(
    runNpm([
      "view",
      spec,
      field,
      "--json",
      "--registry",
      registryBase(),
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      "--prefer-online",
      "--loglevel=error",
    ])
  );
}

function npmPack(packageName, version) {
  const spec = npmPackageSpec(packageName, version);
  const destination = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-tui-npm-pack-"));
  try {
    const output = parseNpmJson(
      runNpm([
        "pack",
        spec,
        "--json",
        "--ignore-scripts",
        "--no-audit",
        "--no-fund",
        "--prefer-online",
        "--loglevel=error",
        "--pack-destination",
        destination,
        "--registry",
        registryBase(),
      ])
    );
    const record = Array.isArray(output) ? output[0] : output;
    const filename = record && record.filename;
    if (
      typeof filename !== "string" ||
      !filename ||
      filename === "." ||
      filename === ".." ||
      filename.includes("/") ||
      filename.includes("\\") ||
      !filename.endsWith(".tgz")
    ) {
      throw new Error("npm pack did not return a safe tarball name");
    }
    const tarball = path.join(destination, filename);
    const stat = fs.lstatSync(tarball);
    if (!stat.isFile() || stat.size > MAX_TARBALL_BYTES) {
      throw new Error("npm pack returned an invalid tarball");
    }
    return fs.readFileSync(tarball);
  } finally {
    try {
      fs.rmSync(destination, { recursive: true, force: true });
    } catch {}
  }
}

function registryHeaders(url, accept) {
  const headers = { accept };
  try {
    const parsed = new URL(url);
    const registry = new URL(registryBase());
    if (parsed.origin !== registry.origin) return headers;
    const tokenKey = `npm_config_//${parsed.host}/:_authToken`;
    const token = process.env[tokenKey] || npmrcAuthToken(parsed);
    if (token) headers.authorization = `Bearer ${token}`;
  } catch {}
  return headers;
}

function npmrcAuthToken(url) {
  const configPaths = new Set([
    process.env.npm_config_userconfig,
    process.env.npm_config_globalconfig,
    path.join(os.homedir(), ".npmrc"),
  ]);
  const host = url.host.toLowerCase();
  for (const configPath of configPaths) {
    if (!configPath) continue;
    let contents;
    try {
      contents = fs.readFileSync(configPath, "utf8");
    } catch {
      continue;
    }
    for (const line of contents.split(/\r?\n/)) {
      const match = /^\s*\/\/([^/]+)(\/[^:]*?)?\/:_authToken\s*=\s*(.*?)\s*$/.exec(line);
      if (!match || match[1].toLowerCase() !== host) continue;
      const scope = match[2] || "/";
      if (scope !== "/") {
        const prefix = scope.endsWith("/") ? scope : `${scope}/`;
        if (url.pathname !== scope && !url.pathname.startsWith(prefix)) continue;
      }
      const token = match[3].replace(/\$\{([^}]+)\}/g, (_, name) => process.env[name] || "");
      if (token) return token;
    }
  }
  return null;
}

function requireNetworkRuntime() {
  const nodeMajor = Number.parseInt(String(process.versions.node).split(".", 1)[0], 10);
  const hasFetch = typeof fetch === "function";
  const hasAbortTimeout =
    typeof AbortSignal === "function" && typeof AbortSignal.timeout === "function";
  if (nodeMajor < MIN_NODE_MAJOR || !hasFetch || !hasAbortTimeout) {
    fail(
      "network access requires Node.js 18 or newer with global fetch and " +
        "AbortSignal.timeout"
    );
  }
}

async function fetchJson(url, npmQuery = null) {
  requireNetworkRuntime();
  if (npmQuery && hasNpmNetworkConfig()) {
    return npmView(npmQuery.packageName, npmQuery.selector, npmQuery.field);
  }
  const response = await fetch(url, {
    headers: registryHeaders(url, "application/json"),
    signal: AbortSignal.timeout(REGISTRY_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error("registry request failed");
  }
  return JSON.parse(
    (await readResponseBody(response, MAX_METADATA_BYTES)).toString("utf8")
  );
}

async function readResponseBody(response, limit) {
  if (!response.body) throw new Error("registry response has no body");
  const reader = response.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > limit) {
        await reader.cancel();
        throw new Error("registry response is too large");
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  return Buffer.concat(chunks, total);
}

// Parse one pax extended header block into { path } overrides.
function parsePaxRecords(buffer) {
  const records = {};
  let offset = 0;
  while (offset < buffer.length) {
    const space = buffer.indexOf(0x20, offset);
    if (space === -1) break;
    const length = Number(buffer.toString("utf8", offset, space));
    if (!Number.isFinite(length) || length <= 0) break;
    const record = buffer.toString("utf8", space + 1, offset + length - 1);
    const eq = record.indexOf("=");
    if (eq !== -1) records[record.slice(0, eq)] = record.slice(eq + 1);
    offset += length;
  }
  return records;
}

// Minimal ustar/pax reader for npm registry tarballs: returns
// [{ name, data }] for regular files under package/bin/.
function extractBinEntries(tarBuffer) {
  const entries = [];
  let offset = 0;
  let paxPath = null;
  let gnuLongName = null;
  while (offset + 512 <= tarBuffer.length) {
    const header = tarBuffer.subarray(offset, offset + 512);
    if (header.every((b) => b === 0)) break;
    const rawName = header.toString("utf8", 0, 100).replace(/\0.*$/, "");
    const prefix = header.toString("utf8", 345, 500).replace(/\0.*$/, "");
    const sizeText = header
      .toString("utf8", 124, 136)
      .replace(/\0.*$/, "")
      .trim();
    if (sizeText && !/^[0-7]+$/.test(sizeText)) {
      throw new Error("invalid tar entry size");
    }
    const size = sizeText ? Number.parseInt(sizeText, 8) : 0;
    if (!Number.isSafeInteger(size) || size < 0) {
      throw new Error("invalid tar entry size");
    }
    const typeflag = String.fromCharCode(header[156]);
    const dataStart = offset + 512;
    if (size > tarBuffer.length - dataStart) {
      throw new Error("truncated tar entry");
    }
    const nextOffset = dataStart + Math.ceil(size / 512) * 512;
    if (nextOffset <= offset || nextOffset > tarBuffer.length) {
      throw new Error("invalid tar entry bounds");
    }
    const data = tarBuffer.subarray(dataStart, dataStart + size);
    offset = nextOffset;

    if (typeflag === "x" || typeflag === "g") {
      const records = parsePaxRecords(data);
      if (typeflag === "x" && records.path) paxPath = records.path;
      continue;
    }
    if (typeflag === "L") {
      gnuLongName = data.toString("utf8").replace(/\0.*$/, "");
      continue;
    }
    let name = paxPath || gnuLongName || (prefix ? `${prefix}/${rawName}` : rawName);
    paxPath = null;
    gnuLongName = null;
    if (typeflag !== "0" && typeflag !== "\0") continue;
    if (!name.startsWith("package/bin/")) continue;
    const base = name.slice("package/bin/".length);
    // Flat bin/ payload only; refuse anything that could escape the dir.
    if (!base || base.includes("/") || base.includes("\\") || base === "." || base === "..") {
      continue;
    }
    entries.push({ name: base, data: Buffer.from(data) });
  }
  return entries;
}

function verifyIntegrity(buffer, integrity) {
  const match = /^sha512-([A-Za-z0-9+/=]+)$/.exec(integrity || "");
  if (!match) {
    throw new Error(`registry did not provide a sha512 integrity value (got: ${integrity})`);
  }
  const actual = crypto.createHash("sha512").update(buffer).digest("base64");
  if (actual !== match[1]) {
    throw new Error("tarball integrity check failed (sha512 mismatch)");
  }
}

function writeCacheManifest(pkg, version, integrity, entries) {
  const target = cacheManifestPath(version);
  const tmp = `${target}.${process.pid}.tmp`;
  const binaries = {};
  for (const entry of entries) binaries[entry.name] = digestHex(entry.data);
  fs.writeFileSync(
    tmp,
    JSON.stringify({ package: pkg, version, tarballIntegrity: integrity, binaries }, null, 2) + "\n",
    { mode: 0o600 }
  );
  fs.renameSync(tmp, target);
}

function removeCachedPayload(version) {
  const versionDir = path.dirname(cachedBinDir(version));
  for (const name of ["bin", "manifest.json", "managed"]) {
    try {
      fs.rmSync(path.join(versionDir, name), { recursive: true, force: true });
    } catch {}
  }
}

// Download pkg@version from the registry, verify integrity, extract bin/
// into the launcher cache. Returns the binary path.
async function downloadVersion(pkg, version) {
  const meta = await fetchJson(`${registryBase()}/${pkg}/${version}`, {
    packageName: pkg,
    selector: version,
    field: "dist",
  });
  // `npm view ... dist --json` returns the dist object directly, while the
  // raw registry document wraps it under `dist`. Accept both shapes so the
  // npm-configured and direct transports share one validation path.
  const dist = meta && meta.dist ? meta.dist : meta;
  const tarballUrl = dist && dist.tarball;
  const integrity = dist && dist.integrity;
  if (!integrity || (!tarballUrl && !hasNpmNetworkConfig())) {
    throw new Error("registry metadata is incomplete");
  }
  console.error(`cmux: downloading ${pkg}@${version}...`);
  let tgz;
  if (hasNpmNetworkConfig()) {
    tgz = npmPack(pkg, version);
  } else {
    const response = await fetch(tarballUrl, {
      headers: registryHeaders(tarballUrl, "application/octet-stream"),
      signal: AbortSignal.timeout(REGISTRY_TIMEOUT_MS),
    });
    if (!response.ok) {
      throw new Error("platform package download failed");
    }
    tgz = await readResponseBody(response, MAX_TARBALL_BYTES);
  }
  verifyIntegrity(tgz, integrity);
  let tar;
  try {
    tar = zlib.gunzipSync(tgz, { maxOutputLength: MAX_TARBALL_BYTES });
  } catch {
    throw new Error("platform package is invalid or too large");
  }
  const entries = extractBinEntries(tar);
  if (!entries.some((entry) => entry.name === BIN_NAME)) {
    throw new Error("platform package does not contain the native binary");
  }

  const finalDir = cachedBinDir(version);
  const stagingDir = path.join(
    platformRoot(),
    "tmp",
    `${version}-${process.pid}-${Date.now().toString(36)}`
  );
  fs.mkdirSync(path.join(stagingDir, "bin"), { recursive: true });
  for (const entry of entries) {
    fs.writeFileSync(path.join(stagingDir, "bin", entry.name), entry.data, { mode: 0o755 });
  }
  fs.mkdirSync(path.dirname(finalDir), { recursive: true });
  try {
    fs.renameSync(path.join(stagingDir, "bin"), finalDir);
    writeCacheManifest(pkg, version, integrity, entries);
    fs.writeFileSync(path.join(path.dirname(finalDir), "managed"), "cmux\n");
  } catch (error) {
    // A concurrent launcher won the race; its extraction is byte-identical
    // only when the existing binary matches the entry we verified above.
    const expected = entries.find((entry) => entry.name === BIN_NAME);
    const existingPath = path.join(cachedBinDir(version), BIN_NAME);
    let existingIsFile = false;
    try {
      existingIsFile = fs.lstatSync(existingPath).isFile();
    } catch {}
    if (!existingIsFile || !expected) throw error;
    const existingDigest = crypto
      .createHash("sha512")
      .update(fs.readFileSync(existingPath))
      .digest();
    const expectedDigest = crypto.createHash("sha512").update(expected.data).digest();
    const matchesExpected =
      existingDigest.length === expectedDigest.length &&
      crypto.timingSafeEqual(existingDigest, expectedDigest);
    if (!matchesExpected) {
      try {
        removeCachedPayload(version);
        fs.renameSync(path.join(stagingDir, "bin"), finalDir);
        writeCacheManifest(pkg, version, integrity, entries);
        fs.writeFileSync(path.join(path.dirname(finalDir), "managed"), "cmux\n");
      } catch {
        throw new Error("cached platform binary failed integrity verification");
      }
    } else {
      try {
        writeCacheManifest(pkg, version, integrity, entries);
        fs.writeFileSync(path.join(path.dirname(finalDir), "managed"), "cmux\n");
      } catch {}
    }
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }
  const binPath = cachedBinary(version);
  if (!binPath) throw new Error(`extraction did not produce ${finalDir}/${BIN_NAME}`);
  return binPath;
}

function isManagedCacheVersion(versionRoot) {
  try {
    if (!fs.lstatSync(versionRoot).isDirectory()) return false;
    const marker = path.join(versionRoot, "managed");
    if (!fs.lstatSync(marker).isFile()) return false;
    return fs.readFileSync(marker, "utf8") === "cmux\n";
  } catch {
    return false;
  }
}

function stateVersionsByChannel() {
  const versions = new Map();
  const add = (state) => {
    const channel = stateVersionChannel(state);
    if (!channel) return;
    let channelVersions = versions.get(channel);
    if (!channelVersions) {
      channelVersions = new Set();
      versions.set(channel, channelVersions);
    }
    channelVersions.add(state.version);
  };
  add(readLegacyState());
  const stateRoot = path.join(platformRoot(), "state");
  let entries;
  try {
    entries = fs.readdirSync(stateRoot, { withFileTypes: true });
  } catch {
    return versions;
  }
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.endsWith(".json")) continue;
    try {
      add(readStateFile(path.join(stateRoot, entry.name)));
    } catch {}
  }
  return versions;
}

function pruneCache(keepVersion) {
  const lock = tryAcquireCacheLock();
  if (!lock) return false;
  const root = path.join(platformRoot(), "v");
  try {
    const managed = fs
      .readdirSync(root)
      .filter((version) => isManagedCacheVersion(path.join(root, version)))
      .sort(compareVersions);
    const keep = new Set([keepVersion]);
    // Every channel state file is a durable promise that its selected binary
    // remains available for an offline launch. Keep those versions even when
    // another channel is being updated.
    for (const channelVersions of stateVersionsByChannel().values()) {
      for (const version of channelVersions) keep.add(version);
    }
    // Retain one rollback predecessor per release channel. A global
    // predecessor is insufficient when stable and nightly caches coexist.
    const managedByChannel = new Map();
    for (const version of managed) {
      const channel = versionChannel(version);
      if (!channel) continue;
      let channelVersions = managedByChannel.get(channel);
      if (!channelVersions) {
        channelVersions = [];
        managedByChannel.set(channel, channelVersions);
      }
      channelVersions.push(version);
    }
    for (const channelVersions of managedByChannel.values()) {
      const predecessors = channelVersions
        .filter((version) => version !== keepVersion)
        .sort(compareVersions)
        .slice(-MAX_PREVIOUS_MANAGED_VERSIONS);
      for (const version of predecessors) keep.add(version);
    }
    for (const version of fs.readdirSync(root)) {
      if (keep.has(version)) continue;
      const versionRoot = path.join(root, version);
      // Direct-cache and development entries have no managed marker. Keep
      // them untouched so routine launches only prune launcher-owned data.
      if (!isManagedCacheVersion(versionRoot)) continue;
      if (versionHasActiveLease(versionRoot)) continue;
      try {
        fs.rmSync(versionRoot, { recursive: true, force: true });
      } catch {}
    }
    return true;
  } catch {
    // Cache cleanup is best effort and must never hide a successful update.
    return false;
  } finally {
    releaseCacheLock(lock);
  }
}

function wantedVersion(pkg) {
  const pinned = shimVersion();
  if (isManagedPlaceholder(pinned)) {
    const installed = installedPackage(pkg);
    const installedVersion =
      installed && validVersion(installed.version) ? installed.version : null;
    const channel = installedVersion ? versionChannel(installedVersion) : null;
    const state = channel ? readState(channel) : readUnambiguousManagedState();
    if (state && validVersion(state.version)) return state.version;
    if (installedVersion) return installedVersion;
    fail(
      "this launcher is an unpublished development copy without a pinned " +
        "binary. Set a development binary override or install a published release."
    );
  }
  if (!validVersion(pinned)) {
    fail("this launcher has an invalid release version");
  }
  const state = readState(versionChannel(pinned));
  if (
    state &&
    stateVersionChannel(state) === versionChannel(pinned) &&
    compareVersions(state.version, pinned) > 0
  ) {
    return state.version;
  }
  return pinned;
}

async function resolveBinary(pkg, wanted, cachedCandidate = null) {
  const override = process.env.CMUX_TUI_BIN;
  if (override) {
    if (!fs.existsSync(override)) fail("configured native binary override does not exist");
    return override;
  }
  if (wanted === undefined || wanted === null) wanted = wantedVersion(pkg);

  const installed = installedPackage(pkg);
  if (installed && installed.version === wanted) {
    return installed.binPath;
  }
  const cached = cachedBinary(wanted, cachedCandidate);
  if (cached) return cached;

  // Check the runtime before entering the generic download error boundary so
  // an unsupported Node version gets a useful, actionable message instead of
  // being flattened into a network failure.
  requireNetworkRuntime();
  try {
    return await downloadVersion(pkg, wanted);
  } catch {
    fail(
      "could not obtain the native binary. Check network access or install " +
        "the matching platform package directly."
    );
  }
}

async function latestVersionForChannel(version) {
  const channel = versionChannel(version);
  const distTag = latestDistTag(version);
  if (!channel || !distTag) {
    fail("could not determine the launcher release channel");
  }
  const latestMeta = await fetchJson(`${registryBase()}/cmux/${distTag}`, {
    packageName: "cmux",
    selector: distTag,
    field: "version",
  });
  const latest =
    typeof latestMeta === "string" ? latestMeta : latestMeta && latestMeta.version;
  if (!validVersion(latest) || versionChannel(latest) !== channel) {
    fail(`could not determine the latest published ${channel} release`);
  }
  return latest;
}

// `cmux update`: move the launcher to the latest published version without
// npm reifying anything, which is what makes upgrades immune to the npx
// cache ENOTEMPTY bug. The shim stays as-is; only the binary moves.
async function runUpdate(pkg, args) {
  const checkOnly = args.includes("--check");
  const unknown = args.filter((a) => a !== "--check");
  if (unknown.length) {
    fail("invalid update arguments. Usage: cmux update [--check]");
  }
  if (checkOnly) {
    const current = wantedVersion(pkg);
    const latest = await latestVersionForChannel(current);
    if (compareVersions(latest, current) <= 0) {
      console.log(`cmux ${current} is up to date (latest is ${latest}).`);
      return;
    }
    console.log(`cmux ${latest} is available (current: ${current}). Run: cmux update`);
    return;
  }

  // Keep one update-wide lock from the version check through download, state
  // publication, and pruning. This prevents two update processes from
  // completing out of order and pinning a channel state file to an older
  // version.
  const updateLockPath = updateOperationLockPath();
  const updateLock = tryAcquireCacheLock(updateLockPath);
  if (!updateLock) fail("could not reserve the native binary for update");
  let lease = null;
  try {
    // Re-read the state after acquiring the lock. Another updater may have
    // completed before this process obtained it.
    const current = wantedVersion(pkg);
    const channel = versionChannel(current);
    const latest = await latestVersionForChannel(current);
    if (compareVersions(latest, current) <= 0) {
      console.log(`cmux ${current} is up to date (latest is ${latest}).`);
      return;
    }
    lease = await acquireVersionLeaseForProcess(latest);
    if (!lease) fail("could not reserve the native binary for update");
    await downloadVersion(pkg, latest);
    writeState({
      version: latest,
      channel,
      updatedAt: new Date().toISOString(),
    });
    pruneCache(latest);
    console.log(`cmux updated: ${current} -> ${latest}. The new version runs on the next start.`);
  } finally {
    releaseVersionLease(lease);
    releaseCacheLock(updateLock, updateLockPath);
  }
}

async function main() {
  const args = process.argv.slice(2);
  const override = process.env.CMUX_TUI_BIN;

  // Owned by the shim, not the Rust CLI: `update` must work even when no
  // binary is present, and must never go through npm. spec/cli.md has no
  // top-level `update` verb, so nothing is shadowed.
  if (args[0] === "update") {
    const pkg = platformPackage();
    try {
      cleanupStaging();
      await runUpdate(pkg, args.slice(1));
    } catch (error) {
      fail(`update failed: ${error.message}`);
    }
    return;
  }

  // An explicit development binary is independent of the published platform
  // matrix. Resolve it before checking process.platform so unsupported hosts
  // can still run with CMUX_TUI_BIN.
  const pkg = override ? null : platformPackage();
  let lease = null;
  let launchSnapshot = null;
  let exitCode = 1;
  let childSignal = null;
  try {
    cleanupStaging();
    const wanted = override ? null : wantedVersion(pkg);
    // A matching installed package is independent of the launcher cache. Do
    // not require a writable cache or create a lease when it can run directly.
    const installed = wanted ? installedPackage(pkg) : null;
    const installedBin = installed && installed.version === wanted ? installed.binPath : null;
    // Resolve a verified cache hit before trying to create a lease. A
    // read-only, pre-populated cache cannot publish `.active` or `.update.lock`;
    // it is safe to launch that verified binary when pruning is skipped.
    const cachedCandidate =
      wanted && !installedBin ? cachedBinaryCandidate(wanted) : null;
    const readOnlyCached = Boolean(
      cachedCandidate && cacheVersionIsReadOnly(wanted)
    );
    // Lease creation serializes with pruning. If another process owns the
    // lock, fail closed rather than launching an unleased binary that a prune
    // can remove while it is running.
    lease =
      wanted && !installedBin && !readOnlyCached
        ? await acquireVersionLeaseForProcess(wanted)
        : null;
    if (wanted && !installedBin && !readOnlyCached && !lease) {
      fail("could not reserve the native binary for launch");
    }
    if (lease) process.once("exit", () => releaseVersionLease(lease));
    let binPath = installedBin;
    if (!binPath && readOnlyCached) {
      // Revalidate and copy the read-only path after all setup. The private
      // snapshot prevents a later replacement from changing the executable
      // between verification and spawn.
      launchSnapshot = snapshotVerifiedCachedBinary(cachedCandidate);
      if (!launchSnapshot) fail("the cached native binary changed before launch");
      binPath = launchSnapshot.path;
    } else if (!binPath) {
      binPath = await resolveBinary(pkg, wanted, cachedCandidate);
    }
    if (lease) pruneCache(wanted);
    const result = spawnSync(binPath, args, { stdio: "inherit" });
    if (result.error) {
      fail("failed to launch the native binary");
    }
    if (result.signal) {
      childSignal = result.signal;
    } else {
      exitCode = result.status === null ? 1 : result.status;
    }
  } finally {
    releaseVersionLease(lease);
    removeLaunchSnapshot(launchSnapshot);
  }
  if (childSignal) {
    process.exitCode = 1;
    try {
      process.kill(process.pid, childSignal);
    } catch {
      // Keep the non-zero fallback when the signal cannot be delivered.
    }
    return;
  }
  process.exitCode = exitCode;
}

main().catch((error) => {
  const message =
    error instanceof LauncherError
      ? error.message
      : "launcher failed before starting the native binary";
  console.error(`cmux: ${message}`);
  process.exitCode = 1;
});
