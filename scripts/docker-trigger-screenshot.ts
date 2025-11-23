#!/usr/bin/env bun

import { Command } from "commander";
import { connectToWorkerManagement, type Socket } from "@cmux/shared/socket";
import type {
  ServerToWorkerEvents,
  WorkerStartScreenshotCollection,
  WorkerToServerEvents,
} from "@cmux/shared";
import { config as loadEnv } from "dotenv";
import { existsSync } from "node:fs";
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

const IMAGE_NAME = "cmux-shell";
const CONTAINER_NAME = "cmux-screenshot";
const WORKER_PORT = 39377;
const VS_CODE_PORT = 39378;
const NOVNC_PORT = 39380;
const WORKSPACE_PATH = "/root/workspace";
const HEALTH_URL = `http://localhost:${WORKER_PORT}/health`;
const WORKER_BASE_URL = `http://localhost:${WORKER_PORT}`;
const HEALTH_ATTEMPTS = 30;

type Options = {
  readonly pr?: string;
  readonly exec?: string;
};

type RunOptions = {
  readonly cwd?: string;
  readonly env?: Record<string, string | undefined>;
  readonly capture?: boolean;
  readonly allowFailure?: boolean;
  readonly description?: string;
};

let containerStarted = false;
let cleaningUp = false;

const delay = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function run(
  command: string,
  args: string[],
  options: RunOptions = {},
): Promise<{ stdout: string; stderr: string; code: number }> {
  const {
    cwd,
    env,
    capture = false,
    allowFailure = false,
    description,
  } = options;
  if (description) {
    console.log(description);
  }

  const subprocess = Bun.spawn([command, ...args], {
    cwd,
    env,
    stdin: "inherit",
    stdout: capture ? "pipe" : "inherit",
    stderr: capture ? "pipe" : "inherit",
  });

  const [code, stdout, stderr] = await Promise.all([
    subprocess.exited,
    capture && subprocess.stdout
      ? new Response(subprocess.stdout).text()
      : "",
    capture && subprocess.stderr
      ? new Response(subprocess.stderr).text()
      : "",
  ]);

  if (code !== 0 && !allowFailure) {
    throw new Error(
      `Command failed (${command} ${args.join(" ")}): exit code ${code}${
        capture ? `\nstdout:\n${stdout}\nstderr:\n${stderr}` : ""
      }`,
    );
  }

  return { stdout: capture ? stdout : "", stderr: capture ? stderr : "", code };
}

async function cleanup(): Promise<void> {
  if (!containerStarted || cleaningUp) {
    return;
  }
  cleaningUp = true;
  console.log("Stopping container...");
  await run("docker", ["stop", CONTAINER_NAME], {
    allowFailure: true,
    capture: true,
  }).catch((error) => {
    console.warn("Failed to stop container:", error);
  });
  containerStarted = false;
}

function registerCleanup(): void {
  const handleSignal = (signal: string) => {
    console.log(`Received ${signal}, shutting down...`);
    void cleanup().finally(() => process.exit(0));
  };

  process.once("SIGINT", handleSignal);
  process.once("SIGTERM", handleSignal);
}

function loadDotEnv(): void {
  const envPath = path.join(process.cwd(), ".env");
  if (existsSync(envPath)) {
    loadEnv({ path: envPath });
  }
}

async function ensureImageBuilt(): Promise<void> {
  await run("docker", ["build", "-t", IMAGE_NAME, "."], {
    description: "Building Docker image...",
  });
}

async function ensureContainerRemoved(): Promise<void> {
  const { stdout } = await run(
    "docker",
    ["ps", "-a", "--format", "{{.Names}}"],
    { capture: true, allowFailure: true },
  );
  const containers = stdout.split("\n").map((value) => value.trim());
  if (containers.includes(CONTAINER_NAME)) {
    await run("docker", ["rm", "-f", CONTAINER_NAME], {
      allowFailure: true,
      description: "Removing existing container...",
    });
  }
}

