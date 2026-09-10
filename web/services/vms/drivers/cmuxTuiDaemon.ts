import { dirname } from "node:path";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../images/workUser";
import {
  ProviderError,
  type CmuxRemoteEndpoint,
  type ExecResult,
  type ProviderId,
} from "./types";

// cmux-tui is the ONE session daemon on every cmux Cloud machine
// (docs/cloud-cmux-tui-daemon.md). This module carries everything about it
// that is not provider-specific: the pinned-manifest source resolution, the
// sha256-verified install command, the daemon command, and the enrollment
// flows, parameterized over a provider exec so freestyle.ts keeps only its
// transport mechanics: how the daemon process is supervised and how port 1337
// is reached from outside.

export function shellQuote(value: string): string {
  return `'${value.replace(/'/g, `'\\''`)}'`;
}

export const CMUX_TUI_PORT = 1337;
export const CMUX_TUI_SESSION = "cloud";
/**
 * The daemon's cloud listener is reachable only inside the owner's private
 * network (every member is the owner's Mac or another of the owner's machines),
 * so it grants carrier authentication to every link: no device enrollment, no
 * invitation, no approval. The env form is what a systemd drop-in sets on a
 * machine whose baked launch line predates the flag; the daemon reads either.
 */
export const CMUX_TUI_TRUSTED_CARRIER_ENV = "CMUX_TUI_REMOTE_WS_TRUSTED_CARRIER";
export const CMUX_TUI_TRUSTED_CARRIER_FLAG = "--remote-ws-trusted-carrier";
export const CMUX_TUI_INSTALL_TIMEOUT_MS = 5 * 60 * 1000;

/**
 * Terminals on a cmux Cloud machine run as the image's work user, never root:
 * coding agents refuse root outright (`claude --dangerously-skip-permissions`
 * exits before it starts), and root is one passwordless `sudo` away anyway.
 * The user, its home and the machine name are the image contract
 * (services/vms/images/workUser.ts); everything here is the runtime half.
 *
 * Machines created from an image baked before that contract have no such user
 * and carry their daemon, binary and state under /root. Every command below
 * therefore picks the layout ON the machine (cmuxTuiLayoutSelector) instead of
 * assuming one, so one driver serves both until the last legacy machine is
 * recreated.
 */
export const CMUX_CLOUD_USER = DEVBOX_WORK_USER;
export const CMUX_CLOUD_HOME = DEVBOX_WORK_HOME;
/** The home, and so the daemon user, of a machine from a pre-work-user image. */
export const CMUX_TUI_LEGACY_HOME = "/root";
export const CMUX_TUI_BINARY_PATH = `${CMUX_CLOUD_HOME}/.cmux/bin/cmux-tui`;
export const CMUX_TUI_LEGACY_BINARY_PATH = `${CMUX_TUI_LEGACY_HOME}/.cmux/bin/cmux-tui`;
/** Which layout the running daemon chose; a breadcrumb for operators, not an input. */
export const CMUX_TUI_LAYOUT_MARKER_PATH = "/etc/cmux/daemon-layout";

/** Returns the durable cmux-tui binary path for a daemon home. */
export function cmuxTuiBinaryPath(home: string): string {
  return `${home}/.cmux/bin/cmux-tui`;
}

/**
 * Shell that sets CMUX_TUI_USER, CMUX_TUI_HOME, CMUX_TUI_BIN and
 * CMUX_TUI_LAYOUT to the layout this machine can actually serve. The work user
 * is used only when it can do the job it promises: it exists, its home is
 * writable by it, and it really has passwordless sudo. Anything else (a legacy
 * image, a broken sudoers) is the root layout — a degraded but working machine
 * beats a crash-looping daemon or a session trapped unprivileged.
 *
 * Install, pin check, daemon launch and every driver-side `cmux-tui` call run
 * this same selector, so they can never disagree about where the binary and
 * the daemon's state live.
 */
export function cmuxTuiLayoutSelector(): string {
  const user = CMUX_CLOUD_USER;
  const home = CMUX_CLOUD_HOME;
  return (
    `if id -u ${user} >/dev/null 2>&1 && command -v setpriv >/dev/null 2>&1 && ` +
    `setpriv --reuid=${user} --regid=${user} --init-groups test -w ${home} 2>/dev/null && ` +
    `setpriv --reuid=${user} --regid=${user} --init-groups sudo -n true >/dev/null 2>&1; then ` +
    `CMUX_TUI_USER=${user}; CMUX_TUI_HOME=${home}; CMUX_TUI_LAYOUT=user; ` +
    `else CMUX_TUI_USER=root; CMUX_TUI_HOME=${CMUX_TUI_LEGACY_HOME}; CMUX_TUI_LAYOUT=root; fi; ` +
    `CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui"`
  );
}

