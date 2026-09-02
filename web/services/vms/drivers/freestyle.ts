import { Freestyle, FreestyleApiError, type VmData, type Vm } from "freestyle";
import { randomBytes } from "node:crypto";
import {
  ProviderError,
  type AttachEndpoint,
  type AttachOptions,
  type AttachTransport,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteApprovalOptions,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
  type CreateOptions,
  type ExecOptions,
  type ExecResult,
  type RestoreOptions,
  type SSHEndpoint,
  type SnapshotRef,
  type VmEdgeRule,
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

// The Freestyle driver, on the public platform (api.freestyle.sh /v5, SDK
// freestyle@0.2.x). This is the only Freestyle arm: the legacy 0.1.x platform
// (SSH gateway, cmuxd-remote WebSocket PTY on 7777) has been removed,
// so every Freestyle machine now attaches the same way every other cmux Cloud
// machine does.
//
// Machines attach through the cmux-tui remote daemon (transport `cmux-remote`,
// docs/cloud-cmux-tui-daemon.md). The API has
// no HTTP ingress proxy to arbitrary VM ports (TLS edge rules need a
// customer-verified domain), so the route is the VM's stable public IPv6
// straight to the daemon: `ws://[<publicIpv6>]:1337/v1/link`. The daemon's
// Noise handshake encrypts and authenticates the session end to end (carrier
// TLS is not required and the route token only feeds the lease ledger, exactly
// like E2B's public proxy). The daemon must therefore bind dual-stack: the
// baked systemd unit sets CMUX_TUI_REMOTE_WS_BIND=[::]:1337 and the driver
// re-asserts it on heal.
//
// Creates take NO ports field, NO create-time env, and NO systemd injection;
// `firewall` is mandatory. The coderouter model plane is edge-injected: the
// create carries an inline `tls` rule for the coderouter host whose
// transform adds `x-coderouter-route-token` and `x-cmux-vm-id` to every
// request the guest makes there. The platform steers the host to its edge
// (/etc/hosts) and installs its CA (/usr/local/share/ca-certificates/
// freestyle-tls.crt) at boot; rules added after boot never reach a running
// guest, so the rule must be inline. The guest env, delivered by writing the
// persisted /root/.config/cmux/model-plane.env (0600) that
// /etc/cmux/agent-config.sh sources, holds only base URLs and placeholder
// keys: no token is ever written into the guest. Injection becomes active
// 20-30 s after boot, so bootstrap ends with a guest-side readiness probe of
// https://<host>/v1/models and rolls the machine back if it never succeeds.

export const FREESTYLE_REMOTE_WS_BIND = `[::]:${CMUX_TUI_PORT}`;
export const FREESTYLE_ATTACH_TRANSPORT: AttachTransport = "cmux-remote";

/**
 * Every guest command runs as root. The 0.2 API's `linuxUser` default is not
 * root but "the account holding uid 1000, or root in an image with no such
 * account", and the cmux devbox image ships a uid-1000 user — so leaving this
 * off would silently move the daemon, its install, and the model-plane write
 * off the root layout they are baked around.
 */
const GUEST_LINUX_USER = "root";

const DEFAULT_TIMEOUT_MS = 60_000;
const CREATE_TIMEOUT_MS = 15 * 60 * 1000;
const SNAPSHOT_TIMEOUT_MS = 15 * 60 * 1000;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
/** The exec API rejects timeoutMs above 300000 (5 minutes per exec). */
const MAX_EXEC_TIMEOUT_MS = 300_000;
const EXEC_OVERHEAD_TIMEOUT_MS = 15_000;
const ROUTE_TOKEN_TTL_SECONDS = 12 * 60 * 60;
const MODEL_PLANE_ENV_PATH = "/root/.config/cmux/model-plane.env";
/** Guest-side edge probe: 30 attempts x (5 s curl + 2 s sleep) worst case, under the 300 s exec cap. */
const EDGE_PROBE_ATTEMPTS = 30;
const EDGE_PROBE_TIMEOUT_MS = 240_000;
const ENV_NAME = /^[A-Za-z_][A-Za-z0-9_]*$/;
const EDGE_DOMAIN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i;
const ROUTE_TOKEN_GRAMMAR = /\bcrt_[A-Za-z0-9._-]+/;

/**
 * The seams tests replace: the SDK client and the cmux-tui manifest read.
 * Production uses the env-configured client and the live manifest.
 */
export type FreestyleProviderDependencies = {
  readonly client: (timeoutMs?: number) => Freestyle;
  readonly resolveDaemonSource: typeof resolveCmuxTuiSource;
};

/**
 * FREESTYLE_API_URL stays as an operator escape hatch (a staging edge); unset,
 * the SDK's own default — the public api.freestyle.sh — is used. The
 * stack-token pair mirrors build-devbox-freestyle.ts for interactive use.
 */
function freestyleClient(timeoutMs = DEFAULT_TIMEOUT_MS): Freestyle {
  const longFetch: typeof fetch = (input, init) =>
    fetch(input as Request, { ...(init ?? {}), signal: AbortSignal.timeout(timeoutMs) });
  const baseUrl = process.env.FREESTYLE_API_URL?.trim() || undefined;
  const apiKey = process.env.FREESTYLE_API_KEY?.trim();
  if (apiKey) return new Freestyle({ apiKey, baseUrl, fetch: longFetch });
  const stackAccessToken = process.env.FREESTYLE_STACK_ACCESS_TOKEN?.trim();
  const teamId = process.env.FREESTYLE_TEAM_ID?.trim();
  if (stackAccessToken && teamId) {
    return new Freestyle({ stackAccessToken, teamId, baseUrl, fetch: longFetch });
  }
  throw new ProviderError(
    "freestyle",
    "freestyle requires FREESTYLE_API_KEY (or FREESTYLE_STACK_ACCESS_TOKEN + FREESTYLE_TEAM_ID)",
  );
}

/**
 * Outbound open (package installs, files.cmux.com, agents); inbound only the
 * cmux-tui daemon port. The mandatory `firewall` field defaults to NOTHING —
 * no outbound, no inbound — so both rules are stated. Session auth on 1337 is
 * the daemon's Noise device enrollment; the platform edge closing every other
 * port is the same posture the e2b driver builds by hand with iptables.
 */
export function freestyleFirewallRules() {
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
export function freestyleCmuxRemoteRoute(publicIpv6: string | null | undefined, vmId: string): string {
  const ipv6 = publicIpv6?.trim();
  if (!ipv6) {
    throw new ProviderError(
      "freestyle",
      `VM ${vmId} has no public IPv6 address, so its cmux-tui daemon is unreachable (the platform has no HTTP ingress to arbitrary ports)`,
    );
  }
  return `ws://[${ipv6}]:${CMUX_TUI_PORT}/v1/link`;
}

/**
 * Inline `tls` rules for a create: egress from the new VM (`source: {}`) to
 * the domain's real origin, with the edge injecting the rule's headers into
 * every request. Header values are write-only at the platform (read back as
 * `***`). Returns undefined for no rules so the create omits the block.
 */
export function freestyleEdgeRules(edgeRules: readonly VmEdgeRule[] | undefined) {
  if (!edgeRules || edgeRules.length === 0) return undefined;
  return edgeRules.map((rule) => {
    if (!EDGE_DOMAIN.test(rule.domain)) {
      throw new ProviderError("freestyle", `edge rule domain ${JSON.stringify(rule.domain)} is not a bare host name`);
    }
    return {
      action: "allow" as const,
      domain: rule.domain,
      source: {},
      destination: { public: true as const },
      transform: [{ headers: { ...rule.headers } }],
    };
  });
}

/**
 * Bounded guest-side loop, one exec: succeeds as soon as a request to the
 * edge-steered host returns 2xx (the injected token is live), fails after
 * ~60 s of 401s (injection not active yet) or connection errors. `-f` makes
 * curl exit non-zero on 401, and the CA the platform installed makes the
 * edge's certificate trusted without any flag.
 */
export function freestyleEdgeProbeCommand(host: string): string {
  if (!EDGE_DOMAIN.test(host)) {
    throw new ProviderError("freestyle", `edge probe host ${JSON.stringify(host)} is not a bare host name`);
  }
  return `for i in $(seq 1 ${EDGE_PROBE_ATTEMPTS}); do curl -fsS -o /dev/null --max-time 5 https://${host}/v1/models && exit 0; sleep 2; done; exit 1`;
}

/**
 * Nothing that reaches the guest (env file, exec command) may carry a route
 * token: the token lives only in the edge rule. Throws on the `crt_` grammar.
 */
export function assertNoRouteTokenInGuestPayload(values: Iterable<string>, what: string): void {
  for (const value of values) {
    if (ROUTE_TOKEN_GRAMMAR.test(value)) {
      throw new ProviderError("freestyle", `refusing to write a coderouter route token into the guest (${what})`);
    }
  }
}

/**
 * The persisted model-plane env file, byte-compatible with what
 * /etc/cmux/agent-config.sh itself writes from a boot env: shells that see no
 * boot env source this copy and then materialize the codex/pi/opencode
 * configs. Freestyle has no create-time env, so the driver writes the file.
 * Every key is rendered; OPENAI_BASE_URL is the anchor the generator keys on,
 * so its absence means "no model plane" and nothing is written.
 */
export function renderFreestyleModelPlaneEnvFile(envs: Readonly<Record<string, string>>): string | null {
  const baseUrl = envs.OPENAI_BASE_URL?.trim();
  if (!baseUrl) return null;
  assertNoRouteTokenInGuestPayload(Object.values(envs), MODEL_PLANE_ENV_PATH);
  const quote = (value: string) => `'${value.replace(/'/g, `'\\''`)}'`;
  const lines = ["# generated by cmux from machine boot env; managed, do not edit"];
  for (const [key, value] of Object.entries(envs)) {
    if (!ENV_NAME.test(key)) {
      throw new ProviderError("freestyle", `model-plane env key ${JSON.stringify(key)} is not a shell identifier`);
    }
    if (value === "") continue;
    lines.push(`export ${key}=${quote(value)}`);
  }
  return `${lines.join("\n")}\n`;
}

export function normalizeFreestyleExecTimeout(timeoutMs: number | undefined): number {
  if (typeof timeoutMs !== "number" || !Number.isFinite(timeoutMs) || timeoutMs <= 0) {
    return EXEC_DEFAULT_TIMEOUT_MS;
  }
  return Math.min(Math.floor(timeoutMs), MAX_EXEC_TIMEOUT_MS);
}

/**
 * `stopped` maps to paused, not destroyed: a stopped VM still exists and
 * `start()` boots it again (poweroff, an idle timeout, or a failure with
 * automaticRestart off all leave a recoverable machine).
 */
export function mapFreestyleState(state: VmData["state"] | null | undefined): VMStatus {
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
export function freestyleDaemonHealthyCommand(): string {
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
 * dual-stack bind.
 */
export function freestyleStartDaemonCommand(): string {
  return [
    "if [ -d /run/systemd/system ] && [ -f /etc/systemd/system/cmux-tui-daemon.service ]; then",
    `mkdir -p ${REMOTE_WS_BIND_OVERRIDE.replace(/\/[^/]+$/, "")};`,
    `printf '[Service]\\nEnvironment=CMUX_TUI_REMOTE_WS_BIND=${FREESTYLE_REMOTE_WS_BIND}\\n' > ${REMOTE_WS_BIND_OVERRIDE};`,
    "systemctl daemon-reload;",
    "systemctl restart cmux-tui-daemon;",
    "else",
    `pgrep -f 'cmux-tui server start' >/dev/null 2>&1 || (setsid nohup sh -c '${cmuxTuiDaemonCommand(FREESTYLE_REMOTE_WS_BIND)}' >>/tmp/cmux-tui-daemon.log 2>&1 &);`,
    "fi",
  ].join(" ");
}

function isNotFound(err: unknown): boolean {
  return err instanceof FreestyleApiError && (err.status === 404 || err.code === "NOT_FOUND");
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

function spanAttributes(vmId: string, operation: string, extra: Record<string, string | number | boolean> = {}) {
  return {
    "cmux.vm.provider": "freestyle",
    "cmux.vm.operation": operation,
    "cmux.vm.id": vmId,
    ...extra,
  };
}

export class FreestyleProvider implements VMProvider {
  readonly id = "freestyle" as const;

  /** The only session transport: the cmux-tui remote daemon (`openCmuxRemote`). */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  constructor(
    private readonly deps: FreestyleProviderDependencies = {
      client: freestyleClient,
      resolveDaemonSource: resolveCmuxTuiSource,
    },
  ) {}

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("freestyle", "create requires a resolved image");
    }
    const tlsRules = freestyleEdgeRules(options.edgeRules);
    return withVmSpan(
      "cmux.vm.provider.create",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "create",
        "cmux.vm.image": image,
        "cmux.vm.edge_rules": tlsRules?.length ?? 0,
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const { vm, vmId } = await fs.vms.create({
            snapshotId: image,
            displayName: "cmux Cloud VM",
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules() },
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          setSpanAttributes(span, { "cmux.vm.id": vmId });
          try {
            await this.bootstrapCmuxTui(vm, vmId, options);
          } catch (err) {
            // A VM that failed to bootstrap must not survive as an orphan.
            await vm.delete().catch((cleanupErr) => {
              console.error(`[freestyle] create rollback failed; VM ${vmId} may be orphaned`, cleanupErr);
            });
            throw err;
          }
          return {
            provider: "freestyle" as const,
            providerVmId: vmId,
            status: "running" as const,
            image,
            createdAt: Date.now(),
            providerMetadata: { ...(options.providerMetadata ?? {}) },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("freestyle", `create(${image}) failed`, err);
        }
      },
    );
  }

  async destroy(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.destroy",
      spanAttributes(vmId, "destroy"),
      async () => {
        try {
          await this.deps.client().vms.ref(vmId).delete();
        } catch (err) {
          if (isNotFound(err)) return; // already gone; destroy is idempotent
          throw new ProviderError("freestyle", `destroy(${vmId})`, err);
        }
      },
    );
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    return withVmSpan(
      "cmux.vm.provider.get_status",
      spanAttributes(vmId, "get_status"),
      async (span) => {
        try {
          const data = await this.deps.client().vms.get(vmId);
          const status = mapFreestyleState(data.state);
          setSpanAttributes(span, { "cmux.vm.provider_state": data.state, "cmux.vm.status": status });
          return status;
        } catch (err) {
          if (isNotFound(err)) return "destroyed";
          throw new ProviderError("freestyle", `getStatus(${vmId})`, err);
        }
      },
    );
  }

  /** Pause freezes memory, so a later start resumes the daemon in place. */
  async pause(vmId: string): Promise<void> {
    return withVmSpan(
      "cmux.vm.provider.pause",
      spanAttributes(vmId, "pause"),
      async () => {
        try {
          await this.deps.client(CREATE_TIMEOUT_MS).vms.ref(vmId).pause();
        } catch (err) {
          throw new ProviderError("freestyle", `pause(${vmId})`, err);
        }
      },
    );
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      spanAttributes(vmId, "resume"),
      async (span) => {
        try {
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          const data = await vm.start();
          const status = mapFreestyleState(data.state);
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
          };
        } catch (err) {
          throw new ProviderError("freestyle", `resume(${vmId})`, err);
        }
      },
    );
  }

  async exec(vmId: string, command: string, opts?: ExecOptions): Promise<ExecResult> {
    const timeoutMs = normalizeFreestyleExecTimeout(opts?.timeoutMs);
    return withVmSpan(
      "cmux.vm.provider.exec",
      spanAttributes(vmId, "exec", {
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      }),
      async (span) => {
        try {
          const fs = this.deps.client(timeoutMs + EXEC_OVERHEAD_TIMEOUT_MS);
          const r = await fs.vms.ref(vmId).exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
          // statusCode is null when the guest killed the command at its timeout.
          const exitCode = r.statusCode ?? 124;
          setSpanAttributes(span, { "cmux.exec.exit_code": exitCode });
          return { exitCode, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
        } catch (err) {
          throw new ProviderError("freestyle", `exec(${vmId})`, err);
        }
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    return withVmSpan(
      "cmux.vm.provider.snapshot",
      spanAttributes(vmId, "snapshot", {
        "cmux.snapshot.named": !!name,
        "cmux.timeout_ms": SNAPSHOT_TIMEOUT_MS,
      }),
      async (span) => {
        try {
          const fs = this.deps.client(SNAPSHOT_TIMEOUT_MS);
          // Snapshots capture memory + disk of a running or paused VM. The
          // caller's name goes to displayName only: slugs are unique per account
          // and a collision would fail the snapshot for a cosmetic label.
          const out = await fs.vms.ref(vmId).snapshot(name ? { displayName: name } : undefined);
          if (!out.snapshotId) throw new Error("snapshot response missing snapshotId");
          setSpanAttributes(span, { "cmux.snapshot.id": out.snapshotId });
          return { id: out.snapshotId, createdAt: Date.now(), name };
        } catch (err) {
          throw new ProviderError("freestyle", `snapshot(${vmId})`, err);
        }
      },
    );
  }

  async restore(snapshotId: string, options?: RestoreOptions): Promise<VMHandle> {
    const tlsRules = freestyleEdgeRules(options?.edgeRules);
    return withVmSpan(
      "cmux.vm.provider.restore",
      {
        "cmux.vm.provider": "freestyle",
        "cmux.vm.operation": "restore",
        "cmux.snapshot.id": snapshotId,
        "cmux.vm.edge_rules": tlsRules?.length ?? 0,
        "cmux.timeout_ms": CREATE_TIMEOUT_MS,
      },
      async (span) => {
        try {
          const fs = this.deps.client(CREATE_TIMEOUT_MS);
          const { vm, vmId } = await fs.vms.create({
            snapshotId,
            displayName: "cmux Cloud VM",
            metadata: { cmux: "cloud" },
            firewall: { rules: freestyleFirewallRules() },
            ...(tlsRules ? { tls: { rules: tlsRules } } : {}),
          });
          setSpanAttributes(span, { "cmux.vm.id": vmId });
          // The snapshot carries the installed binary and a persisted
          // model-plane file with placeholders only; heal best-effort so the
          // machine is attach-ready without failing restore on a transient
          // daemon error. The new machine's env (its own VM id) and edge rule
          // are mandatory: a snapshot never carries a token, so the restored
          // machine is unusable until its own injection is live.
          await this.ensureCmuxTuiRunning(vm, vmId).catch(() => undefined);
          try {
            if (options?.envs) await this.writeModelPlaneEnv(vm, vmId, options.envs);
            await this.probeEdgeRules(vm, vmId, options?.edgeRules);
          } catch (err) {
            await vm.delete().catch((cleanupErr) => {
              console.error(`[freestyle] restore rollback failed; VM ${vmId} may be orphaned`, cleanupErr);
            });
            throw err;
          }
          return {
            provider: "freestyle" as const,
            providerVmId: vmId,
            status: "running" as const,
            image: snapshotId,
            createdAt: Date.now(),
            providerMetadata: { ...(options?.providerMetadata ?? {}) },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("freestyle", `restore(${snapshotId})`, err);
        }
      },
    );
  }

  async openCmuxRemote(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_cmux_remote",
      spanAttributes(vmId, "open_cmux_remote"),
      async (span) => {
        try {
          const fs = this.deps.client(CMUX_TUI_INSTALL_TIMEOUT_MS + EXEC_OVERHEAD_TIMEOUT_MS);
          const vm = fs.vms.ref(vmId);
          const data = await vm.data();
          const route = freestyleCmuxRemoteRoute(data.publicIpv6, vmId);
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
            : new ProviderError("freestyle", `openCmuxRemote(${vmId}) failed`, err);
        }
      },
    );
  }

  async approveCmuxRemoteEnrollment(
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ): Promise<CmuxRemoteApprovalResult> {
    void options;
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      spanAttributes(vmId, "approve_cmux_remote_enrollment"),
      async () => {
        try {
          const vm = this.deps.client().vms.ref(vmId);
          return await approveCmuxTuiEnrollment(this.cmuxTuiInvoke(vm), "freestyle", vmId, invitationId);
        } catch (err) {
          throw err instanceof ProviderError
            ? err
            : new ProviderError("freestyle", `approveCmuxRemoteEnrollment(${vmId}) failed`, err);
        }
      },
    );
  }

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    void options;
    throw new ProviderError(
      "freestyle",
      `openAttach(${vmId}) is not supported: Freestyle machines attach through the cmux-tui remote daemon (transport cmux-remote).`,
    );
  }

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      spanAttributes(vmId, "open_ssh"),
      async () => {
        throw new ProviderError(
          "freestyle",
          "Freestyle machines have no SSH gateway on the public platform. " +
            "They attach through the cmux-tui remote daemon (transport cmux-remote).",
        );
      },
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // openSSH always throws, so there is never an identity to revoke.
  }

  /**
   * Installs the pinned binary, persists the model-plane env, starts the
   * daemon, then proves the edge rule is live (fresh create). Any failure
   * makes create() delete the machine.
   */
  private async bootstrapCmuxTui(
    vm: Vm,
    vmId: string,
    options: Pick<CreateOptions, "envs" | "edgeRules">,
  ): Promise<void> {
    const source = await this.deps.resolveDaemonSource("freestyle");
    await this.execOrThrow(vm, vmId, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS)
      .catch((err: unknown) => {
        throw new ProviderError("freestyle", `cmux-tui install in ${vmId} failed: ${errorMessage(err)}`);
      });
    if (options.envs) await this.writeModelPlaneEnv(vm, vmId, options.envs);
    await this.execOrThrow(vm, vmId, freestyleStartDaemonCommand(), 60_000);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(vm), "freestyle", vmId);
    await this.probeEdgeRules(vm, vmId, options.edgeRules);
  }

  /**
   * There is no create-time env. The coderouter model-plane vars (base URLs
   * and placeholder keys, never a token) are delivered by writing the
   * persisted file /etc/cmux/agent-config.sh already reads (0600, root);
   * every shell the daemon spawns sources it through the profile/bashrc
   * chain and materializes the harness configs from it.
   */
  private async writeModelPlaneEnv(vm: Vm, vmId: string, envs: Readonly<Record<string, string>>): Promise<void> {
    const content = renderFreestyleModelPlaneEnvFile(envs);
    if (!content) return;
    try {
      await vm.exec({
        command: `mkdir -p ${MODEL_PLANE_ENV_PATH.replace(/\/[^/]+$/, "")}`,
        timeoutMs: 30_000,
        linuxUser: GUEST_LINUX_USER,
      });
      await vm.fs.writeTextFile(MODEL_PLANE_ENV_PATH, content, { mode: 0o600 });
    } catch (err) {
      throw new ProviderError("freestyle", `model-plane env write in ${vmId} failed`, err);
    }
  }

  /**
   * Edge injection activates 20-30 s after boot and a guest request made
   * before that reaches coderouter without the token. Prove each rule from
   * inside the guest before handing the machine out; an inactive rule means
   * the machine can never reach a model, so the caller rolls it back.
   */
  private async probeEdgeRules(vm: Vm, vmId: string, edgeRules: readonly VmEdgeRule[] | undefined): Promise<void> {
    if (!edgeRules || edgeRules.length === 0) return;
    for (const rule of edgeRules) {
      const command = freestyleEdgeProbeCommand(rule.domain);
      assertNoRouteTokenInGuestPayload([command], "edge probe");
      const probe = await this.execResult(vm, command, EDGE_PROBE_TIMEOUT_MS);
      if (probe?.exitCode === 0) continue;
      throw new ProviderError(
        "freestyle",
        `edge rule for ${rule.domain} in ${vmId} is inactive: the guest probe of https://${rule.domain}/v1/models did not succeed (exit ${probe?.exitCode ?? "n/a"})`,
      );
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
    const healthy = await this.execResult(vm, freestyleDaemonHealthyCommand());
    if (healthy?.exitCode === 0) return;
    const source = await this.deps.resolveDaemonSource("freestyle");
    const pinned = await this.execResult(vm, cmuxTuiPinCheckCommand(source));
    if (pinned?.exitCode !== 0) {
      await this.execOrThrow(vm, vmId, cmuxTuiInstallCommand(source), CMUX_TUI_INSTALL_TIMEOUT_MS)
        .catch((err: unknown) => {
          throw new ProviderError("freestyle", `cmux-tui install in ${vmId} failed: ${errorMessage(err)}`);
        });
    }
    await this.execOrThrow(vm, vmId, freestyleStartDaemonCommand(), 60_000);
    await waitForCmuxTuiReady(this.cmuxTuiInvoke(vm), "freestyle", vmId);
  }

  private async execResult(vm: Vm, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult | null> {
    try {
      const r = await vm.exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
      return { exitCode: r.statusCode ?? 124, stdout: r.stdout ?? "", stderr: r.stderr ?? "" };
    } catch {
      return null;
    }
  }

  private async execOrThrow(vm: Vm, vmId: string, command: string, timeoutMs: number): Promise<ExecResult> {
    const r = await vm.exec({ command, timeoutMs, linuxUser: GUEST_LINUX_USER });
    const exitCode = r.statusCode ?? 124;
    if (exitCode !== 0) {
      throw new Error(`exec in ${vmId} exited ${exitCode}: ${(r.stderr ?? r.stdout ?? "").trim().slice(0, 500)}`);
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
