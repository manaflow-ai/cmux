import { Daytona, type Sandbox, type SandboxState } from "@daytonaio/sdk";
import { randomBytes } from "node:crypto";
import {
  ProviderError,
  type AttachEndpoint,
  type AttachOptions,
  type CreateOptions,
  type ExecResult,
  type SSHEndpoint,
  type WebSocketPtyEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
  type VMStatus,
} from "./types";
import { recordSpanError, setSpanAttributes, withVmSpan } from "../telemetry";
import {
  isReusableRpcLease,
  ensurePrivateDirectoryCommand,
  leaseClientMetadata,
  makeWebSocketAttachmentId,
  makeWebSocketLease,
  shellArgValue,
  shellQuote,
  type ReusableRpcLease,
} from "./wsLease";

// Daytona sandboxes are reached exclusively through preview URLs
// (`https://7777-<sandboxId>.<proxyDomain>` + `x-daytona-preview-token` header), so the attach
// path is cmuxd-remote WebSocket PTY only. Daytona also has a token-based SSH gateway, but we
// deliberately do not use it (unreliable in practice), so `openSSH` throws like the E2B driver.
const CMUXD_WS_PORT = 7777;
const CMUXD_WS_PTY_LEASE_PATH = "/tmp/cmux/attach-pty-lease.json";
const CMUXD_WS_LEGACY_PTY_LEASE_PATH = "/tmp/cmux/attach-lease.json";
const CMUXD_WS_RPC_LEASE_PATH = "/tmp/cmux/attach-rpc-lease.json";
const CMUXD_WS_RPC_CLIENT_PATH = "/tmp/cmux/attach-rpc-client.json";
const CMUXD_WS_PTY_LEASE_TTL_SECONDS = 5 * 60;
const CMUXD_WS_RPC_LEASE_TTL_SECONDS = 12 * 60 * 60;
const CMUXD_WS_RPC_RENEW_BEFORE_SECONDS = 60;
const CMUX_CLOUD_SHELL_PATH = "/usr/local/bin/cmux-cloud-shell";
const DEFAULT_SANDBOX_ENVS = { LANG: "C.UTF-8" };

const CREATE_TIMEOUT_SECONDS = 15 * 60;
const LIFECYCLE_TIMEOUT_SECONDS = 5 * 60;
const SNAPSHOT_TIMEOUT_SECONDS = 15 * 60;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;
const HEALTH_CHECK_TIMEOUT_MS = 10_000;
const HEALTH_RETRY_ATTEMPTS = 12;
const HEALTH_RETRY_INTERVAL_MS = 1_000;

function client(): Daytona {
  // The SDK reads DAYTONA_API_KEY/DAYTONA_API_URL itself; pass them explicitly so the override
  // surface is visible here. apiUrl defaults to https://app.daytona.io/api when unset.
  return new Daytona({
    apiKey: process.env.DAYTONA_API_KEY,
    apiUrl: process.env.DAYTONA_API_URL,
  });
}

function normalizeExecTimeout(timeoutMs: number | undefined): number {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return EXEC_DEFAULT_TIMEOUT_MS;
  }
  return Math.min(Math.floor(timeoutMs), MAX_EXEC_TIMEOUT_MS);
}

function mapStatus(state: SandboxState | null | undefined): VMStatus {
  switch (state) {
    case "creating":
    case "restoring":
    case "starting":
    case "resuming":
    case "pulling_snapshot":
    case "pending_build":
    case "building_snapshot":
      return "creating";
    case "started":
    case "snapshotting":
    case "forking":
    case "resizing":
      return "running";
    case "stopping":
    case "stopped":
    case "pausing":
    case "paused":
    case "archiving":
    case "archived":
      return "paused";
    case "destroying":
    case "destroyed":
      return "destroyed";
    default:
      return "running";
  }
}

