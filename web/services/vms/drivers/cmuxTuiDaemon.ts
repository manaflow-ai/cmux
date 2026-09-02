import { dirname } from "node:path";
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
export const CMUX_TUI_BINARY_PATH = "/root/.cmux/bin/cmux-tui";
export const CMUX_TUI_INVITATION_TTL_SECONDS = 5 * 60;
export const CMUX_TUI_INSTALL_TIMEOUT_MS = 5 * 60 * 1000;
// A provider can attach the volume after the process starts, but a permanently
// missing volume must fail through the provider's restart/reconciliation path.
export const CMUX_TUI_PERSISTENT_MOUNT_WAIT_TIMEOUT_MS = 30_000;

// The non-root work user on cmux Cloud machines. Terminals must not run as root
// (coding agents refuse root, e.g. `claude --dangerously-skip-permissions`); root
// stays one passwordless `sudo` away. An image that bakes this user is driven
// through CMUX_CLOUD_LAYOUT; images without it keep the root daemon.
export const CMUX_CLOUD_USER = "cmux";
export const CMUX_CLOUD_HOME = "/home/cmux";

// Where the driver mounts the persistent home volume; a bindfs identity view
// presents it at CMUX_CLOUD_HOME (the volume's virtiofs squashes guest identity
// to root, so a plain mount cannot be a non-root home).
export const CMUX_CLOUD_HOME_VOLUME_BACKING_PATH = "/cmux/home";
const CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE = 75;

/**
 * Home layout the daemon runs under: which Unix user owns sessions, where its
 * home is, and (when the machine has a persistent volume) the backing mount the
 * home view maps. The backing path is the fail-over home: if the view is absent
 * while the backing is mounted, sessions must run as root on the backing path —
 * never on the writable-but-disposable rootfs dir at `home`, where user data
 * would die with the sandbox and be swept by the next bootstrap's junk clean.
 */
export type CmuxTuiHomeLayout = {
  readonly user: string;
  readonly home: string;
  readonly volumeBackingPath: string;
};

/** Runtime selection flags for a layout-aware daemon. */
export type CmuxTuiDaemonOptions = {
  /** The provider attached a persistent volume and must never use rootfs home. */
  readonly persistentVolumeExpected?: boolean;
};

export const CMUX_CLOUD_LAYOUT: CmuxTuiHomeLayout = {
  user: CMUX_CLOUD_USER,
  home: CMUX_CLOUD_HOME,
  volumeBackingPath: CMUX_CLOUD_HOME_VOLUME_BACKING_PATH,
};

/** Returns the durable cmux-tui binary path for a daemon home. */
export function cmuxTuiBinaryPath(home: string): string {
  return `${home}/.cmux/bin/cmux-tui`;
}

/** Waits for a provider-declared persistent home before touching its path. */
export function cmuxTuiPersistentMountWait(
  layout: CmuxTuiHomeLayout,
  persistentVolumeExpected: boolean,
): string {
  if (!persistentVolumeExpected) return "";
  const backing = layout.volumeBackingPath;
  return [
    // A pre-layout volume is valid at /root. New-layout volumes must be present
    // before any install or daemon path can touch the home directory.
    `if ! mountpoint -q /root 2>/dev/null && ! mountpoint -q ${backing} 2>/dev/null; then`,
    `mkdir -p ${backing} 2>/dev/null || true;`,
    // Re-check after creating the directory so a mount that arrives in the
    // handoff window is accepted without waiting for a future event.
    `if ! mountpoint -q /root 2>/dev/null && ! mountpoint -q ${backing} 2>/dev/null; then ` +
      // util-linux's timeout bounds the handoff wait. If the tool is too old
      // to expose it, fail closed instead of introducing an unbounded wait.
      // A mount can complete after the second check but before findmnt starts;
      // accept that race when the post-poll mountpoint check proves it is ready.
      `if command -v findmnt >/dev/null 2>&1 && findmnt --help 2>&1 | grep -q -- '--poll' && findmnt --help 2>&1 | grep -q -- '--timeout'; then if findmnt --poll=mount --timeout=${CMUX_TUI_PERSISTENT_MOUNT_WAIT_TIMEOUT_MS} --first-only --mountpoint ${backing} >/dev/null 2>&1; then :; elif mountpoint -q /root 2>/dev/null || mountpoint -q ${backing} 2>/dev/null; then :; else exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi; else exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi; ` +
      `fi;`,
    `if ! mountpoint -q /root 2>/dev/null && ! mountpoint -q ${backing} 2>/dev/null; then exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi;`,
    `fi;`,
  ].join(" ");
}

