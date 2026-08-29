import { Freestyle, FreestyleApiError, type VmData, type Vm } from "freestyle-beta";
import { randomBytes } from "node:crypto";
import {
  ProviderError,
  type AttachTransport,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
  type CreateOptions,
  type ExecResult,
  type SnapshotRef,
  type VMHandle,
  type VMStatus,
} from "./types";
import { recordSpanError, setSpanAttributes, withVmSpan } from "../telemetry";
import { imageUsesFreestyleBetaPlatform } from "../images/resolver";
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

// The Freestyle BETA platform arm of the freestyle driver (beta-api.freestyle.sh
// /v5, SDK alias freestyle-beta = npm:freestyle@0.2.0-beta.7). FreestyleProvider
// in ./freestyle.ts owns the ProviderId and dispatches here per machine; the
// legacy 0.1.51 platform code there keeps serving existing production machines.
//
// Machines attach through the cmux-tui remote daemon (transport `cmux-remote`,
// docs/cloud-cmux-tui-daemon.md), the same model as Blaxel/E2B/Daytona. The
// beta API has no HTTP ingress proxy to arbitrary VM ports (verified against
// /openapi.json: no preview/port routes; TLS edge rules need a customer-verified
// domain), so the route is the VM's stable public IPv6 straight to the daemon:
// `ws://[<publicIpv6>]:1337/v1/link`. The daemon's Noise handshake encrypts and
// authenticates the session end to end (carrier TLS is not required and the
// route token only feeds the lease ledger, exactly like E2B's public proxy).
// The daemon must therefore bind dual-stack: the baked systemd unit sets
// CMUX_TUI_REMOTE_WS_BIND=[::]:1337 and the driver re-asserts it on heal.
//
// Beta creates take NO ports field, NO create-time env, and NO systemd
// injection; `firewall` is mandatory. Model-plane env is delivered by writing
// the persisted /root/.config/cmux/model-plane.env file (0600) that
// /etc/cmux/agent-config.sh already sources when the boot env is absent.

export const FREESTYLE_PLATFORM_METADATA_KEY = "freestylePlatform";
/** Beta VM ids are `vm-<32 hex>`; legacy ids are bare 20-char base36. */
const FREESTYLE_BETA_VM_ID_PATTERN = /^vm-[0-9a-f]{32}$/;
/** Beta snapshot ids are `sh-<32 hex>`; legacy ones are `sh-`/`sc-` + 20 base36. */
const FREESTYLE_BETA_SNAPSHOT_ID_PATTERN = /^sh-[0-9a-f]{32}$/;

export const FREESTYLE_BETA_REMOTE_WS_BIND = `[::]:${CMUX_TUI_PORT}`;
export const FREESTYLE_BETA_ATTACH_TRANSPORT: AttachTransport = "cmux-remote";

const DEFAULT_TIMEOUT_MS = 60_000;
const CREATE_TIMEOUT_MS = 15 * 60 * 1000;
const SNAPSHOT_TIMEOUT_MS = 15 * 60 * 1000;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
/** The beta exec API rejects timeoutMs above 300000 (5 minutes per exec). */
const MAX_EXEC_TIMEOUT_MS = 300_000;
const EXEC_OVERHEAD_TIMEOUT_MS = 15_000;
const ROUTE_TOKEN_TTL_SECONDS = 12 * 60 * 60;
const MODEL_PLANE_ENV_PATH = "/root/.config/cmux/model-plane.env";

export function isFreestyleBetaVmId(vmId: string): boolean {
  return FREESTYLE_BETA_VM_ID_PATTERN.test(vmId.trim());
}

export function isFreestyleBetaSnapshotId(snapshotId: string): boolean {
  return FREESTYLE_BETA_SNAPSHOT_ID_PATTERN.test(snapshotId.trim());
}

export function freestylePlatformIsBeta(metadata: Record<string, unknown> | undefined): boolean {
  return metadata?.[FREESTYLE_PLATFORM_METADATA_KEY] === "beta";
}

/**
 * Legacy and beta are different platforms with different API keys (a legacy key
 * answers 401 on beta-api). FREESTYLE_BETA_API_KEY lets a deployment serve both
 * at once; single-platform setups keep using FREESTYLE_API_KEY. The stack-token
 * pair mirrors build-devbox-freestyle.ts for interactive use.
 */
