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
// `cmux update`), compared by semver so a nightly shim is not downgraded by
// an older stable `update` record.

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

function fail(message) {
  console.error(`cmux: ${message}`);
  process.exit(1);
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

function statePath() {
  return path.join(platformRoot(), "state.json");
}

function platformRoot() {
  return path.join(cacheRoot(), `${process.platform}-${process.arch}`);
}

function readState() {
  try {
    const state = JSON.parse(fs.readFileSync(statePath(), "utf8"));
    if (state && typeof state.version === "string") return state;
  } catch {}
  return null;
}

function writeState(state) {
  const target = statePath();
  fs.mkdirSync(path.dirname(target), { recursive: true });
  const tmp = `${target}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2) + "\n");
  fs.renameSync(tmp, target);
}

function cachedBinDir(version) {
  return path.join(platformRoot(), "v", version, "bin");
}

function cachedBinary(version) {
  const bin = path.join(cachedBinDir(version), BIN_NAME);
  return fs.existsSync(bin) ? bin : null;
}

function cacheLockPath() {
  return path.join(platformRoot(), ".update.lock");
}

function tryAcquireCacheLock() {
  try {
    fs.mkdirSync(cacheLockPath(), { recursive: false });
    fs.writeFileSync(path.join(cacheLockPath(), "pid"), `${process.pid}\n`);
    return true;
  } catch {
    try {
      if (!fs.existsSync(path.join(cacheLockPath(), "pid"))) {
        fs.rmSync(cacheLockPath(), { recursive: true, force: true });
      }
    } catch {}
    try {
      const pid = Number.parseInt(
        fs.readFileSync(path.join(cacheLockPath(), "pid"), "utf8"),
        10
      );
      process.kill(pid, 0);
      return false;
    } catch (error) {
      if (!error || error.code !== "ESRCH") return false;
      try {
        fs.rmSync(cacheLockPath(), { recursive: true, force: true });
        fs.mkdirSync(cacheLockPath(), { recursive: false });
        fs.writeFileSync(path.join(cacheLockPath(), "pid"), `${process.pid}\n`);
        return true;
      } catch {
        return false;
      }
    }
  }
}

function releaseCacheLock() {
  try {
    fs.rmSync(cacheLockPath(), { recursive: true, force: true });
  } catch {}
}

function acquireVersionLease(version) {
  const leaseRoot = path.join(platformRoot(), "v", version, ".active");
  const lease = path.join(
    leaseRoot,
    `${process.pid}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2)}`
  );
  try {
    fs.mkdirSync(leaseRoot, { recursive: true });
    fs.mkdirSync(lease, { recursive: false });
    fs.writeFileSync(path.join(lease, "pid"), `${process.pid}\n`);
    return lease;
  } catch {
    return null;
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

function leaseIsActive(lease) {
  try {
    const pid = Number.parseInt(fs.readFileSync(path.join(lease, "pid"), "utf8"), 10);
    if (!Number.isInteger(pid) || pid <= 0) return true;
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return error && error.code !== "ESRCH";
  }
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
        if (leaseIsActive(lease)) {
          active = true;
        } else {
          fs.rmSync(lease, { recursive: true, force: true });
        }
      } else if (entry.name === "pid") {
        // Read leases written by older launchers, before leases became
        // per-process directories.
        active = leaseIsActive(leaseRoot);
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

function registryBase() {
  const raw =
    process.env.CMUX_NPM_REGISTRY ||
    process.env.npm_config_registry ||
    "https://registry.npmjs.org";
  return raw.replace(/\/+$/, "");
}

function registryHeaders(url, accept) {
  const headers = { accept };
  try {
    const parsed = new URL(url);
    const registry = new URL(registryBase());
    if (parsed.origin !== registry.origin) return headers;
    const tokenKey = `npm_config_//${parsed.host}/:_authToken`;
    const token = process.env[tokenKey];
    if (token) headers.authorization = `Bearer ${token}`;
  } catch {}
  return headers;
}

async function fetchJson(url) {
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
    const size = parseInt(header.toString("utf8", 124, 136).replace(/\0.*$/, "").trim(), 8) || 0;
    const typeflag = String.fromCharCode(header[156]);
    const dataStart = offset + 512;
    const data = tarBuffer.subarray(dataStart, dataStart + size);
    offset = dataStart + Math.ceil(size / 512) * 512;

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

// Download pkg@version from the registry, verify integrity, extract bin/
// into the launcher cache. Returns the binary path.
async function downloadVersion(pkg, version) {
  const meta = await fetchJson(`${registryBase()}/${pkg}/${version}`);
  const tarballUrl = meta && meta.dist && meta.dist.tarball;
  const integrity = meta && meta.dist && meta.dist.integrity;
  if (!tarballUrl) {
    throw new Error("registry metadata is incomplete");
  }
  console.error(`cmux: downloading ${pkg}@${version}...`);
  const response = await fetch(tarballUrl, {
    headers: registryHeaders(tarballUrl, "application/octet-stream"),
    signal: AbortSignal.timeout(REGISTRY_TIMEOUT_MS),
  });
  if (!response.ok) {
    throw new Error("platform package download failed");
  }
  const tgz = await readResponseBody(response, MAX_TARBALL_BYTES);
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
    fs.writeFileSync(path.join(path.dirname(finalDir), "managed"), "cmux\n");
  } catch (error) {
    // A concurrent launcher won the race; its extraction is byte-identical
    // because both verified the same registry integrity.
    if (!cachedBinary(version)) throw error;
    try {
      fs.writeFileSync(path.join(path.dirname(finalDir), "managed"), "cmux\n");
    } catch {}
  } finally {
    fs.rmSync(stagingDir, { recursive: true, force: true });
  }
  const binPath = cachedBinary(version);
  if (!binPath) throw new Error(`extraction did not produce ${finalDir}/${BIN_NAME}`);
  return binPath;
}