/**
 * Runs `cmux-tui <args>` as the daemon's own user, home and state dir. Every
 * driver-side call (status, enrollment, snapshots) goes through this: reading
 * the daemon's state as root when the daemon runs as the work user would find
 * an empty state dir and report a healthy machine as broken.
 */
export function cmuxTuiRunCommand(args: string): string {
  return `${cmuxTuiLayoutSelector()} && ${cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" ${args}`)}`;
}

/**
 * Runs `command` as the daemon's user, via setpriv rather than runuser or su.
 * setpriv EXECs in place, so the daemon is the direct child of its supervisor:
 * signals reach it (runuser does not forward SIGTERM, so stopping the unit
 * SIGKILLed the daemon and left a shutdown record its next start rejected with
 * "shutdown outcome belongs to a different daemon lifecycle"), `pgrep -f`
 * matches one process instead of a wrapper with a lower pid, and no PAM
 * session is opened and closed for every probe.
 */
export function cmuxTuiAsDaemonUser(command: string, options?: { readonly exec?: boolean }): string {
  // `exec` has to prefix the whole chain, not sit inside it: as an argument to
  // env it would name a program called "exec".
  const run = options?.exec === true ? "exec " : "";
  return (
    `if [ "$CMUX_TUI_USER" = root ]; then ${run}env HOME="$CMUX_TUI_HOME" ${CMUX_TUI_DAEMON_TERMINAL_ENV} ${command}; ` +
    `else ${run}setpriv --reuid="$CMUX_TUI_USER" --regid="$CMUX_TUI_USER" --init-groups ` +
    `env HOME="$CMUX_TUI_HOME" USER="$CMUX_TUI_USER" LOGNAME="$CMUX_TUI_USER" SHELL=/bin/bash ${CMUX_TUI_DAEMON_TERMINAL_ENV} ${command}; fi`
  );
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
export function cmuxTuiManifestUrl(provider: ProviderId = "freestyle"): string {
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
  provider: ProviderId = "freestyle",
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
export async function resolveCmuxTuiSource(provider: ProviderId = "freestyle"): Promise<CmuxTuiSource> {
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
 *
 * Runs as root and installs into the daemon's own home, so a work-user machine
 * gets a binary its sessions can execute (/root is 0700) and a legacy machine
 * keeps the one it already has.
 */
export function cmuxTuiInstallCommand(source: CmuxTuiSource): string {
  const bin = '"$CMUX_TUI_BIN"';
  const tmp = '"$CMUX_TUI_TMP"';
  const pinned = (path: string) => `printf '%s  %s\n' ${shellQuote(source.sha256)} ${path} | sha256sum -c >/dev/null 2>&1`;
  const fetch =
    `if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --retry-delay 2 -o ${tmp} ${shellQuote(source.url)}; ` +
    `elif command -v wget >/dev/null 2>&1; then wget -q -O ${tmp} ${shellQuote(source.url)}; ` +
    `else false; fi`;
  return [
    cmuxTuiLayoutSelector(),
    `CMUX_TUI_TMP="$CMUX_TUI_BIN.tmp"`,
    `mkdir -p "$(dirname "$CMUX_TUI_BIN")"`,
    `if [ -x ${bin} ] && ${pinned(bin)}; then :; else ${fetch} && ${pinned(tmp)} && chmod 755 ${tmp} && mv -f ${tmp} ${bin}; fi`,
    `ln -sfn ${bin} /usr/local/bin/cmux-tui`,
    // Only the nodes this install created, never the daemon's state tree.
    `if [ "$CMUX_TUI_USER" != root ]; then chown "$CMUX_TUI_USER:$CMUX_TUI_USER" "$CMUX_TUI_HOME/.cmux" "$CMUX_TUI_HOME/.cmux/bin" ${bin} 2>/dev/null || true; fi`,
    `${bin} --version`,
  ].join(" && ");
}

/** True when the installed binary matches the manifest pin (exit 0 from this command). */
export function cmuxTuiPinCheckCommand(source: CmuxTuiSource): string {
  return (
    `${cmuxTuiLayoutSelector()} && ` +
    `test -x "$CMUX_TUI_BIN" && printf '%s  %s\n' ${shellQuote(source.sha256)} "$CMUX_TUI_BIN" | sha256sum -c >/dev/null 2>&1`
  );
}

/**
 * Terminal identity every daemon-spawned pane inherits. The Mac app renders
 * each pane in its embedded Ghostty and exports the same identity to local and
 * SSH shells, so panes get TERM=xterm-256color, TERM_PROGRAM=ghostty, and
 * TERM_PROGRAM_VERSION from /etc/cmux/ghostty-version (the image's Ghostty
 * .deb pin, written by the devbox bake and Dockerfile; empty on images that
 * predate it). The daemon itself adds COLORTERM=truecolor at spawn. Agents
 * gate synchronized output, progress reporting, strikethrough, and Cmd-click
 * on TERM_PROGRAM. cmux-devbox-boot repeats this string byte for byte.
 */
export const CMUX_TUI_DAEMON_TERMINAL_ENV =
  'TERM=xterm-256color TERM_PROGRAM=ghostty TERM_PROGRAM_VERSION="$(cat /etc/cmux/ghostty-version 2>/dev/null)"';

/** The listener bind every container provider uses; cmux-devbox-boot's CMUX_TUI_REMOTE_WS_BIND default. */
export const CMUX_TUI_DEFAULT_REMOTE_WS_BIND = `0.0.0.0:${CMUX_TUI_PORT}`;

/**
 * The daemon command every supervisor runs: cmux-tui as the machine's daemon
 * user, cwd and HOME its home, so every terminal pane it opens is a shell of
 * that user in that home. `remoteWsBind` defaults to the IPv4 wildcard;
 * Freestyle machines are reached at a private VPC address and pass a
 * dual-stack `[::]` bind instead.
 *
 * The layout is chosen on the machine (cmuxTuiLayoutSelector), so a work-user
 * image serves non-root sessions and a machine from a pre-work-user image
 * keeps its root daemon and its /root state until it is recreated. The choice
 * is written to CMUX_TUI_LAYOUT_MARKER_PATH so a machine can be asked which
 * one it took.
 */
export function cmuxTuiDaemonCommand(
  remoteWsBind: string = CMUX_TUI_DEFAULT_REMOTE_WS_BIND,
): string {
  const args = `server start --session ${CMUX_TUI_SESSION} --remote-ws ${remoteWsBind} --remote-ws-insecure-bind ${CMUX_TUI_TRUSTED_CARRIER_FLAG}`;
  return (
    `${cmuxTuiLayoutSelector()}; ` +
    `{ mkdir -p /etc/cmux 2>/dev/null; printf '%s\\n' "$CMUX_TUI_LAYOUT" > ${CMUX_TUI_LAYOUT_MARKER_PATH}; } 2>/dev/null; ` +
    `cd "$CMUX_TUI_HOME" && ` +
    cmuxTuiAsDaemonUser(`"$CMUX_TUI_BIN" ${args}`, { exec: true })
  );
}

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
 * Runs `cmux-tui <args>` inside the VM as the daemon's own user and HOME (the
 * daemon's state home). Each provider supplies its own transport: Freestyle's
 * VM exec API.
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

/**
 * Everything attach needs from the daemon in ONE guest exec: an optional
 * readiness gate (exit 3 when it fails, so the caller can run the heal), the
 * daemon build (`remote-probe`), the enrolled devices (so a machine where the
 * caller is already enrolled is never restarted under it), and whether the
 * running daemon serves the trusted-carrier listener. Each section is fenced
 * by a marker line so the outputs parse independently.
 */
export const CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT = 3;
const BUNDLE_MARKERS = { probe: "__CMUX_PROBE__", devices: "__CMUX_DEVICES__", trusted: "__CMUX_TRUSTED__", end: "__CMUX_END__" } as const;

/**
 * Prints `1` when the daemon process that owns the cloud session serves the
 * trusted-carrier listener: it was started with the flag or the env, AND the
 * binary it runs parses the flag (`--remote-ws-trusted-carrier --version`
 * exits 0; an older binary rejects the unknown argument with exit 2 before
 * it reaches `--version`). An older binary ignores the env, so the env alone
 * proves nothing; asking the running binary itself also keeps the answer
 * honest while the pinned manifest and the machine's install disagree.
 * Anything else prints `0`.
 */
export function cmuxTuiDaemonPidSelector(): string {
  // NOT `pgrep ... | head -n1`: when the daemon runs as the work user its
  // launcher is `runuser -u cmux -- … cmux-tui server start …`, whose cmdline
  // matches the same pattern and whose pid is LOWER. Picking that wrapper made
  // the trusted-listener probe exec `runuser --remote-ws-trusted-carrier
  // --version`, which fails, so attach refused a perfectly healthy machine.
  // Select the process that IS the binary; comm is `cmux-tui` on both layouts.
  return (
    "p=''; for cmux_tui_pid in $(pgrep -f 'cmux-tui server [s]tart' 2>/dev/null); do " +
    `if [ "$(cat /proc/$cmux_tui_pid/comm 2>/dev/null)" = cmux-tui ]; then p=$cmux_tui_pid; break; fi; done`
  );
}

