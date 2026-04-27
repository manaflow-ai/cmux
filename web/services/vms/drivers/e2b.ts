import { Sandbox } from "e2b";
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
} from "./types";
import { withVmSpan } from "../telemetry";
import {
  isReusableRpcLease,
  leaseClientMetadata,
  makeWebSocketLease,
  parentDirectory,
  shellArgValue,
  shellQuote,
  type ReusableRpcLease,
} from "./wsLease";

export const DEFAULT_E2B_WS_TEMPLATE = "cmuxd-ws:proxy-20260424a";
const CMUXD_WS_PORT = 7777;
const CMUXD_WS_PTY_LEASE_PATH = "/tmp/cmux/attach-pty-lease.json";
const CMUXD_WS_LEGACY_PTY_LEASE_PATH = "/tmp/cmux/attach-lease.json";
const CMUXD_WS_RPC_CLIENT_PATH = "/tmp/cmux/attach-rpc-client.json";
const CMUXD_WS_PTY_LEASE_TTL_SECONDS = 5 * 60;
const CMUXD_WS_RPC_LEASE_TTL_SECONDS = 12 * 60 * 60;
const CMUXD_WS_RPC_RENEW_BEFORE_SECONDS = 60;
const DEFAULT_SANDBOX_ENVS = { LANG: "C.UTF-8" };

// Default cmuxd WebSocket PTY template. Built by web/scripts/build-cloud-vm-images.ts.
// E2B does not expose raw TCP, so interactive attach requires the cmuxd-remote WS image.
const DEFAULT_TEMPLATE =
  process.env.E2B_CMUXD_WS_TEMPLATE ??
  DEFAULT_E2B_WS_TEMPLATE;