export class DaytonaProvider implements VMProvider {
  readonly id = "daytona" as const;

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("daytona", "create requires a resolved image");
    }
    return withVmSpan(
      "cmux.vm.provider.create",
      {
        "cmux.vm.provider": "daytona",
        "cmux.vm.operation": "create",
        "cmux.vm.image": image,
        "cmux.timeout_ms": CREATE_TIMEOUT_SECONDS * 1000,
      },
      async (span) => {
        try {
          const sandbox = await client().create(
            {
              snapshot: image,
              envVars: DEFAULT_SANDBOX_ENVS,
              // Persistent cloud computer shape: never auto-stop. Pause/resume is an explicit
              // cmux workflow, mapped onto Daytona stop/start below.
              autoStopInterval: 0,
            },
            { timeout: CREATE_TIMEOUT_SECONDS },
          );
          setSpanAttributes(span, { "cmux.vm.id": sandbox.id });
          return {
            provider: "daytona",
            providerVmId: sandbox.id,
            status: "running",
            image,
            createdAt: Date.now(),
          };
        } catch (err) {
          throw new ProviderError("daytona", `create(${image})`, err);
        }
      },
    );
  }

  async destroy(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.destroy",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "destroy", "cmux.vm.id": vmId },
      async () => {
        try {
          const sandbox = await client().get(vmId);
          await sandbox.delete(LIFECYCLE_TIMEOUT_SECONDS);
        } catch (err) {
          throw new ProviderError("daytona", `destroy(${vmId})`, err);
        }
      },
    );
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    return withVmSpan(
      "cmux.vm.provider.get_status",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "get_status", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await client().get(vmId);
          const status = mapStatus(sandbox.state);
          setSpanAttributes(span, {
            "cmux.vm.provider_state": sandbox.state ?? "unknown",
            "cmux.vm.status": status,
          });
          return status;
        } catch (err) {
          throw new ProviderError("daytona", `getStatus(${vmId})`, err);
        }
      },
    );
  }

  // Daytona "stop" preserves the filesystem but kills processes (container-class sandbox), which
  // is the pause semantics cmux exposes. Daytona's own memory-freeze `pause()` is not used.
  async pause(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.pause",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "pause", "cmux.vm.id": vmId },
      async () => {
        try {
          const sandbox = await client().get(vmId);
          await sandbox.stop(LIFECYCLE_TIMEOUT_SECONDS);
        } catch (err) {
          throw new ProviderError("daytona", `pause(${vmId})`, err);
        }
      },
    );
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "resume", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await client().get(vmId);
          await sandbox.start(LIFECYCLE_TIMEOUT_SECONDS);
          // Stop killed cmuxd-remote; the image entrypoint restarts it on start, but repair
          // best-effort here so the first attach after resume doesn't race the entrypoint.
          try {
            await this.ensureWebSocketHealthyOrRepair(sandbox);
          } catch (healthErr) {
            recordSpanError(span, healthErr);
          }
          return {
            provider: "daytona",
            providerVmId: sandbox.id,
            status: "running",
            image: sandbox.snapshot ?? "daytona:resumed",
            createdAt: Date.now(),
          };
        } catch (err) {
          throw new ProviderError("daytona", `resume(${vmId})`, err);
        }
      },
    );
  }

  async exec(vmId: string, command: string, opts?: { timeoutMs?: number }): Promise<ExecResult> {
    const timeoutMs = normalizeExecTimeout(opts?.timeoutMs);
    return withVmSpan(
      "cmux.vm.provider.exec",
      {
        "cmux.vm.provider": "daytona",
        "cmux.vm.operation": "exec",
        "cmux.vm.id": vmId,
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      },
      async (span) => {
        try {
          const sandbox = await client().get(vmId);
          const r = await sandbox.process.executeCommand(
            command,
            undefined,
            undefined,
            Math.ceil(timeoutMs / 1000),
          );
          setSpanAttributes(span, { "cmux.exec.exit_code": r.exitCode });
          // The Daytona toolbox merges stderr into `result`; there is no separate stderr stream.
          return { exitCode: r.exitCode, stdout: r.result ?? "", stderr: "" };
        } catch (err) {
          throw new ProviderError("daytona", `exec(${vmId})`, err);
        }
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    return withVmSpan(
      "cmux.vm.provider.snapshot",
      {
        "cmux.vm.provider": "daytona",
        "cmux.vm.operation": "snapshot",
        "cmux.vm.id": vmId,
        "cmux.snapshot.named": !!name,
        "cmux.timeout_ms": SNAPSHOT_TIMEOUT_SECONDS * 1000,
      },
      async (span) => {
        try {
          const sandbox = await client().get(vmId);
          // Daytona snapshots are addressed by name; mint a unique one when the caller didn't
          // pick a name so repeat snapshots of the same VM don't collide.
          const snapshotName = name?.trim() || `cmux-daytona-${randomBytes(8).toString("hex")}`;
          await sandbox._experimental_createSnapshot(snapshotName, SNAPSHOT_TIMEOUT_SECONDS);
          setSpanAttributes(span, { "cmux.snapshot.id": snapshotName });
          return { id: snapshotName, createdAt: Date.now(), name };
        } catch (err) {
          throw new ProviderError("daytona", `snapshot(${vmId})`, err);
        }
      },
    );
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.restore",
      {
        "cmux.vm.provider": "daytona",
        "cmux.vm.operation": "restore",
        "cmux.snapshot.id": snapshotId,
        "cmux.timeout_ms": CREATE_TIMEOUT_SECONDS * 1000,
      },
      async (span) => {
        try {
          const sandbox = await client().create(
            {
              snapshot: snapshotId,
              envVars: DEFAULT_SANDBOX_ENVS,
              autoStopInterval: 0,
            },
            { timeout: CREATE_TIMEOUT_SECONDS },
          );
          setSpanAttributes(span, { "cmux.vm.id": sandbox.id });
          return {
            provider: "daytona",
            providerVmId: sandbox.id,
            status: "running",
            image: snapshotId,
            createdAt: Date.now(),
          };
        } catch (err) {
          throw new ProviderError("daytona", `restore(${snapshotId})`, err);
        }
      },
    );
  }

  async deleteSnapshot(snapshotId: string): Promise<void> {
    await withVmSpan(
      "cmux.vm.provider.delete_snapshot",
      {
        "cmux.vm.provider": "daytona",
        "cmux.vm.operation": "delete_snapshot",
        "cmux.snapshot.id": snapshotId,
      },
      async () => {
        try {
          const daytona = client();
          const snapshot = await daytona.snapshot.get(snapshotId);
          await daytona.snapshot.delete(snapshot);
        } catch (err) {
          throw new ProviderError("daytona", `deleteSnapshot(${snapshotId})`, err);
        }
      },
    );
  }

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "open_ssh", "cmux.vm.id": vmId },
      async () => {
        // Daytona attach is WebSocket-only in cmux. Daytona does offer a token-based SSH
        // gateway, but we deliberately don't dial it, so there is no SSH endpoint to mint.
        // `cmux vm ssh`/`attach` still work through the WebSocket PTY path above.
        throw new ProviderError(
          "daytona",
          "Daytona attach is WebSocket-only; cmux does not use Daytona's SSH gateway. " +
            "`cmux vm ssh <id>` and `cmux vm attach <id>` dial the WebSocket PTY instead. " +
            "For provider SSH info, use `cmux vm new` without `--provider daytona` " +
            "(Freestyle is the default).",
        );
      },
    );
  }

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    const endpoint = await this.openWebSocketPty(vmId, options);
    if (options?.requireDaemon && !endpoint.daemon) {
      throw new ProviderError(
        "daytona",
        `openAttach(${vmId}) requires a cmuxd RPC endpoint, but this sandbox image only exposes the PTY WebSocket. Rebuild it with the current cmuxd-remote image.`,
      );
    }
    return endpoint;
  }

  async openWebSocketPty(vmId: string, options?: AttachOptions): Promise<WebSocketPtyEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_websocket_pty",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "open_websocket_pty", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await client().get(vmId);
          // Preview tokens are invalidated when a sandbox restarts, so mint a fresh link per
          // attach instead of caching one alongside the lease.
          const preview = await this.ensureWebSocketHealthyOrRepair(sandbox);
          const headers = { "x-daytona-preview-token": preview.token };
          const wsBase = httpsToWss(preview.url);
          const pty = makeWebSocketLease("daytona", "pty", true, CMUXD_WS_PTY_LEASE_TTL_SECONDS, options?.sessionId);
          const attachmentId = options?.attachmentId?.trim() || makeWebSocketAttachmentId("daytona");
          const service = await readDaytonaWebSocketService(sandbox);
          const encodedPTY = Buffer.from(JSON.stringify(pty.lease)).toString("base64");
          const commands = [
            ensurePrivateDirectoryCommand(service.ptyLeasePath),
            `printf '%s' '${encodedPTY}' | base64 -d > ${shellQuote(service.ptyLeasePath)}`,
            `chmod 600 ${shellQuote(service.ptyLeasePath)}`,
          ];
          let daemon: ReusableRpcLease | null = null;
          let daemonReused = false;
          if (service.rpcLeasePath) {
            const existingDaemon = await readReusableRpcLease(sandbox, service.rpcLeasePath);
            const newDaemon = existingDaemon
              ? null
              : makeWebSocketLease("daytona", "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
            daemon = existingDaemon ?? newDaemon!;
            daemonReused = !!existingDaemon;
            if (newDaemon) {
              const encodedDaemon = Buffer.from(JSON.stringify(newDaemon.lease)).toString("base64");
              const encodedDaemonClient = Buffer.from(JSON.stringify(leaseClientMetadata(newDaemon))).toString("base64");
              commands.push(
                ensurePrivateDirectoryCommand(service.rpcLeasePath),
                `printf '%s' '${encodedDaemon}' | base64 -d > ${shellQuote(service.rpcLeasePath)}`,
                `chmod 600 ${shellQuote(service.rpcLeasePath)}`,
                `printf '%s' '${encodedDaemonClient}' | base64 -d > ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
                `chmod 600 ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
              );
            }
          }
          await execDaytonaOrThrow(sandbox, commands.join(" && "));
          span.setAttribute("cmux.vm.attach.transport", "websocket");
          span.setAttribute("cmux.vm.attach.expires_at_unix", pty.expiresAtUnix);
          span.setAttribute("cmux.vm.attach.daemon_available", !!daemon);
          if (daemon) {
            span.setAttribute("cmux.vm.attach.daemon_expires_at_unix", daemon.expiresAtUnix);
            span.setAttribute("cmux.vm.attach.daemon_reused", daemonReused);
          }
          return {
            transport: "websocket",
            url: `${wsBase}/terminal`,
            headers,
            token: pty.token,
            sessionId: pty.sessionId,
            attachmentId,
            expiresAtUnix: pty.expiresAtUnix,
            daemon: daemon ? {
              url: `${wsBase}/rpc`,
              headers,
              token: daemon.token,
              sessionId: daemon.sessionId,
              expiresAtUnix: daemon.expiresAtUnix,
            } : undefined,
          };
        } catch (err) {
          throw new ProviderError("daytona", `openWebSocketPty(${vmId})`, err);
        }
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // Daytona doesn't mint per-session SSH credentials here — openSSH always throws — so
    // there's nothing to revoke. Defined to satisfy VMProvider; never called against this driver.
  }

  /**
   * Checks cmuxd-remote through the preview URL and, if it's down (fresh stop/start races the
   * entrypoint, or the process died), restarts it via toolbox exec and waits for /healthz.
   * Returns the preview link so attach reuses the same URL + token it just verified.
   */
  private async ensureWebSocketHealthyOrRepair(sandbox: Sandbox): Promise<{ url: string; token: string }> {
    const preview = await sandbox.getPreviewLink(CMUXD_WS_PORT);
    const previewToken = preview.token?.trim() ?? "";
    if (await isDaytonaWebSocketHealthy(preview.url, previewToken)) {
      return { url: preview.url, token: previewToken };
    }
    await execDaytonaOrThrow(sandbox, daytonaWebSocketRepairCommand(), 60_000);
    let lastError: unknown = new Error("Daytona cmuxd websocket did not become healthy");
    for (let attempt = 0; attempt < HEALTH_RETRY_ATTEMPTS; attempt += 1) {
      try {
        await ensureDaytonaWebSocketHealthy(preview.url, previewToken);
        return { url: preview.url, token: previewToken };
      } catch (err) {
        lastError = err;
        await new Promise((resolve) => setTimeout(resolve, HEALTH_RETRY_INTERVAL_MS));
      }
    }
    throw lastError;
  }
}

