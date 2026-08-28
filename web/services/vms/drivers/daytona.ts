import { Daytona, type Sandbox, type SandboxState } from "@daytonaio/sdk";
import {
  ProviderError,
  type AttachEndpoint,
  type AttachOptions,
  type AttachTransport,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
  type CreateOptions,
  type ExecResult,
  type SSHEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
  type VMStatus,
} from "./types";
import { recordSpanError, setSpanAttributes, withVmSpan } from "../telemetry";
import {
  CMUX_TUI_INSTALL_TIMEOUT_MS,
  CMUX_TUI_PORT,
  CMUX_TUI_SESSION,
  approveCmuxTuiEnrollment,
  cmuxTuiDaemonBuild,
  cmuxTuiDaemonCommand,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
  isCmuxTuiDeviceEnrolled,
  mintCmuxTuiInvitation,
  resolveCmuxTuiSource,
  waitForCmuxTuiReady,
  type CmuxTuiInvoke,
} from "./cmuxTuiDaemon";

// Daytona sandboxes attach through the cmux-tui remote daemon (transport
// `cmux-remote`, docs/cloud-cmux-tui-daemon.md), the machine's only session daemon —
// same model as Blaxel. `create` installs the pinned files.cmux.com build
// (sha256-verified, fetched by the sandbox itself); the devbox image's registered
// entrypoint (/usr/local/bin/cmux-devbox-boot) supervises the daemon and Daytona
// re-runs it on every sandbox start, which matters because Daytona stop kills
// processes while the filesystem (and thus the installed binary and daemon
// identity under /root) persists. Attach re-verifies pin + liveness.
//
// Ingress: the daemon port is reached through Daytona's preview proxy
// (`https://1337-<sandboxId>.<proxyDomain>`), whose token the proxy accepts as the
// `DAYTONA_SANDBOX_AUTH_KEY` query parameter (the Daytona SDK itself dials
// WebSockets that way), so the tokenized wss route carries its own auth. Preview
// tokens are invalidated when a sandbox restarts, so a fresh one is minted per
// attach. Sandboxes created by the old cmuxd-remote driver have no cmux-tui
// entrypoint and need recreation.
const CMUX_DEVBOX_BOOT_PATH = "/usr/local/bin/cmux-devbox-boot";
const ROUTE_TOKEN_TTL_SECONDS = 12 * 60 * 60;
const DEFAULT_SANDBOX_ENVS = { LANG: "C.UTF-8" };

