/**
 * Shared plumbing for the cmux Cloud devbox image bake
 * (build-devbox-freestyle.ts), the post-bake verifier
 * (verify-devbox-image.ts), and the promote step (promote-devbox-image.ts).
 *
 * The image source of truth is web/services/vms/images/devbox/: a plain
 * Dockerfile plus the files it COPYs. No daemon binary is baked: cmux-tui is
 * installed by the drivers at create time from the pinned files.cmux.com
 * manifest (web/services/vms/drivers/cmuxTuiDaemon.ts); the image only ships
 * the cmux-devbox-boot supervisor.
 */
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { vmImageSizeRank, type VmImageSizeName } from "../services/vms/images/sizes";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const webRoot = path.resolve(__dirname, "..");
export const repoRoot = path.resolve(webRoot, "..");
export const devboxDir = path.join(webRoot, "services/vms/images/devbox");
export const devboxDockerfilePath = path.join(devboxDir, "Dockerfile");

/** Files the Dockerfile COPYs plus the Dockerfile itself; all must exist. */
export const DEVBOX_TEMPLATE_FILES = [
  "Dockerfile",
  "agent-config.sh",
  "chrome-managed-policy.json",
  "cmux-bashrc",
  "cmux-devbox-boot",
  "cmux-motd",
  "seed-history",
] as const;

/**
 * The desktop layer (ported from the retired Blaxel cmux-devbox image): an
 * openbox/TigerVNC desktop with a tint2 dock, Ghostty, Chrome, Thunar and
 * noVNC on 6901. Baked by build-devbox-freestyle.ts (a full VM with
 * systemd); the container providers stay shell-only.
 */
export const devboxDesktopDir = path.join(devboxDir, "desktop");
export const DEVBOX_DESKTOP_FILES = [
  "WALLPAPER.md",
  "cmux-desktop-boot",
  "cmux-desktop.service",
  "ghostty-cmux.desktop",
  "google-chrome-cmux.desktop",
  "start-vnc.sh",
  "thunar-cmux.desktop",
  "tint2rc",
  "wallpaper.jpg",
] as const;

/** Ghostty ships no upstream .deb; this community build is pinned by release tag. */
export const DEVBOX_GHOSTTY_DEB_URL =
  "https://github.com/mkasberg/ghostty-ubuntu/releases/download/1.3.1-0-ppa2/ghostty_1.3.1-0.ppa2_amd64_24.04.deb";

const AGENT_PIN_ARGS: readonly { arg: string; pkg: string; binary: string }[] = [
  { arg: "CMUX_IMAGE_CLAUDE_CODE_VERSION", pkg: "@anthropic-ai/claude-code", binary: "claude" },
  { arg: "CMUX_IMAGE_CODEX_VERSION", pkg: "@openai/codex", binary: "codex" },
  { arg: "CMUX_IMAGE_OPENCODE_VERSION", pkg: "opencode-ai", binary: "opencode" },
  { arg: "CMUX_IMAGE_PI_VERSION", pkg: "@earendil-works/pi-coding-agent", binary: "pi" },
  { arg: "CMUX_IMAGE_AGENT_BROWSER_VERSION", pkg: "agent-browser", binary: "agent-browser" },
];

export type AgentPin = { pkg: string; version: string; binary: string; spec: string };

/** The npm pins come from the Dockerfile ARG defaults, never a second copy. */
export function devboxAgentPins(dockerfile = readDevboxDockerfile()): AgentPin[] {
  return AGENT_PIN_ARGS.map(({ arg, pkg, binary }) => {
    const match = new RegExp(`^ARG ${arg}=(\\S+)$`, "m").exec(dockerfile);
    if (!match) throw new Error(`devbox Dockerfile is missing ARG ${arg}`);
    return { pkg, version: match[1], binary, spec: `${pkg}@${match[1]}` };
  });
}

export function readDevboxDockerfile(): string {
  return readFileSync(devboxDockerfilePath, "utf8");
}

/** The cua computer-use driver pin, from the Dockerfile (never a second copy). */
export function devboxCuaDriverVersion(dockerfile = readDevboxDockerfile()): string {
  const version = /CUA_DRIVER_RS_VERSION=(\S+)/.exec(dockerfile)?.[1];
  if (!version) throw new Error("devbox Dockerfile is missing CUA_DRIVER_RS_VERSION");
  return version;
}

