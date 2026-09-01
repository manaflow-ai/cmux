import { dirname } from "node:path";
import {
  ProviderError,
  type CmuxRemoteEndpoint,
  type ExecResult,
  type NativeRelayBootstrap,
  type ProviderId,
} from "./types";
import { shellQuote } from "./wsLease";

// cmux-tui is the ONE session daemon on every cmux Cloud machine
// (docs/cloud-cmux-tui-daemon.md). This module carries everything about it
// that is not provider-specific: the pinned-manifest source resolution, the
// sha256-verified install command, the daemon command, and the enrollment
// flows, all parameterized over a provider exec so blaxel.ts (sandbox API),
// e2b.ts (commands.run as root), and daytona.ts (toolbox exec) share one
// implementation. Providers keep only their process-supervision mechanics.

export const CMUX_TUI_PORT = 1337;
export const CMUX_TUI_SESSION = "cloud";
export const CMUX_TUI_BINARY_PATH = "/root/.cmux/bin/cmux-tui";
export const CMUX_TUI_INVITATION_TTL_SECONDS = 5 * 60;
export const CMUX_TUI_INSTALL_TIMEOUT_MS = 5 * 60 * 1000;
export const CMUX_NATIVE_RELAY_TICKET_PATH = "/usr/local/libexec/cmux-native-relay-ticket";
export const CMUX_NATIVE_RELAY_DAEMON_PATH = "/usr/local/libexec/cmux-native-relay-daemon";
/** Stable command-line marker left after the daemon helper execs cmux-tui. */
export const CMUX_NATIVE_RELAY_PROCESS_MARKER = `--relay-ticket-command ${CMUX_NATIVE_RELAY_TICKET_PATH}`;

/**
 * Guest-side liveness probe for the native daemon. Provider process APIs can
 * report the outer helper command, or omit the command altogether, so checking
 * only their metadata would either miss a healthy native process or restart it
 * on every attach.
 */
export function cmuxNativeRelayProcessHealthyCommand(): string {
  // The bracket expression keeps pgrep from matching the shell that is
  // running this probe. That shell contains the literal command text in its
  // argv while the daemon process contains the actual `cmux-tui` binary name.
  return `pgrep -af '[c]mux-tui server start' | grep -F -- '${CMUX_NATIVE_RELAY_PROCESS_MARKER}' >/dev/null 2>&1`;
}

export type CmuxTuiSource = { url: string; sha256: string; commit: string; builtAt: string | null };

export const CMUX_TUI_LINUX_TARGET = "cmux-tui-x86_64-unknown-linux-musl";
export const CMUX_TUI_DEFAULT_MANIFEST_URL = "https://files.cmux.com/cmux-tui/latest/manifest.json";
const CMUX_TUI_MANIFEST_CACHE_MS = 5 * 60 * 1000;

/**
 * CMUX_VM_CMUX_TUI_MANIFEST_URL pins a deployment to one commit's manifest
 * (`https://files.cmux.com/cmux-tui/<commit>/manifest.json`) instead of the rolling
 * `latest`. Nothing else is configured by hand: the build and its sha256 come from
 * the manifest the artifacts workflow publishes.
 */
export function cmuxTuiManifestUrl(provider: ProviderId = "blaxel"): string {
  const url = process.env.CMUX_VM_CMUX_TUI_MANIFEST_URL?.trim() || CMUX_TUI_DEFAULT_MANIFEST_URL;
  if (!/^https:\/\//.test(url)) {
    throw new ProviderError(provider, "CMUX_VM_CMUX_TUI_MANIFEST_URL must be an https:// URL");
  }
  return url;
}

/** Parses an artifacts manifest into the Linux source; the binary URL is a sibling of the manifest. */
export function parseCmuxTuiManifest(
  manifestUrl: string,
  manifest: unknown,
  provider: ProviderId = "blaxel",
): CmuxTuiSource {
  const record = manifest && typeof manifest === "object" ? manifest as Record<string, unknown> : {};
  const commit = typeof record.commit === "string" ? record.commit : "";
  const binaries = record.binaries && typeof record.binaries === "object" ? record.binaries as Record<string, unknown> : {};
  const sha256 = typeof binaries[CMUX_TUI_LINUX_TARGET] === "string" ? (binaries[CMUX_TUI_LINUX_TARGET] as string).toLowerCase() : "";
  if (!/^[0-9a-f]{40}$/.test(commit)) {
    throw new ProviderError(provider, `cmux-tui manifest at ${manifestUrl} has no commit`);
  }
  if (!/^[0-9a-f]{64}$/.test(sha256)) {
    throw new ProviderError(provider, `cmux-tui manifest at ${manifestUrl} has no ${CMUX_TUI_LINUX_TARGET} sha256 — publish artifacts from a main with the musl target`);
  }
  const base = manifestUrl.replace(/\/manifest\.json$/, "");
  return {
    url: `${base}/${CMUX_TUI_LINUX_TARGET}`,
    sha256,
    commit,
    builtAt: typeof record.builtAt === "string" ? record.builtAt : null,
  };
}

