import { exec as childProcessExec } from "node:child_process";
import { constants as fsConstants, existsSync } from "node:fs";
import { access } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";

const execAsync = promisify(childProcessExec);

const DOCKER_INFO_COMMAND = "docker info --format '{{json .ServerVersion}}'";
const DOCKER_VERSION_COMMAND = "docker version --format '{{.Server.Version}}'";

export interface DockerSocketCandidates {
  remoteHost: boolean;
  candidates: string[];
}

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

function getDockerSocketPath(): string | null {
  const { remoteHost, candidates } = getDockerSocketCandidates();
  if (remoteHost) {
    return null;
  }

  return candidates[0] ?? null;
}

function delay(ms: number): Promise<void> {
  return new Promise((resolve) => {
    setTimeout(resolve, ms);
  });
}

function hasCode(error: unknown): error is { code: unknown } {
  return error !== null && typeof error === "object" && "code" in error;
}

function isRetryableDockerError(error: unknown): boolean {
  if (hasCode(error) && error.code === "ENOENT") {
    return false;
  }

  const message = describeExecError(error);
  const lower = message.toLowerCase();
  return (
    lower.includes("cannot connect to the docker daemon") ||
    lower.includes("is the docker daemon running") ||
    lower.includes("connection refused") ||
    lower.includes("bad file descriptor") ||
    lower.includes("dial unix") ||
    lower.includes("context deadline exceeded") ||
    lower.includes("no such host")
  );
}

function hasStderr(error: unknown): error is { stderr: unknown } {
  return error !== null && typeof error === "object" && "stderr" in error;
}

function hasMessage(error: unknown): error is { message: unknown } {
  return error !== null && typeof error === "object" && "message" in error;
}

function describeExecError(error: unknown): string {
  if (!error) {
    return "Unknown error";
  }

  if (typeof error === "string") {
    return error;
  }

  if (hasStderr(error)) {
    const { stderr } = error;
    if (typeof stderr === "string" && stderr.trim()) {
      return stderr.trim();
    }
    if (stderr instanceof Buffer) {
      const text = stderr.toString().trim();
      if (text) {
        return text;
      }
    }
  }

  if (hasMessage(error)) {
    const { message } = error;
    if (typeof message === "string" && message.trim()) {
      return message.trim();
    }
  }

  if (error instanceof Error) {
    return error.message;
  }

  return "Unknown error";
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

async function dockerSocketExists(): Promise<{
  accessible: boolean;
  path?: string;
  candidates: string[];
  remoteHost: boolean;
}> {
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

export async function ensureDockerDaemonReady(options?: {
  attempts?: number;
  delayMs?: number;
}): Promise<{
  ready: boolean;
  version?: string;
  error?: string;
}> {
  const attempts = options?.attempts ?? 6;
  const delayMs = options?.delayMs ?? 500;

  let version: string | undefined;
  let lastError: string | undefined;

  for (let attempt = 0; attempt < attempts; attempt += 1) {
    try {
      const { stdout } = await execAsync(DOCKER_INFO_COMMAND);
      version = parseVersion(stdout);
      return { ready: true, version };
    } catch (error) {
      lastError = describeExecError(error);
      if (!isRetryableDockerError(error) || attempt === attempts - 1) {
        return {
          ready: false,
          version,
          error: lastError,
        };
      }
      await delay(delayMs);
    }
  }

  return {
    ready: false,
    version,
    error: lastError,
  };
}

export async function checkDockerStatus(): Promise<{
  isRunning: boolean;
  version?: string;
  error?: string;
  workerImage?: {
    name: string;
    isAvailable: boolean;
    isPulling?: boolean;
  };
}> {
  try {
    // Ensure Docker CLI is installed
    await execAsync("docker --version");
  } catch (error) {
    return {
      isRunning: false,
      error:
        describeExecError(error) ||
        "Docker is not installed or not available in PATH",
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
      error:
        readiness.error || "Docker daemon is not running or not accessible",
    };
  }

  try {
    await execAsync("docker ps");
  } catch (error) {
    if (!isRetryableDockerError(error)) {
      return {
        isRunning: false,
        error:
          describeExecError(error) ||
          "Docker daemon is not responding to commands",
      };
    }

    const retry = await ensureDockerDaemonReady({ attempts: 3, delayMs: 500 });
    if (!retry.ready) {
      return {
        isRunning: false,
        error:
          retry.error || "Docker daemon is not responding to commands",
      };
    }

    try {
      await execAsync("docker ps");
    } catch (retryError) {
      return {
        isRunning: false,
        error:
          describeExecError(retryError) ||
          "Docker daemon is not responding to commands",
      };
    }
  }

  const result: {
    isRunning: boolean;
    version?: string;
    workerImage?: {
      name: string;
      isAvailable: boolean;
      isPulling?: boolean;
    };
  } = {
    isRunning: true,
    version: readiness.version,
  };

  if (!result.version) {
    try {
      const { stdout } = await execAsync(DOCKER_VERSION_COMMAND);
      result.version = parseVersion(stdout);
    } catch {
      // Ignore failure to parse version
    }
  }

  const imageName = process.env.WORKER_IMAGE_NAME || "cmux-worker:0.0.1";

  if (imageName) {
    try {
      await execAsync(`docker image inspect "${imageName.replace(/"/g, '\\"')}"`);
      result.workerImage = {
        name: imageName,
        isAvailable: true,
      };
    } catch (error) {
      const errorMessage = describeExecError(error);
      if (errorMessage.toLowerCase().includes("no such image")) {
        result.workerImage = {
          name: imageName,
          isAvailable: false,
          isPulling: false,
        };
      } else {
        try {
          const { stdout } = await execAsync(
            "docker ps -a --format '{{.Command}}'"
          );
          const isPulling = stdout.includes("pull ") && stdout.includes(imageName);

          result.workerImage = {
            name: imageName,
            isAvailable: false,
            isPulling,
          };
        } catch {
          result.workerImage = {
            name: imageName,
            isAvailable: false,
            isPulling: false,
          };
        }
      }
    }
  }

  return result;
}