const CREATE_TIMEOUT_SECONDS = 15 * 60;
const LIFECYCLE_TIMEOUT_SECONDS = 5 * 60;
const SNAPSHOT_TIMEOUT_SECONDS = 15 * 60;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;

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
          // options.envs carries the coderouter model-plane env minted at
          // create (see CreateOptions.envs); it goes to the provider call
          // only, never into persisted handle metadata.
          const sandbox = await client().create(
            {
              snapshot: image,
              envVars: { ...DEFAULT_SANDBOX_ENVS, ...(options.envs ?? {}) },
              // Persistent cloud computer shape: never auto-stop. Pause/resume is an explicit
              // cmux workflow, mapped onto Daytona stop/start below.
              autoStopInterval: 0,
            },
            { timeout: CREATE_TIMEOUT_SECONDS },
          );
          setSpanAttributes(span, { "cmux.vm.id": sandbox.id });
          try {
            await this.bootstrapCmuxTui(sandbox);
          } catch (err) {
            // A sandbox that failed to bootstrap must not survive as an orphan.
            await sandbox.delete(LIFECYCLE_TIMEOUT_SECONDS).catch((cleanupErr) => {
              console.error(`[daytona] create rollback failed; sandbox ${sandbox.id} may be orphaned`, cleanupErr);
            });
            throw err;
          }
          return {
            provider: "daytona",
            providerVmId: sandbox.id,
            status: "running",
            image,
            createdAt: Date.now(),
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("daytona", `create(${image})`, err);
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
          // Stop killed every process; the image entrypoint restarts the daemon on
          // start, but heal best-effort here so the first attach after resume
          // doesn't race the entrypoint.
          try {
            await this.ensureCmuxTuiRunning(sandbox);
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
          const snapshotName = name?.trim() || `cmux-daytona-${crypto.randomUUID().replaceAll("-", "").slice(0, 16)}`;
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
          // The snapshot carries the installed binary; heal best-effort so the
          // machine is attach-ready without failing restore on transient errors.
          await this.ensureCmuxTuiRunning(sandbox).catch(() => undefined);
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

  /** The only session transport: the cmux-tui remote daemon (`openCmuxRemote`). */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    void options;
    throw new ProviderError(
      "daytona",
      `openAttach(${vmId}) is not supported: Daytona machines attach through the cmux-tui remote daemon (transport cmux-remote).`,
    );
  }

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "open_ssh", "cmux.vm.id": vmId },
      async () => {
        // Daytona does offer a token-based SSH gateway, but cmux deliberately doesn't
        // dial it (unreliable in practice); machines attach through the cmux-tui daemon.
        throw new ProviderError(
          "daytona",
          "Daytona machines do not serve SSH in cmux; attach through the cmux-tui remote daemon (transport cmux-remote).",
        );
      },
    );
  }

  async openCmuxRemote(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_cmux_remote",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "open_cmux_remote", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await client().get(vmId);
          await this.ensureCmuxTuiRunning(sandbox);
          const invoke = this.cmuxTuiInvoke(sandbox);
          // Preview tokens are invalidated when a sandbox restarts, so mint a fresh
          // route per attach instead of caching one.
          const preview = await sandbox.getPreviewLink(CMUX_TUI_PORT);
          const token = preview.token?.trim() ?? "";
          if (!token) {
            throw new Error(`preview link for port ${CMUX_TUI_PORT} carried no token`);
          }
          const host = preview.url.replace(/^https?:\/\//, "").replace(/\/+$/, "");
          // The Daytona proxy accepts the preview token as this query parameter
          // (the Daytona SDK dials its own WebSockets the same way), so the route
          // carries its ingress auth URL-only, as the cmux-remote contract needs.
          const route = `wss://${host}/v1/link?DAYTONA_SANDBOX_AUTH_KEY=${encodeURIComponent(token)}`;
          const expiresAtUnix = Math.floor(Date.now() / 1000) + ROUTE_TOKEN_TTL_SECONDS;
          let invitation: CmuxRemoteEndpoint["invitation"];
          const enrolled = options?.deviceFingerprint
            ? await isCmuxTuiDeviceEnrolled(invoke, options.deviceFingerprint)
            : false;
          if (!enrolled) {
            invitation = await mintCmuxTuiInvitation(invoke, "daytona", vmId);
          }
          span.setAttribute("cmux.vm.cmux_remote.invited", !enrolled);
          const daemonBuild = await cmuxTuiDaemonBuild(invoke);
          return {
            transport: "cmux-remote",
            route,
            token,
            expiresAtUnix,
            session: CMUX_TUI_SESSION,
            ...(daemonBuild ? { daemonBuild } : {}),
            ...(invitation ? { invitation } : {}),
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("daytona", `openCmuxRemote(${vmId}) failed`, err);
        }
      },
    );
  }

  async approveCmuxRemoteEnrollment(vmId: string, invitationId: string): Promise<CmuxRemoteApprovalResult> {
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      { "cmux.vm.provider": "daytona", "cmux.vm.operation": "approve_cmux_remote_enrollment", "cmux.vm.id": vmId },
      async () => {
        try {
          const sandbox = await client().get(vmId);
          return await approveCmuxTuiEnrollment(this.cmuxTuiInvoke(sandbox), "daytona", vmId, invitationId);
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("daytona", `approveCmuxRemoteEnrollment(${vmId}) failed`, err);
        }
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // openSSH always throws, so there is never an identity to revoke.
  }

  /** Installs the pinned binary; the image entrypoint (or the fallback below) runs the daemon. */
  private async bootstrapCmuxTui(sandbox: Sandbox): Promise<void> {
    const source = await resolveCmuxTuiSource("daytona");
    const install = await this.execOrThrow(sandbox, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS).catch((err: unknown) => {
      throw new ProviderError("daytona", `cmux-tui install in ${sandbox.id} failed`, err);
    });
    void install;
    await this.startCmuxTuiDaemonIfDead(sandbox);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(sandbox), "daytona", sandbox.id);
  }

  /**
   * Attach-time heal, mirroring the Blaxel driver: a running daemon is left alone;
   * a dead one is restarted, reinstalling first when the binary is missing or a
   * manifest pin change supersedes it. Daytona stop kills processes, so this runs
   * for real after every stop/start cycle that beat the image entrypoint.
   */
  private async ensureCmuxTuiRunning(sandbox: Sandbox): Promise<void> {
    const running = await this.execResult(sandbox, "pgrep -f 'cmux-tui server start' >/dev/null 2>&1");
    if (running?.exitCode === 0) return;
    const source = await resolveCmuxTuiSource("daytona");
    const pinned = await this.execResult(sandbox, cmuxTuiPinCheckCommand(source));
    if (pinned?.exitCode !== 0) {
      await this.execOrThrow(sandbox, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS).catch((err: unknown) => {
        throw new ProviderError("daytona", `cmux-tui install in ${sandbox.id} failed`, err);
      });
    }
    await this.startCmuxTuiDaemonIfDead(sandbox);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(sandbox), "daytona", sandbox.id);
  }

  private async startCmuxTuiDaemonIfDead(sandbox: Sandbox): Promise<void> {
    // Prefer the image's supervisor (the registered entrypoint; restarts the daemon
    // if it ever exits); fall back to launching the daemon directly on images that
    // predate the supervisor script.
    const start = [
      "if ! pgrep -f 'cmux-tui server start' >/dev/null 2>&1; then",
      `if [ -x ${CMUX_DEVBOX_BOOT_PATH} ]; then`,
      `pgrep -f ${CMUX_DEVBOX_BOOT_PATH.split("/").pop()} >/dev/null 2>&1 || (setsid nohup ${CMUX_DEVBOX_BOOT_PATH} >>/tmp/cmux-devbox-boot.log 2>&1 &);`,
      "else",
      `(setsid nohup sh -c '${cmuxTuiDaemonCommand()}' >>/tmp/cmux-tui-daemon.log 2>&1 &);`,
      "fi;",
      "fi",
    ].join(" ");
    await this.execOrThrow(sandbox, start, 60_000);
  }

  private async execResult(sandbox: Sandbox, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<{ exitCode: number; output: string } | null> {
    try {
      const r = await sandbox.process.executeCommand(command, undefined, undefined, Math.ceil(timeoutMs / 1000));
      return { exitCode: r.exitCode, output: r.result ?? "" };
    } catch {
      return null;
    }
  }

  private async execOrThrow(sandbox: Sandbox, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS) {
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

  private cmuxTuiInvoke(sandbox: Sandbox): CmuxTuiInvoke {
    return async (args, timeoutMs) => {
      const r = await this.execResult(
        sandbox,
        `env HOME=/root /root/.cmux/bin/cmux-tui ${args}`,
        timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS,
      );
      if (!r) return { exitCode: 124, stdout: "", stderr: "exec failed" };
      // The toolbox merges stderr into the single output stream.
      return { exitCode: r.exitCode, stdout: r.output, stderr: "" };
    };
  }
}