let cmuxTuiSourceCache: { url: string; fetchedAt: number; source: CmuxTuiSource } | null = null;

/** The Linux daemon build to install, from the manifest (cached 5 min per manifest URL). */
export async function resolveCmuxTuiSource(provider: ProviderId = "blaxel"): Promise<CmuxTuiSource> {
  const manifestUrl = cmuxTuiManifestUrl(provider);
  if (cmuxTuiSourceCache && cmuxTuiSourceCache.url === manifestUrl && Date.now() - cmuxTuiSourceCache.fetchedAt < CMUX_TUI_MANIFEST_CACHE_MS) {
    return cmuxTuiSourceCache.source;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 20_000);
  let manifest: unknown;
  try {
    const response = await fetch(manifestUrl, { signal: controller.signal, cache: "no-store" });
    if (!response.ok) {
      throw new ProviderError(provider, `cmux-tui manifest fetch ${manifestUrl} -> ${response.status}`);
    }
    manifest = await response.json();
  } catch (err) {
    if (cmuxTuiSourceCache?.url === manifestUrl) {
      // A transient manifest outage must not break creates: reuse the last good build.
      return cmuxTuiSourceCache.source;
    }
    throw err instanceof ProviderError ? err : new ProviderError(provider, `cmux-tui manifest fetch ${manifestUrl} failed`, err);
  } finally {
    clearTimeout(timer);
  }
  const source = parseCmuxTuiManifest(manifestUrl, manifest, provider);
  cmuxTuiSourceCache = { url: manifestUrl, fetchedAt: Date.now(), source };
  return source;
}

/** Test hook. */
export function resetCmuxTuiSourceCache(): void {
  cmuxTuiSourceCache = null;
}

/**
 * Installs the pinned cmux-tui binary onto the machine, skipping the download when
 * the installed copy already matches the pin. The VM fetches the ~50 MB static musl
 * binary itself (in-region, seconds) instead of the driver pushing a base64 payload
 * through the provider API on every cold create.
 */
export function cmuxTuiInstallCommand(source: CmuxTuiSource): string {
  const bin = shellQuote(CMUX_TUI_BINARY_PATH);
  const tmp = shellQuote(`${CMUX_TUI_BINARY_PATH}.tmp`);
  const pinned = (path: string) => `printf '%s  %s\n' ${shellQuote(source.sha256)} ${path} | sha256sum -c >/dev/null 2>&1`;
  // A stock blaxel/base-image has no curl until background provisioning adds it, so
  // the fetch installs curl itself (apk, Alpine) and falls back to busybox wget.
  const fetch =
    `(command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1 || true); ` +
    `if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --retry-delay 2 -o ${tmp} ${shellQuote(source.url)}; ` +
    `else wget -q -O ${tmp} ${shellQuote(source.url)}; fi`;
  return [
    `mkdir -p ${shellQuote(dirname(CMUX_TUI_BINARY_PATH))}`,
    `if [ -x ${bin} ] && ${pinned(bin)}; then :; else ` +
      `${fetch} && ${pinned(tmp)} && chmod 755 ${tmp} && mv -f ${tmp} ${bin}; fi`,
    `ln -sfn ${bin} /usr/local/bin/cmux-tui`,
    `${bin} --version`,
  ].join(" && ");
}

/** True when the installed binary matches the manifest pin (exit 0 from this command). */
export function cmuxTuiPinCheckCommand(source: CmuxTuiSource): string {
  return `test -x ${shellQuote(CMUX_TUI_BINARY_PATH)} && printf '%s  %s\n' ${shellQuote(source.sha256)} ${shellQuote(CMUX_TUI_BINARY_PATH)} | sha256sum -c >/dev/null 2>&1`;
}

/** The listener bind used by legacy provider-ingress mode. Native relay mode has no listener. */
export const CMUX_TUI_DEFAULT_REMOTE_WS_BIND = `0.0.0.0:${CMUX_TUI_PORT}`;

/**
 * The daemon command every provider's supervisor runs. Launch cwd = /root so
 * new terminals open in the persistent home. Legacy provider-ingress mode binds
 * `remoteWsBind`; native relay mode is deliberately outbound-only and does not
 * bind a network listener on the VM.
 */
