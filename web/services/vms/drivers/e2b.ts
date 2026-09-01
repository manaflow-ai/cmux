import { Sandbox } from "e2b";
import { randomBytes } from "node:crypto";
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
} from "./types";
import { withVmSpan } from "../telemetry";
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

// E2B sandboxes attach through the cmux-tui remote daemon (transport `cmux-remote`,
// docs/cloud-cmux-tui-daemon.md), the machine's only session daemon — same model as
// Blaxel. `create` installs the pinned files.cmux.com build (sha256-verified, fetched
// by the sandbox itself) and starts the daemon as a background command; E2B
// pause/resume snapshots memory, so the daemon survives lifecycle transitions, and
// every attach re-verifies pin + liveness (ensureCmuxTuiRunning) exactly like the
// Blaxel driver.
//
// Ingress: E2B proxies `https://<port>-<sandbox-id>.e2b.app` per port. Its only
// request auth is the `e2b-traffic-access-token` HEADER, which the cmux-tui dialer
// cannot send (it dials the route verbatim, adding only a User-Agent), so sandboxes
// are created with public port traffic and the daemon's Noise device enrollment is
// the session gate — the same trust model as Blaxel's raw preview, where the route
// token "only gates reachability". Sandboxes created by the old cmuxd-remote driver
// (allowPublicTraffic: false, no cmux-tui) cannot serve this transport and need
// recreation.
const ROUTE_TOKEN_TTL_SECONDS = 12 * 60 * 60;
const DEFAULT_SANDBOX_ENVS = { LANG: "C.UTF-8" };
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
// envd is E2B's in-VM control plane (process exec + filesystem): the SDK reaches
// it through the SAME public port proxy on 49983, so an inbound firewall MUST
// keep it open or every commands.run/attach breaks (researched live 2026-08-28:
// ss shows `envd` listening on *:49983; a default-deny INPUT that allows 49983 +
// 1337 kept control and attach alive while a port-3000 dev server became
// unreachable externally). ConnectionConfig.envdPort in the e2b SDK is the same
// constant.
export const ENVD_CONTROL_PORT = 49983;
// A dedicated INPUT chain that ends in DROP, hooked once. Reversible (flush the
// chain) and idempotent (re-hook only if absent), unlike flipping INPUT's policy.
// allowPublicTraffic exposes every listening port at `<port>-<id>.e2b.app`; this
// closes all of them except the cmux-tui daemon (1337) and envd (49983), so a
// user's dev server on 3000 is not silently world-reachable.
export const INBOUND_FIREWALL_COMMAND = [
  "command -v iptables >/dev/null 2>&1 || exit 0",
  "iptables -w -N CMUX_FW 2>/dev/null || iptables -w -F CMUX_FW",
  "iptables -w -A CMUX_FW -i lo -j ACCEPT",
  "iptables -w -A CMUX_FW -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT",
  "iptables -w -A CMUX_FW -p icmp -j ACCEPT",
  `iptables -w -A CMUX_FW -p tcp --dport ${ENVD_CONTROL_PORT} -j ACCEPT`,
  `iptables -w -A CMUX_FW -p tcp --dport ${CMUX_TUI_PORT} -j ACCEPT`,
  "iptables -w -A CMUX_FW -j DROP",
  "iptables -w -C INPUT -j CMUX_FW 2>/dev/null || iptables -w -I INPUT 1 -j CMUX_FW",
].join(" && ");

