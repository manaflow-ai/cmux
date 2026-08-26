// The cmuxd-remote attach ritual, shared by every VM driver: discover where the in-VM daemon
// reads its lease files, mint a one-use PTY lease, reuse-or-mint the long-lived RPC lease, and
// install the lease files atomically inside the VM. Each driver supplies only a
// `ProviderTransport` (how to run a shell command in its VM); everything else is identical
// across providers, which is what makes the provider layer swappable.

import { randomBytes } from "node:crypto";
import * as Cause from "effect/Cause";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Option from "effect/Option";
import * as Schedule from "effect/Schedule";
import type { ExecResult, ProviderId } from "./types";
import {
  CMUXD_WS_LEGACY_PTY_LEASE_PATH,
  CMUXD_WS_PTY_LEASE_PATH,
  CMUXD_WS_PTY_LEASE_TTL_SECONDS,
  CMUXD_WS_RPC_CLIENT_PATH,
  CMUXD_WS_RPC_LEASE_TTL_SECONDS,
  CMUXD_WS_RPC_RENEW_BEFORE_SECONDS,
  HEALTH_CHECK_TIMEOUT_MS,
  HEALTH_RETRY_ATTEMPTS,
  HEALTH_RETRY_INTERVAL_MS,
} from "./cmuxdConstants";
import {
  ensurePrivateDirectoryCommand,
  isReusableRpcLease,
  leaseClientMetadata,
  makeWebSocketAttachmentId,
  makeWebSocketLease,
  shellArgValue,
  shellQuote,
  type ReusableRpcLease,
  type WebSocketLease,
} from "./wsLease";

/**
 * The two primitives a driver must provide for the shared attach ritual. `exec` runs a shell
 * command inside the VM and reports the exit code and streams; it may either return a non-zero
 * exit code or throw on failure (both SDK styles exist), and the shared code handles both.
 */
export type ProviderTransport = {
  readonly providerId: ProviderId;
  exec(command: string, timeoutMs?: number): Promise<ExecResult>;
};

export type CmuxdServicePaths = {
  ptyLeasePath: string;
  rpcLeasePath: string | null;
};

const DEFAULT_DISCOVERY_COMMAND = "ps auxww | grep cmuxd-remote | grep -v grep || true";

/**
 * Reads the lease paths the running cmuxd-remote was started with. The daemon fixes its lease
 * paths at process start (`--auth-lease-file`/`--rpc-auth-lease-file`), so this is the only
 * source of truth for where an attach must install leases. Falls back to the current default
 * path, or the legacy path when the process table shows an old daemon still using it.
 * Providers that manage the daemon themselves (and therefore know the flags) can skip this.
 */