export function cmuxTuiDaemonCommand(
  remoteWsBind: string = CMUX_TUI_DEFAULT_REMOTE_WS_BIND,
  nativeRelay?: NativeRelayBootstrap,
): string {
  if (!nativeRelay) {
    return `cd /root && env HOME=/root TERM=xterm-256color ${CMUX_TUI_BINARY_PATH} server start --session ${CMUX_TUI_SESSION} --remote-ws ${remoteWsBind} --remote-ws-insecure-bind`;
  }
  return [
    cmuxNativeRelayInstallCommand(),
    `cd /root && env HOME=/root TERM=xterm-256color ${CMUX_NATIVE_RELAY_DAEMON_PATH} ${shellQuote(remoteWsBind)}`,
  ].join(" && ");
}

/**
 * Install the two small, secret-free launch helpers used by a native relay
 * daemon. The bootstrap bearer stays in the provider environment; these
 * scripts only read it when cmux-tui asks for a fresh ticket.
 */
export function cmuxNativeRelayInstallCommand(): string {
  const ticket = Buffer.from(NATIVE_RELAY_TICKET_HELPER, "utf8").toString("base64");
  const daemon = Buffer.from(NATIVE_RELAY_DAEMON_HELPER, "utf8").toString("base64");
  return [
    `install -d -m 0700 ${shellQuote(dirname(CMUX_NATIVE_RELAY_TICKET_PATH))}`,
    `printf '%s' ${shellQuote(ticket)} | base64 -d > ${shellQuote(CMUX_NATIVE_RELAY_TICKET_PATH)}`,
    `printf '%s' ${shellQuote(daemon)} | base64 -d > ${shellQuote(CMUX_NATIVE_RELAY_DAEMON_PATH)}`,
    `chmod 0700 ${shellQuote(CMUX_NATIVE_RELAY_TICKET_PATH)} ${shellQuote(CMUX_NATIVE_RELAY_DAEMON_PATH)}`,
  ].join(" && ");
}

const NATIVE_RELAY_TICKET_HELPER = `#!/bin/sh
set -eu
shard="\${1:-}"
case "\$shard" in
  "") exit 64 ;;
  *[!A-Za-z0-9._-]*) exit 64 ;;
esac
ticket_url="\${CMUX_NATIVE_RELAY_TICKET_URL:-}"
bootstrap_token="\${CMUX_NATIVE_RELAY_BOOTSTRAP_TOKEN:-}"
[ -n "\$ticket_url" ] && [ -n "\$bootstrap_token" ] || exit 78
case "\$ticket_url" in
  https://*|http://127.0.0.1/*|http://127.0.0.1:*/*|http://localhost/*|http://localhost:*/*|http://\[::1\]/*|http://\[::1\]:*/*) ;;
  *) exit 78 ;;
esac
if command -v curl >/dev/null 2>&1; then
  exec curl --fail --silent --show-error --retry 3 --retry-all-errors --connect-timeout 5 --max-time 15 \\
    --proto '=https,http' -X POST -H "Authorization: Bearer \$bootstrap_token" \\
    "\$ticket_url?shard=\$shard"
fi
if command -v wget >/dev/null 2>&1; then
  exec wget -q -O - --post-data='' --timeout=15 --tries=3 --header="Authorization: Bearer \$bootstrap_token" \\
    "\$ticket_url?shard=\$shard"
fi
exit 69
`;

