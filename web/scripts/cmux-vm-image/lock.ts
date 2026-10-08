/**
 * The cmux VM image input lock (images/cmux-vm/inputs.lock.json) and the pure
 * helpers the bake, smoke and reproducibility scripts share
 * (plans/cmux-next/vm-image.md sections 4.1, 4.5 and 4.10).
 *
 * The bake reads only the lock. Every input is exact: the provider base by
 * fingerprint (kernel release + sha256 of the sorted dpkg list), every apt
 * package by exact version from a dated snapshot mirror, and every program by
 * URL, sha256 and size. A range, a missing digest or an unknown program is a
 * validation error, so a lock that would let the bake float never parses.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createHash } from "node:crypto";

export const LOCK_SCHEMA = 1;

/** Every program the image carries in its store. A program outside this list is refused. */
export const KNOWN_PROGRAMS = [
  "cmux-tui",
  "cmux-tui-hook",
  "coderouter",
  "claude",
  "codex",
  "opencode",
  "pi",
  "workerd",
  "gh",
  "juicefs",
] as const;
/**
 * Programs the lock may carry but does not require yet: their release does not
 * exist, so they are pinned only once it does (cloud-automation.md section 2.2).
 */
export const OPTIONAL_PROGRAMS = ["cmux-cua", "chrome-for-testing", "cmux-browser-host"] as const;
export type ProgramName = (typeof KNOWN_PROGRAMS)[number] | (typeof OPTIONAL_PROGRAMS)[number];

/** Role names a program or a lock role may use (vm-image.md 4.3, cloud-automation.md 2.1). */
export const KNOWN_ROLES = [
  "interactive",
  "automation",
  "team",
  "desktop",
  "browser",
  "remote-browser",
  "cua",
  "display",
  "display-wm",
  "cua-video",
  "fonts",
  "ssh",
] as const;
export type RoleName = (typeof KNOWN_ROLES)[number];

/**
 * A role in the lock: `default` says whether `cmux host` starts it without a
 * request; `firstUse` packages are not baked and are installed from the dated
 * snapshot the first time the role starts.
 */
export type LockedRole = {
  readonly default: "on" | "off";
  readonly firstUse?: boolean;
  /** Top-level apt package names; each is in apt.ubuntu.packages, or in apt.ubuntu.firstUse.<role> for a first-use role. */
  readonly apt: readonly string[];
  /** Environment for the role's processes (roles.json); never a sandbox-off switch. */
  readonly env?: Readonly<Record<string, string>>;
};

export const PROGRAM_FORMATS = ["raw", "tar.gz", "npm", "zip"] as const;
export type ProgramFormat = (typeof PROGRAM_FORMATS)[number];

export type Artifact = {
  readonly version: string;
  readonly url: string;
  readonly sha256: string;
  readonly size: number;
};

export type LockedProgram = Artifact & {
  readonly name: ProgramName;
  readonly format: ProgramFormat;
  /** Raw downloads only: the file name inside the store entry. */
  readonly fileName?: string;
  /** Command name -> path inside the store entry. */
  readonly bin: Readonly<Record<string, string>>;
  /** Arguments that print the version; empty means "only check it is executable". */
  readonly versionArgs: readonly string[];
  /** Substring the version output must contain. */
  readonly expect?: string;
  readonly checksumsUrl?: string;
  readonly checksumsName?: string;
  readonly source?: string;
  readonly roles?: readonly RoleName[];
  /** Installed into the store the first time one of its (first-use) roles starts; never baked. */
  readonly firstUse?: boolean;
  /** License and notice files (relative to the store entry) the install must find. */
  readonly notices?: readonly string[];
  /** The same release for the other architectures (the image itself is x86_64). */
  readonly otherArches?: Readonly<Partial<Record<OtherArch, ArchArtifact>>>;
};

export const OTHER_ARCHES = ["aarch64"] as const;
export type OtherArch = (typeof OTHER_ARCHES)[number];
export type ArchArtifact = { readonly url: string; readonly sha256: string; readonly size: number; readonly checksumsName?: string };

export type AptRepo = {
  readonly uri: string;
  readonly components: readonly string[];
  readonly packages: Readonly<Record<string, string>>;
};

export type InputsLock = {
  readonly schema: number;
  readonly image: string;
  readonly base: {
    readonly snapshot: string;
    readonly fingerprint: {
      readonly kernelRelease: string;
      readonly dpkgListSha256: string;
      readonly dpkgPackageCount: number;
      readonly recordedAt: string;
    };
    readonly runtimes: Readonly<Record<string, string>>;
    readonly basePackages: Readonly<Record<string, string>>;
    readonly npmGlobals: { readonly keep: Readonly<Record<string, string>>; readonly strip: readonly string[] };
  };
  readonly apt: {
    readonly ubuntu: AptRepo & {
      readonly snapshot: string;
      readonly suites: readonly string[];
      readonly signedBy: string;
      /** Role -> exact closure installed on first use (relative to the baked set); never baked. */
      readonly firstUse: Readonly<Record<string, Readonly<Record<string, string>>>>;
    };
    readonly pgdg: AptRepo & { readonly suite: string; readonly keyUrl: string; readonly keySha256: string; readonly keyFingerprint: string };
  };
  readonly programs: readonly LockedProgram[];
  readonly roles: Readonly<Record<string, LockedRole>>;
  readonly tools: { readonly syft: Artifact };
};