export function devboxImageEpoch(dockerfile = readDevboxDockerfile()): string {
  return /CMUX_IMAGE_EPOCH=([^\s"]+)/.exec(dockerfile)?.[1] ?? "none";
}

export function devboxTemplateFile(name: string): string {
  return readFileSync(path.join(devboxDir, name), "utf8");
}

export function devboxDesktopFile(name: string): string {
  return readFileSync(path.join(devboxDesktopDir, name), "utf8");
}

/** Raw bytes of a devbox template file (`desktop/<name>` for the desktop layer). */
export function devboxFileBytes(name: string): Uint8Array {
  const file = name.startsWith("desktop/")
    ? path.join(devboxDesktopDir, name.slice("desktop/".length))
    : path.join(devboxDir, name);
  return new Uint8Array(readFileSync(file));
}

export function fileBase64(name: string): string {
  return readFileSync(path.join(devboxDir, name)).toString("base64");
}

export function sha256File(filePath: string): string {
  return createHash("sha256").update(readFileSync(filePath)).digest("hex");
}

function git(args: string, cwd: string): string {
  return execSync(`git ${args}`, { cwd, encoding: "utf8" }).trim();
}

/**
 * Stale-checkout guard (chatmux bake-preflight lineage): refuse to bake from
 * a checkout that silently missed a pull. The Dockerfile COPYs plain files,
 * so there are no base64 embeds to drift-check. Branch bakes are deliberate
 * with CMUX_BAKE_ALLOW_BRANCH=1.
 */
export function bakePreflight(options: { desktop?: boolean } = {}): { sha: string; epoch: string } {
  for (const name of DEVBOX_TEMPLATE_FILES) {
    if (!existsSync(path.join(devboxDir, name))) {
      throw new Error(`bake refused: ${name} is missing from ${devboxDir}`);
    }
  }
  if (options.desktop) {
    for (const name of DEVBOX_DESKTOP_FILES) {
      if (!existsSync(path.join(devboxDesktopDir, name))) {
        throw new Error(`bake refused: desktop/${name} is missing from ${devboxDesktopDir}`);
      }
    }
  }
  const allowBranch = process.env.CMUX_BAKE_ALLOW_BRANCH === "1";
  execSync("git fetch --quiet origin main", { cwd: repoRoot });
  const head = git("rev-parse HEAD", repoRoot);
  const main = git("rev-parse origin/main", repoRoot);
  if (head !== main && !allowBranch) {
    throw new Error(
      `bake refused: HEAD ${head.slice(0, 10)} != origin/main ${main.slice(0, 10)} ` +
        "(pull first, or set CMUX_BAKE_ALLOW_BRANCH=1 for a deliberate branch bake)",
    );
  }
  const epoch = devboxImageEpoch();
  const state = head === main ? "== origin/main" : "!= origin/main (CMUX_BAKE_ALLOW_BRANCH=1)";
  console.log(`bake-preflight: HEAD ${head.slice(0, 10)} ${state}, devbox epoch ${epoch}`);
  return { sha: head, epoch };
}

/**
 * The platform's name for the machine running the command: the Firecracker
 * MMDS instance id (EC2-style token, then GET). Empty output means no metadata
 * service (a container). cmux-devbox-boot keys the daemon identity on it.
 */
export const DEVBOX_INSTANCE_ID_COMMAND =
  "curl -sf -m 2 -H \"X-aws-ec2-metadata-token: $(curl -sf -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60')\" http://169.254.169.254/latest/meta-data/instance-id";

/**
 * Park the cmux-tui daemon on a machine about to be snapshotted: record this
 * machine's instance id as the bake id (cmux-devbox-boot keeps the daemon
 * stopped while the ids match), wait for the supervisor to stop it, wipe the
 * identity and session state it produced, and prove nothing listens on 1337.
 * Every machine created from the resulting snapshot has a different id, so
 * its supervisor starts a daemon with a fresh identity within one tick.
 * Run as root. Exits 0 only when the daemon is parked.
 */
export function devboxParkDaemonCommand(): string {
  return [
    `mkdir -p /etc/cmux && ${DEVBOX_INSTANCE_ID_COMMAND} > /etc/cmux/bake-instance-id && test -s /etc/cmux/bake-instance-id`,
    // [s]tart: the pattern must not match the exec shell carrying this command line.
    "for i in $(seq 1 30); do pgrep -f 'cmux-tui server [s]tart' >/dev/null || break; sleep 1; done",
    "! pgrep -f 'cmux-tui server [s]tart' >/dev/null",
    "systemctl is-active cmux-tui-daemon >/dev/null",
    "rm -rf /root/.local/state/cmux/remote /root/.local/state/cmux-tui /etc/cmux/daemon-instance-id",
    "! grep -qi ':0539 ' /proc/net/tcp6",
    "echo daemon-parked-for-clones",
  ].join(" && ");
}

export function defaultBakeTag(): string {
  const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+$/, "").replace("T", "-");
  return `devbox-${stamp}`;
}

export function argValue(name: string): string | undefined {
  const index = process.argv.indexOf(name);
  if (index === -1) return undefined;
  return process.argv[index + 1];
}

export function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

export type DevboxBakeMetadata = {
  readonly builtAt: string;
  readonly epoch: string;
  readonly repoCommit: string;
  readonly builderScriptVersion: string;
  readonly agentToolResolvedVersions: Record<string, string>;
};

export function bakeMetadata(
  preflight: { sha: string; epoch: string },
  builderScriptPath: string,
): DevboxBakeMetadata {
  return {
    builtAt: new Date().toISOString(),
    epoch: preflight.epoch,
    repoCommit: preflight.sha,
    builderScriptVersion: sha256File(builderScriptPath),
    agentToolResolvedVersions: Object.fromEntries(
      devboxAgentPins().map((pin) => [pin.pkg, pin.version]),
    ),
  };
}

export type DevboxProvider = "freestyle";
export type DevboxImageKind = "desktop" | "base";
export type DevboxImageSize = {
  name: VmImageSizeName;
  cpu: number;
  memoryMb: number;
  storageMb: number;
};

/** One `images[]` row of services/vms/images/manifest.json, as the bake scripts emit it. */
export type DevboxManifestEntry = {
  provider: DevboxProvider;
  version: string;
  imageId: string;
  /** Legacy: nothing reads it; kept so old entries parse. */
  envVar: string;
  /** Legacy: local dev uses the same `defaultForKind` entry as production. */
  defaultForLocalDev?: boolean;
  kind?: DevboxImageKind;
  defaultForKind?: boolean;
  /** The shape this snapshot boots at (Freestyle ladder). Size-less entries are pre-ladder bakes. */
  size?: DevboxImageSize;
  cmuxdRemoteCommit: string;
  /** The cmux-tui build baked at /root/.cmux/bin/cmux-tui (files.cmux.com manifest pin at bake time). Absent on images that installed it at create time. */
  cmuxTuiCommit?: string;
  cmuxTuiSha256?: string;
  /** The cmux commit whose devbox definition produced this image. */
  repoCommit?: string;
  builtAt: string;
  builderScriptVersion: string;
  agentToolResolvedVersions: Record<string, string>;
  validationStatus: "passed" | "failed" | "unknown";
  notes?: string;
};

export function manifestEntrySkeleton(
  provider: DevboxProvider,
  version: string,
  imageId: string,
  envVar: string,
  metadata: DevboxBakeMetadata,
  extraNotes = "",
  kind?: DevboxImageKind,
): DevboxManifestEntry {
  return {
    provider,
    version,
    imageId,
    envVar,
    ...(kind ? { kind } : {}),
    // The session daemon is cmux-tui, installed at create time from the pinned
    // artifacts manifest; no cmuxd-remote build is baked.
    cmuxdRemoteCommit: "none-cmux-tui",
    repoCommit: metadata.repoCommit,
    builtAt: metadata.builtAt,
    builderScriptVersion: metadata.builderScriptVersion,
    agentToolResolvedVersions: metadata.agentToolResolvedVersions,
    // The bake alone never marks an image passed; verify-devbox-image.ts does.
    validationStatus: "unknown",
    notes: [
      `cmux devbox epoch ${metadata.epoch}`,
      extraNotes,
    ].filter(Boolean).join(" "),
  };
}

/**
 * The bake's machine-readable result. `--out <path>` on a bake script writes
 * it there so promote-devbox-image.ts never has to scrape build logs.
 */
export type DevboxBakeResult = {
  readonly provider: DevboxProvider;
  readonly imageId: string;
  readonly manifestEntry: DevboxManifestEntry;
  readonly next: string;
  readonly [extra: string]: unknown;
};

export function emitBakeResult(result: DevboxBakeResult): void {
  console.log(JSON.stringify(result, null, 2));
  const out = argValue("--out");
  if (out) {
    writeFileSync(out, `${JSON.stringify(result, null, 2)}\n`);
    console.log(`bake result written to ${out}`);
  }
  // The last stdout line is the image id alone, so shell callers can
  // `tail -n 1` it without parsing JSON.
  console.log(`IMAGE_ID ${result.imageId}`);
}

// ---------------------------------------------------------------------------
// Manifest promotion: the checked-in manifest is the source of truth for the
// image users get, so "promote" is a pure edit of that file that a PR
// carries. Only verified images are promotable, and a provider+kind has
// exactly one default at a time.
// ---------------------------------------------------------------------------

export const imageManifestPath = path.join(webRoot, "services/vms/images/manifest.json");

export type DevboxImageManifest = {
  schemaVersion: number;
  images: DevboxManifestEntry[];
};

export function readImageManifest(file = imageManifestPath): DevboxImageManifest {
  const parsed = JSON.parse(readFileSync(file, "utf8")) as DevboxImageManifest;
  if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.images)) {
    throw new Error(`${file}: unsupported image manifest shape`);
  }
  return parsed;
}