const NATIVE_RELAY_DAEMON_HELPER = `#!/bin/sh
set -eu
bind="\${1:-0.0.0.0:1337}"
case "\$bind" in
  *[!A-Za-z0-9.:\[\]-]*) exit 64 ;;
esac
shift || true
[ "\${CMUX_NATIVE_RELAY_ENABLED:-}" = "1" ] || exit 78
[ -n "\${CMUX_NATIVE_RELAY_TICKET_URL:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_BOOTSTRAP_TOKEN:-}" ] || exit 78
# Native helpers are installed only for relay mode. Do not fall back to an
# unauthenticated public WebSocket listener when bootstrap configuration is
# missing. The legacy bind argument is accepted for supervisor API
# compatibility, but native relay mode must never pass it to cmux-tui or open
# a direct listener.
[ "\$#" -eq 0 ] || exit 64
set -- server start --session cloud
[ -n "\${CMUX_NATIVE_RELAY_1_URL:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_1_SLOT:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_1_ID:-}" ] || exit 78
[ -n "\${CMUX_NATIVE_RELAY_2_URL:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_2_SLOT:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_2_ID:-}" ] || exit 78
if [ -n "\${CMUX_NATIVE_RELAY_1_URL:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_1_SLOT:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_1_ID:-}" ]; then
  [ -n "\${CMUX_NATIVE_RELAY_1_URL:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_1_SLOT:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_1_ID:-}" ] || exit 78
  set -- "\$@" --relay "\$CMUX_NATIVE_RELAY_1_URL" --relay-slot "\$CMUX_NATIVE_RELAY_1_SLOT" --relay-ticket-command /usr/local/libexec/cmux-native-relay-ticket --relay-ticket-command-arg "\$CMUX_NATIVE_RELAY_1_ID"
fi
if [ -n "\${CMUX_NATIVE_RELAY_2_URL:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_2_SLOT:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_2_ID:-}" ]; then
  [ -n "\${CMUX_NATIVE_RELAY_2_URL:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_2_SLOT:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_2_ID:-}" ] || exit 78
  set -- "\$@" --relay "\$CMUX_NATIVE_RELAY_2_URL" --relay-slot "\$CMUX_NATIVE_RELAY_2_SLOT" --relay-ticket-command /usr/local/libexec/cmux-native-relay-ticket --relay-ticket-command-arg "\$CMUX_NATIVE_RELAY_2_ID"
fi
if [ -n "\${CMUX_NATIVE_RELAY_3_URL:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_3_SLOT:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_3_ID:-}" ]; then
  [ -n "\${CMUX_NATIVE_RELAY_3_URL:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_3_SLOT:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_3_ID:-}" ] || exit 78
  set -- "\$@" --relay "\$CMUX_NATIVE_RELAY_3_URL" --relay-slot "\$CMUX_NATIVE_RELAY_3_SLOT" --relay-ticket-command /usr/local/libexec/cmux-native-relay-ticket --relay-ticket-command-arg "\$CMUX_NATIVE_RELAY_3_ID"
fi
if [ -n "\${CMUX_NATIVE_RELAY_4_URL:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_4_SLOT:-}" ] || [ -n "\${CMUX_NATIVE_RELAY_4_ID:-}" ]; then
  [ -n "\${CMUX_NATIVE_RELAY_4_URL:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_4_SLOT:-}" ] && [ -n "\${CMUX_NATIVE_RELAY_4_ID:-}" ] || exit 78
  set -- "\$@" --relay "\$CMUX_NATIVE_RELAY_4_URL" --relay-slot "\$CMUX_NATIVE_RELAY_4_SLOT" --relay-ticket-command /usr/local/libexec/cmux-native-relay-ticket --relay-ticket-command-arg "\$CMUX_NATIVE_RELAY_4_ID"
fi
exec /root/.cmux/bin/cmux-tui "\$@"
`;

/** Enrollment invitations are `cmux://enroll/<base64url JSON>`; the id and expiry inside are what the approve flow needs. */
export function parseEnrollmentInvitationUri(
  uri: string,
  provider: ProviderId = "blaxel",
): { id: string; expiresAtUnix: number; daemonFingerprint: string | null } {
  const prefix = "cmux://enroll/";
  if (!uri.startsWith(prefix)) {
    throw new ProviderError(provider, "cmux-tui returned an invitation with an unexpected scheme");
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(Buffer.from(uri.slice(prefix.length), "base64url").toString("utf8"));
  } catch (err) {
    throw new ProviderError(provider, "cmux-tui returned an undecodable invitation", err);
  }
  const record = parsed && typeof parsed === "object" ? parsed as Record<string, unknown> : {};
  const id = typeof record.id === "string" ? record.id : "";
  const expiresAtUnix = typeof record.expires_at_unix === "number" ? record.expires_at_unix : 0;
  if (!id || !expiresAtUnix) {
    throw new ProviderError(provider, "cmux-tui returned an invitation without an id or expiry");
  }
  return {
    id,
    expiresAtUnix,
    daemonFingerprint: typeof record.daemon_fingerprint === "string" ? record.daemon_fingerprint : null,
  };
}

export const ENROLLMENT_ID_PATTERN = /^[A-Za-z0-9._-]{1,128}$/;