function betaClient(timeoutMs = DEFAULT_TIMEOUT_MS): Freestyle {
  const longFetch: typeof fetch = (input, init) =>
    fetch(input as Request, { ...(init ?? {}), signal: AbortSignal.timeout(timeoutMs) });
  const baseUrl = process.env.FREESTYLE_BETA_API_URL?.trim() || undefined;
  const apiKey = process.env.FREESTYLE_BETA_API_KEY?.trim() || process.env.FREESTYLE_API_KEY?.trim();
  if (apiKey) return new Freestyle({ apiKey, baseUrl, fetch: longFetch });
  const stackAccessToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN?.trim();
  const teamId = process.env.FREESTYLE_TEAM_ID?.trim();
  if (stackAccessToken && teamId) {
    return new Freestyle({ stackAccessToken, teamId, baseUrl, fetch: longFetch });
  }
  throw new ProviderError(
    "freestyle",
    "beta platform requires FREESTYLE_BETA_API_KEY or FREESTYLE_API_KEY (or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID)",
  );
}

/**
 * Outbound open (package installs, files.cmux.com, agents); inbound only the
 * cmux-tui daemon port. Beta's mandatory `firewall` field defaults to NOTHING —
 * no outbound, no inbound — so both rules are stated. Session auth on 1337 is
 * the daemon's Noise device enrollment; the platform edge closing every other
 * port is the same posture the e2b driver builds by hand with iptables.
 */
export function freestyleBetaFirewallRules() {
  return [
    { action: "allow" as const, source: {}, destination: { public: true as const } },
    {
      action: "allow" as const,
      source: { public: true as const },
      destination: { port: CMUX_TUI_PORT, protocol: "tcp" as const },
    },
  ];
}

/** `ws://[<publicIpv6>]:1337/v1/link` — see the ingress note at the top of this file. */
export function freestyleBetaCmuxRemoteRoute(publicIpv6: string | null | undefined, vmId: string): string {
  const ipv6 = publicIpv6?.trim();
  if (!ipv6) {
    throw new ProviderError(
      "freestyle",
      `VM ${vmId} has no public IPv6 address, so its cmux-tui daemon is unreachable (the beta platform has no HTTP ingress to arbitrary ports)`,
    );
  }
  return `ws://[${ipv6}]:${CMUX_TUI_PORT}/v1/link`;
}

/**
 * The persisted model-plane env file, byte-compatible with what
 * /etc/cmux/agent-config.sh itself writes from a boot env: shells that see no
 * boot env source this copy and then materialize the codex/pi/opencode
 * configs. Beta has no create-time env, so the driver writes the file instead.
 */
export function renderFreestyleModelPlaneEnvFile(envs: Readonly<Record<string, string>>): string | null {
  const baseUrl = envs.OPENAI_BASE_URL?.trim();
  if (!baseUrl) return null;
  const quote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;
  const lines = [
    "# generated by cmux from machine boot env; managed, do not edit",
    `export OPENAI_BASE_URL=${quote(baseUrl)}`,
  ];
  if (envs.OPENAI_API_KEY) lines.push(`export OPENAI_API_KEY=${quote(envs.OPENAI_API_KEY)}`);
  if (envs.CMUX_CODEROUTER_URL) lines.push(`export CMUX_CODEROUTER_URL=${quote(envs.CMUX_CODEROUTER_URL)}`);
  return `${lines.join("\n")}\n`;
}

export function normalizeFreestyleBetaExecTimeout(timeoutMs: number | undefined): number {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return EXEC_DEFAULT_TIMEOUT_MS;
  }
  return Math.min(Math.floor(timeoutMs), MAX_EXEC_TIMEOUT_MS);
}

/**
 * `stopped` maps to paused, not destroyed: a stopped beta VM still exists and
 * `start()` boots it again (poweroff, an idle timeout, or a failure with
 * automaticRestart off all leave a recoverable machine).
 */
export function mapFreestyleBetaState(state: VmData["state"] | null | undefined): VMStatus {
  switch (state) {
    case "starting":
      return "creating";
    case "running":
      return "running";
    case "pausing":
    case "paused":
    case "stopped":
      return "paused";
    default:
      return "running";
  }
}