export function writeImageManifest(manifest: DevboxImageManifest, file = imageManifestPath): void {
  writeFileSync(file, `${JSON.stringify(manifest, null, 2)}\n`);
}

export type PromoteImageOptions = {
  /** Kinds this image serves. Each gets its own entry flagged `defaultForKind`. */
  readonly kinds: readonly DevboxImageKind[];
  /**
   * Sized snapshots derived from the bake (derive-devbox-sizes.ts): one
   * manifest entry per kind and size, each the default for that kind+size.
   * Omitted: a single size-less entry per kind (a pre-ladder bake).
   */
  readonly sizes?: readonly { readonly imageId: string; readonly size: DevboxImageSize }[];
  /** Human-readable validation summary appended to `notes`. */
  readonly validationNotes?: string;
};

function sizeKey(entry: Pick<DevboxManifestEntry, "size">): string {
  return entry.size?.name ?? "";
}

/**
 * Appends a verified image to the manifest as the default for every kind in
 * `kinds` (and every size in `sizes`), demoting the provider's previous
 * defaults for those kind+size pairs. Pure: returns a new manifest and never
 * mutates the input. Existing entries are only ever flag-flipped, never
 * removed, so rollback stays a one-line manifest change.
 */
export function promoteImageManifestEntry(
  manifest: DevboxImageManifest,
  entry: DevboxManifestEntry,
  options: PromoteImageOptions,
): DevboxImageManifest {
  if (entry.validationStatus !== "passed") {
    throw new Error(
      `refusing to promote ${entry.provider} ${entry.imageId}: validationStatus is ` +
        `${entry.validationStatus}, not passed (run verify-devbox-image.ts first)`,
    );
  }
  if (options.kinds.length === 0) {
    throw new Error(`refusing to promote ${entry.imageId}: no kinds given`);
  }
  const kinds = [...new Set(options.kinds)];
  const variants: Array<{ imageId: string; size?: DevboxImageSize }> =
    options.sizes && options.sizes.length > 0
      ? [...options.sizes].sort((a, b) => vmImageSizeRank(a.size.name) - vmImageSizeRank(b.size.name))
      : [{ imageId: entry.imageId }];
  for (const kind of kinds) {
    for (const variant of variants) {
      const clash = manifest.images.find((candidate) =>
        candidate.provider === entry.provider &&
        candidate.imageId === variant.imageId &&
        (candidate.kind ?? "base") === kind &&
        sizeKey(candidate) === (variant.size?.name ?? "")
      );
      if (clash) {
        throw new Error(
          `refusing to promote ${entry.provider} ${variant.imageId}: already listed as ${clash.version} (${kind}${variant.size ? `, ${variant.size.name}` : ""})`,
        );
      }
    }
  }
  const promotedSizes = new Set<string>(variants.map((variant) => variant.size?.name ?? ""));
  const demoted = manifest.images.map((candidate) => {
    if (candidate.provider !== entry.provider) return candidate;
    const next: DevboxManifestEntry = { ...candidate };
    // A sized promotion demotes the provider's size-less defaults too: the
    // ladder replaces the single-shape image, not just one row of it.
    const sameSize = promotedSizes.has(sizeKey(next)) || (sizeKey(next) === "" && promotedSizes.size > 0);
    if (next.defaultForKind && kinds.includes(next.kind ?? "base") && sameSize) next.defaultForKind = false;
    return next;
  });
  const notes = [entry.notes, options.validationNotes].filter(Boolean).join(" ");
  const promoted: DevboxManifestEntry[] = [];
  for (const kind of kinds) {
    for (const variant of variants) {
      const suffix = [variant.size ? variant.size.name : "", kind !== kinds[0] ? kind : ""].filter(Boolean).join("-");
      promoted.push({
        ...entry,
        version: suffix ? `${entry.version}-${suffix}` : entry.version,
        imageId: variant.imageId,
        kind,
        defaultForKind: true,
        ...(variant.size ? { size: variant.size } : {}),
        ...(notes ? { notes } : {}),
      });
    }
  }
  return { schemaVersion: manifest.schemaVersion, images: [...demoted, ...promoted] };
}