async function startContainer(anthropicApiKey: string): Promise<void> {
  const args = [
    "run",
    "-d",
    "--rm",
    "--privileged",
    "--cgroupns=host",
    "--tmpfs",
    "/run",
    "--tmpfs",
    "/run/lock",
    "-v",
    "/sys/fs/cgroup:/sys/fs/cgroup:rw",
    "-v",
    "docker-data:/var/lib/docker",
    "-p",
    "39375:39375",
    "-p",
    "39376:39376",
    "-p",
    "39377:39377",
    "-p",
    "39378:39378",
    "-p",
    "39379:39379",
    "-p",
    "39380:39380",
    "-p",
    "39381:39381",
    "-p",
    "39382:39382",
    "-p",
    "39383:39383",
    "-e",
    `ANTHROPIC_API_KEY=${anthropicApiKey}`,
    "--name",
    CONTAINER_NAME,
    IMAGE_NAME,
  ];

  const { stdout } = await run("docker", args, {
    capture: true,
    description: "Starting worker container...",
  });
  containerStarted = stdout.trim().length > 0;
  console.log(`Container started: ${stdout.trim()}`);
}

async function waitForHealth(): Promise<void> {
  process.stdout.write("Waiting for worker health endpoint");
  for (let attempt = 0; attempt < HEALTH_ATTEMPTS; attempt += 1) {
    try {
      const response = await fetch(HEALTH_URL);
      if (response.ok) {
        console.log("\nWorker health endpoint ready");
        return;
      }
    } catch {
      // ignore until timeout
    }
    process.stdout.write(".");
    await delay(1_000);
  }
  console.log("");
  throw new Error("Worker health endpoint did not respond in time");
}

async function readGhToken(): Promise<string> {
  const result = await run("gh", ["auth", "token"], {
    capture: true,
    allowFailure: true,
  });
  if (result.code !== 0) {
    throw new Error(
      "GitHub auth token unavailable. Run `gh auth login` before using --pr.",
    );
  }
  return result.stdout.trim();
}

function assertValidPrUrl(prUrl: string): void {
  if (!/^https:\/\/github\.com\/[^/]+\/[^/]+\/pull\/\d+/.test(prUrl)) {
    throw new Error(
      "PR URL must match https://github.com/<owner>/<repo>/pull/<number>",
    );
  }
}

async function copyPrDescriptionIntoContainer(description: string): Promise<void> {
  if (!description) {
    return;
  }
  const tempDir = await mkdtemp(path.join(tmpdir(), "cmux-pr-"));
  const tempFile = path.join(tempDir, "pr-description.md");
  await writeFile(tempFile, description, "utf8");
  await run("docker", ["exec", CONTAINER_NAME, "bash", "-lc", "mkdir -p /root/workspace/.cmux"], {
    description: "Creating .cmux directory inside container...",
  });
  await run("docker", ["cp", tempFile, `${CONTAINER_NAME}:${WORKSPACE_PATH}/.cmux/pr-description.md`], {
    description: "Copying PR description into container...",
  });
  await run(
    "docker",
    ["exec", CONTAINER_NAME, "bash", "-lc", "chmod 600 /root/workspace/.cmux/pr-description.md"],
  );
  await rm(tempDir, { recursive: true, force: true });
  console.log("PR description copied into container for screenshot context.");
}

async function preparePr(prUrl: string): Promise<void> {
  assertValidPrUrl(prUrl);
  const ghToken = await readGhToken();
  console.log(`Preparing PR ${prUrl} in ${WORKSPACE_PATH}...`);

  const cloneScript = String.raw`set -euo pipefail

if [[ -z "\${GH_TOKEN:-}" ]]; then
  echo "GH_TOKEN not provided; cannot check out PR inside container" >&2
  exit 1
fi

if [[ -z "\${PR_URL:-}" ]]; then
  echo "PR_URL environment variable is required when cloning" >&2
  exit 1
fi

if [[ "$PR_URL" != https://github.com/*/pull/* ]]; then
  echo "PR URL must match https://github.com/<owner>/<repo>/pull/<number>" >&2
  exit 1
fi

REPO_URL="\${PR_URL%/pull/*}"
WORKTREE=${WORKSPACE_PATH}

rm -rf "$WORKTREE"
echo "Cloning $REPO_URL into $WORKTREE"
git clone "$REPO_URL" "$WORKTREE"
cd "$WORKTREE"
echo "Fetching PR branch via gh pr checkout..."
export GIT_TERMINAL_PROMPT=0
gh pr checkout "$PR_URL" >/dev/null
echo "Repository ready at $WORKTREE"`;

  await run(
    "docker",
    [
      "exec",
      "-e",
      `PR_URL=${prUrl}`,
      "-e",
      `GH_TOKEN=${ghToken}`,
      CONTAINER_NAME,
      "bash",
      "-lc",
      cloneScript,
    ],
    { description: "Cloning repository inside container..." },
  );

  const prDescriptionResult = await run(
    "gh",
    [
      "pr",
      "view",
      prUrl,
      "--json",
      "body",
      "--jq",
      '.body // ""',
    ],
    { capture: true, allowFailure: true },
  );

  if (prDescriptionResult.code !== 0) {
    console.warn("Unable to retrieve PR description; continuing without it.");
    return;
  }

  const description = prDescriptionResult.stdout.trim();
  if (description.length === 0) {
    return;
  }
  await copyPrDescriptionIntoContainer(description);
}