export class E2BProvider implements VMProvider {
  readonly id = "e2b" as const;

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image || DEFAULT_TEMPLATE;
    return withVmSpan(
      "cmux.vm.provider.create",
      {
        "cmux.vm.provider": "e2b",
        "cmux.vm.operation": "create",
        "cmux.vm.image_set": image.length > 0,
      },
      async (span) => {
        try {
          const sandbox = await Sandbox.create(image, {
            envs: DEFAULT_SANDBOX_ENVS,
            network: { allowPublicTraffic: false },
          });
          span.setAttribute("cmux.vm.id", sandbox.sandboxId);
          return {
            provider: "e2b",
            providerVmId: sandbox.sandboxId,
            status: "running",
            image,
            createdAt: Date.now(),
          };
        } catch (err) {
          throw new ProviderError("e2b", `create(${image}) failed`, err);
        }
      },
    );
  }

  async destroy(vmId: string): Promise<void> {
    await withVmSpan(
      "cmux.vm.provider.destroy",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "destroy", "cmux.vm.id": vmId },
      async () => {
        await Sandbox.kill(vmId);
      },
    );
  }

  async pause(vmId: string): Promise<void> {
    await withVmSpan(
      "cmux.vm.provider.pause",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "pause", "cmux.vm.id": vmId },
      async () => {
        await Sandbox.pause(vmId);
      },
    );
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "resume", "cmux.vm.id": vmId },
      async () => {
        const sbx = await Sandbox.connect(vmId);
        const info = await Sandbox.getInfo(vmId);
        return {
          provider: "e2b",
          providerVmId: sbx.sandboxId,
          status: "running",
          image: info.templateId,
          createdAt: info.startedAt.getTime(),
        };
      },
    );
  }

  async exec(vmId: string, command: string, opts?: { timeoutMs?: number }): Promise<ExecResult> {
    const timeoutMs = opts?.timeoutMs ?? 30_000;
    return withVmSpan(
      "cmux.vm.provider.exec",
      {
        "cmux.vm.provider": "e2b",
        "cmux.vm.operation": "exec",
        "cmux.vm.id": vmId,
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      },
      async (span) => {
        const sbx = await Sandbox.connect(vmId);
        const r = await sbx.commands.run(command, { timeoutMs });
        span.setAttribute("cmux.exec.exit_code", r.exitCode);
        return { exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr };
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    return withVmSpan(
      "cmux.vm.provider.snapshot",
      {
        "cmux.vm.provider": "e2b",
        "cmux.vm.operation": "snapshot",
        "cmux.vm.id": vmId,
        "cmux.snapshot.named": !!name,
      },
      async (span) => {
        const sbx = await Sandbox.connect(vmId);
        const snap = await sbx.createSnapshot();
        const id =
          (snap as { snapshotId?: string }).snapshotId ??
          (snap as { snapshot_id?: string }).snapshot_id;
        if (!id || typeof id !== "string") {
          throw new ProviderError("e2b", `snapshot(${vmId}) returned no snapshot id`, snap);
        }
        span.setAttribute("cmux.snapshot.id", id);
        return { id, createdAt: Date.now(), name };
      },
    );
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.restore",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "restore", "cmux.snapshot.id": snapshotId },
      async (span) => {
        const sbx = await Sandbox.create(snapshotId, {
          envs: DEFAULT_SANDBOX_ENVS,
          network: { allowPublicTraffic: false },
        });
        span.setAttribute("cmux.vm.id", sbx.sandboxId);
        return {
          provider: "e2b",
          providerVmId: sbx.sandboxId,
          status: "running",
          image: snapshotId,
          createdAt: Date.now(),
        };
      },
    );
  }

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "open_ssh", "cmux.vm.id": vmId },
      async () => {
        // E2B sandboxes expose ports only via https://<port>-<sandbox-id>.e2b.app — they don't
        // route raw TCP/22 from outside, so mac client can't SSH directly into an E2B VM.
        // cmux's interactive paths (`cmux vm new` shell, `cmux vm new --workspace`) require
        // direct SSH + cmuxd-remote, so we surface a user-facing error. Use --provider freestyle
        // for interactive work, or `cmux vm new --provider e2b --detach` for scratch exec.
        throw new ProviderError(
          "e2b",
          "E2B sandboxes don't support interactive attach (no raw TCP egress). " +
            "Use `cmux vm new` without `--provider e2b` (Freestyle is the default), " +
            "or `cmux vm new --provider e2b --detach` to create without attach, " +
            "then `cmux vm exec <id> -- <cmd>`.",
        );
      },
    );
  }

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    const endpoint = await this.openWebSocketPty(vmId);
    if (options?.requireDaemon && !endpoint.daemon) {
      throw new ProviderError(
        "e2b",
        `openAttach(${vmId}) requires a cmuxd RPC endpoint, but this sandbox image only exposes the PTY WebSocket. Rebuild it with the current cmuxd-remote image.`,
      );
    }
    return endpoint;
  }

  async openWebSocketPty(vmId: string): Promise<WebSocketPtyEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_websocket_pty",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "open_websocket_pty", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await Sandbox.connect(vmId);
          const trafficAccessToken = sandbox.trafficAccessToken?.trim();
          if (!trafficAccessToken) {
            throw new Error("sandbox is missing a traffic access token; recreate it with the cmuxd WebSocket image");
          }
          const service = await readWebSocketService(sandbox);
          const pty = makeWebSocketLease("e2b", "pty", true, CMUXD_WS_PTY_LEASE_TTL_SECONDS);
          const encodedPTY = Buffer.from(JSON.stringify(pty.lease)).toString("base64");
          const commands = [
            `install -d -m 0700 ${shellQuote(parentDirectory(service.ptyLeasePath))}`,
            `printf '%s' '${encodedPTY}' | base64 -d > ${shellQuote(service.ptyLeasePath)}`,
            `chmod 600 ${shellQuote(service.ptyLeasePath)}`,
          ];
          let daemon: ReusableRpcLease | null = null;
          let daemonReused = false;
          if (service.rpcLeasePath) {
            const existingDaemon = await readReusableRpcLease(sandbox, service.rpcLeasePath);
            const newDaemon = existingDaemon
              ? null
              : makeWebSocketLease("e2b", "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
            daemon = existingDaemon ?? newDaemon!;
            daemonReused = !!existingDaemon;
            if (newDaemon) {
              const encodedDaemon = Buffer.from(JSON.stringify(newDaemon.lease)).toString("base64");
              const encodedDaemonClient = Buffer.from(JSON.stringify(leaseClientMetadata(newDaemon))).toString("base64");
              commands.push(
                `install -d -m 0700 ${shellQuote(parentDirectory(service.rpcLeasePath))}`,
                `printf '%s' '${encodedDaemon}' | base64 -d > ${shellQuote(service.rpcLeasePath)}`,
                `chmod 600 ${shellQuote(service.rpcLeasePath)}`,
                `printf '%s' '${encodedDaemonClient}' | base64 -d > ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
                `chmod 600 ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
              );
            }
          }
          await sandbox.commands.run(commands.join(" && "), { timeoutMs: 30_000 });
          span.setAttribute("cmux.vm.attach.transport", "websocket");
          span.setAttribute("cmux.vm.attach.expires_at_unix", pty.expiresAtUnix);
          span.setAttribute("cmux.vm.attach.daemon_available", !!daemon);
          if (daemon) {
            span.setAttribute("cmux.vm.attach.daemon_expires_at_unix", daemon.expiresAtUnix);
            span.setAttribute("cmux.vm.attach.daemon_reused", daemonReused);
          }
          return {
            transport: "websocket",
            url: `wss://${sandbox.getHost(CMUXD_WS_PORT)}/terminal`,
            headers: { "e2b-traffic-access-token": trafficAccessToken },
            token: pty.token,
            sessionId: pty.sessionId,
            expiresAtUnix: pty.expiresAtUnix,
            daemon: daemon ? {
              url: `wss://${sandbox.getHost(CMUXD_WS_PORT)}/rpc`,
              headers: { "e2b-traffic-access-token": trafficAccessToken },
              token: daemon.token,
              sessionId: daemon.sessionId,
              expiresAtUnix: daemon.expiresAtUnix,
            } : undefined,
          };
        } catch (err) {
          throw new ProviderError("e2b", `openWebSocketPty(${vmId}) failed`, err);
        }
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // E2B doesn't mint per-session credentials — openSSH always throws — so there's
    // nothing to revoke. Defined to satisfy VMProvider; never called against this driver.
  }
}

async function readWebSocketService(sandbox: Sandbox): Promise<{
  ptyLeasePath: string;
  rpcLeasePath: string | null;
}> {
  const result = await sandbox.commands.run(
    "ps auxww | grep cmuxd-remote | grep -v grep || true",
    { timeoutMs: 30_000 },
  );
  const stdout = result.stdout ?? "";
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
  const result = await sandbox.commands.run(
    [
      `test -s ${shellQuote(rpcLeasePath)}`,
      `test -s ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
      `cat ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
    ].join(" && "),
    { timeoutMs: 30_000 },
  ).catch(() => null);
  const raw = result?.stdout.trim();
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