/**
 * Healthy = the daemon process is up AND something listens on 1337 in the v6
 * table (a dual-stack `[::]` bind; 0x0539 = 1337). A daemon bound 0.0.0.0 only
 * appears in /proc/net/tcp, is unreachable at the public IPv6, and must be
 * restarted under the dual-stack override.
 */
export function freestyleBetaDaemonHealthyCommand(): string {
  return "pgrep -f 'cmux-tui server start' >/dev/null 2>&1 && grep -qi ':0539 ' /proc/net/tcp6";
}

const REMOTE_WS_BIND_OVERRIDE =
  "/etc/systemd/system/cmux-tui-daemon.service.d/10-cmux-remote-ws-bind.conf";

/**
 * (Re)start the daemon listening dual-stack. Under systemd (the baked
 * cmux-tui-daemon unit), install a drop-in setting
 * CMUX_TUI_REMOTE_WS_BIND=[::]:1337 — the env cmux-devbox-boot reads — then
 * restart the unit, healing machines from bakes that predate the env default.
 * Without systemd (or the unit), fall back to a direct daemon launch with the
 * dual-stack bind, mirroring the Daytona driver's fallback.
 */
export function freestyleBetaStartDaemonCommand(): string {
  return [
    "if [ -d /run/systemd/system ] && [ -f /etc/systemd/system/cmux-tui-daemon.service ]; then",
    `mkdir -p ${REMOTE_WS_BIND_OVERRIDE.replace(/\/[^/]+$/, "")};`,
    `printf '[Service]\\nEnvironment=CMUX_TUI_REMOTE_WS_BIND=${FREESTYLE_BETA_REMOTE_WS_BIND}\\n' > ${REMOTE_WS_BIND_OVERRIDE};`,
    "systemctl daemon-reload;",
    "systemctl restart cmux-tui-daemon;",
    "else",
    `pgrep -f 'cmux-tui server start' >/dev/null 2>&1 || (setsid nohup sh -c '${cmuxTuiDaemonCommand(FREESTYLE_BETA_REMOTE_WS_BIND)}' >>/tmp/cmux-tui-daemon.log 2>&1 &);`,
    "fi",
  ].join(" ");
}