function cmuxTuiInstallHomeSelector(
  layout: CmuxTuiHomeLayout,
  persistentVolumeExpected = false,
): string {
  const root = shellQuote("/root");
  const backing = shellQuote(layout.volumeBackingPath);
  const home = shellQuote(layout.home);
  return (
    cmuxTuiPersistentMountWait(layout, persistentVolumeExpected) +
    `if mountpoint -q ${root} 2>/dev/null; then CMUX_TUI_HOME=${root}; ` +
    `elif mountpoint -q ${backing} 2>/dev/null; then CMUX_TUI_HOME=${backing}; ` +
    `else CMUX_TUI_HOME=${home}; fi`
  );
}

/** Selects the durable home used by a layout-aware install or pin check. */
export function cmuxTuiUserUsableCondition(layout: CmuxTuiHomeLayout): string {
  const { user, home, volumeBackingPath: backing } = layout;
  return (
    `command -v mountpoint >/dev/null 2>&1 && ` +
    // The layout daemon has to watch the FUSE view for a later unmount. Require
    // util-linux's event monitor here; without it the safe root fallback is used.
    `command -v findmnt >/dev/null 2>&1 && findmnt --help 2>&1 | grep -q -- '--poll' && ` +
    `(! mountpoint -q ${backing} 2>/dev/null || mountpoint -q ${home} 2>/dev/null) && ` +
    `[ "$(id -u ${user} 2>/dev/null || echo -1)" = "1001" ] && command -v bash >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 && ` +
    `command -v sudo >/dev/null 2>&1 && ` +
    `runuser -u ${user} -- test -w ${home} 2>/dev/null`
  );
}