async function connectToWorkerSocket(): Promise<
  Socket<WorkerToServerEvents, ServerToWorkerEvents>
> {
  console.log("Connecting to worker management namespace...");
  return await new Promise((resolve, reject) => {
    const socket = connectToWorkerManagement({
      url: WORKER_BASE_URL,
      timeoutMs: 10_000,
      reconnectionAttempts: 0,
      forceNew: true,
    });
    socket.once("connect", () => {
      console.log("Connected to worker management socket.");
      resolve(socket);
    });
    socket.once("connect_error", (error) => {
      socket.disconnect();
      reject(error);
    });
  });
}

function logHelpfulUrls(): void {
  console.log("");
  console.log("================================ URLs =================================");
  console.log(
    `| ${"Worker Logs".padEnd(18)} | http://localhost:${VS_CODE_PORT}/?folder=/var/log/cmux |`,
  );
  console.log(
    `| ${"Workspace".padEnd(18)} | http://localhost:${VS_CODE_PORT}/?folder=${WORKSPACE_PATH} |`,
  );
  console.log(
    `| ${"VS Code".padEnd(18)} | http://localhost:${VS_CODE_PORT}/?folder=${WORKSPACE_PATH} |`,
  );
  console.log(
    `| ${"noVNC".padEnd(18)} | http://localhost:${NOVNC_PORT}/vnc.html |`,
  );
  console.log("========================================================================");
}

async function waitForUserIfNeeded(nonInteractive: boolean): Promise<void> {
  if (nonInteractive) {
    return;
  }
  if (process.stdin.isTTY) {
    console.log("");
    console.log(
      "Leave this script running while you inspect the worker. Press Enter when ready to stop the container.",
    );
    await new Promise<void>((resolve) => {
      process.stdin.setEncoding("utf8");
      process.stdin.resume();
      process.stdin.once("data", () => {
        process.stdin.pause();
        resolve();
      });
    });
  } else {
    console.log("");
    console.log(
      "Non-interactive shell detected; keeping the container alive for 5 minutes before cleanup.",
    );
    await delay(5 * 60 * 1_000);
  }
}

async function main(): Promise<void> {
  loadDotEnv();
  registerCleanup();

  const program = new Command()
    .name("docker-trigger-screenshot")
    .description("Start a local worker container and trigger screenshot collection.")
    .option("--pr <url>", "GitHub PR URL to clone inside the worker container")
    .option("--exec <command>", "Command to execute inside the worker container");

  program.parse();
  const options = program.opts<Options>();

  const anthropicApiKey = process.env.ANTHROPIC_API_KEY;
  if (!anthropicApiKey) {
    throw new Error(
      "ANTHROPIC_API_KEY not set. Add it to your environment or .env before running.",
    );
  }

  await ensureImageBuilt();
  await ensureContainerRemoved();
  await startContainer(anthropicApiKey);
  await delay(5_000);
  await waitForHealth();

  if (options.pr) {
    await preparePr(options.pr);
  }

  const socket = await connectToWorkerSocket();
  try {
    const payload: WorkerStartScreenshotCollection | undefined =
      anthropicApiKey.length > 0 ? { anthropicApiKey } : undefined;
    console.log("Triggering worker:start-screenshot-collection...");
    socket.emit("worker:start-screenshot-collection", payload);
    console.log(
      "Screenshot collection trigger sent. View logs via http://localhost:39378/?folder=/var/log/cmux",
    );
  } finally {
    socket.disconnect();
  }

  logHelpfulUrls();

  if (options.exec) {
    console.log(`Executing command inside container: ${options.exec}`);
    await run("docker", ["exec", CONTAINER_NAME, "bash", "-lc", options.exec], {
      description: "Running custom command...",
    });
  }

  const nonInteractive = Boolean(options.exec);
  await waitForUserIfNeeded(nonInteractive);
}

void main()
  .catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  })
  .finally(async () => {
    await cleanup();
  });
