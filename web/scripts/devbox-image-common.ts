/**
 * Shared plumbing for the cmux Cloud devbox image bakes
 * (build-devbox-e2b.ts, build-devbox-daytona.ts, build-devbox-freestyle.ts)
 * and the post-bake verifier (verify-devbox-image.ts).
 *
 * The image source of truth is web/services/vms/images/devbox/: a plain
 * Dockerfile plus the files it COPYs. No daemon binary is baked: cmux-tui is
 * installed by the drivers at create time from the pinned files.cmux.com
 * manifest (web/services/vms/drivers/cmuxTuiDaemon.ts); the image only ships
 * the cmux-devbox-boot supervisor.
 */
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

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
  "seed-history",
] as const;

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

export function devboxImageEpoch(dockerfile = readDevboxDockerfile()): string {
  return /CMUX_IMAGE_EPOCH=([^\s"]+)/.exec(dockerfile)?.[1] ?? "none";
}

export function devboxTemplateFile(name: string): string {
  return readFileSync(path.join(devboxDir, name), "utf8");
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
export function bakePreflight(): { sha: string; epoch: string } {
  for (const name of DEVBOX_TEMPLATE_FILES) {
    if (!existsSync(path.join(devboxDir, name))) {
      throw new Error(`bake refused: ${name} is missing from ${devboxDir}`);
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

export function manifestEntrySkeleton(
  provider: "e2b" | "daytona" | "freestyle",
  version: string,
  imageId: string,
  envVar: string,
  metadata: DevboxBakeMetadata,
  extraNotes = "",
): Record<string, unknown> {
  return {
    provider,
    version,
    imageId,
    envVar,
    defaultForLocalDev: false,
    // The session daemon is cmux-tui, installed at create time from the pinned
    // artifacts manifest; no cmuxd-remote build is baked (same as Blaxel).
    cmuxdRemoteCommit: "none-cmux-tui",
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