export function cmuxTuiTrustedListenerProbe(): string {
  return (
    `${cmuxTuiDaemonPidSelector()}; ` +
    `if [ -n "$p" ] && { tr '\\0' '\\n' < "/proc/$p/environ" 2>/dev/null | grep -qx ${shellQuote(`${CMUX_TUI_TRUSTED_CARRIER_ENV}=1`)} || tr '\\0' '\\n' < "/proc/$p/cmdline" 2>/dev/null | grep -qx -- ${shellQuote(CMUX_TUI_TRUSTED_CARRIER_FLAG)}; }` +
    ` && "/proc/$p/exe" ${CMUX_TUI_TRUSTED_CARRIER_FLAG} --version >/dev/null 2>&1; then echo 1; else echo 0; fi`
  );
}

export function cmuxTuiAttachBundleCommand(options: {
  readonly readyGate?: string;
  readonly deviceFingerprint?: string;
  readonly binary?: string;
}): string {
  // The enrolled-device list lives in the DAEMON's state dir, so every call
  // here has to be the daemon's user and HOME. Reading it as root on a
  // work-user machine would find an empty state dir and report a healthy
  // machine as un-enrolled.
  const bin = options.binary ? shellQuote(options.binary) : '"$CMUX_TUI_BIN"';
  // The arguments go INSIDE the drop-to-user block: it is an `if … fi`
  // compound statement, so anything appended after it is a separate command.
  const run = (args: string) => cmuxTuiAsDaemonUser(`${bin} ${args}`);
  const fingerprint = options.deviceFingerprint?.trim();
  if (fingerprint !== undefined && fingerprint !== "" && !/^[A-Za-z0-9._:=+/-]+$/.test(fingerprint)) {
    throw new Error("device fingerprint has an unexpected shape");
  }
  return [
    // Run the readiness probe in a subshell. The Freestyle gate uses `exit` for
    // its success and failure branches; without a subshell those exits terminate
    // the entire attach bundle before the probe, device, and invitation sections.
    ...(options.readyGate ? [`( ${options.readyGate}; ) || exit ${CMUX_TUI_ATTACH_BUNDLE_NOT_READY_EXIT}`] : []),
    cmuxTuiLayoutSelector(),
    `echo ${BUNDLE_MARKERS.probe}`,
    `${run("remote-probe --json")}; echo`,
    `echo ${BUNDLE_MARKERS.devices}`,
    `${run(`remote enroll devices --session ${CMUX_TUI_SESSION} --json`)}; echo`,
    `echo ${BUNDLE_MARKERS.trusted}`,
    cmuxTuiTrustedListenerProbe(),
    `echo ${BUNDLE_MARKERS.end}`,
  ].join("; ");
}