/** Detects a mounted persistent volume whose identity view needs recovery. */
export function cmuxTuiHomeViewMissingCondition(layout: CmuxTuiHomeLayout): string {
  return `mountpoint -q ${layout.volumeBackingPath} 2>/dev/null && ! mountpoint -q ${layout.home} 2>/dev/null`;
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
 */
export function cmuxTuiInstallCommand(
  source: CmuxTuiSource,
  layout?: CmuxTuiHomeLayout,
  options?: CmuxTuiDaemonOptions,
): string {
  if (layout) {
    const selector = cmuxTuiInstallHomeSelector(layout, options?.persistentVolumeExpected === true);
    const bin = '"$CMUX_TUI_BIN"';
    const tmp = '"$CMUX_TUI_TMP"';
    const pinned = (path: string) => `printf '%s  %s\n' ${shellQuote(source.sha256)} ${path} | sha256sum -c >/dev/null 2>&1`;
    const fetch =
      `if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --retry-delay 2 -o ${tmp} ${shellQuote(source.url)}; ` +
      `elif command -v wget >/dev/null 2>&1; then wget -q -O ${tmp} ${shellQuote(source.url)}; ` +
      `else false; fi`;
    return [
      selector,
      `CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui"`,
      `CMUX_TUI_TMP="$CMUX_TUI_BIN.tmp"`,
      `mkdir -p "$(dirname "$CMUX_TUI_BIN")"`,
      `if [ -x ${bin} ] && ${pinned(bin)}; then :; else ${fetch} && ${pinned(tmp)} && chmod 755 ${tmp} && mv -f ${tmp} ${bin}; fi`,
      `ln -sfn ${bin} /usr/local/bin/cmux-tui`,
      // The volume is already identity-mapped by bindfs. Chown only the nodes this
      // install created, never the potentially large persistent state tree.
      `if [ "$CMUX_TUI_HOME" != '/root' ]; then chown ${layout.user}:${layout.user} "$CMUX_TUI_HOME/.cmux" "$CMUX_TUI_HOME/.cmux/bin" "$CMUX_TUI_BIN" 2>/dev/null || true; fi`,
      `${bin} --version`,
    ].join(" && ");
  }
  const binaryPath = CMUX_TUI_BINARY_PATH;
  const bin = shellQuote(binaryPath);
  const tmp = shellQuote(`${binaryPath}.tmp`);
  const pinned = (path: string) => `printf '%s  %s\n' ${shellQuote(source.sha256)} ${path} | sha256sum -c >/dev/null 2>&1`;
  // A stock minimal base image may have no curl until background provisioning adds
  // it, so the fetch installs curl itself (apk, Alpine) and falls back to busybox wget.
  const fetch =
    `(command -v curl >/dev/null 2>&1 || apk add --no-cache curl >/dev/null 2>&1 || true); ` +
    `if command -v curl >/dev/null 2>&1; then curl -fsSL --retry 3 --retry-delay 2 -o ${tmp} ${shellQuote(source.url)}; ` +
    `else wget -q -O ${tmp} ${shellQuote(source.url)}; fi`;
  return [
    `mkdir -p ${shellQuote(dirname(binaryPath))}`,
    `if [ -x ${bin} ] && ${pinned(bin)}; then :; else ` +
      `${fetch} && ${pinned(tmp)} && chmod 755 ${tmp} && mv -f ${tmp} ${bin}; fi`,
    `ln -sfn ${bin} /usr/local/bin/cmux-tui`,
    `${bin} --version`,
  ].join(" && ");
}

/** True when the installed binary matches the manifest pin (exit 0 from this command). */
export function cmuxTuiPinCheckCommand(
  source: CmuxTuiSource,
  layout?: CmuxTuiHomeLayout,
  options?: CmuxTuiDaemonOptions,
): string {
  if (layout) {
    return (
      `${cmuxTuiInstallHomeSelector(layout, options?.persistentVolumeExpected === true)} && ` +
      `CMUX_TUI_BIN="$CMUX_TUI_HOME/.cmux/bin/cmux-tui" && ` +
      `test -x "$CMUX_TUI_BIN" && printf '%s  %s\n' ${shellQuote(source.sha256)} "$CMUX_TUI_BIN" | sha256sum -c >/dev/null 2>&1`
    );
  }
  return `test -x ${shellQuote(CMUX_TUI_BINARY_PATH)} && printf '%s  %s\n' ${shellQuote(source.sha256)} ${shellQuote(CMUX_TUI_BINARY_PATH)} | sha256sum -c >/dev/null 2>&1`;
}

/** The listener bind every container provider uses; cmux-devbox-boot's CMUX_TUI_REMOTE_WS_BIND default. */
export const CMUX_TUI_DEFAULT_REMOTE_WS_BIND = `0.0.0.0:${CMUX_TUI_PORT}`;
// Rootfs state lets a driver distinguish an intentional root fallback from a
// still-running non-root daemon and reconcile it on attach.
export const CMUX_TUI_LAYOUT_MARKER_PATH = "/etc/cmux/daemon-layout";

const CMUX_TUI_BACKING_EXPECTED_VAR = "cmux_tui_backing_expected";
// Old/custom images may have mountpoint but not util-linux's findmnt poller.
// A one-second direct check keeps the durable root fallback alive without a
// busy loop and still notices a lost backing mount promptly.
const CMUX_TUI_MOUNT_WATCH_INTERVAL_SECONDS = 1;
// A daemon can be blocked in FUSE I/O and ignore TERM while its home disappears.
// Keep the restart path bounded, then force the child down so the provider can
// start the durable fallback.
const CMUX_TUI_CHILD_SHUTDOWN_GRACE_SECONDS = 2;
const CMUX_TUI_CHILD_SHUTDOWN_POLL_SECONDS = 0.02;
const CMUX_TUI_CHILD_SHUTDOWN_GRACE_POLLS = Math.round(
  CMUX_TUI_CHILD_SHUTDOWN_GRACE_SECONDS / CMUX_TUI_CHILD_SHUTDOWN_POLL_SECONDS,
);

/**
 * Runs a layout daemon with an event-driven mount watcher. A persistent mount
 * can disappear while the daemon remains alive; the watcher signals the
 * supervisor, stops the child, and returns a restartable failure code. The
 * provider then reevaluates the layout instead of allowing writes through a
 * disposable directory below a lost mountpoint.
 */
function cmuxTuiSupervisedDaemonInvocation(
  daemon: string,
  watchedMounts: readonly string[],
  watchCondition: string,
  unwatchableCondition?: string,
  layoutMarker: "user" | "root" = "user",
): string {
  const parentPid = "cmux_tui_supervisor_pid";
  const daemonPid = "cmux_tui_daemon_pid";
  const watcherPid = "cmux_tui_mount_watcher_pid";
  const pollPids = watchedMounts.map((_, index) => `cmux_tui_mount_poll_${index}`);
  const viewLost = "cmux_tui_view_lost";
  const daemonStatus = "cmux_tui_daemon_status";
  // The watcher runs in a background subshell, so its local assignments cannot
  // update the supervisor. The supervisor trap owns the state; repeated signals
  // are harmless and avoiding the assignment keeps the generated POSIX shell
  // honest about the cross-process handoff.
  const signalViewLost = `kill -USR1 "$${parentPid}" 2>/dev/null || true`;
  const anyMissing = watchedMounts
    .map((mount) => `! mountpoint -q ${mount} 2>/dev/null`)
    .join(" || ");
  const pollLoops = watchedMounts.map((mount, index) => [
    // A poll error is not a mount event. Fail closed and let the provider restart
    // the named process instead of retrying in a tight loop at full CPU.
    `( trap 'exit 143' TERM INT HUP; while :; do if findmnt --poll=umount,move,remount --first-only --mountpoint ${mount} >/dev/null 2>&1; then :; else ${signalViewLost}; break; fi;`,
    `if ${anyMissing}; then ${signalViewLost}; break; fi; done ) & ${pollPids[index]}=$!;`,
  ].join(" ")).join(" ");
  const pollCleanup = pollPids.length > 0
    ? `kill -TERM ${pollPids.map((pid) => `"$${pid}"`).join(" ")} 2>/dev/null || true;`
    : "";
  const pollWait = pollPids
    .map((pid) => `wait "$${pid}" 2>/dev/null || true;`)
    .join(" ");
  const mountWatcher = [
    `${pollPids.map((pid) => `${pid}=''`).join(" ")};`,
    `trap '${pollCleanup} exit 143' TERM INT HUP;`,
    // The expected-state snapshot closes the race between the outer branch and
    // watcher startup. Every selected persistent mount must still be present.
    `if ${watchCondition}; then`,
    `if ${anyMissing}; then ${signalViewLost};`,
    `elif command -v findmnt >/dev/null 2>&1 && findmnt --help 2>&1 | grep -q -- '--poll'; then`,
    // findmnt --poll blocks in the kernel until a mount event. Scope each poll
    // to one relevant mount so unrelated container mounts do not wake this loop.
    pollLoops,
    pollWait,
    `else`,
    // A mounted backing path is still a valid durable fallback when an old image
    // lacks findmnt. Poll mountpoint at a bounded interval instead of exiting the
    // daemon before it can serve the user's persistent home.
    `while :; do if ${anyMissing}; then ${signalViewLost}; break; fi; sleep ${CMUX_TUI_MOUNT_WATCH_INTERVAL_SECONDS}; done;`,
    `fi;`,
    unwatchableCondition
      ? `elif ${unwatchableCondition}; then ${signalViewLost}; fi`
      : `fi`,
  ].join(" ");
  const terminateChild = [
    `cmux_tui_terminate_child() {`,
    `cmux_tui_terminate_pid="$1";`,
    `if [ -z "$cmux_tui_terminate_pid" ]; then return 0; fi;`,
    `kill -TERM "$cmux_tui_terminate_pid" 2>/dev/null || true;`,
    // The grace-period helper polls the child instead of sleeping for the whole
    // period and being signalled: once the supervisor's wait reaps the child,
    // kill -0 fails and the helper exits on its own within one poll interval.
    // Nothing is signalled, so there is no race with dash's trap reset (a TERM
    // that lands while a forked subshell still carries the parent's trap is
    // dropped) and no orphaned sleep. A child that ignores TERM is KILLed at
    // the end of the grace period as before.
    `( cmux_tui_killer_polls=0;`,
    `while [ "$cmux_tui_killer_polls" -lt ${CMUX_TUI_CHILD_SHUTDOWN_GRACE_POLLS} ] && kill -0 "$cmux_tui_terminate_pid" 2>/dev/null; do`,
    `sleep ${CMUX_TUI_CHILD_SHUTDOWN_POLL_SECONDS}; cmux_tui_killer_polls=$((cmux_tui_killer_polls + 1)); done;`,
    // Only a child that outlived the whole grace period is KILLed, and its
    // liveness is rechecked right before the signal so the window in which a
    // reaped pid could be reused is the check-to-kill gap, not a poll interval.
    `if [ "$cmux_tui_killer_polls" -ge ${CMUX_TUI_CHILD_SHUTDOWN_GRACE_POLLS} ] && kill -0 "$cmux_tui_terminate_pid" 2>/dev/null; then kill -KILL "$cmux_tui_terminate_pid" 2>/dev/null || true; fi ) &`,
    `cmux_tui_killer_pid=$!;`,
    `wait "$cmux_tui_terminate_pid" 2>/dev/null || true;`,
    // Cancel the helper as soon as the child is reaped so it can never act on
    // a reused pid. KILL rather than TERM: dash forks the helper with the
    // parent's TERM trap still inherited and resets it afterwards, so a TERM
    // that lands in that window is dropped. The helper holds at most one
    // 20 ms sleep, so a KILL orphans nothing that matters.
    `kill -KILL "$cmux_tui_killer_pid" 2>/dev/null || true;`,
    `wait "$cmux_tui_killer_pid" 2>/dev/null || true;`,
    `}`,
  ].join(" ");
  return [
    `${viewLost}=0`,
    `${parentPid}=$$`,
    `${daemonPid}=''`,
    `${watcherPid}=''`,
    terminateChild,
    // USR1 is private to this supervisor. TERM/INT/HUP still stop both children
    // cleanly when a provider stops the named process during lease revocation.
    `trap '${viewLost}=1; cmux_tui_terminate_child "$${daemonPid}"' USR1`,
    `trap 'cmux_tui_terminate_child "$${daemonPid}"; cmux_tui_terminate_child "$${watcherPid}"; exit 143' TERM INT HUP`,
    `{ mkdir -p /etc/cmux 2>/dev/null; printf '${layoutMarker}\\n' > ${CMUX_TUI_LAYOUT_MARKER_PATH}; } 2>/dev/null`,
    // Group the complete selection and `cd` in the child. Without the group,
    // shell precedence backgrounds only the final command after a leading
    // guard, leaving a mount check and directory change in the supervisor before
    // the watcher can start.
    `( ${daemon} ) & ${daemonPid}=$!`,
    `( ${mountWatcher} ) & ${watcherPid}=$!`,
    `wait "$${daemonPid}"; ${daemonStatus}=$?`,
    // A signal trap can interrupt the first wait before the daemon has handled
    // TERM. Reap it before returning so the provider never restarts alongside
    // a still-running process that still points at the lost view.
    `if [ "$${viewLost}" -eq 1 ]; then cmux_tui_terminate_child "$${daemonPid}"; fi`,
    `cmux_tui_terminate_child "$${watcherPid}"`,
    `if [ "$${viewLost}" -eq 1 ]; then exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi`,
    `exit "$${daemonStatus}"`,
  ].join("; ");
}

/** Runs the non-root daemon while watching both the bindfs view and its backing mount. */
function cmuxTuiUserDaemonInvocation(
  layout: CmuxTuiHomeLayout,
  binary: string,
  args: string,
): string {
  const { user, home, volumeBackingPath: backing } = layout;
  const daemon =
    `if [ "$${CMUX_TUI_BACKING_EXPECTED_VAR}" -eq 1 ]; then ` +
    `if ! mountpoint -q ${home} 2>/dev/null || ! mountpoint -q ${backing} 2>/dev/null; then exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi; ` +
    `elif mountpoint -q ${home} 2>/dev/null; then exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi; ` +
    `cd ${home} 2>/dev/null || exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; ` +
    `exec runuser -u ${user} -- env HOME=${home} USER=${user} LOGNAME=${user} SHELL=/bin/bash TERM=xterm-256color ${binary} ${args}`;
  return cmuxTuiSupervisedDaemonInvocation(
    daemon,
    [home, backing],
    `[ "$${CMUX_TUI_BACKING_EXPECTED_VAR}" -eq 1 ]`,
    `mountpoint -q ${home} 2>/dev/null`,
  );
}

/** Runs a root fallback on persistent storage while watching that backing mount. */
function cmuxTuiBackingDaemonInvocation(
  layout: CmuxTuiHomeLayout,
  daemon: string,
): string {
  const backing = layout.volumeBackingPath;
  return cmuxTuiSupervisedDaemonInvocation(
    `if ! mountpoint -q ${backing} 2>/dev/null; then exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi; cd ${backing} 2>/dev/null || exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; ${daemon}`,
    [backing],
    ":",
    undefined,
    "root",
  );
}

/**
 * The daemon command every provider's supervisor runs. Launch cwd = the persistent
 * home so new terminals open there. `remoteWsBind` defaults to the IPv4 wildcard
 * the container providers' proxies dial; Freestyle machines are reached at
 * their public IPv6 and pass a dual-stack `[::]` bind instead (a container with
 * IPv6 disabled cannot bind `[::]` at all, so dual-stack is per-provider, not the
 * default).
 *
 * Without a layout the daemon (and so every terminal pane it spawns) runs as root
 * with HOME=/root — the model the Freestyle driver uses. With a layout the
 * daemon drops to the layout user via runuser, so panes are non-root shells
 * with passwordless sudo. Two guards keep
 * old machines working:
 *  - A sandbox from before the layout change mounts its persistent volume at
 *    /root (mountpoint -q /root); its data and daemon state live there, so it
 *    keeps the root daemon until it is resurrected onto the new mount path.
 *  - A machine where the user cannot actually use the home — no user or no
 *    runuser (stock Alpine base), or the bindfs identity view over the
 *    root-squashing volume failed to mount (the mount guard) — falls back
 *    to a root daemon rather than crash-looping or serving broken shells.
 * The layout branch also supervises the user daemon with a kernel mount-event
 * watcher. If the bindfs view disappears, it stops the user daemon and exits
 * with a restartable failure code; the provider then evaluates the layout again
 * and starts the root daemon on the persistent backing mount until the view is
 * repaired.
 */
export function cmuxTuiDaemonCommand(
  remoteWsBind: string = CMUX_TUI_DEFAULT_REMOTE_WS_BIND,
  layout?: CmuxTuiHomeLayout,
  options?: CmuxTuiDaemonOptions,
): string {
  const args = `server start --session ${CMUX_TUI_SESSION} --remote-ws ${remoteWsBind} --remote-ws-insecure-bind`;
  if (!layout) {
    return `cd /root && env HOME=/root TERM=xterm-256color ${CMUX_TUI_BINARY_PATH} ${args}`;
  }
  const { home, volumeBackingPath: backing } = layout;
  const persistentVolumeExpected = options?.persistentVolumeExpected === true;
  const bin = cmuxTuiBinaryPath(home);
  const backingBin = cmuxTuiBinaryPath(backing);
  const legacyBin = cmuxTuiBinaryPath("/root");
  const usableBase = cmuxTuiUserUsableCondition(layout);
  // A no-volume machine legitimately uses its disposable rootfs home.
  // A volume-backed machine must never silently switch to that path while its
  // mount is late or lost, because all writes there disappear on resurrection.
  const usable = persistentVolumeExpected
    ? `${usableBase} && mountpoint -q ${backing} 2>/dev/null`
    : usableBase;
  const backingDaemon =
    `if [ -x ${backingBin} ]; then exec env HOME=${backing} TERM=xterm-256color ${backingBin} ${args}; ` +
    `elif [ -x ${legacyBin} ]; then exec env HOME=${backing} TERM=xterm-256color ${legacyBin} ${args}; ` +
    `else exec env HOME=${backing} TERM=xterm-256color ${backingBin} ${args}; fi`;
  const backingInvocation = cmuxTuiBackingDaemonInvocation(layout, backingDaemon);
  const legacyDaemon =
    `if [ -x ${legacyBin} ]; then exec env HOME=/root TERM=xterm-256color ${legacyBin} ${args}; ` +
    `elif [ -x ${bin} ]; then exec env HOME=/root TERM=xterm-256color ${bin} ${args}; ` +
    `else exec env HOME=/root TERM=xterm-256color ${legacyBin} ${args}; fi`;
  const legacyInvocation = persistentVolumeExpected
    ? cmuxTuiSupervisedDaemonInvocation(
      `if ! mountpoint -q /root 2>/dev/null; then exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi; cd /root 2>/dev/null || exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; ${legacyDaemon}`,
      ["/root"],
      ":",
      undefined,
      "root",
    )
    : `cd /root && ${legacyDaemon}`;
  const rootFallbackInvocation =
    persistentVolumeExpected
      ? `if mountpoint -q ${backing} 2>/dev/null; then ${backingInvocation}; else exit ${CMUX_TUI_HOME_VIEW_LOST_EXIT_CODE}; fi`
      : `if mountpoint -q ${backing} 2>/dev/null; then ${backingInvocation}; ` +
        `else cd ${home} && exec env HOME=${home} TERM=xterm-256color ${bin} ${args}; fi`;
  const persistentVolumeGuard = cmuxTuiPersistentMountWait(layout, persistentVolumeExpected);
  return (
    // Snapshot the backing mount before selecting a branch. The watcher uses
    // this value to catch a backing unmount that happens between this branch
    // check and its first mountpoint probe.
    persistentVolumeGuard +
    `${CMUX_TUI_BACKING_EXPECTED_VAR}=${persistentVolumeExpected ? "1" : "0"}; ` +
    `if mountpoint -q ${backing} 2>/dev/null; then ${CMUX_TUI_BACKING_EXPECTED_VAR}=1; fi; ` +
    `if mountpoint -q /root 2>/dev/null; then ` +
    `{ mkdir -p /etc/cmux 2>/dev/null; printf 'root\\n' > ${CMUX_TUI_LAYOUT_MARKER_PATH}; } 2>/dev/null; ` +
    `${legacyInvocation}; ` +
    // The volume is mounted but the identity view over it is not: home on the
    // backing path as root, so sessions and daemon state stay on persistent
    // storage. The rootfs dir at ${home} is writable yet disposable — never it.
    `elif mountpoint -q ${backing} 2>/dev/null && ! mountpoint -q ${home} 2>/dev/null; then ` +
    // Degraded but recoverable: every bootstrap and daemon restart re-runs the
    // user setup, which retries the view mount; the breadcrumb makes the state
    // findable on the machine instead of silent.
    // Overwrite-latest, not append: a crash-looping daemon must not grow this file.
    `{ mkdir -p /etc/cmux 2>/dev/null; printf '%s view-missing\\n' "$(date -u +%FT%TZ)" > /etc/cmux/root-session-fallback; printf 'root\\n' > ${CMUX_TUI_LAYOUT_MARKER_PATH}; } 2>/dev/null; ` +
    backingInvocation +
    "; " +
    // A cmux session is promised passwordless sudo; without the binary it would be
    // trapped unprivileged, so fall back to a (breadcrumbed) root session until
    // the driver's sudo heal lands and the next daemon start re-evaluates.
    `elif ${usable}; then ` +
    `${cmuxTuiUserDaemonInvocation(layout, bin, args)}; ` +
    `else ` +
    `{ mkdir -p /etc/cmux 2>/dev/null; printf '%s user-unusable\\n' "$(date -u +%FT%TZ)" > /etc/cmux/root-session-fallback; printf 'root\\n' > ${CMUX_TUI_LAYOUT_MARKER_PATH}; } 2>/dev/null; ` +
    `${rootFallbackInvocation}; fi`
  );
}

/** Enrollment invitations are `cmux://enroll/<base64url JSON>`; the id and expiry inside are what the approve flow needs. */
export function parseEnrollmentInvitationUri(
  uri: string,
  provider: ProviderId = "freestyle",
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