export class E2BProvider implements VMProvider {
  readonly id = "e2b" as const;

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
          // options.envs carries the coderouter model-plane env minted at
          // create (see CreateOptions.envs); it goes to the provider call
          // only, never into persisted handle metadata.
          const sandbox = await Sandbox.create(image, {
            envs: { ...DEFAULT_SANDBOX_ENVS, ...(options.envs ?? {}) },
            // Public port traffic: see the ingress note at the top of this file.
            network: { allowPublicTraffic: true },
          });
          span.setAttribute("cmux.vm.id", sandbox.sandboxId);
          try {
            await this.bootstrapCmuxTui(sandbox);
          } catch (err) {
            // A sandbox that failed to bootstrap must not survive as an orphan.
            await Sandbox.kill(sandbox.sandboxId).catch((cleanupErr) => {
              console.error(`[e2b] create rollback failed; sandbox ${sandbox.sandboxId} may be orphaned`, cleanupErr);
            });
            throw err;
          }
          return {
            provider: "e2b",
            providerVmId: sandbox.sandboxId,
            status: "running",
            image,
            createdAt: Date.now(),
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("e2b", `create(${image}) failed`, err);
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
          network: { allowPublicTraffic: true },
        });
        span.setAttribute("cmux.vm.id", sbx.sandboxId);
        // The snapshot carries the installed binary but boots with no processes;
        // start the daemon now so the machine is attach-ready. Failures are left
        // to the attach path's ensureCmuxTuiRunning rather than failing restore.
        await this.ensureCmuxTuiRunning(sbx).catch(() => undefined);
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

  /** The only session transport: the cmux-tui remote daemon (`openCmuxRemote`). */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    void options;
    throw new ProviderError(
      "e2b",
      `openAttach(${vmId}) is not supported: E2B machines attach through the cmux-tui remote daemon (transport cmux-remote).`,
    );
  }

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "open_ssh", "cmux.vm.id": vmId },
      async () => {
        // E2B exposes ports only through its HTTPS proxy — no raw TCP/22 — so SSH
        // can never be served. Machines attach through the cmux-tui remote daemon.
        throw new ProviderError(
          "e2b",
          "E2B machines do not support SSH (no raw TCP ingress); attach through the cmux-tui remote daemon (transport cmux-remote).",
        );
      },
    );
  }

  async openCmuxRemote(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_cmux_remote",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "open_cmux_remote", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await Sandbox.connect(vmId);
          await this.ensureCmuxTuiRunning(sandbox);
          const invoke = this.cmuxTuiInvoke(sandbox);
          // The E2B proxy has no URL-carriable ingress auth (header-only), so the
          // route is the bare public host and this token exists only for the
          // lease ledger; the daemon's Noise enrollment is the session gate.
          const token = `cmux-e2b-route-${randomBytes(32).toString("hex")}`;
          const expiresAtUnix = Math.floor(Date.now() / 1000) + ROUTE_TOKEN_TTL_SECONDS;
          const route = `wss://${sandbox.getHost(CMUX_TUI_PORT)}/v1/link`;
          let invitation: CmuxRemoteEndpoint["invitation"];
          const enrolled = options?.deviceFingerprint
            ? await isCmuxTuiDeviceEnrolled(invoke, options.deviceFingerprint)
            : false;
          if (!enrolled) {
            invitation = await mintCmuxTuiInvitation(invoke, "e2b", vmId);
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
          throw err instanceof ProviderError ? err : new ProviderError("e2b", `openCmuxRemote(${vmId}) failed`, err);
        }
      },
    );
  }

  async approveCmuxRemoteEnrollment(vmId: string, invitationId: string): Promise<CmuxRemoteApprovalResult> {
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      { "cmux.vm.provider": "e2b", "cmux.vm.operation": "approve_cmux_remote_enrollment", "cmux.vm.id": vmId },
      async () => {
        try {
          const sandbox = await Sandbox.connect(vmId);
          return await approveCmuxTuiEnrollment(this.cmuxTuiInvoke(sandbox), "e2b", vmId, invitationId);
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("e2b", `approveCmuxRemoteEnrollment(${vmId}) failed`, err);
        }
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // openSSH always throws, so there is never an identity to revoke.
  }

  /** Installs the pinned binary and starts the daemon (fresh create). */
  private async bootstrapCmuxTui(sandbox: Sandbox): Promise<void> {
    const source = await resolveCmuxTuiSource("e2b");
    const install = await this.rootExec(sandbox, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS);
    if (install.exitCode !== 0) {
      throw new ProviderError("e2b", `cmux-tui install in ${sandbox.sandboxId} failed: ${install.stderr || install.stdout}`);
    }
    await this.startCmuxTuiDaemon(sandbox);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(sandbox), "e2b", sandbox.sandboxId);
    await this.applyInboundFirewall(sandbox);
  }

  /**
   * Close every externally reachable port except the cmux-tui daemon (1337)
   * and envd (49983). allowPublicTraffic exposes every listener at
   * `<port>-<id>.e2b.app`, so without this a user's dev server would be
   * world-reachable. Best-effort: a firewall failure must not brick a machine
   * whose daemon is already up, so it is logged, not thrown. Idempotent, so
   * ensureCmuxTuiRunning re-asserts it after resume/restore.
   */
  private async applyInboundFirewall(sandbox: Sandbox): Promise<void> {
    const result = await this.rootExec(sandbox, INBOUND_FIREWALL_COMMAND).catch(() => null);
    if (!result || result.exitCode !== 0) {
      console.error(
        `[e2b] inbound firewall on ${sandbox.sandboxId} did not apply cleanly; ports other than ${CMUX_TUI_PORT}/${ENVD_CONTROL_PORT} may be publicly reachable`,
        result?.stderr || result?.stdout || "",
      );
    }
  }

  /**
   * Attach-time heal, mirroring the Blaxel driver: a running daemon is left
   * alone; a dead one is restarted, reinstalling first when the binary is
   * missing or a manifest pin change supersedes it. E2B pause/resume preserves
   * processes (memory snapshot), so this is normally a no-op.
   */
  private async ensureCmuxTuiRunning(sandbox: Sandbox): Promise<void> {
    const running = await this.rootExec(sandbox, "pgrep -f 'cmux-tui server start' >/dev/null 2>&1").catch(() => null);
    if (running?.exitCode === 0) return;
    const source = await resolveCmuxTuiSource("e2b");
    const pinned = await this.rootExec(sandbox, cmuxTuiPinCheckCommand(source)).catch(() => null);
    if (pinned?.exitCode !== 0) {
      const install = await this.rootExec(sandbox, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS);
      if (install.exitCode !== 0) {
        throw new ProviderError("e2b", `cmux-tui install in ${sandbox.sandboxId} failed: ${install.stderr || install.stdout}`);
      }
    }
    await this.startCmuxTuiDaemon(sandbox);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(sandbox), "e2b", sandbox.sandboxId);
    // Re-assert the inbound firewall: a fresh restore boots with no rules, and
    // a resume that somehow lost them is repaired here (idempotent).
    await this.applyInboundFirewall(sandbox);
  }

  private async startCmuxTuiDaemon(sandbox: Sandbox): Promise<void> {
    // A background command is E2B's process supervisor surface; there is no
    // restart-on-failure flag, so attach-time ensureCmuxTuiRunning is the heal.
    await sandbox.commands.run(cmuxTuiDaemonCommand(), {
      background: true,
      user: "root",
      timeoutMs: 0,
    });
  }

  /** Runs a command as root (the daemon's user; exec defaults to the template user). */
  private async rootExec(sandbox: Sandbox, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult> {
    const r = await sandbox.commands.run(command, { timeoutMs, user: "root" }).catch((err: unknown) => {
      // e2b throws CommandExitError on nonzero exit; unwrap it into an ExecResult.
      if (err && typeof err === "object" && "exitCode" in err) return err as never;
      throw err;
    });
    return { exitCode: r.exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  }

  private cmuxTuiInvoke(sandbox: Sandbox): CmuxTuiInvoke {
    return (args, timeoutMs) =>
      this.rootExec(sandbox, `env HOME=/root /root/.cmux/bin/cmux-tui ${args}`, timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS);
  }
}