export function parseJsonObject(text: string): Record<string, unknown> {
  try {
    const value = JSON.parse(text.trim());
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

export function parseJsonArray(text: string): Array<Record<string, unknown>> {
  try {
    const value = JSON.parse(text.trim());
    return Array.isArray(value)
      ? value.filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === "object")
      : [];
  } catch {
    return [];
  }
}

/**
 * Runs `cmux-tui <args>` inside the VM as root with HOME=/root (the daemon's state
 * home). Each provider supplies its own transport: Blaxel's sandbox API, E2B's
 * commands.run, Daytona's toolbox exec.
 */
export type CmuxTuiInvoke = (args: string, timeoutMs?: number) => Promise<ExecResult>;

export async function waitForCmuxTuiReady(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
): Promise<void> {
  let last = "";
  for (let attempt = 0; attempt < 15; attempt += 1) {
    const status = await invoke(`server status --session ${CMUX_TUI_SESSION}`).catch(() => null);
    if (status?.exitCode === 0) return;
    last = status ? (status.stderr || status.stdout) : "status probe failed";
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new ProviderError(provider, `cmux-tui daemon in ${vmId} did not become ready: ${last}`);
}

/** The installed daemon's build identity and remote protocol, so clients can name a mismatch instead of hanging. */
export async function cmuxTuiDaemonBuild(
  invoke: CmuxTuiInvoke,
): Promise<CmuxRemoteEndpoint["daemonBuild"] | null> {
  const probe = await invoke("remote-probe --json").catch(() => null);
  if (!probe || probe.exitCode !== 0) return null;
  const record = parseJsonObject(probe.stdout);
  const commit = typeof record.build_identity === "string" ? record.build_identity : null;
  const remoteProtocol = typeof record.remote_protocol === "number" ? record.remote_protocol : null;
  const version = typeof record.version === "string" ? record.version : null;
  if (!commit && remoteProtocol === null) return null;
  return { commit, remoteProtocol, version };
}

export async function mintCmuxTuiInvitation(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
): Promise<NonNullable<CmuxRemoteEndpoint["invitation"]>> {
  const created = await invoke(
    `remote enroll create --session ${CMUX_TUI_SESSION} --ttl ${CMUX_TUI_INVITATION_TTL_SECONDS} --json`,
  );
  if (created.exitCode !== 0) {
    throw new ProviderError(provider, `cmux-tui enrollment invitation in ${vmId} failed: ${created.stderr || created.stdout}`);
  }
  const uri = parseJsonObject(created.stdout).uri;
  if (typeof uri !== "string" || !uri) {
    throw new ProviderError(provider, `cmux-tui enrollment invitation in ${vmId} returned no uri`);
  }
  const parsed = parseEnrollmentInvitationUri(uri, provider);
  return { uri, invitationId: parsed.id, expiresAtUnix: parsed.expiresAtUnix };
}

export async function isCmuxTuiDeviceEnrolled(
  invoke: CmuxTuiInvoke,
  fingerprint: string,
): Promise<boolean> {
  const devices = await invoke(`remote enroll devices --session ${CMUX_TUI_SESSION} --json`).catch(() => null);
  if (!devices || devices.exitCode !== 0) return false;
  return parseJsonArray(devices.stdout).some((device) =>
    device.fingerprint === fingerprint && (device.revoked_at_unix === null || device.revoked_at_unix === undefined)
  );
}

export async function approveCmuxTuiEnrollment(
  invoke: CmuxTuiInvoke,
  provider: ProviderId,
  vmId: string,
  invitationId: string,
): Promise<{ approved: boolean; state: "approved" | "pending"; deviceFingerprint?: string }> {
  if (!ENROLLMENT_ID_PATTERN.test(invitationId)) {
    throw new ProviderError(provider, "invitation id has an unexpected shape");
  }
  const pending = await invoke(`remote enroll pending --session ${CMUX_TUI_SESSION} --json`);
  if (pending.exitCode !== 0) {
    throw new ProviderError(provider, `cmux-tui pending enrollments in ${vmId} failed: ${pending.stderr || pending.stdout}`);
  }
  const entries = parseJsonArray(pending.stdout);
  const match = entries.find((entry) => entry.invitation_id === invitationId);
  if (!match) {
    // The client has not claimed the invitation yet (or it expired); the caller polls.
    return { approved: false, state: "pending" };
  }
  const approved = await invoke(
    `remote enroll approve ${shellQuote(invitationId)} --session ${CMUX_TUI_SESSION} --json`,
  );
  if (approved.exitCode !== 0) {
    throw new ProviderError(provider, `cmux-tui enrollment approval in ${vmId} failed: ${approved.stderr || approved.stdout}`);
  }
  const device = parseJsonObject(approved.stdout);
  const fingerprint = typeof device.fingerprint === "string"
    ? device.fingerprint
    : typeof match.device_fingerprint === "string" ? match.device_fingerprint : undefined;
  return { approved: true, state: "approved", ...(fingerprint ? { deviceFingerprint: fingerprint } : {}) };
}
