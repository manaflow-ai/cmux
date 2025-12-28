import { exec as childProcessExec } from "node:child_process";
import { constants as fsConstants, existsSync } from "node:fs";
import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import type { DockerStatus } from "../../socket-schemas";

const execAsync = promisify(childProcessExec);

const DOCKER_BINARY_NAME = process.platform === "win32" ? "docker.exe" : "docker";
const PATH_DELIMITER = process.platform === "win32" ? ";" : ":";

const DOCKER_INFO_COMMAND = "docker info --format '{{json .ServerVersion}}'";
const DOCKER_VERSION_COMMAND = "docker version --format '{{.Server.Version}}'";

interface ExecError extends Error {
  code?: string | number;
  stderr?: string | Buffer;
  stdout?: string | Buffer;
}

export interface DockerSocketCandidates {
  remoteHost: boolean;
  candidates: string[];
}

interface DockerSocketStatus {
  accessible: boolean;
  path?: string;
  candidates: string[];
  remoteHost: boolean;
}

export interface DockerDaemonReadiness {
  ready: boolean;
  version?: string;
  error?: string;
}

function normalizePathSegment(segment: string): string {
  const trimmed = segment.trim();

  if (process.platform === "win32") {
    return trimmed.replace(/\\+/g, "\\").toLowerCase();
  }

  if (trimmed === "/") {
    return trimmed;
  }

  return trimmed.replace(/\/+$/u, "");
}

function getDockerBinaryDirectoryCandidates(): string[] {
  const candidates = new Set<string>();

  const macOsCandidates = [
    "/usr/local/bin",
    "/opt/homebrew/bin",
    "/Applications/Docker.app/Contents/Resources/bin",
  ];

  const linuxCandidates = [
    "/usr/local/bin",
    "/usr/bin",
    "/snap/bin",
  ];

  const windowsCandidates = [
    "C:/Program Files/Docker/Docker/resources/bin",
    "C:/Program Files/Docker/Docker",
  ];

  for (const pathValue of (process.env.DOCKER_EXTRA_PATHS ?? "").split(PATH_DELIMITER)) {
    const trimmed = pathValue.trim();
    if (trimmed) {
      candidates.add(trimmed);
    }
  }

  const platformCandidates = process.platform === "darwin"
    ? macOsCandidates
    : process.platform === "win32"
      ? windowsCandidates
      : linuxCandidates;

  for (const candidate of platformCandidates) {
    candidates.add(candidate);
  }

  return Array.from(candidates);
}

export function ensureDockerBinaryInPath(): void {
  const currentPath = process.env.PATH ?? "";
  const parts = currentPath.split(PATH_DELIMITER).filter(Boolean);
  const seen = new Set(parts.map(normalizePathSegment));
  const additions: string[] = [];

  for (const directory of getDockerBinaryDirectoryCandidates()) {
    const binaryPath = join(directory, DOCKER_BINARY_NAME);
    if (!existsSync(binaryPath)) {
      continue;
    }

    const normalizedDirectory = normalizePathSegment(directory);
    if (seen.has(normalizedDirectory)) {
      continue;
    }

    additions.push(directory);
    seen.add(normalizedDirectory);
  }

  if (additions.length === 0) {
    return;
  }

  const updatedPath = [...additions, ...parts].join(PATH_DELIMITER);
  process.env.PATH = updatedPath;

  if (process.platform === "win32") {
    process.env.Path = updatedPath;
  }
}

ensureDockerBinaryInPath();

function collectDefaultSocketCandidates(): string[] {
  const defaults = new Set<string>([
    "/var/run/docker.sock",
    "/private/var/run/docker.sock",
  ]);
  const home = homedir();
  if (home) {
    defaults.add(join(home, ".docker/run/docker.sock"));
    if (process.platform === "darwin") {
      defaults.add(
        join(home, "Library/Containers/com.docker.docker/Data/docker.sock"),
      );
      defaults.add(
        join(home, "Library/Containers/com.docker.docker/Data/docker-api.sock"),
      );
      defaults.add(
        join(home, "Library/Containers/com.docker.docker/Data/docker.raw.sock"),
      );
    }
  }

  const existing: string[] = [];
  const missing: string[] = [];
  defaults.forEach((candidate) => {
    if (existsSync(candidate)) {
      existing.push(candidate);
    } else {
      missing.push(candidate);
    }
  });

  return [...existing, ...missing];
}