function isBetaNotFound(err: unknown): boolean {
  return err instanceof FreestyleApiError && (err.status === 404 || err.code === "NOT_FOUND");
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function betaSpanAttributes(vmId: string, operation: string, extra: Record<string, string | number | boolean> = {}) {
  return {
    "cmux.vm.provider": "freestyle",
    "cmux.vm.operation": operation,
    "cmux.vm.id": vmId,
    "cmux.vm.platform": "beta",
    ...extra,
  };
}

export class FreestyleBetaPlatform {
  /**
   * A create targets beta when any of these say so: the caller's metadata
   * marker, the image's manifest entry (`features.freestylePlatform: "beta"`),
   * the CMUX_FREESTYLE_PLATFORM=beta operator override (unmanifested beta
   * snapshots in local dev), or the snapshot id's beta shape. Everything else
   * stays on the legacy platform, so existing images and deployments are
   * untouched until an operator points at a beta image.
   */
  createTargetsBeta(options: CreateOptions): boolean {
    if (freestylePlatformIsBeta(options.providerMetadata)) return true;
    if (imageUsesFreestyleBetaPlatform("freestyle", options.image.trim())) return true;
    if (process.env.CMUX_FREESTYLE_PLATFORM?.trim().toLowerCase() === "beta") return true;
    return isFreestyleBetaSnapshotId(options.image);
  }

  restoreTargetsBeta(snapshotId: string): boolean {
    if (imageUsesFreestyleBetaPlatform("freestyle", snapshotId.trim())) return true;
    if (process.env.CMUX_FREESTYLE_PLATFORM?.trim().toLowerCase() === "beta") return true;
    return isFreestyleBetaSnapshotId(snapshotId);
  }

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("freestyle", "create requires a resolved image");
    }
    return withVmSpan(
      "cmux.vm.provider.create",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "create",
        "cmux.vm.image": image,
        "cmux.vm.platform": "beta",
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = betaClient(CREATE_TIMEOUT_MS);
          const { vm, vmId } = await fs.vms.create({
            snapshotId: image,
            displayName: "cmux Cloud VM",
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleBetaFirewallRules() },
          });
          setSpanAttributes(span, { "cmux.vm.id": vmId });
          try {
            await this.bootstrapCmuxTui(vm, vmId, options.envs);
          } catch (err) {
            // A VM that failed to bootstrap must not survive as an orphan.
            await vm.delete().catch((cleanupErr) => {
              console.error(`[freestyle-beta] create rollback failed; VM ${vmId} may be orphaned`, cleanupErr);
            });
            throw err;
          }
          return {
            provider: "freestyle" as const,
            providerVmId: vmId,
            status: "running" as const,
            image,
            createdAt: Date.now(),
            providerMetadata: {
              ...(options.providerMetadata ?? {}),
              [FREESTYLE_PLATFORM_METADATA_KEY]: "beta",
            },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("freestyle", `create(${image}) on beta failed`, err);
        }
      },
    );
  }

  async destroy(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.destroy",
      betaSpanAttributes(vmId, "destroy"),
      async () => {
        try {
          await betaClient().vms.ref(vmId).delete();
        } catch (err) {
          if (isBetaNotFound(err)) return; // already gone; destroy is idempotent
          throw new ProviderError("freestyle", `destroy(${vmId}) on beta`, err);
        }
      },
    );
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    return withVmSpan(
      "cmux.vm.provider.get_status",
      betaSpanAttributes(vmId, "get_status"),
      async (span) => {
        try {
          const data = await betaClient().vms.get(vmId);
          const status = mapFreestyleBetaState(data.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": data.state, "cmux.vm.status": status });
          return status;
        } catch (err) {
          if (isBetaNotFound(err)) return "destroyed";
          throw new ProviderError("freestyle", `getStatus(${vmId}) on beta`, err);
        }
      },
    );
  }

  /** Beta pause freezes memory, so a later start resumes the daemon in place. */
  async pause(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.pause",
      betaSpanAttributes(vmId, "pause"),
      async () => {
        try {
          await betaClient(CREATE_TIMEOUT_MS).vms.ref(vmId).pause();
        } catch (err) {
          throw new ProviderError("freestyle", `pause(${vmId}) on beta`, err);
        }
      },
    );
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      betaSpanAttributes(vmId, "resume"),
      async (span) => {
        try {
          const fs = betaClient(CREATE_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          const data = await vm.start();
          const status = mapFreestyleBetaState(data.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": data.state, "cmux.vm.status": status });
          // A memory-preserving pause keeps the daemon; a cold boot (the VM had
          // stopped) relies on the baked systemd unit. Heal best-effort so the
          // first attach doesn't race the unit; attach re-verifies anyway.
          try {
            await this.ensureCmuxTuiRunning(vm, vmId);
          } catch (healErr) {
            recordSpanError(span, healErr);
          }
          return {
            provider: "freestyle" as const,
            providerVmId: data.id,
            status,
            image: data.snapshotId ?? "freestyle:resumed",
            createdAt: Date.now(),
            providerMetadata: { [FREESTYLE_PLATFORM_METADATA_KEY]: "beta" },
          };
        } catch (err) {
          throw new ProviderError("freestyle", `resume(${vmId}) on beta`, err);
        }
      },
    );
  }

  async exec(vmId: string, command: string, opts?: { timeoutMs?: number }): Promise<ExecResult> {
    const timeoutMs = normalizeFreestyleBetaExecTimeout(opts?.timeoutMs);
    return withVmSpan(
      "cmux.vm.provider.exec",
      betaSpanAttributes(vmId, "exec", {
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      }),
      async (span) => {
        try {
          const fs = betaClient(timeoutMs + EXEC_OVERHEAD_TIMEOUT_MS);
          const r = await fs.vms.ref(vmId).exec({ command, timeoutMs });
          // statusCode is null when the guest killed the command at its timeout.
          const exitCode = r.statusCode ?? 124;
          setSpanAttributes(span, { "cmux.exec.exit_code": exitCode });
          return { exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
        } catch (err) {
          throw new ProviderError("freestyle", `exec(${vmId}) on beta`, err);
        }
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    return withVmSpan(
      "cmux.vm.provider.snapshot",
      betaSpanAttributes(vmId, "snapshot", {
        "cmux.snapshot.named": !!name,
        "cmux.timeout_ms": SNAPSHOT_TIMEOUT_MS,
      }),
      async (span) => {
        try {
          const fs = betaClient(SNAPSHOT_TIMEOUT_MS);
          // Beta snapshots capture memory + disk of a running or paused VM. The
          // caller's name goes to displayName only: slugs are unique per account
          // and a collision would fail the snapshot for a cosmetic label.
          const out = await fs.vms.ref(vmId).snapshot(name ? { displayName: name } : undefined);
          if (!out.snapshotId) throw new Error("snapshot response missing snapshotId");
          setSpanAttributes(span, { "cmux.snapshot.id": out.snapshotId });
          return { id: out.snapshotId, createdAt: Date.now(), name };
        } catch (err) {
          throw new ProviderError("freestyle", `snapshot(${vmId}) on beta`, err);
        }
      },
    );
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.restore",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "restore",
        "cmux.snapshot.id": snapshotId,
        "cmux.vm.platform": "beta",
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = betaClient(CREATE_TIMEOUT_MS);
          const { vm, vmId } = await fs.vms.create({
            snapshotId,
            displayName: "cmux Cloud VM",
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleBetaFirewallRules() },
          });
          setSpanAttributes(span, { "cmux.vm.id": vmId });
          // The snapshot carries the installed binary and the persisted
          // model-plane file; heal best-effort so the machine is attach-ready
          // without failing restore on a transient error.
          await this.ensureCmuxTuiRunning(vm, vmId).catch(() => undefined);
          return {
            provider: "freestyle" as const,
            providerVmId: vmId,
            status: "running" as const,
            image: snapshotId,
            createdAt: Date.now(),
            providerMetadata: { [FREESTYLE_PLATFORM_METADATA_KEY]: "beta" },
          };
        } catch (err) {
          throw new ProviderError("freestyle", `restore(${snapshotId}) on beta`, err);
        }
      },
    );
  }

  async openCmuxRemote(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_cmux_remote",
      betaSpanAttributes(vmId, "open_cmux_remote"),
      async (span) => {
        try {
          const fs = betaClient(CMUX_TUI_INSTALL_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          const data = await vm.data();
          const route = freestyleBetaCmuxRemoteRoute(data.publicIpv6, vmId);
          await this.ensureCmuxTuiRunning(vm, vmId);
          const invoke = this.cmuxTuiInvoke(vm);
          // Direct-IPv6 carries no URL token; this one exists only for the
          // lease ledger. The daemon's Noise enrollment is the session gate —
          // the same trust model as E2B's public proxy route.
          const token = `cmux-freestyle-route-${randomBytes(32).toString("hex")}`;
          const expiresAtUnix = Math.floor(Date.now() / 1000) + ROUTE_TOKEN_TTL_SECONDS;
          let invitation: CmuxRemoteEndpoint["invitation"];
          const enrolled = options?.deviceFingerprint
            ? await isCmuxTuiDeviceEnrolled(invoke, options.deviceFingerprint)
            : false;
          if (!enrolled) {
            invitation = await mintCmuxTuiInvitation(invoke, "freestyle", vmId);
          }
          span.setAttribute("cmux.vm.cmux_remote.invited", !enrolled);
          const daemonBuild = await cmuxTuiDaemonBuild(invoke);
          return {
            transport: "cmux-remote" as const,
            route,
            token,
            expiresAtUnix,
            session: CMUX_TUI_SESSION,
            ...(daemonBuild ? { daemonBuild } : {}),
            ...(invitation ? { invitation } : {}),
          };
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("freestyle", `openCmuxRemote(${vmId}) on beta failed`, err);
        }
      },
    );
  }

  async approveCmuxRemoteEnrollment(vmId: string, invitationId: string): Promise<CmuxRemoteApprovalResult> {
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      betaSpanAttributes(vmId, "approve_cmux_remote_enrollment"),
      async () => {
        try {
          const vm = betaClient().vms.ref(vmId);
          return await approveCmuxTuiEnrollment(this.cmuxTuiInvoke(vm), "freestyle", vmId, invitationId);
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("freestyle", `approveCmuxRemoteEnrollment(${vmId}) on beta failed`, err);
        }
      },
    );
  }

  /** Installs the pinned binary, persists the model-plane env, starts the daemon (fresh create). */
  private async bootstrapCmuxTui(vm: Vm, vmId: string, envs?: Readonly<Record<string, string>>): Promise<void> {
    const source = await resolveCmuxTuiSource("freestyle");
    await this.execOrThrow(vm, vmId, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS)
      .catch((err: unknown) => {
        throw new ProviderError("freestyle", `cmux-tui install in ${vmId} failed: ${errorMessage(err)}`);
      });
    if (envs) await this.writeModelPlaneEnv(vm, vmId, envs);
    await this.execOrThrow(vm, vmId, freestyleBetaStartDaemonCommand(), 60_000);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(vm), "freestyle", vmId);
  }

  /**
   * Beta has no create-time env. The coderouter model-plane vars are delivered
   * by writing the persisted file /etc/cmux/agent-config.sh already reads
   * (0600, root); every shell the daemon spawns sources it through the
   * profile/bashrc chain and materializes the harness configs from it.
   */
  private async writeModelPlaneEnv(vm: Vm, vmId: string, envs: Readonly<Record<string, string>>): Promise<void> {
    const content = renderFreestyleModelPlaneEnvFile(envs);
    if (!content) return;
    try {
      await vm.exec({ command: `mkdir -p ${MODEL_PLANE_ENV_PATH.replace(/\/[^/]+$/, "")}`, timeoutMs: 30_000 });
      await vm.fs.writeTextFile(MODEL_PLANE_ENV_PATH, content, { mode: 0o600 });
    } catch (err) {
      throw new ProviderError("freestyle", `model-plane env write in ${vmId} failed`, err);
    }
  }

  /**
   * Attach-time heal, mirroring the other cmux-tui drivers: a daemon that is
   * running AND listening dual-stack is left alone; anything else is repaired,
   * reinstalling first when the binary is missing or superseded by a manifest
   * pin change. The dual-stack check matters because a machine from an older
   * bake boots the daemon on 0.0.0.0, which the public-IPv6 route cannot reach.
   */
  private async ensureCmuxTuiRunning(vm: Vm, vmId: string): Promise<void> {
    const healthy = await this.execResult(vm, freestyleBetaDaemonHealthyCommand());
    if (healthy?.exitCode === 0) return;
    const source = await resolveCmuxTuiSource("freestyle");
    const pinned = await this.execResult(vm, cmuxTuiPinCheckCommand(source));
    if (pinned?.exitCode !== 0) {
      await this.execOrThrow(vm, vmId, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS)
        .catch((err: unknown) => {
          throw new ProviderError("freestyle", `cmux-tui install in ${vmId} failed: ${errorMessage(err)}`);
        });
    }
    await this.execOrThrow(vm, vmId, freestyleBetaStartDaemonCommand(), 60_000);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(vm), "freestyle", vmId);
  }

  private async execResult(vm: Vm, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult | null> {
    try {
      const r = await vm.exec({ command, timeoutMs });
      return { exitCode: r.statusCode ?? 124, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
    } catch {
      return null;
    }
  }

  private async execOrThrow(vm: Vm, vmId: string, command: string, timeoutMs: number): Promise<ExecResult> {
    const r = await vm.exec({ command, timeoutMs });
    const exitCode = r.statusCode ?? 124;
    if (exitCode !== 0) {
      throw new Error(`beta exec in ${vmId} exited ${exitCode}: ${(r.stderr ?? r.stdout ?? "").trim().slice(0, 500)}`);
    }
    return { exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
  }

  private cmuxTuiInvoke(vm: Vm): CmuxTuiInvoke {
    return async (args, timeoutMs) => {
      const r = await this.execResult(vm, `env HOME=/root /root/.cmux/bin/cmux-tui ${args}`, timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS);
      return r ?? { exitCode: 124, stdout: "", stderr: "exec failed" };
    };
  }
}
