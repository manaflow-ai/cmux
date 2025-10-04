import { spawnSync } from "node:child_process";

export type DockerStatus = "ok" | "not_installed" | "not_running";

type CheckDockerOptions = {
  maxWaitMs?: number;
  retryDelayMs?: number;
  infoTimeoutMs?: number;
  versionTimeoutMs?: number;
  onRetry?: (attempt: number, error: NodeJS.ErrnoException | null) => void;
};

const DEFAULT_OPTIONS: Required<Omit<CheckDockerOptions, "onRetry">> = {
  maxWaitMs: 12_000,
  retryDelayMs: 1_000,
  infoTimeoutMs: 5_000,
  versionTimeoutMs: 5_000,
};

const sleep = (ms: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));

function ensureDockerInstalled(versionTimeoutMs: number): DockerStatus | null {
  try {
    const version = spawnSync("docker", ["--version"], {
      stdio: "ignore",
      timeout: versionTimeoutMs,
    });

    if (version.error || version.status !== 0) {
      return "not_installed";
    }
  } catch {
    return "not_installed";
  }

  return null;
}

export async function checkDockerStatus(
  options: CheckDockerOptions = {}
): Promise<DockerStatus> {
  const {
    maxWaitMs,
    retryDelayMs,
    infoTimeoutMs,
    versionTimeoutMs,
  } = { ...DEFAULT_OPTIONS, ...options };

  const installedStatus = ensureDockerInstalled(versionTimeoutMs);
  if (installedStatus) {
    return installedStatus;
  }

  const start = Date.now();
  let attempt = 0;

  while (true) {
    const info = spawnSync("docker", ["info"], {
      stdio: "ignore",
      timeout: infoTimeoutMs,
    });

    if (!info.error && info.status === 0) {
      return "ok";
    }

    if (info.error && (info.error as NodeJS.ErrnoException).code === "ENOENT") {
      return "not_installed";
    }

    const elapsed = Date.now() - start;
    if (elapsed >= maxWaitMs) {
      return "not_running";
    }

    attempt += 1;
    options.onRetry?.(attempt, info.error as NodeJS.ErrnoException | null);

    const remaining = Math.max(0, maxWaitMs - elapsed);
    await sleep(Math.min(retryDelayMs, remaining));
  }
}