export function getDockerSocketCandidates(): DockerSocketCandidates {
  const explicitSocket = process.env.DOCKER_SOCKET;
  if (explicitSocket) {
    return { remoteHost: false, candidates: [explicitSocket] };
  }

  const dockerHost = process.env.DOCKER_HOST;
  if (dockerHost) {
    if (dockerHost.startsWith("unix://")) {
      return {
        remoteHost: false,
        candidates: [dockerHost.replace("unix://", "")],
      };
    }

    return { remoteHost: true, candidates: [] };
  }

  return {
    remoteHost: false,
    candidates: collectDefaultSocketCandidates(),
  };
}

function isExecError(error: unknown): error is ExecError {
  return error instanceof Error;
}

function describeExecError(error: unknown): string {
  if (!error) {
    return "Unknown error";
  }

  if (typeof error === "string") {
    return error;
  }

  if (!isExecError(error)) {
    return "Unknown error";
  }

  const { stderr, message } = error;

  if (stderr) {
    const text = typeof stderr === "string"
      ? stderr.trim()
      : stderr.toString().trim();
    if (text) {
      return text;
    }
  }

  return message.trim() || "Unknown error";
}

function parseVersion(output: string): string | undefined {
  const trimmed = output.trim();
  if (trimmed.length === 0) {
    return undefined;
  }
  try {
    const parsed = JSON.parse(trimmed);
    if (typeof parsed === "string") {
      return parsed;
    }
  } catch {
    // Fallback to raw trimmed output
  }
  return trimmed;
}

async function dockerSocketExists(): Promise<DockerSocketStatus> {
  const { remoteHost, candidates } = getDockerSocketCandidates();
  if (remoteHost) {
    return { accessible: true, remoteHost, candidates };
  }

  for (const candidate of candidates) {
    try {
      await access(candidate, fsConstants.F_OK);
      return {
        accessible: true,
        path: candidate,
        candidates,
        remoteHost: false,
      };
    } catch {
      // continue checking remaining candidates
    }
  }

  return { accessible: false, candidates, remoteHost: false };
}

export async function ensureDockerDaemonReady(): Promise<DockerDaemonReadiness> {
  try {
    const { stdout } = await execAsync(DOCKER_INFO_COMMAND);
    const version = parseVersion(stdout);
    return { ready: true, version };
  } catch (error) {
    return {
      ready: false,
      error: describeExecError(error),
    };
  }
}

export async function checkDockerStatus(): Promise<DockerStatus> {
  try {
    // Ensure Docker CLI is installed
    await execAsync("docker --version");
  } catch (error) {
    return {
      isRunning: false,
      error: describeExecError(error),
    };
  }

  const socketCheck = await dockerSocketExists();
  if (!socketCheck.accessible) {
    const attempted = socketCheck.candidates;
    const attemptedMessage =
      attempted.length > 0
        ? `Docker socket not accessible. Checked: ${attempted.join(", ")}`
        : "Docker socket not accessible";

    return {
      isRunning: false,
      error: attemptedMessage,
    };
  }

  const readiness = await ensureDockerDaemonReady();
  if (!readiness.ready) {
    return {
      isRunning: false,
      error: readiness.error ?? "Docker daemon is not running or not accessible",
    };
  }

  try {
    await execAsync("docker ps");
  } catch (error) {
    return {
      isRunning: false,
      error: describeExecError(error),
    };
  }

  let version = readiness.version;
  if (!version) {
    try {
      const { stdout } = await execAsync(DOCKER_VERSION_COMMAND);
      version = parseVersion(stdout);
    } catch {
      // Ignore failure to parse version
    }
  }

  const imageName = process.env.WORKER_IMAGE_NAME ?? "ghcr.io/manaflow-ai/cmux:latest";

  try {
    await execAsync(`docker image inspect "${imageName.replace(/"/g, '\\"')}"`);
    return {
      isRunning: true,
      version,
      workerImage: {
        name: imageName,
        isAvailable: true,
      },
    };
  } catch (error) {
    const errorMessage = describeExecError(error);
    if (errorMessage.toLowerCase().includes("no such image")) {
      return {
        isRunning: true,
        version,
        workerImage: {
          name: imageName,
          isAvailable: false,
          isPulling: false,
        },
      };
    }

    try {
      const { stdout } = await execAsync(
        "docker ps -a --format '{{.Command}}'"
      );
      const isPulling = stdout.includes("pull ") && stdout.includes(imageName);

      return {
        isRunning: true,
        version,
        workerImage: {
          name: imageName,
          isAvailable: false,
          isPulling,
        },
      };
    } catch {
      return {
        isRunning: true,
        version,
        workerImage: {
          name: imageName,
          isAvailable: false,
          isPulling: false,
        },
      };
    }
  }
}