function httpsToWss(url: string): string {
  return url.replace(/^https:/, "wss:").replace(/\/+$/, "");
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function daytonaWebSocketRepairCommand(): string {
  // The image entrypoint (`cmux-daytona-entrypoint`) normally keeps cmuxd-remote alive; this is
  // the fallback when the daemon isn't up yet (or the sandbox predates the entrypoint script).
  const serve = [
    "/usr/local/bin/cmuxd-remote",
    "serve",
    "--ws",
    "--listen",
    `0.0.0.0:${CMUXD_WS_PORT}`,
    "--auth-lease-file",
    CMUXD_WS_PTY_LEASE_PATH,
    "--rpc-auth-lease-file",
    CMUXD_WS_RPC_LEASE_PATH,
    "--shell",
    CMUX_CLOUD_SHELL_PATH,
  ].map(shellQuote).join(" ");
  return [
    "mkdir -p /tmp/cmux",
    "chmod 700 /tmp/cmux",
    `pgrep -f 'cmuxd-remote serve' >/dev/null 2>&1 || (setsid nohup ${serve} >>/tmp/cmux/cmuxd-ws.log 2>&1 &)`,
  ].join(" && ");
}

async function isDaytonaWebSocketHealthy(previewUrl: string, previewToken: string): Promise<boolean> {
  try {
    await ensureDaytonaWebSocketHealthy(previewUrl, previewToken);
    return true;
  } catch {
    return false;
  }
}

async function ensureDaytonaWebSocketHealthy(previewUrl: string, previewToken: string): Promise<void> {
  const response = await fetch(`${previewUrl.replace(/\/+$/, "")}/healthz`, {
    headers: previewToken ? { "x-daytona-preview-token": previewToken } : {},
    signal: AbortSignal.timeout(HEALTH_CHECK_TIMEOUT_MS),
  }).catch((err: unknown) => {
    throw new Error(`Daytona cmuxd websocket health check failed: ${errorMessage(err)}`);
  });
  if (response.status !== 200) {
    throw new Error(`Daytona cmuxd websocket health check returned ${response.status}`);
  }
}

async function readDaytonaWebSocketService(sandbox: Sandbox): Promise<{
  ptyLeasePath: string;
  rpcLeasePath: string | null;
}> {
  const result = await execDaytonaOrThrow(
    sandbox,
    "ps auxww | grep cmuxd-remote | grep -v grep || true",
  );
  const stdout = result.result ?? "";
  return {
    ptyLeasePath:
      shellArgValue(stdout, "--auth-lease-file")
      ?? (stdout.includes(CMUXD_WS_LEGACY_PTY_LEASE_PATH)
        ? CMUXD_WS_LEGACY_PTY_LEASE_PATH
        : CMUXD_WS_PTY_LEASE_PATH),
    rpcLeasePath: shellArgValue(stdout, "--rpc-auth-lease-file"),
  };
}

async function readReusableRpcLease(
  sandbox: Sandbox,
  rpcLeasePath: string,
): Promise<ReusableRpcLease | null> {
  const result = await execDaytonaOrThrow(
    sandbox,
    [
      `test -s ${shellQuote(rpcLeasePath)}`,
      `test -s ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
      `cat ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
    ].join(" && "),
  ).catch(() => null);
  const raw = result?.result?.trim();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!isReusableRpcLease(parsed)) return null;
    const nowUnix = Math.floor(Date.now() / 1000);
    if (parsed.expiresAtUnix <= nowUnix + CMUXD_WS_RPC_RENEW_BEFORE_SECONDS) return null;
    return parsed;
  } catch {
    return null;
  }
}

async function execDaytonaOrThrow(sandbox: Sandbox, command: string, timeoutMs = 30_000) {
  const result = await sandbox.process.executeCommand(
    command,
    undefined,
    undefined,
    Math.ceil(timeoutMs / 1000),
  );
  if (result.exitCode !== 0) {
    throw new Error(`Daytona exec failed with status ${result.exitCode}: ${(result.result ?? "").trim()}`);
  }
  return result;
}