/**
 * Invariants the checked-in manifest must hold; tests/vm-image-manifest.test.ts
 * runs this against the real file, promote-devbox-image.ts against its output.
 */
export function imageManifestProblems(manifest: DevboxImageManifest): string[] {
  const problems: string[] = [];
  const defaults = new Map<string, DevboxManifestEntry[]>();
  for (const entry of manifest.images) {
    for (const field of ["provider", "version", "imageId", "envVar", "builtAt", "validationStatus"] as const) {
      if (!entry[field]) problems.push(`${entry.version ?? entry.imageId ?? "?"}: missing ${field}`);
    }
    if (!["passed", "failed", "unknown"].includes(entry.validationStatus)) {
      problems.push(`${entry.version}: validationStatus ${String(entry.validationStatus)} is not passed|failed|unknown`);
    }
    if (entry.kind !== undefined && entry.kind !== "desktop" && entry.kind !== "base") {
      problems.push(`${entry.version}: kind ${String(entry.kind)} is not desktop|base`);
    }
    if (entry.size !== undefined) {
      const { name, cpu, memoryMb, storageMb } = entry.size;
      if (vmImageSizeRank(name) < 0) problems.push(`${entry.version}: size ${String(name)} is not on the ladder`);
      if (![cpu, memoryMb, storageMb].every((n) => Number.isInteger(n) && n > 0)) {
        problems.push(`${entry.version}: size ${String(name)} needs positive integer cpu/memoryMb/storageMb`);
      }
    }
    if (entry.defaultForKind) {
      if (entry.validationStatus !== "passed") {
        problems.push(`${entry.version}: defaultForKind but validationStatus is ${entry.validationStatus}`);
      }
      const key = `${entry.provider}/${entry.kind ?? "base"}${entry.size ? `/${entry.size.name}` : ""}`;
      defaults.set(key, [...(defaults.get(key) ?? []), entry]);
    }
  }
  const versions = manifest.images.map((entry) => `${entry.provider}/${entry.version}`);
  for (const dup of versions.filter((v, i) => versions.indexOf(v) !== i)) {
    problems.push(`${dup}: version listed more than once`);
  }
  const shapesByKind = new Map<string, Set<string>>();
  for (const entry of manifest.images) {
    if (!entry.defaultForKind) continue;
    const key = `${entry.provider}/${entry.kind ?? "base"}`;
    shapesByKind.set(key, new Set([...(shapesByKind.get(key) ?? []), entry.size ? "sized" : "size-less"]));
  }
  for (const [key, shapes] of shapesByKind) {
    if (shapes.size > 1) problems.push(`${key}: defaults mix sized and size-less entries`);
  }
  for (const [key, entries] of defaults) {
    if (entries.length > 1) {
      problems.push(`${key}: ${entries.length} entries flagged defaultForKind (${entries.map((e) => e.version).join(", ")})`);
    }
  }
  return problems;
}