export async function discoverCmuxdService(
  transport: ProviderTransport,
  opts?: { discoveryCommand?: string },
): Promise<CmuxdServicePaths> {
  const result = await transport.exec(opts?.discoveryCommand ?? DEFAULT_DISCOVERY_COMMAND);
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

/**
 * Returns the still-valid reusable RPC lease previously installed in this VM, or null when
 * there is none, it is malformed, or it expires within the renew window. Never throws: any
 * exec failure (missing files exit non-zero, some transports throw on that) means "no lease".
 */
export async function readReusableCmuxdRpcLease(
  transport: ProviderTransport,
  rpcLeasePath: string,
): Promise<ReusableRpcLease | null> {
  const result = await transport.exec(
    [
      `test -s ${shellQuote(rpcLeasePath)}`,
      `test -s ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
      `cat ${shellQuote(CMUXD_WS_RPC_CLIENT_PATH)}`,
    ].join(" && "),
  ).catch(() => null);
  if (!result || result.exitCode !== 0) return null;
  const raw = result.stdout.trim();
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

/**
 * Commands that install a JSON payload at `path` atomically: decode into a random temp name in
 * the same directory, chmod it closed, then `mv -f` over the target. The daemon polls/reads the
 * lease file on connect, so a direct `> path` redirect could expose a half-written lease; the
 * rename makes every observed state either the old file or the complete new one.
 */
export function atomicJsonInstallCommands(path: string, payload: unknown): string[] {
  const encoded = Buffer.from(JSON.stringify(payload)).toString("base64");
  const tempPath = `${path}.tmp-${randomBytes(6).toString("hex")}`;
  return [
    ensurePrivateDirectoryCommand(path),
    `printf '%s' '${encoded}' | base64 -d > ${shellQuote(tempPath)}`,
    `chmod 600 ${shellQuote(tempPath)}`,
    `mv -f ${shellQuote(tempPath)} ${shellQuote(path)}`,
  ];
}

export type CmuxdAttachLeases = {
  pty: WebSocketLease;
  attachmentId: string;
  daemon: ReusableRpcLease | null;
  daemonReused: boolean;
};

/**
 * Mints and installs the leases for one attach: a fresh one-use PTY lease always, plus (when
 * the daemon exposes an RPC lease path) either the reusable RPC lease already in the VM or a
 * newly minted one written alongside its client-metadata copy. One exec round-trip installs
 * everything atomically.
 */
export async function installCmuxdAttachLeases(
  transport: ProviderTransport,
  service: CmuxdServicePaths,
  options?: { sessionId?: string; attachmentId?: string; execTimeoutMs?: number },
): Promise<CmuxdAttachLeases> {
  const provider = transport.providerId;
  const pty = makeWebSocketLease(provider, "pty", true, CMUXD_WS_PTY_LEASE_TTL_SECONDS, options?.sessionId);
  const attachmentId = options?.attachmentId?.trim() || makeWebSocketAttachmentId(provider);
  const commands = [...atomicJsonInstallCommands(service.ptyLeasePath, pty.lease)];
  let daemon: ReusableRpcLease | null = null;
  let daemonReused = false;
  if (service.rpcLeasePath) {
    const existing = await readReusableCmuxdRpcLease(transport, service.rpcLeasePath);
    if (existing) {
      daemon = existing;
      daemonReused = true;
    } else {
      const minted = makeWebSocketLease(provider, "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
      daemon = minted;
      commands.push(
        ...atomicJsonInstallCommands(service.rpcLeasePath, minted.lease),
        ...atomicJsonInstallCommands(CMUXD_WS_RPC_CLIENT_PATH, leaseClientMetadata(minted)),
      );
    }
  }
  const result = await transport.exec(commands.join(" && "), options?.execTimeoutMs);
  if (result.exitCode !== 0) {
    throw new Error(
      `cmuxd lease install failed with status ${result.exitCode}: ${(result.stderr || result.stdout).trim()}`,
    );
  }
  return { pty, attachmentId, daemon, daemonReused };
}

/**
 * RPC-lease-only provisioning, for endpoints that ride alongside a non-PTY attach (Freestyle
 * SSH sessions still hand out the daemon RPC endpoint). Reuses the VM's valid lease or mints
 * and installs a replacement, exactly like the combined path.
 */
export async function installReusableCmuxdRpcLease(
  transport: ProviderTransport,
  rpcLeasePath: string,
): Promise<{ daemon: ReusableRpcLease; daemonReused: boolean }> {
  const existing = await readReusableCmuxdRpcLease(transport, rpcLeasePath);
  if (existing) return { daemon: existing, daemonReused: true };
  const minted = makeWebSocketLease(transport.providerId, "rpc", false, CMUXD_WS_RPC_LEASE_TTL_SECONDS);
  const commands = [
    ...atomicJsonInstallCommands(rpcLeasePath, minted.lease),
    ...atomicJsonInstallCommands(CMUXD_WS_RPC_CLIENT_PATH, leaseClientMetadata(minted)),
  ];
  const result = await transport.exec(commands.join(" && "));
  if (result.exitCode !== 0) {
    throw new Error(
      `cmuxd lease install failed with status ${result.exitCode}: ${(result.stderr || result.stdout).trim()}`,
    );
  }
  return { daemon: minted, daemonReused: false };
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

export type CmuxdHealthOptions = {
  /** Provider label baked into error messages, e.g. "Freestyle cmuxd websocket health check failed". */
  label: string;
  headers?: Record<string, string>;
  timeoutMs?: number;
};

/** One /healthz probe against the daemon's ingress URL. Throws with the provider-labeled message. */
export async function checkCmuxdHealthz(baseUrl: string, opts: CmuxdHealthOptions): Promise<void> {
  const response = await fetch(`${baseUrl.replace(/\/+$/, "")}/healthz`, {
    headers: opts.headers ?? {},
    signal: AbortSignal.timeout(opts.timeoutMs ?? HEALTH_CHECK_TIMEOUT_MS),
  }).catch((err: unknown) => {
    throw new Error(`${opts.label} cmuxd websocket health check failed: ${errorMessage(err)}`);
  });
  if (response.status !== 200) {
    throw new Error(`${opts.label} cmuxd websocket health check returned ${response.status}`);
  }
}

export async function isCmuxdHealthy(baseUrl: string, opts: CmuxdHealthOptions): Promise<boolean> {
  try {
    await checkCmuxdHealthz(baseUrl, opts);
    return true;
  } catch {
    return false;
  }
}

/**
 * Polls /healthz until it answers 200 or the attempts run out, then rethrows the last failure
 * unchanged (drivers and the Freestyle SSH-fallback classifier match on its message). The one
 * retry loop that used to exist in three hand-rolled idioms across the drivers, expressed as
 * an Effect Schedule: `attempts` total probes spaced `intervalMs` apart.
 */
export async function waitForCmuxdHealthy(
  baseUrl: string,
  opts: CmuxdHealthOptions & { attempts?: number; intervalMs?: number },
): Promise<void> {
  const attempts = Math.max(1, opts.attempts ?? HEALTH_RETRY_ATTEMPTS);
  const intervalMs = opts.intervalMs ?? HEALTH_RETRY_INTERVAL_MS;
  const probe = Effect.tryPromise({
    try: () => checkCmuxdHealthz(baseUrl, opts),
    catch: (err) => (err instanceof Error ? err : new Error(String(err))),
  });
  const policy = Schedule.intersect(
    Schedule.recurs(attempts - 1),
    Schedule.spaced(Duration.millis(intervalMs)),
  );
  const exit = await Effect.runPromiseExit(probe.pipe(Effect.retry(policy)));
  if (Exit.isFailure(exit)) {
    const failure = Cause.failureOption(exit.cause);
    throw Option.isSome(failure) ? failure.value : Cause.squash(exit.cause);
  }
}