export type CmuxTuiAttachBundle = {
  readonly daemonBuild: CmuxRemoteEndpoint["daemonBuild"] | null;
  /** The caller's device is on the daemon's enrolled list (only known when a fingerprint was given). */
  readonly enrolled: boolean;
  /** The running daemon grants carrier authentication on its cloud listener. */
  readonly trustedCarrier: boolean;
};

/** Parses the fenced stdout of {@link cmuxTuiAttachBundleCommand}. */
export function parseCmuxTuiAttachBundle(
  stdout: string,
  provider: ProviderId,
  vmId: string,
  deviceFingerprint?: string,
): CmuxTuiAttachBundle {
  const section = (from: string, to: string): string => {
    const start = stdout.indexOf(from);
    const end = stdout.indexOf(to);
    if (start === -1 || end === -1 || end < start) return "";
    return stdout.slice(start + from.length, end).trim();
  };
  const probeText = section(BUNDLE_MARKERS.probe, BUNDLE_MARKERS.devices);
  const devicesText = section(BUNDLE_MARKERS.devices, BUNDLE_MARKERS.trusted);
  const trustedText = section(BUNDLE_MARKERS.trusted, BUNDLE_MARKERS.end);
  let daemonBuild: CmuxTuiAttachBundle["daemonBuild"] = null;
  try {
    const record = parseJsonObject(probeText);
    const commit = typeof record.build_identity === "string" ? record.build_identity : null;
    const remoteProtocol = typeof record.remote_protocol === "number" ? record.remote_protocol : null;
    const version = typeof record.version === "string" ? record.version : null;
    if (commit || remoteProtocol !== null) daemonBuild = { commit, remoteProtocol, version };
  } catch {
    daemonBuild = null;
  }
  let enrolled = false;
  if (deviceFingerprint) {
    try {
      enrolled = parseJsonArray(devicesText).some((device) =>
        device.fingerprint === deviceFingerprint && (device.revoked_at_unix === null || device.revoked_at_unix === undefined)
      );
    } catch {
      enrolled = false;
    }
  }
  // Fail closed: a missing or malformed section means the caller must heal.
  const trustedCarrier = trustedText.split("\n").pop()?.trim() === "1";
  void provider;
  void vmId;
  return { daemonBuild, enrolled, trustedCarrier };
}
