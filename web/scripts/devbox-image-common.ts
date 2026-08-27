/**
 * Shared plumbing for the cmux Cloud devbox image bakes
 * (build-devbox-e2b.ts, build-devbox-daytona.ts, build-devbox-freestyle.ts)
 * and the post-bake verifier (verify-devbox-image.ts).
 *
 * The image source of truth is web/services/vms/images/devbox/: a plain
 * Dockerfile plus the files it COPYs. The only generated artifact is the
 * cmuxd-remote linux binary, built here from daemon/remote into the
 * gitignored .build/ context directory.
 */
import { execSync, spawn } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
export const webRoot = path.resolve(__dirname, "..");
export const repoRoot = path.resolve(webRoot, "..");
export const devboxDir = path.join(webRoot, "services/vms/images/devbox");
export const devboxDockerfilePath = path.join(devboxDir, "Dockerfile");
export const daemonBuildPath = path.join(devboxDir, ".build/cmuxd-remote-linux-amd64");

/**
 * The serve command every provider's boot path runs. Must stay in lockstep
 * with the driver constants in web/services/vms/drivers/{e2b,daytona,freestyle}.ts
 * (port 7777, lease paths under /tmp/cmux) and with
 * services/vms/images/devbox/cmux-daytona-entrypoint.
 */
export const DEVBOX_SERVE_COMMAND =
  "/usr/local/bin/cmuxd-remote serve --ws --listen 0.0.0.0:7777 " +
  "--auth-lease-file /tmp/cmux/attach-pty-lease.json " +
  "--rpc-auth-lease-file /tmp/cmux/attach-rpc-lease.json " +
  "--shell /usr/local/bin/cmux-cloud-shell";

/** Files the Dockerfile COPYs (beyond the .build daemon); all must exist. */
export const DEVBOX_TEMPLATE_FILES = [
  "Dockerfile",
  "agent-config.sh",
  "chrome-managed-policy.json",
  "cmux-bashrc",
  "cmux-cloud-shell",
  "cmux-daytona-entrypoint",
  "cmux-zshrc",
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

export function sha256Text(text: string): string {
  return createHash("sha256").update(text).digest("hex");
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

/** Cross-compile cmuxd-remote for linux/amd64 into the devbox .build context. */
export async function buildRemoteDaemon(): Promise<{ path: string; sha256: string; commit: string }> {
  mkdirSync(path.dirname(daemonBuildPath), { recursive: true });
  await runCommand(
    "go",
    ["build", "-trimpath", "-ldflags=-s -w", "-o", daemonBuildPath, "./cmd/cmuxd-remote"],
    {
      cwd: path.join(repoRoot, "daemon/remote"),
      env: { GOOS: "linux", GOARCH: "amd64", CGO_ENABLED: "0" },
    },
  );
  return {
    path: daemonBuildPath,
    sha256: sha256File(daemonBuildPath),
    commit: git("rev-parse HEAD", path.join(repoRoot, "daemon/remote")),
  };
}

/**
 * A URL the Freestyle builder VM can download cmuxd-remote from (its exec API
 * has no file upload big enough for the daemon). Either CMUX_REMOTE_DAEMON_BUILD_URL
 * points at an already-hosted build, or the binary is uploaded to R2 and
 * presigned (same contract as web/scripts/build-cloud-vm-images.ts).
 */
export async function remoteDaemonBuildURL(tag: string): Promise<string> {
  const explicit = process.env.CMUX_REMOTE_DAEMON_BUILD_URL?.trim();
  if (explicit) return explicit;

  const required = ["R2_ENDPOINT", "R2_BUCKET_NAME", "R2_ACCESS_KEY_ID", "R2_SECRET_ACCESS_KEY"];
  const missing = required.filter((key) => !process.env[key]?.trim());
  if (missing.length > 0) {
    throw new Error(
      `Freestyle bake needs CMUX_REMOTE_DAEMON_BUILD_URL or R2 env vars; missing ${missing.join(", ")}`,
    );
  }

  const key = `cmux-build-artifacts/cloud-vm/${tag}/cmuxd-remote-linux-amd64`;
  const env = {
    AWS_ACCESS_KEY_ID: process.env.R2_ACCESS_KEY_ID!,
    AWS_SECRET_ACCESS_KEY: process.env.R2_SECRET_ACCESS_KEY!,
    AWS_DEFAULT_REGION: "auto",
    AWS_REGION: "auto",
  };
  await runCommand(
    "aws",
    [
      "s3",
      "cp",
      daemonBuildPath,
      `s3://${process.env.R2_BUCKET_NAME!}/${key}`,
      "--endpoint-url",
      process.env.R2_ENDPOINT!,
      "--content-type",
      "application/octet-stream",
      "--cache-control",
      "no-store",
      "--only-show-errors",
    ],
    { env },
  );
  const presigned = await runCommand(
    "aws",
    [
      "s3",
      "presign",
      `s3://${process.env.R2_BUCKET_NAME!}/${key}`,
      "--endpoint-url",
      process.env.R2_ENDPOINT!,
      "--expires-in",
      "3600",
    ],
    { env },
  );
  return presigned.trim();
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
  readonly cmuxdRemoteCommit: string;
  readonly binarySha256: string;
  readonly builderScriptVersion: string;
  readonly agentToolResolvedVersions: Record<string, string>;
};

export function bakeMetadata(
  preflight: { sha: string; epoch: string },
  daemon: { sha256: string; commit: string },
  builderScriptPath: string,
): DevboxBakeMetadata {
  return {
    builtAt: new Date().toISOString(),
    epoch: preflight.epoch,
    repoCommit: preflight.sha,
    cmuxdRemoteCommit: daemon.commit,
    binarySha256: daemon.sha256,
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
    cmuxdRemoteCommit: metadata.cmuxdRemoteCommit,
    builtAt: metadata.builtAt,
    builderScriptVersion: metadata.builderScriptVersion,
    agentToolResolvedVersions: metadata.agentToolResolvedVersions,
    // The bake alone never marks an image passed; verify-devbox-image.ts does.
    validationStatus: "unknown",
    notes: [
      `cmux devbox epoch ${metadata.epoch}`,
      `binarySha256=${metadata.binarySha256}`,
      extraNotes,
    ].filter(Boolean).join(" "),
  };
}

export function runCommand(
  command: string,
  args: string[],
  options: { cwd?: string; env?: Record<string, string> } = {},
): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd: options.cwd,
      env: { ...process.env, ...options.env },
      stdio: ["ignore", "pipe", "pipe"],
    });
    const stdout: Buffer[] = [];
    const stderr: Buffer[] = [];
    child.stdout.on("data", (chunk: Buffer) => stdout.push(chunk));
    child.stderr.on("data", (chunk: Buffer) => stderr.push(chunk));
    child.once("error", reject);
    child.once("close", (code) => {
      if (code === 0) {
        resolve(Buffer.concat(stdout).toString());
        return;
      }
      reject(
        new Error(`${command} ${args.join(" ")} failed with ${code}\n${Buffer.concat(stderr).toString()}`),
      );
    });
  });
}