function pruneCache(keepVersion) {
  if (!tryAcquireCacheLock()) return;
  const root = path.join(platformRoot(), "v");
  try {
    const managed = fs
      .readdirSync(root)
      .filter((version) => fs.existsSync(path.join(root, version, "managed")))
      .sort(compareVersions);
    const keep = new Set([keepVersion, ...managed.slice(-2)]);
    for (const version of fs.readdirSync(root)) {
      if (keep.has(version)) continue;
      if (versionHasActiveLease(path.join(root, version))) continue;
      try {
        fs.rmSync(path.join(root, version), { recursive: true, force: true });
      } catch {}
    }
  } catch {
    // Cache cleanup is best effort and must never hide a successful update.
  } finally {
    releaseCacheLock();
  }
}

function wantedVersion(pkg) {
  const pinned = shimVersion();
  const state = readState();
  if (isManagedPlaceholder(pinned)) {
    if (state && validVersion(state.version)) return state.version;
    const installed = installedPackage(pkg);
    if (installed && validVersion(installed.version)) return installed.version;
    fail(
      "this launcher is an unpublished development copy without a pinned " +
        "binary. Set a development binary override or install a published release."
    );
  }
  if (!validVersion(pinned)) {
    fail("this launcher has an invalid release version");
  }
  if (state && compareVersions(state.version, pinned) > 0) {
    return validVersion(state.version) ? state.version : pinned;
  }
  return pinned;
}

async function resolveBinary(pkg, wanted = wantedVersion(pkg)) {
  const override = process.env.CMUX_TUI_BIN;
  if (override) {
    if (!fs.existsSync(override)) fail(`CMUX_TUI_BIN does not exist: ${override}`);
    return override;
  }

  const installed = installedPackage(pkg);
  if (installed && installed.version === wanted) {
    return installed.binPath;
  }
  const cached = cachedBinary(wanted);
  if (cached) return cached;

  try {
    return await downloadVersion(pkg, wanted);
  } catch {
    fail(
      "could not obtain the native binary. Check network access or install " +
        "the matching platform package directly."
    );
  }
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
  const current = wantedVersion(pkg);
  const latestMeta = await fetchJson(`${registryBase()}/cmux/latest`);
  const latest = latestMeta && latestMeta.version;
  if (!validVersion(latest)) fail("could not determine the latest published release");
  if (compareVersions(latest, current) <= 0) {
    console.log(`cmux ${current} is up to date (latest is ${latest}).`);
    return;
  }
  if (checkOnly) {
    console.log(`cmux ${latest} is available (current: ${current}). Run: cmux update`);
    return;
  }
  await downloadVersion(pkg, latest);
  writeState({
    version: latest,
    updatedAt: new Date().toISOString(),
  });
  pruneCache(latest);
  console.log(`cmux updated: ${current} -> ${latest}. The new version runs on the next start.`);
}

async function main() {
  const pkg = platformPackage();
  const args = process.argv.slice(2);

  // Owned by the shim, not the Rust CLI: `update` must work even when no
  // binary is present, and must never go through npm. spec/cli.md has no
  // top-level `update` verb, so nothing is shadowed.
  if (args[0] === "update") {
    try {
      await runUpdate(pkg, args.slice(1));
    } catch (error) {
      fail(`update failed: ${error.message}`);
    }
    return;
  }

  let lease = null;
  let exitCode = 1;
  try {
    const wanted = wantedVersion(pkg);
    // Hold a per-process lease independently of the update lock. An update
    // may already own that lock while pruning another version, and the
    // binary must remain present through resolution and spawn.
    lease = acquireVersionLease(wanted);
    if (lease) process.once("exit", () => releaseVersionLease(lease));
    const binPath = await resolveBinary(pkg, wanted);
    const result = spawnSync(binPath, args, { stdio: "inherit" });
    if (result.error) {
      fail("failed to launch the native binary");
    }
    if (result.signal) {
      process.kill(process.pid, result.signal);
      return;
    }
    exitCode = result.status === null ? 1 : result.status;
  } finally {
    releaseVersionLease(lease);
  }
  process.exit(exitCode);
}

main().catch(() => fail("launcher failed before starting the native binary"));