export const STORE_ROOT = "/opt/cmux";
export const STORE_DIR = `${STORE_ROOT}/store`;
export const PROFILES_DIR = `${STORE_ROOT}/profiles`;
export const CURRENT_LINK = `${STORE_ROOT}/current`;
export const CURRENT_BIN = `${CURRENT_LINK}/bin`;
/** The generation the bake creates; the updater (cmux host update) adds later ones. */
export const BAKED_GENERATION = 1;

export const DEFAULT_LOCK_PATH = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../../../images/cmux-vm/inputs.lock.json");

export class LockError extends Error {
  constructor(readonly problems: readonly string[]) {
    super(`inputs.lock.json is invalid:\n- ${problems.join("\n- ")}`);
  }
}

const SHA256 = /^[0-9a-f]{64}$/;
const COMMIT = /^[0-9a-f]{40}$/;
const EXACT_SEMVER = /^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/;
/** Chrome's four-part version (major.minor.build.patch), as Chrome for Testing names its releases. */
const CHROME_VERSION = /^\d+\.\d+\.\d+\.\d+$/;
/** Debian version: optional epoch, upstream starting with a digit, no operators or spaces. */
const DEBIAN_VERSION = /^(?:\d+:)?\d[A-Za-z0-9.+~-]*$/;
const PACKAGE_NAME = /^[a-z0-9][a-z0-9.+-]+$/;
const NPM_NAME = /^(?:@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*$/;
const APT_SNAPSHOT = /^\d{8}T\d{6}Z$/;
const RELATIVE_PATH = /^(?!\/)(?!.*(?:^|\/)\.\.(?:\/|$))[A-Za-z0-9._+\/-]+$/;
const COMMAND_NAME = /^[a-z0-9][a-z0-9._-]*$/;

type Rec = Record<string, unknown>;
const isRec = (value: unknown): value is Rec => typeof value === "object" && value !== null && !Array.isArray(value);
const str = (value: unknown): string | null => (typeof value === "string" && value.trim() !== "" ? value : null);

/** True for an exact program version: semver x.y.z (optionally -pre/+build), a date-style x.y.z, or a 40-hex commit. */
export function isExactProgramVersion(version: string): boolean {
  return EXACT_SEMVER.test(version) || CHROME_VERSION.test(version) || COMMIT.test(version);
}

/** True for an exact Debian version string (no `>=`, `*`, spaces, or `latest`). */
export function isExactDebianVersion(version: string): boolean {
  return DEBIAN_VERSION.test(version);
}

function checkArtifact(where: string, raw: unknown, problems: string[]): void {
  if (!isRec(raw)) {
    problems.push(`${where}: not an object`);
    return;
  }
  const version = str(raw.version);
  if (!version) problems.push(`${where}.version: missing`);
  else if (!isExactProgramVersion(version)) problems.push(`${where}.version: ${JSON.stringify(version)} is not an exact version (ranges, tags and "latest" are refused)`);
  const url = str(raw.url);
  if (!url || !url.startsWith("https://")) problems.push(`${where}.url: must be an https:// URL`);
  else if (/\/latest\//.test(url)) problems.push(`${where}.url: a "latest" URL floats; pin a versioned URL`);
  const sha = raw.sha256;
  if (typeof sha !== "string" || !SHA256.test(sha)) problems.push(`${where}.sha256: missing or not 64 lowercase hex`);
  const size = raw.size;
  if (typeof size !== "number" || !Number.isInteger(size) || size <= 0) problems.push(`${where}.size: missing or not a positive integer`);
}

function checkProgram(index: number, raw: unknown, seen: Set<string>, problems: string[]): void {
  const where = `programs[${index}]`;
  checkArtifact(where, raw, problems);
  if (!isRec(raw)) return;
  const name = str(raw.name);
  if (!name) {
    problems.push(`${where}.name: missing`);
  } else if (![...KNOWN_PROGRAMS, ...OPTIONAL_PROGRAMS].includes(name as ProgramName)) {
    problems.push(`${where}.name: unknown program ${JSON.stringify(name)} (known: ${[...KNOWN_PROGRAMS, ...OPTIONAL_PROGRAMS].join(", ")})`);
  } else if (seen.has(name)) {
    problems.push(`${where}.name: duplicate ${name}`);
  } else {
    seen.add(name);
  }
  const format = raw.format;
  if (!(PROGRAM_FORMATS as readonly unknown[]).includes(format)) problems.push(`${where}.format: must be one of ${PROGRAM_FORMATS.join(", ")}`);
  if (format === "raw") {
    const fileName = str(raw.fileName);
    if (!fileName || !COMMAND_NAME.test(fileName)) problems.push(`${where}.fileName: a raw download needs a plain file name`);
  }
  if (!isRec(raw.bin) || Object.keys(raw.bin).length === 0) {
    problems.push(`${where}.bin: needs at least one command`);
  } else {
    for (const [command, target] of Object.entries(raw.bin)) {
      if (!COMMAND_NAME.test(command)) problems.push(`${where}.bin: bad command name ${JSON.stringify(command)}`);
      if (typeof target !== "string" || !RELATIVE_PATH.test(target)) problems.push(`${where}.bin.${command}: must be a relative path inside the store entry`);
    }
  }
  if (!Array.isArray(raw.versionArgs) || raw.versionArgs.some((arg) => typeof arg !== "string")) problems.push(`${where}.versionArgs: must be an array of strings`);
  if (raw.expect !== undefined && !str(raw.expect)) problems.push(`${where}.expect: must be a non-empty string when present`);
  if (raw.checksumsUrl !== undefined && (!str(raw.checksumsUrl)?.startsWith("https://") || !str(raw.checksumsName))) {
    problems.push(`${where}.checksumsUrl: needs an https URL and checksumsName`);
  }
  checkProgramRoles(where, raw.roles, problems);
  if (raw.firstUse !== undefined && typeof raw.firstUse !== "boolean") problems.push(`${where}.firstUse: must be a boolean`);
  checkNotices(where, raw.notices, problems);
  checkOtherArches(where, raw.otherArches, problems);
  if (name === "chrome-for-testing" && typeof raw.version === "string") {
    const expected = chromeForTestingShape(raw.version).url;
    if (raw.url !== expected) problems.push(`${where}.url: must be ${expected}`);
  }
}

function checkNotices(where: string, raw: unknown, problems: string[]): void {
  if (raw === undefined) return;
  if (!Array.isArray(raw) || raw.length === 0) {
    problems.push(`${where}.notices: must be a non-empty array of paths`);
    return;
  }
  for (const notice of raw) if (typeof notice !== "string" || !RELATIVE_PATH.test(notice)) problems.push(`${where}.notices: ${JSON.stringify(notice)} must be a relative path inside the store entry`);
}

function checkOtherArches(where: string, raw: unknown, problems: string[]): void {
  if (raw === undefined) return;
  if (!isRec(raw)) {
    problems.push(`${where}.otherArches: must be an object`);
    return;
  }
  for (const [arch, artifact] of Object.entries(raw)) {
    const at = `${where}.otherArches.${arch}`;
    if (!(OTHER_ARCHES as readonly string[]).includes(arch)) {
      problems.push(`${at}: unknown arch`);
      continue;
    }
    if (!isRec(artifact)) {
      problems.push(`${at}: must be an object`);
      continue;
    }
    if (typeof artifact.url !== "string" || !artifact.url.startsWith("https://")) problems.push(`${at}.url: must be an https:// URL`);
    if (typeof artifact.sha256 !== "string" || !SHA256.test(artifact.sha256)) problems.push(`${at}.sha256: missing or not 64 lowercase hex`);
    if (typeof artifact.size !== "number" || !Number.isInteger(artifact.size) || artifact.size <= 0) problems.push(`${at}.size: missing or not a positive integer`);
  }
}

/** A first-use program needs at least one role, and every role it names is a first-use role. */
function checkFirstUsePrograms(programs: unknown, roles: unknown, problems: string[]): void {
  if (!Array.isArray(programs)) return;
  programs.forEach((raw, index) => {
    if (!isRec(raw) || raw.firstUse !== true) return;
    const where = `programs[${index}].firstUse`;
    const named = Array.isArray(raw.roles) ? raw.roles : [];
    if (named.length === 0) problems.push(`${where}: needs at least one role`);
    for (const role of named) {
      const locked = isRec(roles) ? roles[role as string] : undefined;
      if (!isRec(locked) || locked.firstUse !== true) problems.push(`${where}: role ${String(role)} is not a first-use role`);
    }
  });
}

const ENV_NAME = /^[A-Z_][A-Z0-9_]*$/;
const SANDBOX_OFF = ["--no-sandbox", "--disable-setuid-sandbox"] as const;

/** Role env: plain variable names and string values; the sandbox stays on; the browser role throttles background tabs. */
function checkRoleEnv(name: string, raw: unknown, problems: string[]): void {
  const where = `roles.${name}.env`;
  if (raw !== undefined && !isRec(raw)) {
    problems.push(`${where}: must be an object of strings`);
    return;
  }
  const env = (raw ?? {}) as Rec;
  for (const [key, value] of Object.entries(env)) {
    if (!ENV_NAME.test(key)) problems.push(`${where}: bad variable name ${JSON.stringify(key)}`);
    if (typeof value !== "string") {
      problems.push(`${where}.${key}: must be a string`);
      continue;
    }
    for (const flag of SANDBOX_OFF) if (value.includes(flag)) problems.push(`${where}.${key}: ${flag} is refused (the sandbox stays on)`);
  }
  if (name === "browser" && env.CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE !== "0") {
    problems.push(`${where}.CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE: must be "0" (background tabs are throttled, RT8 idle budget)`);
  }
}

function checkProgramRoles(where: string, roles: unknown, problems: string[]): void {
  if (roles === undefined) return;
  if (!Array.isArray(roles)) {
    problems.push(`${where}.roles: must be an array of role names`);
    return;
  }
  for (const role of roles) {
    if (!(KNOWN_ROLES as readonly unknown[]).includes(role)) problems.push(`${where}.roles: unknown role ${JSON.stringify(role)}`);
  }
}

function checkDebianPackages(where: string, raw: unknown, problems: string[]): void {
  if (!isRec(raw) || Object.keys(raw).length === 0) {
    problems.push(`${where}: needs at least one package`);
    return;
  }
  for (const [name, version] of Object.entries(raw)) {
    if (!PACKAGE_NAME.test(name)) problems.push(`${where}: bad package name ${JSON.stringify(name)}`);
    if (typeof version !== "string" || !isExactDebianVersion(version)) {
      problems.push(`${where}.${name}: ${JSON.stringify(version)} is not an exact version`);
    }
  }
}

function checkBase(raw: unknown, problems: string[]): void {
  if (!isRec(raw)) {
    problems.push("base: missing");
    return;
  }
  if (!str(raw.snapshot)) problems.push("base.snapshot: missing");
  const fp = raw.fingerprint;
  if (!isRec(fp)) {
    problems.push("base.fingerprint: missing");
  } else {
    if (!str(fp.kernelRelease)) problems.push("base.fingerprint.kernelRelease: missing");
    if (typeof fp.dpkgListSha256 !== "string" || !SHA256.test(fp.dpkgListSha256)) problems.push("base.fingerprint.dpkgListSha256: missing or not 64 lowercase hex");
    if (typeof fp.dpkgPackageCount !== "number" || fp.dpkgPackageCount <= 0) problems.push("base.fingerprint.dpkgPackageCount: missing");
  }
  if (!isRec(raw.runtimes)) problems.push("base.runtimes: missing");
  checkDebianPackages("base.basePackages", raw.basePackages, problems);
  const npm = raw.npmGlobals;
  if (!isRec(npm) || !isRec(npm.keep) || !Array.isArray(npm.strip)) {
    problems.push("base.npmGlobals: needs keep (name -> exact version) and strip (names)");
    return;
  }
  for (const [name, version] of Object.entries(npm.keep)) {
    if (!NPM_NAME.test(name)) problems.push(`base.npmGlobals.keep: bad name ${JSON.stringify(name)}`);
    if (typeof version !== "string" || !EXACT_SEMVER.test(version)) problems.push(`base.npmGlobals.keep.${name}: not an exact version`);
  }
  for (const name of npm.strip) {
    if (typeof name !== "string" || !NPM_NAME.test(name)) problems.push(`base.npmGlobals.strip: bad name ${JSON.stringify(name)}`);
  }
}

function checkApt(raw: unknown, problems: string[]): void {
  if (!isRec(raw) || !isRec(raw.ubuntu) || !isRec(raw.pgdg)) {
    problems.push("apt: needs ubuntu and pgdg");
    return;
  }
  const ubuntu = raw.ubuntu;
  const snapshot = str(ubuntu.snapshot);
  if (!snapshot || !APT_SNAPSHOT.test(snapshot)) problems.push("apt.ubuntu.snapshot: must be a snapshot timestamp like 20261001T000000Z");
  const uri = str(ubuntu.uri);
  if (!uri || !snapshot || !uri.startsWith("https://snapshot.ubuntu.com/") || !uri.includes(`/${snapshot}/`)) {
    problems.push("apt.ubuntu.uri: must be the snapshot.ubuntu.com URL of apt.ubuntu.snapshot");
  }
  if (!Array.isArray(ubuntu.suites) || ubuntu.suites.length === 0) problems.push("apt.ubuntu.suites: missing");
  checkDebianPackages("apt.ubuntu.packages", ubuntu.packages, problems);
  checkFirstUse(ubuntu.firstUse, isRec(ubuntu.packages) ? ubuntu.packages : {}, problems);
  const pgdg = raw.pgdg;
  if (!str(pgdg.uri)?.startsWith("https://")) problems.push("apt.pgdg.uri: must be https");
  if (typeof pgdg.keySha256 !== "string" || !SHA256.test(pgdg.keySha256)) problems.push("apt.pgdg.keySha256: missing or not 64 lowercase hex");
  if (typeof pgdg.keyFingerprint !== "string" || !/^[0-9A-F]{40}$/.test(pgdg.keyFingerprint)) problems.push("apt.pgdg.keyFingerprint: missing");
  checkDebianPackages("apt.pgdg.packages", pgdg.packages, problems);
}

function checkFirstUse(raw: unknown, baked: Rec, problems: string[]): void {
  if (!isRec(raw)) {
    problems.push("apt.ubuntu.firstUse: needs role -> package closure");
    return;
  }
  for (const [role, closure] of Object.entries(raw)) {
    const where = `apt.ubuntu.firstUse.${role}`;
    checkDebianPackages(where, closure, problems);
    if (!isRec(closure)) continue;
    for (const name of Object.keys(closure)) if (name in baked) problems.push(`${where}: ${name} is also baked in apt.ubuntu.packages`);
  }
}

function checkRole(name: string, raw: unknown, apt: Rec, problems: string[]): void {
  const where = `roles.${name}`;
  if (!(KNOWN_ROLES as readonly string[]).includes(name)) problems.push(`${where}: unknown role`);
  if (!isRec(raw)) {
    problems.push(`${where}: not an object`);
    return;
  }
  if (raw.default !== "on" && raw.default !== "off") problems.push(`${where}.default: must be "on" or "off"`);
  if (raw.firstUse !== undefined && typeof raw.firstUse !== "boolean") problems.push(`${where}.firstUse: must be a boolean`);
  checkRoleEnv(name, raw.env, problems);
  const firstUse = isRec(apt.firstUse) ? apt.firstUse[name] : undefined;
  if (raw.firstUse === true && !isRec(firstUse)) {
    problems.push(`${where}: firstUse needs apt.ubuntu.firstUse.${name}`);
    return;
  }
  const source = raw.firstUse === true ? (firstUse as Rec) : isRec(apt.packages) ? apt.packages : {};
  const sourceName = raw.firstUse === true ? `apt.ubuntu.firstUse.${name}` : "apt.ubuntu.packages";
  if (!Array.isArray(raw.apt) || raw.apt.length === 0) {
    problems.push(`${where}.apt: needs at least one package`);
    return;
  }
  for (const pkg of raw.apt) if (typeof pkg !== "string" || !(pkg in source)) problems.push(`${where}.apt: ${JSON.stringify(pkg)} is not in ${sourceName}`);
}

function checkRoles(raw: unknown, apt: unknown, problems: string[]): void {
  if (!isRec(raw)) {
    problems.push("roles: missing");
    return;
  }
  const ubuntu = isRec(apt) && isRec(apt.ubuntu) ? apt.ubuntu : {};
  for (const [name, role] of Object.entries(raw)) checkRole(name, role, ubuntu, problems);
}

/** Validates a parsed lock. Throws LockError listing every problem; returns the typed lock. */
export function validateInputsLock(raw: unknown): InputsLock {
  const problems: string[] = [];
  if (!isRec(raw)) throw new LockError(["the lock is not a JSON object"]);
  if (raw.schema !== LOCK_SCHEMA) problems.push(`schema: expected ${LOCK_SCHEMA}`);
  if (!str(raw.image)) problems.push("image: missing");
  checkBase(raw.base, problems);
  checkApt(raw.apt, problems);
  const seen = new Set<string>();
  if (!Array.isArray(raw.programs)) problems.push("programs: missing");
  else raw.programs.forEach((program, index) => checkProgram(index, program, seen, problems));
  for (const name of KNOWN_PROGRAMS) {
    if (Array.isArray(raw.programs) && !seen.has(name)) problems.push(`programs: ${name} is missing`);
  }
  checkRoles(raw.roles, raw.apt, problems);
  checkFirstUsePrograms(raw.programs, raw.roles, problems);
  if (!isRec(raw.tools)) problems.push("tools: missing");
  else checkArtifact("tools.syft", raw.tools.syft, problems);
  if (problems.length > 0) throw new LockError(problems);
  return raw as unknown as InputsLock;
}

export function parseInputsLock(text: string): InputsLock {
  let raw: unknown;
  try {
    raw = JSON.parse(text);
  } catch (error) {
    throw new LockError([`not valid JSON: ${String(error)}`]);
  }
  return validateInputsLock(raw);
}

export function readInputsLock(file = DEFAULT_LOCK_PATH): InputsLock {
  return parseInputsLock(readFileSync(file, "utf8"));
}

export const ROLES_MANIFEST_PATH = "/etc/cmux/roles.json";

/** A first-use program as roles.json lists it: what the installer downloads, checks and unpacks into the store. */
export type RoleProgram = Pick<LockedProgram, "name" | "version" | "url" | "sha256" | "size" | "format" | "bin" | "fileName" | "checksumsUrl" | "checksumsName" | "notices" | "otherArches"> & { readonly storeEntry: string };

export type RoleManifestEntry = {
  readonly default: "on" | "off";
  readonly firstUse: boolean;
  readonly apt: readonly string[];
  /** Role env plus, for the browser role, CMUX_BROWSER_HOST_CHROMIUM at its store path. */
  readonly env: Readonly<Record<string, string>>;
  readonly programs: readonly RoleProgram[];
};

export type RolesManifest = {
  readonly schema: 1;
  /** The dated snapshot every first-use install reads (apt sources point at the live archive after the bake). */
  readonly aptSnapshot: string;
  /** The snapshot's deb822 source (suites, components, keyring) for first-use installs. */
  readonly aptSources: string;
  readonly roles: Readonly<Record<string, RoleManifestEntry>>;
  readonly firstUse: Readonly<Record<string, Readonly<Record<string, string>>>>;
};

/** Programs the bake installs into the store and links into the profile (first-use programs are not). */
export function bakedPrograms(lock: InputsLock): LockedProgram[] {
  return lock.programs.filter((p) => p.firstUse !== true);
}

/** The roles file the bake writes for `cmux host` (which starts roles and installs first-use closures and programs). */
export function rolesManifest(lock: InputsLock): RolesManifest {
  const roles: Record<string, RoleManifestEntry> = {};
  for (const [name, role] of Object.entries(lock.roles)) {
    const programs: RoleProgram[] = lock.programs
      .filter((p) => p.firstUse === true && (p.roles ?? []).includes(name as RoleName))
      .map((p) => ({
        name: p.name,
        version: p.version,
        url: p.url,
        sha256: p.sha256,
        size: p.size,
        format: p.format,
        bin: p.bin,
        ...(p.fileName ? { fileName: p.fileName } : {}),
        ...(p.checksumsUrl ? { checksumsUrl: p.checksumsUrl, checksumsName: p.checksumsName } : {}),
        ...(p.notices ? { notices: p.notices } : {}),
        ...(p.otherArches ? { otherArches: p.otherArches } : {}),
        storeEntry: storeEntry(p.sha256),
      }));
    const env: Record<string, string> = { ...(role.env ?? {}) };
    const chrome = programs.find((p) => p.name === "chrome-for-testing");
    if (name === "browser" && chrome) env.CMUX_BROWSER_HOST_CHROMIUM = `${chrome.storeEntry}/${chrome.bin.chrome}`;
    roles[name] = { default: role.default, firstUse: role.firstUse === true, apt: role.apt, env, programs };
  }
  return { schema: 1, aptSnapshot: lock.apt.ubuntu.uri, aptSources: ubuntuSourcesFile(lock.apt.ubuntu), roles, firstUse: lock.apt.ubuntu.firstUse };
}

/**
 * The lock entry shape for a Chrome for Testing linux64 release (D-A1 interim browser engine,
 * x86_64 only). sha256 and size are ours, from the downloaded file; Google publishes MD5 and
 * CRC32C (x-goog-hash) for it, recorded in `source`.
 */
export function chromeForTestingShape(version: string) {
  return {
    name: "chrome-for-testing" as const,
    version,
    url: `https://storage.googleapis.com/chrome-for-testing-public/${version}/linux64/chrome-linux64.zip`,
    format: "zip" as const,
    bin: { chrome: "chrome-linux64/chrome" },
    versionArgs: ["--version"],
    expect: `Google Chrome for Testing ${version}`,
    roles: ["browser" as const],
  };
}

export type CuaArch = "x86_64" | "arm64";

/**
 * The lock entry shape for a cmux-cua Linux release (contract from the CI
 * lead: cmux-cua-<V>-linux-<arch>.tar.gz holds cmux-cua-<V>-linux-<arch>/ with
 * the binary and LICENSE). sha256 and size are added only from the published
 * release; this shape never invents them.
 */
export function cmuxCuaReleaseShape(version: string, arch: CuaArch) {
  const dir = `cmux-cua-${version}-linux-${arch}`;
  return {
    name: "cmux-cua" as const,
    version,
    url: `https://github.com/manaflow-ai/cmux-cua/releases/download/cmux-cua-v${version}/${dir}.tar.gz`,
    format: "tar.gz" as const,
    bin: { "cmux-cua": `${dir}/cmux-cua` },
    versionArgs: ["--version"],
    expect: version,
    roles: ["cua" as const],
  };
}

/** POSIX single-quote a value for a shell command. */
export function sq(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export function storeEntry(sha256: string): string {
  if (!SHA256.test(sha256)) throw new Error(`store key ${sha256} is not a sha256`);
  return `${STORE_DIR}/${sha256}`;
}

/** What an install needs from a lock program or a roles.json first-use program. */
export type InstallableProgram = Pick<LockedProgram, "name" | "version" | "url" | "sha256" | "size" | "format" | "bin" | "fileName" | "checksumsUrl" | "checksumsName" | "notices">;

/** Download, verify (sha256 and size) and unpack one program into its immutable store entry. */
export function programInstallCommand(program: InstallableProgram): string {
  const entry = storeEntry(program.sha256);
  const dl = `/tmp/cmux-dl/${program.sha256}`;
  const stage = `${entry}.partial`;
  const unpack = {
    raw: `install -m 0755 ${dl} ${stage}/${program.fileName}`,
    "tar.gz": `tar -xzf ${dl} -C ${stage} --no-same-owner`,
    zip: `unzip -q ${dl} -d ${stage}`,
    npm: `npm install -g --prefix ${stage} --no-audit --no-fund --no-update-notifier ${dl}.tgz >/tmp/cmux-dl/${program.name}-npm.log 2>&1 || { tail -30 /tmp/cmux-dl/${program.name}-npm.log; exit 1; }`,
  }[program.format];
  const checksums = program.checksumsUrl
    ? `curl -fsSL --retry 3 -o ${dl}.sums ${sq(program.checksumsUrl)} && grep -qx ${sq(`${program.sha256}  ${program.checksumsName}`)} ${dl}.sums && `
    : "";
  return [
    `mkdir -p /tmp/cmux-dl ${STORE_DIR}`,
    `rm -rf ${stage} && mkdir -p ${stage}`,
    `curl -fsSL --retry 3 -o ${dl} ${sq(program.url)}`,
    `${checksums}printf '%s  %s\\n' ${program.sha256} ${dl} | sha256sum -c --quiet -`,
    `test "$(stat -c %s ${dl})" = ${program.size}`,
    program.format === "npm" ? `mv ${dl} ${dl}.tgz` : "true",
    unpack,
    ...Object.values(program.bin).map((target) => `test -x ${stage}/${target}`),
    ...(program.notices ?? []).map((notice) => `test -s ${stage}/${notice}`),
    `chmod -R a-w ${stage}`,
    `rm -rf ${entry} && mv ${stage} ${entry}`,
    `rm -f ${dl} ${dl}.tgz ${dl}.sums`,
    `echo store ${program.name} ${program.version} $(du -sb ${entry} | cut -f1)`,
  ].join(" && ");
}

/** Every command in the baked profile: name -> absolute target inside the store. */
export function profileLinks(lock: InputsLock): Array<{ command: string; target: string }> {
  const links: Array<{ command: string; target: string }> = [];
  const seen = new Set<string>();
  for (const program of bakedPrograms(lock)) {
    for (const [command, relative] of Object.entries(program.bin)) {
      if (seen.has(command)) throw new Error(`two programs provide ${command}`);
      seen.add(command);
      links.push({ command, target: `${storeEntry(program.sha256)}/${relative}` });
    }
  }
  return links.sort((a, b) => a.command.localeCompare(b.command));
}

/** Build profile generation 1 and point `current` at it with one rename. */
export function profileCommand(lock: InputsLock): string {
  const profile = `${PROFILES_DIR}/${BAKED_GENERATION}`;
  return [
    `rm -rf ${profile} && mkdir -p ${profile}/bin`,
    ...profileLinks(lock).map(({ command, target }) => `ln -s ${target} ${profile}/bin/${command}`),
    `ln -sfn profiles/${BAKED_GENERATION} ${STORE_ROOT}/.current-new && mv -T ${STORE_ROOT}/.current-new ${CURRENT_LINK}`,
    `ls ${CURRENT_BIN}`,
  ].join(" && ");
}

export function aptPinArgs(packages: Readonly<Record<string, string>>): string {
  return Object.entries(packages)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([name, version]) => sq(`${name}=${version}`))
    .join(" ");
}

export function ubuntuSourcesFile(repo: InputsLock["apt"]["ubuntu"]): string {
  return [
    "Types: deb",
    `URIs: ${repo.uri}`,
    `Suites: ${repo.suites.join(" ")}`,
    `Components: ${repo.components.join(" ")}`,
    `Signed-By: ${repo.signedBy}`,
    "",
  ].join("\n");
}

export function pgdgSourcesFile(repo: InputsLock["apt"]["pgdg"], keyPath: string): string {
  return ["Types: deb", `URIs: ${repo.uri}`, `Suites: ${repo.suite}`, `Components: ${repo.components.join(" ")}`, `Signed-By: ${keyPath}`, ""].join("\n");
}

/** `dpkg-query -W -f='${Package}\t${Version}\t${Architecture}\n' | LC_ALL=C sort` output -> name -> version. */
export function parseDpkgList(tsv: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of tsv.split("\n")) {
    const [name, version] = line.split("\t");
    if (name && version) out.set(name.split(":")[0], version);
  }
  return out;
}

/** Packages added or changed between two dpkg lists. */
export function dpkgChanges(before: Map<string, string>, after: Map<string, string>): Map<string, string> {
  const changed = new Map<string, string>();
  for (const [name, version] of after) if (before.get(name) !== version) changed.set(name, version);
  return changed;
}

/** Problems when the packages an install added differ from the lock's exact set (extra, missing, or other version). */
export function aptClosureProblems(expected: Readonly<Record<string, string>>, added: Map<string, string>): string[] {
  const problems: string[] = [];
  for (const [name, version] of added) {
    if (!(name in expected)) problems.push(`apt installed ${name}=${version}, which is not in the lock`);
    else if (expected[name] !== version) problems.push(`apt installed ${name}=${version}, the lock says ${expected[name]}`);
  }
  for (const name of Object.keys(expected)) if (!added.has(name)) problems.push(`lock package ${name} was not installed`);
  return problems;
}

export type BaseObservation = { kernelRelease: string; dpkgListSha256: string; dpkgPackageCount: number };

export function fingerprintProblems(lock: InputsLock, observed: BaseObservation): string[] {
  const fp = lock.base.fingerprint;
  const problems: string[] = [];
  if (observed.kernelRelease !== fp.kernelRelease) problems.push(`kernel release ${observed.kernelRelease}, lock ${fp.kernelRelease}`);
  if (observed.dpkgListSha256 !== fp.dpkgListSha256) {
    problems.push(`dpkg list sha256 ${observed.dpkgListSha256} (${observed.dpkgPackageCount} packages), lock ${fp.dpkgListSha256} (${fp.dpkgPackageCount})`);
  }
  return problems;
}

/** Base packages the lock records that the base dpkg list does not carry at that version. */
export function basePackageProblems(lock: InputsLock, baseDpkg: Map<string, string>): string[] {
  return Object.entries(lock.base.basePackages)
    .filter(([name, version]) => baseDpkg.get(name) !== version)
    .map(([name, version]) => `base package ${name}: lock ${version}, base ${baseDpkg.get(name) ?? "absent"}`);
}

/** Base npm globals that are neither kept (at the locked version) nor on the strip list. */
export function npmGlobalProblems(lock: InputsLock, observed: Map<string, string>): string[] {
  const { keep, strip } = lock.base.npmGlobals;
  const problems: string[] = [];
  for (const [name, version] of observed) {
    if (strip.includes(name)) continue;
    if (!(name in keep)) problems.push(`base npm global ${name}@${version} is not in the lock (keep or strip it)`);
    else if (keep[name] !== version) problems.push(`base npm global ${name}@${version}, lock keeps ${keep[name]}`);
  }
  return problems;
}

/** Returns a new lock text with the base fingerprint replaced (the --update-lock path). */
export function withFingerprint(lockText: string, observed: BaseObservation, recordedAt: string): string {
  const raw = JSON.parse(lockText) as { base: { fingerprint: Record<string, unknown> } };
  raw.base.fingerprint = { kernelRelease: observed.kernelRelease, dpkgListSha256: observed.dpkgListSha256, dpkgPackageCount: observed.dpkgPackageCount, recordedAt };
  return `${JSON.stringify(raw, null, 2)}\n`;
}

/** sha256 of the lock text: the image stamp names the exact inputs. */
export function lockDigest(text: string): string {
  return createHash("sha256").update(text).digest("hex");
}

export function percentile(values: readonly number[], p: number): number {
  if (values.length === 0) return Number.NaN;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.max(0, Math.ceil((p / 100) * sorted.length) - 1));
  return sorted[index];
}

