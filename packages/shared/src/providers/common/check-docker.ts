import http from "node:http";
import { URL } from "node:url";
import { access } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

type DockerCheckResult = {
  isRunning: boolean;
  version?: string;
  error?: string;
  workerImage?: {
    name: string;
    isAvailable: boolean;
    isPulling?: boolean;
  };
};

type UnixSocketConfig = { kind: "unix"; socketPath: string };
type TcpConfig = { kind: "tcp"; host: string; port: number; protocol: "http" | "https" };
type DockerEndpoint = UnixSocketConfig | TcpConfig;

function parseDockerHostEnv(): DockerEndpoint | null {
  const raw = process.env.DOCKER_HOST?.trim();
  if (!raw) return null;
  try {
    // Normalize npipe on Windows (docker uses npipe:////./pipe/docker_engine)
    if (raw.startsWith("npipe://")) {
      // Node http supports named pipes via socketPath
      // Remove the "npipe:" scheme and ensure it starts with //./pipe/
      const pipePath = raw.replace(/^npipe:\/\//, "");
      return { kind: "unix", socketPath: pipePath };
    }

    if (raw.startsWith("unix://")) {
      const p = raw.replace("unix://", "");
      return { kind: "unix", socketPath: p };
    }

    // Fallback to URL parsing for tcp
    const u = new URL(raw.replace(/^tcp:\/\//, "http://"));
    const port = u.port ? Number(u.port) : 2375;
    return {
      kind: "tcp",
      host: u.hostname,
      port: Number.isFinite(port) ? port : 2375,
      protocol: (u.protocol.replace(":", "") as "http" | "https") ?? "http",
    };
  } catch {
    return null;
  }
}

async function fileExists(p: string): Promise<boolean> {
  try {
    await access(p);
    return true;
  } catch {
    return false;
  }
}

async function candidateDockerEndpoints(): Promise<DockerEndpoint[]> {
  const candidates: DockerEndpoint[] = [];

  const fromEnv = parseDockerHostEnv();
  if (fromEnv) candidates.push(fromEnv);

  if (process.platform === "win32") {
    candidates.push({ kind: "unix", socketPath: "//./pipe/docker_engine" });
  }

  // Standard Unix socket
  candidates.push({ kind: "unix", socketPath: "/var/run/docker.sock" });

  // Orbstack (macOS)
  const home = os.homedir();
  const orb = path.join(home, ".orbstack", "run", "docker.sock");
  if (await fileExists(orb)) {
    candidates.push({ kind: "unix", socketPath: orb });
  }

  // Rootless Docker (Linux)
  try {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const getuid = (process as any).getuid as (() => number) | undefined;
    const uid = typeof getuid === "function" ? getuid() : undefined;
    if (uid && uid > 0) {
      const rootless = path.join("/run/user", String(uid), "docker.sock");
      if (await fileExists(rootless)) {
        candidates.push({ kind: "unix", socketPath: rootless });
      }
    }
  } catch {
    // ignore
  }

  return candidates;
}

function httpGet(
  endpoint: DockerEndpoint,
  pathName: string,
  timeoutMs: number
): Promise<{ statusCode: number; body: string }> {
  return new Promise((resolve, reject) => {
    const options: http.RequestOptions = endpoint.kind === "unix"
      ? { socketPath: endpoint.socketPath, path: pathName, method: "GET" }
      : { host: endpoint.host, port: endpoint.port, path: pathName, method: "GET" };

    const req = http.request(options, (res) => {
      const chunks: Buffer[] = [];
      res.on("data", (c) => chunks.push(Buffer.isBuffer(c) ? c : Buffer.from(c)));
      res.on("end", () => {
        const body = Buffer.concat(chunks).toString("utf8");
        resolve({ statusCode: res.statusCode ?? 0, body });
      });
    });
    req.on("error", (err) => reject(err));
    req.setTimeout(timeoutMs, () => {
      try {
        req.destroy(new Error("Request timeout"));
      } catch {
        // ignore
      }
    });
    req.end();
  });
}

async function tryEndpoint(endpoint: DockerEndpoint): Promise<DockerCheckResult> {
  try {
    // Check daemon readiness
    const ping = await httpGet(endpoint, "/_ping", 1000);
    if (ping.statusCode !== 200) {
      return { isRunning: false, error: `Ping failed: ${ping.statusCode}` };
    }

    // Get version
    const ver = await httpGet(endpoint, "/version", 1500);
    let version: string | undefined;
    try {
      const parsed = JSON.parse(ver.body) as { Version?: string };
      version = parsed?.Version ?? undefined;
    } catch {
      version = undefined;
    }

    const result: DockerCheckResult = { isRunning: true, version };

    // Check worker image availability via HTTP API if we can
    const imageName = process.env.WORKER_IMAGE_NAME || "cmux-worker:0.0.1";
    if (imageName) {
      try {
        const img = await httpGet(
          endpoint,
          `/images/${encodeURIComponent(imageName)}/json`,
          1500
        );
        if (img.statusCode === 200) {
          result.workerImage = { name: imageName, isAvailable: true };
        } else if (img.statusCode === 404) {
          result.workerImage = {
            name: imageName,
            isAvailable: false,
            isPulling: false,
          };
        }
      } catch {
        // Ignore image check errors; keep core status
      }
    }

    return result;
  } catch (err) {
    return {
      isRunning: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function checkDockerStatus(): Promise<DockerCheckResult> {
  const endpoints = await candidateDockerEndpoints();
  for (const ep of endpoints) {
    const res = await tryEndpoint(ep);
    if (res.isRunning) return res;
  }
  // If none succeeded, return the last error or a generic message
  return {
    isRunning: false,
    error: "Docker is not running or not reachable",
  };
}
