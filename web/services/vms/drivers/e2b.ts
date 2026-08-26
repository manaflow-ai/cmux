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
  type VmProviderCapabilities,
  type VmProviderDriver,
} from "./types";
import { withVmSpan } from "../telemetry";
import {
  discoverCmuxdService,
  installCmuxdAttachLeases,
  type ProviderTransport,
} from "./cmuxdAttach";
import { CMUXD_WS_PORT } from "./cmuxdConstants";

const DEFAULT_SANDBOX_ENVS = { LANG: "C.UTF-8" };

export class E2BProvider implements VmProviderDriver {
  readonly id = "e2b" as const;
  // No SSH (no raw TCP egress), no fork, no control-plane status/stats/port ingress in the
  // driver yet. Pause/resume and snapshots are real E2B features.
  readonly capabilities: VmProviderCapabilities = {
    ssh: false,
    snapshot: true,
    fork: false,
    pause: true,
    getStatus: false,
    getStats: false,
    openPort: false,
    revokeEndpointLeases: false,
  };

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("e2b", "create requires a resolved image");
    }
    return withVmSpan(
      "cmux.vm.provider.create",
      {
        "cmux.vm.provider": "e2b",
        "cmux.vm.operation": "create",
        "cmux.vm.image": image,
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
            "Use `cmux vm new` without `--provider e2b` (Blaxel is the default), " +
            "or `cmux vm new --provider e2b --detach` to create without attach, " +
            "then `cmux vm exec <id> -- <cmd>`.",
        );
      },
    );
  }

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    const endpoint = await this.openWebSocketPty(vmId, options);
    if (options?.requireDaemon && !endpoint.daemon) {
      throw new ProviderError(
        "e2b",
        `openAttach(${vmId}) requires a cmuxd RPC endpoint, but this sandbox image only exposes the PTY WebSocket. Rebuild it with the current cmuxd-remote image.`,
      );
    }
    return endpoint;
  }

  async openWebSocketPty(vmId: string, options?: AttachOptions): Promise<WebSocketPtyEndpoint> {
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
          const transport = e2bTransport(sandbox);
          const service = await discoverCmuxdService(transport);
          const { pty, attachmentId, daemon, daemonReused } = await installCmuxdAttachLeases(transport, service, {
            sessionId: options?.sessionId,
            attachmentId: options?.attachmentId,
          });
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
            attachmentId,
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

// The E2B SDK throws on non-zero exit codes; the shared attach module handles both that style
// and exit-code returns.
function e2bTransport(sandbox: Sandbox): ProviderTransport {
  return {
    providerId: "e2b",
    exec: async (command, timeoutMs = 30_000) => {
      const result = await sandbox.commands.run(command, { timeoutMs });
      return { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr };
    },
  };
}