/** Snapshot and VM names: branch bakes carry cmuxnp-dev-; only an explicit promotion may not. */
export function imageResourceName(options: { promotion: boolean; tag: string; date: string; sha: string }): string {
  if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(options.tag)) throw new Error(`tag ${options.tag} must be [a-z0-9-], at most 41 chars`);
  if (options.promotion) return `cmux-vm-${options.date}-${options.sha.slice(0, 10)}`;
  return `cmuxnp-dev-vmimg-${options.tag}`;
}

export type SbomComponent = { name: string; version: string; type: string };

/** CycloneDX components -> multiset keyed by type|name|version. */
export function sbomComponentCounts(sbom: unknown): Map<string, number> {
  const counts = new Map<string, number>();
  const components = isRec(sbom) && Array.isArray(sbom.components) ? sbom.components : [];
  for (const component of components) {
    if (!isRec(component)) continue;
    const key = `${String(component.type ?? "")}|${String(component.name ?? "")}|${String(component.version ?? "")}`;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

export function diffCounts(a: Map<string, number>, b: Map<string, number>): string[] {
  const diffs: string[] = [];
  for (const key of new Set([...a.keys(), ...b.keys()])) {
    const ca = a.get(key) ?? 0;
    const cb = b.get(key) ?? 0;
    if (ca !== cb) diffs.push(`${key}: ${ca} vs ${cb}`);
  }
  return diffs.sort();
}

/** File manifest lines `path\tkind\tdigest-or-target\t...` -> path -> "kind digest". */
export function parseFileManifest(tsv: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const line of tsv.split("\n")) {
    const fields = line.split("\t");
    if (fields.length >= 3) out.set(fields[0], `${fields[1]} ${fields[2]}`);
  }
  return out;
}

/**
 * Files that differ between two bakes by design: the stamp (bake time and name)
 * and the builder's instance id, which cmux-devbox-boot reads to keep the daemon
 * parked in the snapshot. The bind agent drops the second one.
 */
export const REPRO_ALLOWED_DIFFS: readonly string[] = ["/etc/cmux/image-stamp", "/etc/cmux/bake-instance-id"];

export function diffFileManifests(a: Map<string, string>, b: Map<string, string>, allowed: readonly string[] = REPRO_ALLOWED_DIFFS): { diffs: string[]; allowed: string[] } {
  const diffs: string[] = [];
  const hitAllowed: string[] = [];
  for (const file of new Set([...a.keys(), ...b.keys()])) {
    if (a.get(file) === b.get(file)) continue;
    const line = `${file}: ${a.get(file) ?? "absent"} vs ${b.get(file) ?? "absent"}`;
    if (allowed.includes(file)) hitAllowed.push(line);
    else diffs.push(line);
  }
  return { diffs: diffs.sort(), allowed: hitAllowed.sort() };
}
