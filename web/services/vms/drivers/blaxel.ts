import { dirname } from "node:path";
import { randomBytes } from "node:crypto";
import {
  ProviderError,
  type AttachEndpoint,
  type AttachOptions,
  type AttachTransport,
  type CreateOptions,
  type ExecOptions,
  type ExecResult,
  type SSHEndpoint,
  type SnapshotRef,
  type VMHandle,
  type VMProvider,
  type VMStats,
  type VMStatus,
  type VMVolume,
  type VMVolumePage,
  type VMVolumeListOptions,
  type VMVolumeInventory,
  type CmuxRemoteApprovalResult,
  type CmuxRemoteApprovalOptions,
  type CmuxRemoteAttachOptions,
  type CmuxRemoteEndpoint,
} from "./types";
import { VmOperationUnsupportedError } from "../errors";
import { withVmSpan } from "../telemetry";
import { shellQuote } from "./wsLease";
import {
  approveCmuxTuiEnrollment,
  CMUX_CLOUD_HOME,
  CMUX_CLOUD_HOME_VOLUME_BACKING_PATH,
  CMUX_CLOUD_LAYOUT,
  CMUX_CLOUD_USER,
  cmuxTuiBinaryPath,
  cmuxTuiDaemonBuild,
  cmuxTuiDaemonCommand as sharedCmuxTuiDaemonCommand,
  cmuxTuiHomeViewMissingCondition,
  cmuxTuiPersistentMountWait as sharedCmuxTuiPersistentMountWait,
  CMUX_TUI_PERSISTENT_MOUNT_WAIT_TIMEOUT_MS,
  CMUX_TUI_LAYOUT_MARKER_PATH,
  cmuxTuiInstallCommand as sharedCmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand as sharedCmuxTuiPinCheckCommand,
  cmuxTuiUserUsableCondition,
  isCmuxTuiDeviceEnrolled,
  mintCmuxTuiInvitation,
  resolveCmuxTuiSource as sharedResolveCmuxTuiSource,
  waitForCmuxTuiReady as sharedWaitForCmuxTuiReady,
  type CmuxTuiInvoke,
  type CmuxTuiSource,
} from "./cmuxTuiDaemon";

// Blaxel sandboxes are name-addressed micro-VMs reached over HTTPS only: a per-sandbox
// "sandbox API" (process exec + filesystem) on the control side, and per-port preview URLs
// (`https://<id>.<region>.preview.bl.run` + `X-Blaxel-Preview-Token` header) for ingress.
// There is no raw TCP, so `openSSH` throws: Blaxel machines attach through the cmux-tui
// remote daemon (transport `cmux-remote`, docs/cloud-cmux-tui-daemon.md), the machine's
// only session daemon.
//
// Unlike the other drivers this one does not need a pre-baked provider image: `create`
// bootstraps a stock Blaxel image by having the sandbox download the pinned cmux-tui
// build onto its persistent home volume and starting `cmux-tui server start` under the
// sandbox supervisor. Blaxel freezes a sandbox ~15 s after the last open connection
// unless a keepAlive process runs; the smart-sleep watcher below is that process, so a
// busy machine stays awake and an idle one drops to (free) standby.
// 8080 is the Blaxel sandbox-api (control channel); never expose it through a preview.
const CMUX_SANDBOX_API_PORT = 8080;
const SMART_SLEEP_PATH = "/usr/local/bin/cmux-smart-sleep";
const SMART_SLEEP_PROCESS_NAME = "cmux-keepalive";
// cmux-tui remote daemon: listens on its own port behind a private preview. The binary
// lives on the persistent home volume so a resurrected sandbox reuses it; daemon identity
// and enrolled devices live under the same home (the daemon's default state dir), so
// they survive as well. The daemon and every terminal pane run as the non-root cmux
// user (CMUX_CLOUD_LAYOUT); machines from before that change keep their volume at
// /root and stay root until resurrected (see cmuxTuiDaemonCommand).
const CMUX_TUI_PORT = 1337;
// Two previews for the same port: the branded one for clients that can pass the
// custom-domain ingress, the raw one for everything else (see cmuxTuiPreviewBranded).
const CMUX_TUI_PREVIEW_NAME = "cmuxtui";
const CMUX_TUI_RAW_PREVIEW_NAME = "cmuxtui-raw";
const CMUX_TUI_SESSION = "cloud";
const CMUX_TUI_BINARY_PATH = cmuxTuiBinaryPath(CMUX_CLOUD_HOME);
const CMUX_TUI_BACKING_BINARY_PATH = cmuxTuiBinaryPath(CMUX_CLOUD_HOME_VOLUME_BACKING_PATH);
// Where the binary lived when the volume mounted at /root; still what a pre-layout
// machine's running daemon was started from, so lease revocation must match it too.
const CMUX_TUI_LEGACY_BINARY_PATH = cmuxTuiBinaryPath("/root");
const CMUX_TUI_PROCESS_NAME = "cmux-tui-daemon";

const CMUX_TUI_INSTALL_TIMEOUT_MS = 5 * 60 * 1000;
// Blaxel keeps a sandbox awake while any keepAlive process runs and freezes it ~15 s after the
// last connection otherwise. The watcher is that keepAlive process: it stays alive while any
// cmux-tui shell has a foreground/background job (a daemon child with descendants) or any
// client is connected to the daemon port, and exits after a sustained idle grace so the
// sandbox drops to standby ($0, memory snapshot, ~25 ms wake). Every attach re-arms it, so
// "wake" is just reconnecting.
export const SMART_SLEEP_SCRIPT = `#!/bin/sh
# cmux smart sleep: hold the sandbox awake while work is running or a client is attached.
TUI_PORT_HEX=0539 # 1337 (cmux-tui remote daemon)
IDLE_LIMIT=\${CMUX_SMART_SLEEP_IDLE_CHECKS:-8}
INTERVAL=\${CMUX_SMART_SLEEP_INTERVAL:-15}
idle=0
while true; do
  busy=""
  for cm in $(pidof cmux-tui 2>/dev/null); do
    for c in $(pgrep -P "$cm" 2>/dev/null); do
      if pgrep -P "$c" >/dev/null 2>&1; then busy=jobs; break 2; fi
    done
  done
  if [ -z "$busy" ]; then
    if awk -v tui="$TUI_PORT_HEX" '$2 ~ ":"tui"$" && $4 == "01" { found=1 } END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null; then
      busy=conn
    fi
  fi
  if [ -n "$busy" ]; then
    idle=0
  else
    idle=$((idle + 1))
    if [ "$idle" -ge "$IDLE_LIMIT" ]; then
      echo "smart-sleep: idle for $((idle * INTERVAL))s, releasing keepAlive"
      exit 0
    fi
  fi
  sleep "$INTERVAL"
done
`;
// The persistent volume is virtiofs with all guest identity squashed to root
// (measured 2026-08-28 on sandbox/cmux-devbox: chown is a silent no-op, and a file
// created by uid 1001 comes back root:root 644 — the creator instantly loses write).
// Idmapped bind mounts are refused by this virtiofs (mount_setattr EINVAL), so a
// non-root home on the volume needs a FUSE identity map: the volume mounts at a
// backing path and bindfs presents it at /home/cmux with every file owned by cmux,
// performing the real I/O as root. Legacy root-owned volume data becomes cmux-owned
// through the view instantly, with no chown walk.
export const CMUX_HOME_VOLUME_BACKING_PATH = CMUX_CLOUD_HOME_VOLUME_BACKING_PATH;
export const CMUX_HOME_BINDFS_COMMAND =
  `bindfs -o allow_other --multithreaded --force-user=${CMUX_CLOUD_USER} --force-group=${CMUX_CLOUD_USER} ` +
  `--create-for-user=root --create-for-group=root --chown-ignore --chgrp-ignore ` +
  `${CMUX_HOME_VOLUME_BACKING_PATH} ${CMUX_CLOUD_HOME}`;

const CMUX_PACKAGE_INSTALL_LOCK_PATH = "/etc/cmux/package-install.lock";
const CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH = "/etc/cmux/package-install.lock.d";
const CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH = `${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH}/owner`;
const CMUX_PACKAGE_INSTALL_BUSY_PATH = "/etc/cmux/package-install.lock.busy";
const CMUX_PACKAGE_INSTALL_LOCK_STALE_MINUTES = 5;
const CMUX_PACKAGE_INSTALL_LOCK_WAIT_SECONDS = 300;

/**
 * Serializes every apt/apk mutation with one transition-safe protocol. The
 * directory gate is acquired before checking flock, so a caller that installs
 * util-linux cannot race a caller that already sees flock. Once flock exists,
 * the gate is released after the file lock is held and later callers block on
 * that same file. Contenders wait for the owner to release the directory, with
 * a bounded timeout, so a concurrent bootstrap does not silently select the
 * root fallback. A dead owner pid permits recovery from a killed old-image
 * setup; an ownerless directory is reclaimed only after a grace period, which
 * covers a process killed between mkdir and writing its owner pid without
 * interrupting a fresh acquisition.
 */
function withPackageInstallLock(body: string): string {
  const packageDir = CMUX_PACKAGE_INSTALL_LOCK_PATH.replace(/\/[^/]+$/, "");
  return (
    `mkdir -p ${packageDir} 2>/dev/null; ` +
    `cmux_package_lock_acquired=0; cmux_package_lock_wait=0; ` +
    `while [ "$cmux_package_lock_wait" -lt ${CMUX_PACKAGE_INSTALL_LOCK_WAIT_SECONDS} ]; do ` +
    `if [ -d ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} ]; then ` +
    `cmux_package_lock_pid=""; ` +
    `if [ -r ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} ]; then ` +
    `cmux_package_lock_pid="$(cat ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} 2>/dev/null || true)"; fi; ` +
    `if [ -n "$cmux_package_lock_pid" ] && ! kill -0 "$cmux_package_lock_pid" 2>/dev/null; then ` +
    `rm -f ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} 2>/dev/null || true; ` +
    `rmdir ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} 2>/dev/null || true; ` +
    `elif [ -z "$cmux_package_lock_pid" ] && [ -n "$(find ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} -prune -mmin +${CMUX_PACKAGE_INSTALL_LOCK_STALE_MINUTES} -print 2>/dev/null)" ]; then ` +
    `rm -f ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} 2>/dev/null || true; ` +
    `rmdir ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} 2>/dev/null || true; fi; fi; ` +
    `if mkdir ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} 2>/dev/null; then cmux_package_lock_acquired=1; break; fi; ` +
    `if [ ! -d ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} ]; then break; fi; ` +
    `sleep 1; cmux_package_lock_wait=$((cmux_package_lock_wait + 1)); ` +
    `done; ` +
    `if [ "$cmux_package_lock_acquired" -eq 1 ]; then ` +
    // Create the owner file before writing the pid. If the shell is killed in
    // this tiny window, stale recovery can observe the empty file and reclaim
    // the directory after the grace period instead of wedging all future setup.
    `if ! : > ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} || ! printf '%s\\n' "$$" > ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH}; then ` +
    `rmdir ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} 2>/dev/null || true; false; ` +
    `else ( ` +
    `trap 'rm -f ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} 2>/dev/null || true; rmdir ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} 2>/dev/null || true; exit 143' TERM INT HUP; ` +
    `trap 'rm -f ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} 2>/dev/null || true; rmdir ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} 2>/dev/null || true' EXIT; ` +
    `if command -v flock >/dev/null 2>&1; then ` +
    // Once flock exists, hold the file lock before releasing the transition gate.
    // This lets later callers wait on the same file while this body runs.
    `flock -w ${CMUX_PACKAGE_INSTALL_LOCK_WAIT_SECONDS} 9 || exit 1; ` +
    `rm -f ${CMUX_PACKAGE_INSTALL_LOCK_OWNER_PATH} 2>/dev/null || true; ` +
    `rmdir ${CMUX_PACKAGE_INSTALL_FALLBACK_LOCK_PATH} 2>/dev/null || true; ` +
    `${body}; ` +
    `else ` +
    // Before util-linux installs flock, the directory itself is the mutex. Keep
    // it until body exits; releasing it here would let a second apt/apk mutate
    // the package database concurrently during this first transaction.
    `${body}; fi ) 9>${CMUX_PACKAGE_INSTALL_LOCK_PATH}; fi; ` +
    `else printf '%s package-install-busy\\n' "$(date -u +%FT%TZ)" > ${CMUX_PACKAGE_INSTALL_BUSY_PATH} 2>/dev/null || true; false; fi`
  );
}

// The non-root branches need runuser and mountpoint. findmnt is also required:
// the layout daemon uses its kernel mount-event poll to leave a failed bindfs
// view before any terminal can write to a disposable rootfs directory.
const CMUX_CLOUD_PREREQUISITE_INSTALL =
  `if ! (command -v bash >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 && command -v mountpoint >/dev/null 2>&1 && command -v findmnt >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 && (command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1)); then ` +
  `if command -v apk >/dev/null 2>&1; then ` +
  `apk add --no-cache bash 2>/dev/null || true; ` +
  `apk add --no-cache runuser 2>/dev/null || true; ` +
  `apk add --no-cache util-linux 2>/dev/null || true; ` +
  `if ! (command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1); then apk add --no-cache curl 2>/dev/null || true; fi; ` +
  `elif command -v apt-get >/dev/null 2>&1; then ` +
  `export DEBIAN_FRONTEND=noninteractive; ` +
  `apt-get update -qq && apt-get install -y -qq --no-install-recommends util-linux curl 2>/dev/null || true; ` +
  `fi; fi; ` +
  // Re-check after installation. The caller's usability predicate decides the
  // safe root fallback when an old image cannot provide these tools.
  `command -v bash >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1 && command -v mountpoint >/dev/null 2>&1 && command -v findmnt >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || true`;

const CMUX_CLOUD_HOME_VIEW_SETUP =
  `if mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null && ! mountpoint -q ${CMUX_CLOUD_HOME} 2>/dev/null; then ` +
  // bindfs ships in baked images; this install path repairs older images while
  // still holding the package lock shared with sudo and provisioning.
  `command -v bindfs >/dev/null 2>&1` +
  ` || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends bindfs; }` +
  ` || apk add --no-cache bindfs 2>/dev/null || true; ` +
  `if command -v bindfs >/dev/null 2>&1; then ` +
  // On a volume machine the real home is the volume. The rootfs directory at
  // the mountpoint is disposable skel and must be empty before FUSE mounts.
  `find ${CMUX_CLOUD_HOME} -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null; ` +
  `${CMUX_HOME_BINDFS_COMMAND}; fi; fi`;

// Runtime user setup, run at every bootstrap (create and resurrect) before the daemon
// starts. Idempotent, and the safety net for images that predate the baked cmux user:
// creates the user at uid 1001 so uids are stable across image versions (with
// Alpine's busybox adduser as a fallback), writes the passwordless-sudo policy
// (inert until the sudo binary exists — see CMUX_SUDO_INSTALL_COMMAND), and puts the
// bindfs view over /home/cmux when this machine has a home volume. Machines without a
// volume keep /home/cmux on the (chown-capable) rootfs and need no view. All package
// mutations, including the util-linux prerequisite and bindfs repair, run inside the
// shared lock with detached provisioning and the sudo heal. Skipped work on pre-layout
// sandboxes (volume still at /root): no backing mount exists there.
export const CMUX_CLOUD_USER_SETUP_COMMAND = [
  // Every creation form pins uid 1001. If that uid is already occupied, the
  // command fails closed below instead of silently creating a different identity.
  `id -u ${CMUX_CLOUD_USER} >/dev/null 2>&1` +
    ` || useradd -m -u 1001 -s /bin/bash ${CMUX_CLOUD_USER} 2>/dev/null` +
    ` || adduser -D -u 1001 -s /bin/bash ${CMUX_CLOUD_USER} 2>/dev/null` +
    ` || useradd -m -u 1001 -s /bin/bash ${CMUX_CLOUD_USER} 2>/dev/null` +
    ` || adduser -D -u 1001 -s /bin/bash ${CMUX_CLOUD_USER} 2>/dev/null || true`,
  `[ "$(id -u ${CMUX_CLOUD_USER} 2>/dev/null || echo -1)" = "1001" ] || exit 1`,
  `mkdir -p ${CMUX_CLOUD_HOME} /etc/sudoers.d`,
  `printf '${CMUX_CLOUD_USER} ALL=(ALL) NOPASSWD:ALL\\n' > /etc/sudoers.d/90-cmux-nopasswd`,
  `chmod 0440 /etc/sudoers.d/90-cmux-nopasswd`,
  // All prerequisite and bindfs installs share one lock. This prevents an attach
  // from racing the detached provisioner while an older image is being repaired.
  `${withPackageInstallLock(`${CMUX_CLOUD_PREREQUISITE_INSTALL}; ${CMUX_CLOUD_HOME_VIEW_SETUP}`)} || true`,
  // A failed view is not a failed machine: the daemon command's usable-user probe
  // falls back to a root daemon, which still attaches (the pre-layout behavior).
  `true`,
].join("; ");
// Installing bindfs on an old image does an apt round-trip; give it minutes, not the
// default exec timeout. Everything else in the setup returns instantly.
const CMUX_USER_SETUP_TIMEOUT_MS = 5 * 60 * 1000;
// Baked images before 2026-08-31-r12 ship no sudo binary. This heal runs synchronously
// and is awaited at every bootstrap and daemon restart, including stock images without
// an image stamp, so readiness never races package installation. The lock serializes it
// with the detached provisioner when an attach overlaps a still-running first boot.
const CMUX_SUDO_INSTALL_BODY =
  "command -v sudo >/dev/null 2>&1 || " +
  "{ export DEBIAN_FRONTEND=noninteractive; " +
  "{ apt-get update -qq && apt-get install -y -qq --no-install-recommends sudo; } 2>/dev/null" +
  " || apk add --no-cache sudo 2>/dev/null || true; }";
export const CMUX_SUDO_INSTALL_COMMAND =
  "if command -v sudo >/dev/null 2>&1; then :; else " +
  // The sudo heal uses the same lock as user setup and detached provisioning,
  // including the old-image directory-lock path while flock is being installed.
  `${withPackageInstallLock(CMUX_SUDO_INSTALL_BODY)}; fi; ` +
  "command -v sudo >/dev/null 2>&1" +
  " || { mkdir -p /etc/cmux 2>/dev/null; printf '%s sudo-install-failed\\n' \"$(date -u +%FT%TZ)\" > /etc/cmux/root-session-fallback; exit 1; }";
const CMUX_SUDO_INSTALL_TIMEOUT_MS = 3 * 60 * 1000;

// "The volume is mounted but its identity view is not": the fail-over state where
// sessions must run as root homed on the backing path, because the rootfs dir at
// /home/cmux is writable (useradd -m) yet disposable — data written there dies with
// the sandbox and is swept by the next bootstrap's junk clean.
const CMUX_HOME_VIEW_MISSING_CONDITION = cmuxTuiHomeViewMissingCondition(CMUX_CLOUD_LAYOUT);
// "The work user is actually usable": it exists, runuser can drop to it, and it can
// write its home. Callers check CMUX_HOME_VIEW_MISSING_CONDITION first, so reaching
// this means the home is the mounted view or the (volume-less) rootfs home. Shared by
// the daemon command (via cmuxTuiDaemon), CLI invocations, and user exec so they
// always agree on which user owns the machine's sessions.
const CMUX_CLOUD_USER_USABLE_CONDITION = cmuxTuiUserUsableCondition(CMUX_CLOUD_LAYOUT);

/** Runs user-facing `cmux vm exec` under the same identity and home as a terminal pane. */
export function userExecCommand(
  command: string,
  options?: { readonly persistentVolumeExpected?: boolean },
): string {
  const quoted = shellQuote(command);
  const persistentVolumeExpected = options?.persistentVolumeExpected === true;
  const backingExec =
    `if mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then ` +
    `cd ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null || exit 75; exec env HOME=${CMUX_HOME_VOLUME_BACKING_PATH} sh -c ${quoted}; ` +
    `else exit 75; fi`;
  const rootFallback = persistentVolumeExpected
    ? `elif mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then ${backingExec}; else exit 75`
    : `elif mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then ${backingExec}; ` +
      `else cd ${CMUX_CLOUD_HOME} 2>/dev/null || exit 75; exec env HOME=${CMUX_CLOUD_HOME} sh -c ${quoted}`;
  const persistentVolumeGuard = persistentVolumeExpected
    ? `if ! mountpoint -q /root 2>/dev/null && ! mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then exit 75; fi; `
    : "";
  return (
    persistentVolumeGuard +
    `if mountpoint -q /root 2>/dev/null; then cd /root 2>/dev/null || exit 75; exec env HOME=/root sh -c ${quoted}; ` +
    `elif ${CMUX_HOME_VIEW_MISSING_CONDITION}; then ` +
    `${backingExec}; ` +
    `elif ${CMUX_CLOUD_USER_USABLE_CONDITION}; then ` +
    `cd ${CMUX_CLOUD_HOME} 2>/dev/null || exit 75; exec runuser -u ${CMUX_CLOUD_USER} -- env HOME=${CMUX_CLOUD_HOME} USER=${CMUX_CLOUD_USER} LOGNAME=${CMUX_CLOUD_USER} sh -c ${quoted}; ` +
    `${rootFallback}; fi`
  );
}

// Background provisioning for every machine: coding agents plus the dev essentials a person
// expects on "their computer". The .bashrc seed only writes when absent so user edits stick.
// Background provisioning: a machine comes with the tools agents and people expect,
// without delaying attach. Written to the sandbox as a file (heredoc-free, so it survives
// the process API's own quoting) and run detached; the log is /tmp/cmux/provision.log.
// Idempotent: re-runs on resurrection (the sandbox root filesystem is disposable, the
// home volume is not), so anything that can live in the persistent home does — bun, npm
// globals (the agents), uv tools — and only distro packages are reinstalled. Ubuntu/Debian
// (blaxel/xfce-vnc) and Alpine (blaxel/base-image) are both handled. Runs as root;
// everything it puts in the home is handed to the cmux user at the end.
export const CMUX_PROVISION_SCRIPT_PATH = "/tmp/cmux/provision.sh";
export const CMUX_PROVISION_LOG_PATH = "/tmp/cmux/provision.log";
export const CMUX_PROVISION_AGENT_PACKAGES = [
  "@anthropic-ai/claude-code",
  "@openai/codex",
  "opencode-ai",
  "@earendil-works/pi-coding-agent",
] as const;
export const CMUX_PROVISION_SCRIPT = `#!/bin/bash
# cmux machine provisioning (background, idempotent). Log: ${CMUX_PROVISION_LOG_PATH}
# Baked images (services/vms/images/blaxel) already contain everything below, pinned
# at bake time, and stamp /etc/cmux/image-stamp; re-provisioning would only drift the
# pinned versions to latest, so the stamp short-circuits the whole script. The cmux-tui
# session daemon is NOT part of this script: bootstrapDaemon installs and starts it via
# cmuxTuiInstallCommand on every image, so a stamped image still gets its daemon.
[ -f /etc/cmux/image-stamp ] && exit 0
# A pre-layout sandbox keeps its persistent volume at /root (the daemon and exec
# paths detect and honor that); its old driver already provisioned /root at create.
# Writing the new-layout home there would target disposable rootfs, so do nothing.
mountpoint -q /root 2>/dev/null && exit 0
# A volume-backed process carries this intent explicitly. If the provider has
# not mounted the volume yet, wait for its kernel mount event instead of
# installing tools into the disposable /home/cmux rootfs directory.
if [ "\${CMUX_PROVISION_VOLUME_EXPECTED:-0}" = "1" ] && ! mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then
  mkdir -p ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null || true
  if command -v findmnt >/dev/null 2>&1 && findmnt --help 2>&1 | grep -q -- '--poll' && findmnt --help 2>&1 | grep -q -- '--timeout'; then
    findmnt --poll=mount --timeout=${CMUX_TUI_PERSISTENT_MOUNT_WAIT_TIMEOUT_MS} --first-only --mountpoint ${CMUX_HOME_VOLUME_BACKING_PATH} >/dev/null 2>&1 || exit 75
  else
    exit 75
  fi
  mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null || exit 75
fi
# A mounted volume with no bindfs identity view is still durable. Use its backing
# path for provisioning instead of the writable-but-disposable /home/cmux rootfs dir.
# When the view exists, keep using it so files are presented as cmux-owned.
if mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null && ! mountpoint -q ${CMUX_CLOUD_HOME} 2>/dev/null; then
  export HOME=${CMUX_HOME_VOLUME_BACKING_PATH}
else
  export HOME=${CMUX_CLOUD_HOME}
fi
export DEBIAN_FRONTEND=noninteractive
export PATH="$HOME/.bun/bin:$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:$PATH"
mkdir -p "$HOME/.npm-global" "$HOME/.local/bin"
log() { printf '%s %s\\n' "$(date -u +%FT%TZ)" "$*"; }
step() { local name="$1"; shift; if "$@"; then log "ok $name"; else log "FAILED $name (exit $?)"; fi; }

distro_packages_unlocked() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends \\
      ca-certificates curl wget git sudo tmux vim less jq ripgrep fd-find unzip zip \\
      build-essential pkg-config python3 python3-pip python3-venv openssh-client util-linux \\
      xdotool scrot xclip xsel
    [ -x /usr/local/bin/fd ] || ln -sf "$(command -v fdfind)" /usr/local/bin/fd
    if ! command -v node >/dev/null 2>&1 || [ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)" -lt 20 ]; then
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y -qq nodejs
    fi
    if ! command -v gh >/dev/null 2>&1; then
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /usr/share/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
      apt-get update -qq && apt-get install -y -qq gh
    fi
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache ca-certificates curl wget git sudo tmux vim less jq ripgrep fd unzip zip \\
      build-base pkgconf python3 py3-pip openssh-client nodejs npm github-cli util-linux
  fi
}

# The create path starts this script after the daemon bootstrap, but an attach can
# overlap a still-running first boot. Share the same lock as the synchronous sudo
# heal so apt and apk never mutate their databases at the same time.
distro_packages() {
  ${withPackageInstallLock("distro_packages_unlocked")}
}

bun_runtime() {
  [ -x "$HOME/.bun/bin/bun" ] || curl -fsSL https://bun.sh/install | bash
  ln -sf "$HOME/.bun/bin/bun" /usr/local/bin/bun
  ln -sf "$HOME/.bun/bin/bunx" /usr/local/bin/bunx
}

uv_runtime() {
  command -v uv >/dev/null 2>&1 || curl -LsSf https://astral.sh/uv/install.sh | sh
}

# The coding agents live under the persistent home so they survive sandbox resurrection.
agents() {
  command -v npm >/dev/null 2>&1 || return 1
  npm config set prefix "$HOME/.npm-global"
  npm install -g --no-fund --no-audit ${CMUX_PROVISION_AGENT_PACKAGES.join(" ")}
  for bin in "$HOME"/.npm-global/bin/*; do [ -x "$bin" ] && ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"; done
}

# The CUA driver: cua-computer-server exposes the desktop (screenshot, click, type) to
# computer-use agents. The desktop image ships and starts it; base images get it too so a
# later desktop attach has something to talk to.
cua_driver() {
  python3 -m pip show cua-computer-server >/dev/null 2>&1 || python3 -m pip install -q --break-system-packages cua-computer-server 2>/dev/null || python3 -m pip install -q cua-computer-server
}

shell_profile() {
  [ -f "$HOME/.bashrc" ] || printf '%s\\n' \\
    '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' \\
    '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' \\
    "export PS1='\\\\[\\\\e[1;36m\\\\]\\\\h\\\\[\\\\e[0m\\\\]:\\\\[\\\\e[1;34m\\\\]\\\\w\\\\[\\\\e[0m\\\\]\\\\$ '" \\
    "alias ll='ls -la'" > "$HOME/.bashrc"
  grep -qF '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' "$HOME/.bashrc" 2>/dev/null || \\
    printf '%s\\n' '[ -f /etc/cmux/bashrc ] && . /etc/cmux/bashrc' >> "$HOME/.bashrc"
  grep -qF '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' "$HOME/.bashrc" 2>/dev/null || \\
    printf '%s\\n' '[ -f /etc/cmux/agent-config.sh ] && . /etc/cmux/agent-config.sh' >> "$HOME/.bashrc"
  grep -q '\\$HOME/.bun' "$HOME/.bashrc" 2>/dev/null || printf '%s\\n' '# cmux provisioning: tools that live on the persistent home' 'export PATH=$HOME/.bun/bin:$HOME/.npm-global/bin:$HOME/.local/bin:$PATH' >> "$HOME/.bashrc"
  [ -f "$HOME/.profile" ] || printf '%s\\n' '[ -f "$HOME/.bashrc" ] && . "$HOME/.bashrc"' > "$HOME/.profile"
}

# Provisioning runs as root; the home belongs to the cmux user. Only needed when
# the home is a plain rootfs dir (no-volume machines, always small): a mounted
# bindfs view already presents every file as cmux-owned and turns chown into a
# pure no-op, so walking a grown persistent home there would be wasted disk work
# on every resurrection. Scoped to the dirs this script writes, never the whole home.
own_home() {
  id -u ${CMUX_CLOUD_USER} >/dev/null 2>&1 || return 0
  # Bindfs already maps ownership, and a raw volume may reject chown entirely.
  mountpoint -q ${CMUX_CLOUD_HOME} 2>/dev/null && return 0
  mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null && return 0
  chown -R ${CMUX_CLOUD_USER}:${CMUX_CLOUD_USER} "$HOME/.bun" "$HOME/.npm-global" "$HOME/.local" "$HOME/.bashrc" "$HOME/.profile" 2>/dev/null || true
}

{
  log "provisioning start"
  step distro_packages distro_packages
  step bun bun_runtime
  step uv uv_runtime
  step agents agents
  step cua_driver cua_driver
  step shell_profile shell_profile
  step own_home own_home
  log "provisioning done"
} >> ${CMUX_PROVISION_LOG_PATH} 2>&1
`;
export const CMUX_PROVISION_COMMAND = `bash ${CMUX_PROVISION_SCRIPT_PATH}`;

// The machine knows its own name: the prompt reads noble-wren:~#, not (none):~#. But a
// renamed host must stay *resolvable*: TigerVNC's `vncserver` wrapper calls `hostname -f`
// and aborts the whole desktop session when the name has no /etc/hosts entry. A bare
// `hostname <name>` (all we used to do) silently broke noVNC on every desktop machine —
// 5901 never bound and the browser showed "Failed to connect to server". Map the name to
// loopback so `hostname -f` resolves. Idempotent: re-runs harmlessly on resurrection.
export function hostnameSetupCommand(name: string): string {
  const q = shellQuote(name);
  return (
    `hostname ${q} 2>/dev/null; echo ${q} > /etc/hostname || true; ` +
    `grep -qF ${q} /etc/hosts || printf '127.0.0.1 %s\\n127.0.1.1 %s\\n' ${q} ${q} >> /etc/hosts`
  );
}

// Desktop images (blaxel/xfce-vnc) start TigerVNC via supervisord at boot — before this
// driver's bootstrap makes the hostname resolvable — so that first attempt fails and
// supervisord exhausts its retries and gives up (FATAL). Once hostnameSetupCommand has
// fixed /etc/hosts nothing kicks vncserver again, so we start it ourselves, as the image's
// `cua` desktop user, when 5901 is not already listening (a snapshot-resumed machine keeps
// its running Xtigervnc, so we skip). A no-op on base images, which have no start-vnc.sh.
const DESKTOP_VNC_HEAL_PROCESS_NAME = "cmux-vnc-heal";
export const DESKTOP_VNC_HEAL_COMMAND = [
  "[ -x /usr/local/bin/start-vnc.sh ] || exit 0;",
  "for i in 1 2 3 4 5; do { ss -tln 2>/dev/null || netstat -tln 2>/dev/null; } | grep -q ':5901 ' && exit 0; sleep 1; done;",
  "exec runuser -u cua -- env HOME=/home/cua USER=cua DISPLAY=:1 bash /usr/local/bin/start-vnc.sh",
].join(" ");

const PREVIEW_TOKEN_TTL_SECONDS = 12 * 60 * 60;
// Desktop/port panes are long-lived surfaces a person leaves open for days; a
// 12h token turned every long-lived pane into a silent white screen at hour
// twelve. The wrapper page shows an honest expiry screen when this lapses.
const PREVIEW_OPEN_TOKEN_TTL_SECONDS = 7 * 24 * 60 * 60;
const EXEC_DEFAULT_TIMEOUT_MS = 30_000;
const MAX_EXEC_TIMEOUT_MS = 15 * 60 * 1000;
const CONTROL_PLANE_BASE = "https://api.blaxel.ai/v0";
const DEFAULT_MEMORY_MB = 4096;
// The persistent-home volume backs the cmux user's home so dotfiles, repos, and agent
// state survive sandbox destruction. The sandbox is disposable compute; the volume is
// the machine. It mounts at the backing path, and the runtime user setup presents it
// at /home/cmux through the bindfs identity map (see CMUX_HOME_BINDFS_COMMAND).
// Volumes born when this said "/root" keep their data: resurrection remounts them here
// and the view makes the root-owned tree cmux-owned instantly.
const HOME_VOLUME_MOUNT_PATH = CMUX_HOME_VOLUME_BACKING_PATH;

/** Returns whether the VM row or live Blaxel response identifies a persistent home volume. */
function sandboxHasPersistentHomeVolume(
  sandbox: BlaxelSandbox,
  providerMetadata?: Record<string, unknown>,
): boolean {
  const liveVolume = (sandbox.spec?.volumes ?? []).some((volume) =>
    volume.mountPath === HOME_VOLUME_MOUNT_PATH || volume.mountPath === "/root"
  );
  if (liveVolume) return true;
  const persistedVolume = providerMetadata?.homeVolume;
  return typeof persistedVolume === "string" && persistedVolume.trim().length > 0;
}

// Disk follows memory the way hosted dev boxes do, but Blaxel caps a volume at 16 GB
// (measured 2026-08-26: 16384 MB accepted, 20480 MB refused with "exceeds maximum allowed
// size"), so the 24 GB plan default gets the 16 GB ceiling instead of the old flat 5 GB.
// Volumes are created once and never resized: existing machines keep what they were born
// with. Raise the ceiling here when the provider does.
export const BLAXEL_MAX_HOME_VOLUME_MB = 16 * 1024;
const HOME_VOLUME_MB_BY_MEMORY: ReadonlyArray<readonly [maxMemoryMb: number, volumeMb: number]> = [
  [4 * 1024, 8 * 1024],
  [8 * 1024, 16 * 1024],
];

/** Home volume size for a machine's memory: ≤4 GB → 8 GB, otherwise the 16 GB provider ceiling. */
export function defaultHomeVolumeMbForMemory(memoryMb: number): number {
  if (!Number.isFinite(memoryMb) || memoryMb <= 0) {
    throw new ProviderError("blaxel", "memoryMb must be a positive number to size the home volume");
  }
  for (const [maxMemoryMb, volumeMb] of HOME_VOLUME_MB_BY_MEMORY) {
    if (memoryMb <= maxMemoryMb) return Math.min(volumeMb, BLAXEL_MAX_HOME_VOLUME_MB);
  }
  return BLAXEL_MAX_HOME_VOLUME_MB;
}

/** `CMUX_VM_BLAXEL_HOME_VOLUME_MB` pins every new volume to one size; otherwise disk follows memory. */
export function resolveHomeVolumeMb(
  memoryMb: number,
  envValues: Record<string, string | undefined> = process.env,
): number {
  const raw = envValues.CMUX_VM_BLAXEL_HOME_VOLUME_MB?.trim();
  if (raw) {
    const parsed = Number.parseInt(raw, 10);
    if (Number.isFinite(parsed) && parsed > 0) return parsed;
  }
  return defaultHomeVolumeMbForMemory(memoryMb);
}

type BlaxelSandbox = {
  metadata?: { name?: string; url?: string; createdAt?: string };
  spec?: {
    runtime?: { image?: string; memory?: number };
    volumes?: Array<{ name?: string; mountPath?: string }>;
  };
  state?: string;
  status?: string;
};

type BlaxelProcess = {
  pid?: string;
  name?: string;
  status?: string;
  exitCode?: number;
  stdout?: string;
  stderr?: string;
  logs?: string;
};

type BlaxelPreview = {
  metadata?: { name?: string };
  spec?: {
    url?: string;
    public?: boolean;
    prefixUrl?: string;
    customDomain?: string;
  };
};

type BlaxelVolume = {
  metadata?: { name?: string; createdAt?: string | number };
  state?: { attachedTo?: unknown };
  // Keep the parser tolerant of older control-plane responses that surfaced
  // attachment state at the resource root.
  attachedTo?: unknown;
};

// The preview URL is the only ingress to the cmux-tui daemon, and it must stay token-gated:
// a preview that is (or has been flipped) public would expose the daemon's `/v1/link`
// listener to anyone holding the URL, leaving device enrollment as the sole barrier. Only a
// private preview's URL is ever usable; a public one is treated as absent so callers replace
// or reject it.
export function usablePrivatePreviewUrl(preview: BlaxelPreview | null | undefined): string | null {
  const url = preview?.spec?.url;
  if (!url) return null;
  if (preview?.spec?.public === true) return null;
  return url;
}

function env(name: string): string | undefined {
  return process.env[name]?.trim() || undefined;
}

function requireEnv(name: string): string {
  const value = env(name);
  if (!value) {
    throw new ProviderError("blaxel", `${name} is not configured`);
  }
  return value;
}

// Step-level latency attribution for the create path. The workflow recorder only
// shows provider_create as one block, so CMUX_VM_DEBUG_TIMINGS=1 additionally logs
// one line per driver step (volume, sandbox create, daemon install, preview) — slow
// creates get measured, not guessed at.
async function timedStep<T>(step: string, run: () => Promise<T>): Promise<T> {
  if (env("CMUX_VM_DEBUG_TIMINGS") !== "1") return run();
  const start = performance.now();
  try {
    return await run();
  } finally {
    console.info(`[blaxel] timing step=${step} ms=${Math.round(performance.now() - start)}`);
  }
}

function controlHeaders(): Record<string, string> {
  return {
    "X-Blaxel-Authorization": `Bearer ${requireEnv("BL_API_KEY")}`,
    "X-Blaxel-Workspace": requireEnv("BL_WORKSPACE"),
    "Content-Type": "application/json",
  };
}

// Bounded retry for the Blaxel control plane. Every control-plane call used to
// be a single bare fetch, so any transient 429/5xx or network blip failed the
// whole provisioning workflow (August 2026: 18 of 19 real create attempts).
// Retries are per-method: 429, 5xx, and network errors are retried only for
// idempotent requests (GET, DELETE, HEAD, and this driver's PUTs, which write
// fixed file content). POST is never replayed because a rate-limit response
// does not prove that the provider did no work. Sandbox create relies on the
// caller's 409 name-collision loop instead, and process starts are not
// idempotent.
export const BLAXEL_FETCH_MAX_ATTEMPTS = 4;
const BLAXEL_RETRY_BASE_DELAY_MS = 250;
const BLAXEL_RETRY_MAX_DELAY_MS = 4_000;
const BLAXEL_RETRY_AFTER_CAP_MS = 15_000;

/**
 * Retries exhausted on a retriable control-plane failure. Distinct from a
 * plain ProviderError so logs can tell "Blaxel kept failing for the whole
 * retry budget" from "Blaxel rejected this request".
 */
export class BlaxelRetryExhaustedError extends ProviderError {
  constructor(method: string, url: string, attempts: number, lastFailure: string, cause?: unknown) {
    super(
      "blaxel",
      `${method} ${url} -> ${lastFailure} (retries exhausted after ${attempts} attempts)`,
      cause,
    );
    this.name = "BlaxelRetryExhaustedError";
  }
}

function parseRetryAfterMs(header: string | null): number | null {
  if (!header) return null;
  const seconds = Number(header);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.round(seconds * 1000);
  const dateMs = Date.parse(header);
  if (!Number.isNaN(dateMs)) return Math.max(0, dateMs - Date.now());
  return null;
}

/** Full-jitter exponential backoff; a server-provided Retry-After wins (capped). */
export function blaxelRetryDelayMs(
  attempt: number,
  retryAfterHeader: string | null,
  random: () => number = Math.random,
): number {
  const retryAfterMs = parseRetryAfterMs(retryAfterHeader);
  if (retryAfterMs !== null) return Math.min(retryAfterMs, BLAXEL_RETRY_AFTER_CAP_MS);
  const cap = Math.min(BLAXEL_RETRY_MAX_DELAY_MS, BLAXEL_RETRY_BASE_DELAY_MS * 2 ** attempt);
  return Math.floor(random() * cap);
}

const BLAXEL_DEFAULT_TIMEOUT_MS = 60_000;

type BlaxelFetchOptions = {
  /** Maximum time allowed for one HTTP attempt. */
  timeoutMs?: number;
  /** Maximum time allowed for the complete request and all retries. */
  retryBudgetMs?: number;
  /** Disable transport/status retries for callers with a narrower retry policy. */
  retry?: boolean;
  /** Caller-owned cancellation for the complete request and all retries. */
  signal?: AbortSignal;
  /** Test seam; production callers use the cancellation-aware implementation. */
  sleep?: (ms: number, signal: AbortSignal) => Promise<void>;
  /** Test seam for deterministic jitter. */
  random?: () => number;
};

/** Return the caller's abort reason, with a standards-compatible fallback. */
function abortReason(signal: AbortSignal): unknown {
  return signal.reason ?? new DOMException("The operation was aborted", "AbortError");
}

/** Stop an attempt immediately when its caller has cancelled the operation. */
function throwIfAborted(signal: AbortSignal | undefined): void {
  if (signal?.aborted) throw abortReason(signal);
}

/** Wait for a retry delay, and always remove the abort listener and timer. */
function defaultRetrySleep(ms: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.reject(abortReason(signal));
  return new Promise<void>((resolve, reject) => {
    let settled = false;
    const finish = (error?: unknown) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal.removeEventListener("abort", onAbort);
      if (error === undefined) resolve();
      else reject(error);
    };
    const onAbort = () => finish(abortReason(signal));
    const timer = setTimeout(() => finish(), Math.max(0, ms));
    signal.addEventListener("abort", onAbort, { once: true });
    if (signal.aborted) onAbort();
  });
}

type TimedAbortSignal = {
  signal: AbortSignal;
  cleanup: () => void;
};

/** Create a parent-aware timeout signal whose timer is always explicitly cleared. */
function timedAbortSignal(parent: AbortSignal | undefined, timeoutMs: number): TimedAbortSignal {
  const controller = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const onParentAbort = () => {
    if (!controller.signal.aborted && parent) controller.abort(abortReason(parent));
  };
  if (parent?.aborted) {
    onParentAbort();
  } else if (parent) {
    parent.addEventListener("abort", onParentAbort, { once: true });
  }
  if (!controller.signal.aborted) {
    timer = setTimeout(() => {
      if (!controller.signal.aborted) {
        controller.abort(new DOMException("The operation timed out", "TimeoutError"));
      }
    }, Math.max(1, timeoutMs));
  }
  return {
    signal: controller.signal,
    cleanup: () => {
      if (timer !== undefined) clearTimeout(timer);
      parent?.removeEventListener("abort", onParentAbort);
    },
  };
}

/** Convert an unknown transport failure into a bounded diagnostic for operators. */
function retryFailureMessage(err: unknown): string {
  return `network failure: ${err instanceof Error ? err.message : String(err)}`;
}

/** Execute one Blaxel request with bounded, cancellation-aware retries. */
export async function blaxelFetch<T>(
  method: string,
  url: string,
  body?: unknown,
  opts?: BlaxelFetchOptions,
): Promise<T> {
  const requestMethod = method.toUpperCase();
  const idempotent =
    requestMethod === "GET" ||
    requestMethod === "DELETE" ||
    requestMethod === "PUT" ||
    requestMethod === "HEAD";
  const callerSignal = opts?.signal;
  throwIfAborted(callerSignal);
  // Resolve configuration and serialize the body before entering the retry
  // boundary. Configuration and serialization errors are deterministic and
  // must never be mislabeled as transport failures.
  const headers = controlHeaders();
  const serializedBody = body === undefined ? undefined : JSON.stringify(body);
  const sleep = opts?.sleep ?? defaultRetrySleep;
  const random = opts?.random ?? Math.random;
  const retryEnabled = opts?.retry !== false;
  const attemptTimeoutMs = Math.max(1, opts?.timeoutMs ?? BLAXEL_DEFAULT_TIMEOUT_MS);
  // The default operation budget must leave room for every configured attempt
  // and the waits between them. Retry-After is capped at 15 seconds, so this
  // covers both server-directed waits and the shorter exponential backoff.
  // An explicit budget remains authoritative for callers that need a tighter
  // wall-clock limit.
  const defaultRetryBudgetMs =
    attemptTimeoutMs * BLAXEL_FETCH_MAX_ATTEMPTS +
    BLAXEL_RETRY_AFTER_CAP_MS * (BLAXEL_FETCH_MAX_ATTEMPTS - 1);
  const retryBudgetMs = Math.max(1, opts?.retryBudgetMs ?? defaultRetryBudgetMs);
  const deadlineMs = Date.now() + retryBudgetMs;
  let lastFailure = "";
  let lastCause: unknown;
  let attemptsMade = 0;
  for (let attempt = 0; attempt < BLAXEL_FETCH_MAX_ATTEMPTS; attempt += 1) {
    throwIfAborted(callerSignal);
    const remainingMs = deadlineMs - Date.now();
    if (remainingMs <= 0) break;
    const lastAttempt = attempt === BLAXEL_FETCH_MAX_ATTEMPTS - 1;
    attemptsMade += 1;
    let response: Response;
    let text: string;
    const attemptSignal = timedAbortSignal(
      callerSignal,
      Math.min(attemptTimeoutMs, remainingMs),
    );
    try {
      response = await fetch(url, {
        method: requestMethod,
        headers,
        body: serializedBody,
        signal: attemptSignal.signal,
      });
      // A response can arrive while its body stream fails. Keep that transport
      // failure in the same attempt boundary so safe requests can retry it.
      text = await response.text();
    } catch (err) {
      attemptSignal.cleanup();
      if (callerSignal?.aborted) throw abortReason(callerSignal);
      // Network failure or timeout: a non-idempotent request may still have
      // executed on the far side, so only idempotent methods are replayed.
      if (!idempotent || !retryEnabled) throw err;
      lastFailure = retryFailureMessage(err);
      lastCause = err;
      if (lastAttempt || Date.now() >= deadlineMs) break;
      const delayMs = blaxelRetryDelayMs(attempt, null, random);
      const waitRemainingMs = deadlineMs - Date.now();
      if (waitRemainingMs <= 0) break;
      const waitSignal = timedAbortSignal(callerSignal, waitRemainingMs);
      try {
        await sleep(Math.min(delayMs, waitRemainingMs), waitSignal.signal);
      } catch (err) {
        // The operation-level deadline ends the retry loop with the normal
        // exhausted error. Only caller cancellation or a test/transport
        // failure escapes this wait.
        if (callerSignal?.aborted) throw abortReason(callerSignal);
        if (!waitSignal.signal.aborted) throw err;
        break;
      } finally {
        waitSignal.cleanup();
      }
      throwIfAborted(callerSignal);
      if (Date.now() >= deadlineMs) break;
      continue;
    }
    attemptSignal.cleanup();
    if (response.ok) return (text ? JSON.parse(text) : undefined) as T;
    const retriable = retryEnabled && idempotent && (response.status === 429 || response.status >= 500);
    if (!retriable) {
      // Preserve the exact historical message shape: the sandbox-create
      // name-collision loop matches /-> 409/ and not-found checks match /-> 404/.
      throw new ProviderError(
        "blaxel",
        `${requestMethod} ${url} -> ${response.status}: ${text.slice(0, 500)}`,
      );
    }
    lastFailure = `${response.status}: ${text.slice(0, 500)}`;
    lastCause = undefined;
    if (lastAttempt || Date.now() >= deadlineMs) break;
    const delayMs = blaxelRetryDelayMs(attempt, response.headers.get("retry-after"), random);
    const waitRemainingMs = deadlineMs - Date.now();
    if (waitRemainingMs <= 0) break;
    const waitSignal = timedAbortSignal(callerSignal, waitRemainingMs);
    try {
      await sleep(Math.min(delayMs, waitRemainingMs), waitSignal.signal);
    } catch (err) {
      if (callerSignal?.aborted) throw abortReason(callerSignal);
      if (!waitSignal.signal.aborted) throw err;
      break;
    } finally {
      waitSignal.cleanup();
    }
    throwIfAborted(callerSignal);
    if (Date.now() >= deadlineMs) break;
  }
  throw new BlaxelRetryExhaustedError(
    requestMethod,
    url,
    attemptsMade,
    lastFailure || "retry budget expired",
    lastCause,
  );
}

// The daemon source resolution, install command, daemon command, and enrollment
// flows live in ./cmuxTuiDaemon (shared with the E2B and Daytona drivers); the
// re-exports keep this module the historical import site.
export {
  CMUX_CLOUD_HOME,
  CMUX_CLOUD_LAYOUT,
  CMUX_CLOUD_USER,
  CMUX_TUI_LINUX_TARGET,
  CMUX_TUI_DEFAULT_MANIFEST_URL,
  cmuxTuiBinaryPath,
  cmuxTuiManifestUrl,
  parseCmuxTuiManifest,
  resolveCmuxTuiSource,
  resetCmuxTuiSourceCache,
  cmuxTuiInstallCommand,
  cmuxTuiPinCheckCommand,
  cmuxTuiDaemonCommand,
  parseEnrollmentInvitationUri,
  type CmuxTuiSource,
  type CmuxTuiDaemonOptions,
} from "./cmuxTuiDaemon";

export const CMUX_TUI_CLIENT_CAPABILITY_USER_AGENT = "direct-ws-user-agent";

/**
 * The branded machine host (`<machine>.vm.cmux.sh`) sits behind a CloudFront
 * distribution that refuses WebSocket upgrades without a User-Agent (measured
 * 2026-08-26: 403 without, 101 with). cmux-tui clients that send one advertise
 * `direct-ws-user-agent`; every other client gets the raw `<hash>.preview.bl.run`
 * host, which does not enforce it.
 */
export function cmuxTuiPreviewBranded(clientCapabilities: readonly string[] | undefined): boolean {
  return (clientCapabilities ?? []).includes(CMUX_TUI_CLIENT_CAPABILITY_USER_AGENT);
}


function parseJsonObject(text: string): Record<string, unknown> {
  try {
    const value = JSON.parse(text.trim());
    return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
  } catch {
    return {};
  }
}

function parseJsonArray(text: string): Array<Record<string, unknown>> {
  try {
    const value = JSON.parse(text.trim());
    return Array.isArray(value)
      ? value.filter((entry): entry is Record<string, unknown> => !!entry && typeof entry === "object")
      : [];
  } catch {
    return [];
  }
}

function volumeListItems(payload: unknown): unknown[] {
  if (Array.isArray(payload)) return payload;
  if (!payload || typeof payload !== "object") return [];
  const candidate = payload as { items?: unknown; data?: unknown };
  if (Array.isArray(candidate.items)) return candidate.items;
  if (Array.isArray(candidate.data)) return candidate.data;
  // Current Blaxel responses wrap the page as `{ data: { items }, meta }`.
  if (candidate.data && typeof candidate.data === "object") {
    const data = candidate.data as { items?: unknown; data?: unknown };
    if (Array.isArray(data.items)) return data.items;
    if (Array.isArray(data.data)) return data.data;
  }
  return [];
}

/**
 * Completion must be an explicit provider signal: a continuation-cursor key
 * present with an empty value, or hasMore === false. A meta object that only
 * carries counts (e.g. { total: 1000 }) proves nothing about exhaustion and
 * must leave coverage marked partial.
 */
/**
 * A payload only counts as a volume page when it carries a recognized items
 * container. Completion claims from shapes we cannot parse must fail closed,
 * otherwise a malformed response reads as an empty-but-complete inventory.
 */
function hasRecognizedVolumeContainer(payload: unknown): boolean {
  if (Array.isArray(payload)) return true;
  if (!payload || typeof payload !== "object") return false;
  const candidate = payload as { items?: unknown; data?: unknown };
  if (Array.isArray(candidate.items) || Array.isArray(candidate.data)) return true;
  if (candidate.data && typeof candidate.data === "object") {
    const data = candidate.data as { items?: unknown; data?: unknown };
    return Array.isArray(data.items) || Array.isArray(data.data);
  }
  return false;
}

function volumePaginationComplete(payload: unknown): boolean {
  if (!payload || typeof payload !== "object" || Array.isArray(payload)) return false;
  const explicitEnd = (source: unknown): boolean => {
    if (!source || typeof source !== "object" || Array.isArray(source)) return false;
    const value = source as {
      nextCursor?: unknown;
      next_cursor?: unknown;
      hasMore?: unknown;
      has_more?: unknown;
    };
    if (value.hasMore === false || value.has_more === false) return true;
    const cursorKeyPresent = "nextCursor" in value || "next_cursor" in value;
    if (!cursorKeyPresent) return false;
    const cursor = value.nextCursor ?? value.next_cursor;
    return cursor === null || cursor === undefined || cursor === "";
  };
  const candidate = payload as { meta?: unknown; data?: unknown };
  if (explicitEnd(payload)) return true;
  if (explicitEnd(candidate.meta)) return true;
  if (candidate.data && typeof candidate.data === "object" && !Array.isArray(candidate.data)) {
    return explicitEnd((candidate.data as { meta?: unknown }).meta);
  }
  return false;
}

function volumeNextCursor(payload: unknown): string | null {
  if (!payload || typeof payload !== "object") return null;
  const candidate = payload as {
    nextCursor?: unknown;
    next_cursor?: unknown;
    meta?: unknown;
    data?: unknown;
  };
  const readMeta = (meta: unknown): string | null => {
    if (!meta || typeof meta !== "object") return null;
    const value = meta as { nextCursor?: unknown; next_cursor?: unknown };
    const cursor = value.nextCursor ?? value.next_cursor;
    return typeof cursor === "string" && cursor.trim().length > 0 ? cursor.trim() : null;
  };
  return readMeta(candidate.meta) ??
    (typeof candidate.nextCursor === "string" && candidate.nextCursor.trim().length > 0
      ? candidate.nextCursor.trim()
      : typeof candidate.next_cursor === "string" && candidate.next_cursor.trim().length > 0
        ? candidate.next_cursor.trim()
        : candidate.data && typeof candidate.data === "object"
          ? readMeta((candidate.data as { meta?: unknown }).meta)
          : null);
}

function attachmentFields(volume: BlaxelVolume): Pick<VMVolume, "attachedTo" | "attachmentState"> {
  const hasOwn = (value: object, key: string): boolean => Object.prototype.hasOwnProperty.call(value, key);
  const state = volume.state && typeof volume.state === "object" ? volume.state : undefined;
  const stateHasAttachment = !!state && hasOwn(state, "attachedTo");
  const rootHasAttachment = hasOwn(volume, "attachedTo");
  const raw = stateHasAttachment
    ? state?.attachedTo
      : rootHasAttachment
      ? volume.attachedTo
      : undefined;

  if (typeof raw === "string" && raw.trim().length > 0) {
    return { attachedTo: raw.trim(), attachmentState: "attached" };
  }
  if (raw === null) return { attachedTo: null, attachmentState: "unattached" };
  // An absent, empty, or malformed attachment field is not proof of freedom.
  return { attachmentState: "unknown" };
}

function parseBlaxelVolumeItems(items: readonly unknown[]): VMVolume[] {
  return items.flatMap((item): VMVolume[] => {
    if (!item || typeof item !== "object") return [];
    const volume = item as BlaxelVolume;
    const rawName = volume.metadata && typeof volume.metadata === "object"
      ? (volume.metadata as { name?: unknown }).name
      : undefined;
    const name = typeof rawName === "string" ? rawName.trim() : "";
    if (!name) return [];
    const rawCreatedAt = volume.metadata && typeof volume.metadata === "object"
      ? (volume.metadata as { createdAt?: unknown }).createdAt
      : undefined;
    const createdAt = typeof rawCreatedAt === "number" && Number.isFinite(rawCreatedAt)
      ? rawCreatedAt
      : typeof rawCreatedAt === "string"
        ? Date.parse(rawCreatedAt)
        : Number.NaN;
    const attachment = attachmentFields(volume);
    return [{
      name,
      createdAt: Number.isFinite(createdAt) ? createdAt : null,
      ...attachment,
    }];
  });
}

/** Normalize the Blaxel `/volumes` response for provider-agnostic cleanup code. */
export function parseBlaxelVolumes(payload: unknown): VMVolume[] {
  return parseBlaxelVolumeItems(volumeListItems(payload));
}

/** Parse one bounded Blaxel volume page, including its opaque continuation cursor. */
export function parseBlaxelVolumePage(payload: unknown, limit = 100): VMVolumePage {
  const boundedLimit = Number.isSafeInteger(limit) && limit > 0 ? Math.min(limit, 100) : 100;
  const items = volumeListItems(payload);
  const truncated = items.length > boundedLimit;
  return {
    // Slice before normalization so legacy responses do not make the reaper
    // retain or sort an unbounded provider inventory.
    volumes: parseBlaxelVolumeItems(items.slice(0, boundedLimit)),
    nextCursor: volumeNextCursor(payload),
    complete: hasRecognizedVolumeContainer(payload) &&
      volumeNextCursor(payload) === null &&
      volumePaginationComplete(payload) &&
      !truncated,
  };
}

export class BlaxelProvider implements VMProvider {
  // Snapshot/fork are a workspace-tier feature Blaxel has not enabled (see `snapshot`);
  // declared so the app hides Checkpoint/Fork instead of offering verbs that 502.
  readonly capabilities = { snapshot: false, restore: false, fork: false } as const;
  readonly id = "blaxel" as const;

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!image) {
      throw new ProviderError("blaxel", "create requires a resolved image");
    }
    return withVmSpan(
      "cmux.vm.provider.create",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "create", "cmux.vm.image": image },
      async (span) => {
        try {
          const memoryMb = resolveMemoryMb(options.memoryMb);
          // Memory is settled before any volume exists: the home's size follows it.
          const homeVolumeMb = resolveHomeVolumeMb(memoryMb);
          // A `{machine}` token in homeVolume is resolved against the generated
          // machine name, giving every fresh machine its own durable home. The
          // resolved name (never the template) is what lands in providerMetadata,
          // so resurrection finds the right volume.
          const homeVolumeSpec = options.homeVolume?.trim() || undefined;
          // A `{machine}` volume is owned by exactly one machine, so failure paths
          // may delete it; a fixed name is the user's shared volume and is never
          // deleted by create/destroy paths.
          const perMachineHomeVolume = !!homeVolumeSpec?.includes("{machine}");
          const resolveHomeVolume = (machineName: string): string | undefined =>
            homeVolumeSpec?.replace("{machine}", machineName);
          let name = friendlyVmName();
          let homeVolume = resolveHomeVolume(name);
          let created: BlaxelSandbox | null = null;
          for (let attempt = 0; attempt < 4 && !created; attempt += 1) {
            let volumeCreated = false;
            if (homeVolume) {
              const volume = homeVolume;
              volumeCreated = await timedStep("ensure_home_volume", () => this.ensureHomeVolume(volume, homeVolumeMb));
            }
            try {
              created = await timedStep("create_sandbox", () => blaxelFetch<BlaxelSandbox>("POST", `${CONTROL_PLANE_BASE}/sandboxes`, {
                metadata: { name },
                spec: {
                  runtime: {
                    image,
                    memory: memoryMb,
                    envs: sandboxEnvs(options.envs),
                    ports: sandboxPorts(),
                  },
                  ...(homeVolume ? { volumes: [{ name: homeVolume, mountPath: HOME_VOLUME_MOUNT_PATH }] } : {}),
                },
              }));
            } catch (err) {
              // A per-machine volume this call just created for a sandbox that never
              // came to exist is already orphaned — a retried create picks a fresh
              // name, so nothing ever reattaches it. Delete it before moving on. A
              // pre-existing volume (409 on ensure) is left alone: it may belong to
              // the live sandbox this name conflicted with.
              if (homeVolume && perMachineHomeVolume && volumeCreated) {
                const volume = homeVolume;
                await this.deleteHomeVolume(volume).catch((cleanupErr) => {
                  console.error(`[blaxel] create cleanup failed; volume ${volume} may be orphaned`, cleanupErr);
                });
              }
              const conflict = err instanceof ProviderError && /-> 409/.test(err.message);
              if (!conflict || attempt === 3) throw err;
              name = friendlyVmName(attempt >= 1);
              homeVolume = resolveHomeVolume(name);
            }
          }
          const sandboxUrl = created?.metadata?.url;
          if (!sandboxUrl) {
            throw new Error("create response is missing metadata.url for the sandbox API");
          }
          // The daemon previews are minted through the same paths attach uses, so a
          // machine is born at https://<name>.vm.cmux.sh (or <name>-cmux.preview.bl.run)
          // rather than an opaque hash it would then keep for life; the raw preview is
          // the route for clients that cannot pass the branded ingress. Previews live on
          // the control plane and only need the sandbox to exist, so they are created in
          // parallel with the in-sandbox daemon bootstrap.
          // All branches settle before any rollback (allSettled, not all): a
          // fast-failing bootstrap must not start deleting the sandbox while a
          // preview POST is still in flight, or the late preview recreates the
          // orphaned branded route the rollback exists to remove.
          const [bootstrapResult, previewResult, rawPreviewResult] = await Promise.allSettled([
            timedStep("bootstrap_daemon", () => this.bootstrapMachine(name, sandboxUrl, !!homeVolume)),
            timedStep("ensure_preview", () => this.ensurePreview(name, CMUX_TUI_PREVIEW_NAME, CMUX_TUI_PORT, { branded: true })),
            timedStep("ensure_raw_preview", () => this.ensurePreview(name, CMUX_TUI_RAW_PREVIEW_NAME, CMUX_TUI_PORT, { branded: false })),
          ]);
          // A machine that failed to bootstrap must not survive as an orphaned
          // sandbox (its previews die with it). A per-machine home volume dies with
          // the machine: a retried create picks a fresh name, so nothing would ever
          // reattach it while its storage keeps billing. A shared user volume is
          // kept — a retried create reattaches it by name.
          // A rollback failure means the sandbox or volume is now leaked on the
          // provider: log it loudly (the original create error still propagates) so
          // the orphan is findable instead of silently accumulating.
          const rollback = async () => {
            await this.destroy(name).catch((cleanupErr) => {
              console.error(`[blaxel] create rollback failed; sandbox ${name} may be orphaned`, cleanupErr);
            });
            if (homeVolume && perMachineHomeVolume) {
              const volume = homeVolume;
              await this.deleteHomeVolume(volume).catch((cleanupErr) => {
                console.error(`[blaxel] create rollback failed; volume ${volume} may be orphaned`, cleanupErr);
              });
            }
          };
          if (bootstrapResult.status === "rejected") {
            await rollback();
            throw bootstrapResult.reason;
          }
          if (previewResult.status === "rejected") {
            await rollback();
            throw previewResult.reason;
          }
          if (rawPreviewResult.status === "rejected") {
            await rollback();
            throw rawPreviewResult.reason;
          }
          const previewUrl = previewResult.value;
          span.setAttribute("cmux.vm.id", name);
          return {
            provider: "blaxel",
            providerVmId: name,
            status: "running",
            image,
            createdAt: Date.now(),
            providerMetadata: homeVolume
              ? {
                  sandboxUrl,
                  previewUrl,
                  homeVolume,
                  homeVolumeMb,
                  image,
                  memoryMb,
                  // Destroy paths delete only volumes a machine owns exclusively;
                  // this marker is that ownership record.
                  ...(perMachineHomeVolume ? { homeVolumePerMachine: true } : {}),
                }
              : { sandboxUrl, previewUrl, image, memoryMb },
          };
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("blaxel", `create(${image}) failed`, err);
        }
      },
    );
  }

  // MARK: cmux-tui remote daemon

  /** Create-time bootstrap: the smart-sleep watcher, the cmux-tui daemon, the hostname/VNC chain and background provisioning. */
  private async bootstrapMachine(
    name: string,
    sandboxUrl: string,
    persistentVolumeExpected: boolean,
  ): Promise<void> {
    // A just-created sandbox answers 404 ("VM not found") on its API for a few
    // seconds; the first write is the readiness probe and retries instead.
    await this.awaitSandboxApi(name, sandboxUrl, () =>
      blaxelFetch("PUT", `${sandboxUrl}/filesystem/${SMART_SLEEP_PATH}`, { content: SMART_SLEEP_SCRIPT, permissions: "0755" }));
    const prep = await this.sandboxExec(sandboxUrl, `chmod 755 ${SMART_SLEEP_PATH} && mkdir -p /tmp/cmux && chmod 700 /tmp/cmux`);
    if (prep.exitCode !== 0) {
      throw new ProviderError("blaxel", `machine prep in ${name} failed: ${prep.stderr || prep.stdout}`);
    }
    // The work user must exist (and a migrated volume must be owned) before the daemon
    // starts, or its panes would be root shells. The daemon bootstrap also owns the
    // first package-manager operation (curl on a stock image), so it completes before
    // the detached provisioner can start another apt/apk process.
    let userSetup: ExecResult | null = null;
    try {
      userSetup = await timedStep("user_setup", () =>
        this.sandboxExec(sandboxUrl, CMUX_CLOUD_USER_SETUP_COMMAND, CMUX_USER_SETUP_TIMEOUT_MS));
    } catch (err) {
      // User setup is best effort. The daemon's UID and mount predicates select
      // the persistent root fallback when an old or custom image cannot provide
      // the work user, so a setup failure must not orphan an otherwise usable VM.
      console.warn(`[blaxel] user setup in ${name} failed; continuing with root fallback`, err);
    }
    if (userSetup && userSetup.exitCode !== 0) {
      console.warn(`[blaxel] user setup in ${name} exited ${userSetup.exitCode}; continuing with root fallback`);
    }
    // Readiness must imply an attempted escalation setup: the bounded sudo heal
    // completes before the daemon can start, including on unstamped stock images.
    // A known install failure is logged and leaves the daemon's root fallback active.
    await timedStep("sudo_heal", () => this.healSudo(sandboxUrl, `create ${name}`));
    // The watcher and hostname/VNC heal can start while the daemon downloads its
    // binary. Keep the detached provisioner until that download is done, because a
    // stock image may need apk for curl and cannot run two package managers safely.
    const daemonReady = timedStep("cmux_tui_bootstrap", () =>
      this.bootstrapCmuxTui(name, sandboxUrl, persistentVolumeExpected),
    );
    await Promise.all([
      daemonReady,
      timedStep("watcher_start", () => this.startWatcherProcess(sandboxUrl)),
      (async () => {
        await timedStep("hostname_setup", () => this.sandboxExec(sandboxUrl, hostnameSetupCommand(name)).catch(() => undefined));
        await timedStep("vnc_heal_start", () => this.startDesktopVncHeal(sandboxUrl));
      })(),
    ]);
    // The provision script has its own package lock for attach races. Its process is
    // detached, so launching it here does not delay the create response.
    await (async () => {
      await blaxelFetch("PUT", `${sandboxUrl}/filesystem/${CMUX_PROVISION_SCRIPT_PATH}`, { content: CMUX_PROVISION_SCRIPT, permissions: "0755" });
      await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
        name: "cmux-provision",
        command: `CMUX_PROVISION_VOLUME_EXPECTED=${persistentVolumeExpected ? "1" : "0"} ${CMUX_PROVISION_COMMAND}`,
        waitForCompletion: false,
      });
    })().catch(() => undefined);
  }

  private async awaitSandboxApi<T>(name: string, sandboxUrl: string, call: () => Promise<T>): Promise<T> {
    const deadline = Date.now() + 60_000;
    let lastError: unknown;
    while (Date.now() < deadline) {
      try {
        return await call();
      } catch (err) {
        const notReady = err instanceof ProviderError && /-> 404|VM not found|-> 503/i.test(err.message);
        if (!notReady) throw err;
        lastError = err;
        await new Promise((resolve) => setTimeout(resolve, 1500));
      }
    }
    throw new ProviderError("blaxel", `sandbox API for ${name} did not become reachable`, lastError);
  }

  /** Installs (or re-verifies) the pinned binary and starts the daemon. */
  private async bootstrapCmuxTui(
    name: string,
    sandboxUrl: string,
    persistentVolumeExpected: boolean,
  ): Promise<void> {
    const source = await sharedResolveCmuxTuiSource("blaxel");
    const install = await this.sandboxExec(
      sandboxUrl,
      sharedCmuxTuiInstallCommand(source, CMUX_CLOUD_LAYOUT, { persistentVolumeExpected }),
      CMUX_TUI_INSTALL_TIMEOUT_MS,
    );
    if (install.exitCode !== 0) {
      throw new ProviderError("blaxel", `cmux-tui install in ${name} failed: ${install.stderr || install.stdout}`);
    }
    await this.startCmuxTuiProcess(sandboxUrl, persistentVolumeExpected);
    await this.waitForCmuxTuiReady(name, sandboxUrl, persistentVolumeExpected);
  }

  private async startCmuxTuiProcess(
    sandboxUrl: string,
    persistentVolumeExpected: boolean,
  ): Promise<void> {
    // Blaxel restarts this named process after the mount watcher returns 75.
    // Re-run the idempotent setup in that same command so a lost bindfs view
    // is repaired before the daemon chooses its root backing fallback. A
    // bounded second attempt covers a short package-lock or mirror failure
    // before the daemon accepts a deliberate root fallback.
    const setup = shellQuote(CMUX_CLOUD_USER_SETUP_COMMAND);
    const daemon = sharedCmuxTuiDaemonCommand(undefined, CMUX_CLOUD_LAYOUT, {
      persistentVolumeExpected,
    });
    const setupAttempt = `if command -v timeout >/dev/null 2>&1; then timeout 300 sh -c ${setup}; else sh -c ${setup}; fi`;
    // A volume may be attached after the provider process starts. Wait for that
    // mount before setup so bindfs repair runs against durable storage, rather
    // than creating a healthy root fallback from a transient rootfs home.
    const persistentMountWait = sharedCmuxTuiPersistentMountWait(
      CMUX_CLOUD_LAYOUT,
      persistentVolumeExpected,
    );
    const command =
      persistentMountWait +
      `for _ in 1 2; do ` +
      `${setupAttempt} >/dev/null 2>&1 || true; ` +
      `if ${CMUX_CLOUD_USER_USABLE_CONDITION}; then break; fi; ` +
      `done; ` +
      `${daemon}`;
    await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
      name: CMUX_TUI_PROCESS_NAME,
      command,
      waitForCompletion: false,
      // Not keepAlive: the smart-sleep watcher counts connections on the daemon's port,
      // so an idle machine still drops to standby.
      keepAlive: false,
      restartOnFailure: true,
      maxRestarts: 10,
    });
  }

  /** Stops the named daemon supervisor without turning an already-gone process into an error. */
  private async stopCmuxTuiProcess(sandboxUrl: string, context: string): Promise<boolean> {
    try {
      await blaxelFetch(
        "DELETE",
        `${sandboxUrl}/process/${encodeURIComponent(CMUX_TUI_PROCESS_NAME)}`,
      );
      return true;
    } catch (err) {
      if (err instanceof ProviderError && /-> 404/.test(err.message)) return true;
      console.warn(`[blaxel] ${context}: could not stop the named cmux-tui process`, err);
      return false;
    }
  }

  /** Reconciles a healthy root fallback after setup later restores the non-root layout. */
  private async reconcileCmuxTuiRootFallback(
    vmId: string,
    sandboxUrl: string,
    proc: BlaxelProcess,
    source: CmuxTuiSource,
    persistentVolumeExpected: boolean,
  ): Promise<void> {
    if (proc.status !== "running") return;
    const marker = await this.sandboxExec(
      sandboxUrl,
      `cat ${CMUX_TUI_LAYOUT_MARKER_PATH} 2>/dev/null`,
      10_000,
    ).catch(() => null);
    if (marker?.stdout.trim() !== "root") return;
    // A /root mount is the intentional pre-layout state. Keep that daemon root-owned
    // until resurrection moves the volume to the current layout.
    const legacy = await this.sandboxExec(sandboxUrl, "mountpoint -q /root 2>/dev/null", 10_000).catch(() => null);
    if (legacy?.exitCode === 0) return;

    // Retry the same idempotent setup used by the process command. This is the
    // attach-time reconciliation for a transient lock or package mirror failure.
    await this.sandboxExec(sandboxUrl, CMUX_CLOUD_USER_SETUP_COMMAND, CMUX_USER_SETUP_TIMEOUT_MS).catch(() => undefined);
    await this.healSudo(sandboxUrl, `attach ${vmId} root-fallback-reconcile`);
    // Do not stop a durable root fallback until the expected volume is back. The
    // setup command is safe to retry, but replacing the only live daemon while
    // its persistent home is absent would create avoidable downtime.
    const usableCondition = persistentVolumeExpected
      ? `${CMUX_CLOUD_USER_USABLE_CONDITION} && mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null`
      : CMUX_CLOUD_USER_USABLE_CONDITION;
    const usable = await this.sandboxExec(sandboxUrl, usableCondition, 10_000).catch(() => null);
    if (usable?.exitCode !== 0) return;

    const installed = await this.sandboxExec(
      sandboxUrl,
      sharedCmuxTuiPinCheckCommand(source, CMUX_CLOUD_LAYOUT, { persistentVolumeExpected }),
    ).catch(() => null);
    if (!(await this.stopCmuxTuiProcess(sandboxUrl, `attach ${vmId} root-fallback-reconcile`))) return;
    if (installed?.exitCode !== 0) {
      await this.bootstrapCmuxTui(vmId, sandboxUrl, persistentVolumeExpected);
    } else {
      await this.startCmuxTuiProcess(sandboxUrl, persistentVolumeExpected);
      await this.waitForCmuxTuiReady(vmId, sandboxUrl, persistentVolumeExpected);
    }
  }

  // Attach requests can arrive in parallel while a degraded daemon is being
  // replaced. Coalesce the stop/setup/start sequence per sandbox so one attach
  // cannot terminate the replacement started by another.
  private readonly inflightRootFallbackReconciliations = new Map<string, Promise<void>>();

  private reconcileCmuxTuiRootFallbackOnce(
    vmId: string,
    sandboxUrl: string,
    proc: BlaxelProcess,
    source: CmuxTuiSource,
    persistentVolumeExpected: boolean,
  ): Promise<void> {
    const key = `${vmId}:${sandboxUrl}`;
    const inflight = this.inflightRootFallbackReconciliations.get(key);
    if (inflight) return inflight;
    const task = this.reconcileCmuxTuiRootFallback(
      vmId,
      sandboxUrl,
      proc,
      source,
      persistentVolumeExpected,
    ).finally(() => {
      if (this.inflightRootFallbackReconciliations.get(key) === task) {
        this.inflightRootFallbackReconciliations.delete(key);
      }
    });
    this.inflightRootFallbackReconciliations.set(key, task);
    return task;
  }

  private waitForCmuxTuiReady(
    name: string,
    sandboxUrl: string,
    persistentVolumeExpected: boolean,
  ): Promise<void> {
    return sharedWaitForCmuxTuiReady(
      this.cmuxTuiInvoke(sandboxUrl, persistentVolumeExpected),
      "blaxel",
      name,
    );
  }

  // Mirrors the daemon command's user/home selection (cmuxTuiDaemonCommand): CLI
  // invocations must read the same state dir, as the same user, as the daemon writes.
  /** Runs a cmux-tui CLI request using the daemon's selected home and identity. */
  private cmuxTuiExec(
    sandboxUrl: string,
    args: string,
    timeoutMs = EXEC_DEFAULT_TIMEOUT_MS,
    persistentVolumeExpected = false,
  ): Promise<ExecResult> {
    const legacy =
      `if [ -x ${CMUX_TUI_LEGACY_BINARY_PATH} ]; then exec env HOME=/root ${CMUX_TUI_LEGACY_BINARY_PATH} ${args}; ` +
      `elif [ -x ${CMUX_TUI_BINARY_PATH} ]; then exec env HOME=/root ${CMUX_TUI_BINARY_PATH} ${args}; ` +
      `else exec env HOME=/root ${CMUX_TUI_LEGACY_BINARY_PATH} ${args}; fi`;
    const backing =
      `if ! mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then exit 75; fi; ` +
      `if [ -x ${CMUX_TUI_BACKING_BINARY_PATH} ]; then exec env HOME=${CMUX_HOME_VOLUME_BACKING_PATH} ${CMUX_TUI_BACKING_BINARY_PATH} ${args}; ` +
      `elif [ -x ${CMUX_TUI_LEGACY_BINARY_PATH} ]; then exec env HOME=${CMUX_HOME_VOLUME_BACKING_PATH} ${CMUX_TUI_LEGACY_BINARY_PATH} ${args}; ` +
      `else exec env HOME=${CMUX_HOME_VOLUME_BACKING_PATH} ${CMUX_TUI_BACKING_BINARY_PATH} ${args}; fi`;
    const usable = persistentVolumeExpected
      ? `${CMUX_CLOUD_USER_USABLE_CONDITION} && mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null`
      : CMUX_CLOUD_USER_USABLE_CONDITION;
    const rootFallback = persistentVolumeExpected
      ? `elif mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then ${backing}; else exit 75`
      : `elif mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then ${backing}; ` +
        `else exec env HOME=${CMUX_CLOUD_HOME} ${CMUX_TUI_BINARY_PATH} ${args}`;
    const persistentVolumeGuard = persistentVolumeExpected
      ? `if ! mountpoint -q /root 2>/dev/null && ! mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then exit 75; fi; `
      : "";
    const command =
      persistentVolumeGuard +
      `if mountpoint -q /root 2>/dev/null; then ${legacy}; ` +
      `elif ${CMUX_HOME_VIEW_MISSING_CONDITION}; then ` +
      backing +
      "; " +
      `elif ${usable}; then ` +
      `exec runuser -u ${CMUX_CLOUD_USER} -- env HOME=${CMUX_CLOUD_HOME} USER=${CMUX_CLOUD_USER} LOGNAME=${CMUX_CLOUD_USER} ${CMUX_TUI_BINARY_PATH} ${args}; ` +
      `${rootFallback}; fi`;
    return this.sandboxExec(sandboxUrl, command, timeoutMs);
  }

  /** Adapts the sandbox API exec to the shared cmux-tui flows. */
  private cmuxTuiInvoke(
    sandboxUrl: string,
    persistentVolumeExpected = false,
  ): CmuxTuiInvoke {
    return (args, timeoutMs) => this.cmuxTuiExec(
      sandboxUrl,
      args,
      timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS,
      persistentVolumeExpected,
    );
  }

  private async ensureCmuxTuiRunning(
    vmId: string,
    sandboxUrl: string,
    persistentVolumeExpected: boolean,
  ): Promise<void> {
    const source = await sharedResolveCmuxTuiSource("blaxel");
    const proc = await blaxelFetch<BlaxelProcess>("GET", `${sandboxUrl}/process/${CMUX_TUI_PROCESS_NAME}`).catch(() => null);
    if (proc?.status === "running") {
      await this.reconcileCmuxTuiRootFallbackOnce(
        vmId,
        sandboxUrl,
        proc,
        source,
        persistentVolumeExpected,
      );
    } else {
      // The daemon is about to (re)start with the layout command; make sure the work
      // user it drops to exists even on a sandbox whose create predates the layout
      // (best-effort: the daemon command itself falls back to root without the user).
      await this.sandboxExec(sandboxUrl, CMUX_CLOUD_USER_SETUP_COMMAND, CMUX_USER_SETUP_TIMEOUT_MS).catch(() => undefined);
      // Same heal as create/resurrect bootstrap: a still-alive sandbox from a stamped
      // pre-r12 image has the user and sudoers policy but no sudo binary, and without
      // this its cmux sessions would have no escalation path after a daemon restart.
      await this.healSudo(sandboxUrl, `attach ${vmId}`);
      // The binary lives on the persistent volume, so a resurrected sandbox usually only
      // needs the process started; a pin change or a fresh volume re-runs the install.
      const installed = await this.sandboxExec(
        sandboxUrl,
        sharedCmuxTuiPinCheckCommand(source, CMUX_CLOUD_LAYOUT, { persistentVolumeExpected }),
      ).catch(() => null);
      if (installed?.exitCode !== 0) {
        // Missing, or a different build than the manifest now pins: (re)install.
        await this.bootstrapCmuxTui(vmId, sandboxUrl, persistentVolumeExpected);
      } else {
        await this.startCmuxTuiProcess(sandboxUrl, persistentVolumeExpected);
        await this.waitForCmuxTuiReady(vmId, sandboxUrl, persistentVolumeExpected);
      }
    }
    // Attach = user activity: re-arm the smart-sleep watcher so the sandbox stays awake
    // while this session works, and can freeze again once it goes idle.
    const watcher = await blaxelFetch<BlaxelProcess>("GET", `${sandboxUrl}/process/${SMART_SLEEP_PROCESS_NAME}`).catch(() => null);
    if (watcher?.status !== "running") {
      await this.startWatcherProcess(sandboxUrl);
    }
  }

  /**
   * A status read doubles as the wake request for a sandbox in standby. A persistent-home
   * machine whose sandbox is gone gets resurrected around its volume. "Gone" is either a
   * 404 or a still-listed TERMINATED/DELETING record — Blaxel deletion is asynchronous, so
   * both shapes mean the compute is dead.
   */
  private async liveSandboxForAttach(vmId: string, providerMetadata?: Record<string, unknown>): Promise<BlaxelSandbox> {
    let sandbox: BlaxelSandbox | null = null;
    try {
      const fetched = await this.getSandbox(vmId);
      sandbox = mapStatus(fetched) === "destroyed" ? null : fetched;
    } catch (err) {
      const gone = err instanceof ProviderError && /-> 404/.test(err.message);
      if (!gone) throw err;
    }
    if (!sandbox) {
      sandbox = providerMetadata ? await this.resurrectSandbox(vmId, providerMetadata) : null;
      if (!sandbox) {
        throw new ProviderError("blaxel", `sandbox ${vmId} is gone and has no persistent home to resurrect from`);
      }
    }
    return sandbox;
  }

  async openCmuxRemote(vmId: string, options?: CmuxRemoteAttachOptions): Promise<CmuxRemoteEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_cmux_remote",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "open_cmux_remote", "cmux.vm.id": vmId },
      async (span) => {
        try {
          const sandbox = await this.liveSandboxForAttach(vmId, options?.providerMetadata);
          const sandboxUrl = sandbox.metadata?.url;
          if (!sandboxUrl) {
            throw new Error("sandbox is missing metadata.url");
          }
          const persistentVolumeExpected =
            sandboxHasPersistentHomeVolume(sandbox, options?.providerMetadata);
          await this.ensureCmuxTuiRunning(vmId, sandboxUrl, persistentVolumeExpected);
          const branded = cmuxTuiPreviewBranded(options?.clientCapabilities);
          const previewUrl = await this.ensurePreview(
            vmId,
            branded ? CMUX_TUI_PREVIEW_NAME : CMUX_TUI_RAW_PREVIEW_NAME,
            CMUX_TUI_PORT,
            { branded },
          );
          span.setAttribute("cmux.vm.cmux_remote.branded", branded);
          const token = await this.mintPreviewToken(vmId, branded ? CMUX_TUI_PREVIEW_NAME : CMUX_TUI_RAW_PREVIEW_NAME);
          const expiresAtUnix = Math.floor(Date.now() / 1000) + PREVIEW_TOKEN_TTL_SECONDS;
          const host = previewUrl.replace(/^https?:\/\//, "").replace(/\/+$/, "");
          // The gateway accepts the preview token as a query parameter and the Rust dialer
          // passes the URL through verbatim, so the tokenized route is the whole story
          // (proven by scripts/spike-cmux-tui-blaxel.sh). It travels only in this response,
          // never inside an invitation.
          const route = `wss://${host}/v1/link?bl_preview_token=${encodeURIComponent(token)}`;

          const invoke = this.cmuxTuiInvoke(sandboxUrl, persistentVolumeExpected);
          let invitation: CmuxRemoteEndpoint["invitation"];
          const enrolled = options?.deviceFingerprint
            ? await isCmuxTuiDeviceEnrolled(invoke, options.deviceFingerprint)
            : false;
          if (!enrolled) {
            invitation = await mintCmuxTuiInvitation(invoke, "blaxel", vmId);
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
          throw err instanceof ProviderError ? err : new ProviderError("blaxel", `openCmuxRemote(${vmId}) failed`, err);
        }
      },
    );
  }

  async approveCmuxRemoteEnrollment(
    vmId: string,
    invitationId: string,
    options?: CmuxRemoteApprovalOptions,
  ): Promise<CmuxRemoteApprovalResult> {
    return withVmSpan(
      "cmux.vm.provider.approve_cmux_remote_enrollment",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "approve_cmux_remote_enrollment", "cmux.vm.id": vmId },
      async () => {
        try {
          const sandbox = await this.getSandbox(vmId);
          const sandboxUrl = sandbox.metadata?.url;
          if (!sandboxUrl) {
            throw new ProviderError("blaxel", `sandbox ${vmId} has no API url (status ${sandbox.status ?? "unknown"})`);
          }
          return await approveCmuxTuiEnrollment(
            this.cmuxTuiInvoke(sandboxUrl, sandboxHasPersistentHomeVolume(sandbox, options?.providerMetadata)),
            "blaxel",
            vmId,
            invitationId,
          );
        } catch (err) {
          throw err instanceof ProviderError ? err : new ProviderError("blaxel", `approveCmuxRemoteEnrollment(${vmId}) failed`, err);
        }
      },
    );
  }

  // The daemon itself is NOT keepAlive: while every shell is idle and no client is attached,
  // nothing pins the sandbox and Blaxel freezes it (processes preserved in the memory
  // snapshot). The smart-sleep watcher is the only keepAlive process, and it exits when idle.
  private async startWatcherProcess(sandboxUrl: string): Promise<void> {
    await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
      name: SMART_SLEEP_PROCESS_NAME,
      command: SMART_SLEEP_PATH,
      waitForCompletion: false,
      keepAlive: true,
    });
  }

  // Best-effort: a desktop machine should come up with its screen, but a base machine has no
  // start-vnc.sh and the command self-exits, so this is safe to run on every bootstrap. Not
  // keepAlive — a live desktop is pinned by the attached client, not by this starter.
  private async startDesktopVncHeal(sandboxUrl: string): Promise<void> {
    await blaxelFetch<BlaxelProcess>("POST", `${sandboxUrl}/process`, {
      name: DESKTOP_VNC_HEAL_PROCESS_NAME,
      command: DESKTOP_VNC_HEAL_COMMAND,
      waitForCompletion: false,
      keepAlive: false,
    }).catch(() => undefined);
  }

  async destroy(vmId: string): Promise<void> {
    await withVmSpan(
      "cmux.vm.provider.destroy",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "destroy", "cmux.vm.id": vmId },
      async () => {
        try {
          await blaxelFetch("DELETE", `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}`);
        } catch (err) {
          // Cleanup paths retry destroy after partial create failures; a sandbox
          // that is already gone is this operation's success state, not an error.
          const gone = err instanceof ProviderError && /-> 404/.test(err.message);
          if (!gone) throw err;
        }
      },
    );
  }

  /** List one bounded page of volumes; the no-argument form keeps legacy callers working. */
  async listVolumes(): Promise<readonly VMVolume[]>;
  async listVolumes(options: VMVolumeListOptions): Promise<VMVolumePage>;
  async listVolumes(options?: VMVolumeListOptions): Promise<VMVolumeInventory> {
    const query = new URLSearchParams();
    if (options) {
      const limit = Number.isSafeInteger(options.limit) && options.limit > 0
        ? Math.min(options.limit, 100)
        : 100;
      query.set("limit", String(limit));
      if (options.cursor) query.set("cursor", options.cursor);
      // The provider supports ordered cursor pages. This keeps a run fair for
      // old volumes without requiring the reaper to sort an unbounded result.
      query.set("sort", "createdAt:asc");
    }
    const suffix = query.size > 0 ? `?${query.toString()}` : "";
    const payload = await blaxelFetch<unknown>("GET", `${CONTROL_PLANE_BASE}/volumes${suffix}`);
    return options
      ? parseBlaxelVolumePage(payload, options.limit)
      : parseBlaxelVolumes(payload);
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    const sandbox = await this.getSandbox(vmId);
    return mapStatus(sandbox);
  }

  // Blaxel hibernates automatically (~15 s after the last connection when no keepAlive process
  // is running) and wakes transparently on the next request, so pause is a no-op and resume is
  // just a status read that also serves as the wake request.
  async pause(vmId: string): Promise<void> {
    void vmId;
  }

  async resume(vmId: string): Promise<VMHandle> {
    return withVmSpan(
      "cmux.vm.provider.resume",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "resume", "cmux.vm.id": vmId },
      async () => {
        const sandbox = await this.getSandbox(vmId);
        return this.handleFromSandbox(vmId, sandbox);
      },
    );
  }

  async exec(vmId: string, command: string, opts?: ExecOptions): Promise<ExecResult> {
    const timeoutMs = Math.min(opts?.timeoutMs ?? EXEC_DEFAULT_TIMEOUT_MS, MAX_EXEC_TIMEOUT_MS);
    return withVmSpan(
      "cmux.vm.provider.exec",
      {
        "cmux.vm.provider": "blaxel",
        "cmux.vm.operation": "exec",
        "cmux.vm.id": vmId,
        "cmux.command_length": command.length,
        "cmux.timeout_ms": timeoutMs,
      },
      async (span) => {
        const sandbox = await this.getSandbox(vmId);
        const sandboxUrl = sandbox.metadata?.url;
        if (!sandboxUrl) {
          throw new ProviderError("blaxel", `sandbox ${vmId} has no API url (status ${sandbox.status ?? "unknown"})`);
        }
        const result = await this.sandboxExec(
          sandboxUrl,
          userExecCommand(command, {
            persistentVolumeExpected: sandboxHasPersistentHomeVolume(sandbox, opts?.providerMetadata),
          }),
          timeoutMs,
        );
        span.setAttribute("cmux.exec.exit_code", result.exitCode);
        return result;
      },
    );
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    void vmId;
    void name;
    // Blaxel exposes GET/POST /sandboxes/{name}/snapshots, but the API returns
    // 403 "Sandbox snapshot/fork feature is not enabled for this workspace" on the current
    // workspace tier (verified 2026-08-20). Wire this up once the feature is enabled; until
    // then durability comes from standby memory snapshots (automatic) and the sandbox TTL.
    throw new VmOperationUnsupportedError({ provider: this.id, operation: "snapshot" });
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    void snapshotId;
    throw new VmOperationUnsupportedError({ provider: this.id, operation: "restore" });
  }

  async openSSH(vmId: string): Promise<SSHEndpoint> {
    return withVmSpan(
      "cmux.vm.provider.open_ssh",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "open_ssh", "cmux.vm.id": vmId },
      async () => {
        throw new ProviderError(
          "blaxel",
          "Blaxel sandboxes have no raw TCP ingress, so there is no SSH. " +
            "Blaxel machines attach through the cmux-tui remote daemon (transport cmux-remote).",
        );
      },
    );
  }

  /** The only session transport: the cmux-tui remote daemon (`openCmuxRemote`). */
  readonly attachTransports: readonly AttachTransport[] = ["cmux-remote"];

  async openAttach(vmId: string, options?: AttachOptions): Promise<AttachEndpoint> {
    void options;
    throw new ProviderError(
      "blaxel",
      `openAttach(${vmId}) is not supported: Blaxel machines attach through the cmux-tui remote daemon (transport cmux-remote).`,
    );
  }

  async revokeSSHIdentity(identityHandle: string): Promise<void> {
    void identityHandle;
    // openSSH always throws, so there is never an identity to revoke.
  }

  /**
   * Close every cmux ingress for a machine during account sign-out.
   *
   * Blaxel preview tokens are independent of Stack Auth, so deleting only the
   * Postgres lease row would leave a copied preview URL usable until its TTL.
   * Remove the private previews and stop the cmux-tui daemon before returning;
   * the next authenticated attach recreates both idempotently.
   */
  async revokeEndpointLeases(vmId: string): Promise<void> {
    const previewsBase = `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}/previews`;
    let sandbox: BlaxelSandbox | null = null;
    try {
      sandbox = await this.getSandbox(vmId);
    } catch (err) {
      if (!(err instanceof ProviderError && /-> 404/.test(err.message))) throw err;
    }

    const sandboxUrl = sandbox?.metadata?.url;
    if (sandboxUrl) {
      // Stop the named supervisor through the sandbox API first. The layout
      // daemon owns a mount-health watcher and a child process; killing only
      // the child would make restartOnFailure launch it again. The shell
      // fallback below still cleans up legacy daemons on older API versions.
      await this.stopCmuxTuiProcess(sandboxUrl, `revokeEndpointLeases(${vmId})`);
      const result = await this.sandboxExec(
        sandboxUrl,
        [
          `pkill -TERM -x ${shellQuote(SMART_SLEEP_PROCESS_NAME)} 2>/dev/null || true`,
          `pkill -TERM -f ${shellQuote(`${CMUX_TUI_BINARY_PATH} server start`)} 2>/dev/null || true`,
          `pkill -TERM -f ${shellQuote(`${CMUX_TUI_BACKING_BINARY_PATH} server start`)} 2>/dev/null || true`,
          // A pre-layout sandbox's daemon was started from the /root binary path.
          `pkill -TERM -f ${shellQuote(`${CMUX_TUI_LEGACY_BINARY_PATH} server start`)} 2>/dev/null || true`,
        ].join("; "),
        15_000,
      );
      if (result.exitCode !== 0) {
        throw new ProviderError(
          "blaxel",
          `revokeEndpointLeases(${vmId}) failed to stop the cmux-tui daemon: ${result.stderr || result.stdout}`,
        );
      }
    }

    // Preview deletion is control-plane-only, so it also works when the
    // sandbox is asleep and has no live sandbox API URL.
    let listed: unknown;
    try {
      listed = await blaxelFetch<unknown>("GET", previewsBase);
    } catch (err) {
      if (err instanceof ProviderError && /-> 404/.test(err.message)) return;
      throw err;
    }
    const rawItems = Array.isArray(listed)
      ? listed
      : listed && typeof listed === "object" && Array.isArray((listed as { items?: unknown }).items)
      ? (listed as { items: unknown[] }).items
      : [];
    const names = rawItems
      .map((item) => {
        if (!item || typeof item !== "object") return null;
        const candidate = item as BlaxelPreview;
        return candidate.metadata?.name?.trim() || null;
      })
      .filter((name): name is string => !!name);
    await Promise.all(names.map(async (name) => {
      try {
        await blaxelFetch("DELETE", `${previewsBase}/${encodeURIComponent(name)}`);
      } catch (err) {
        if (!(err instanceof ProviderError && /-> 404/.test(err.message))) throw err;
      }
    }));
  }

  private async getSandbox(vmId: string): Promise<BlaxelSandbox> {
    return blaxelFetch<BlaxelSandbox>("GET", `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}`);
  }

  // A size the volume API rejects surfaces as the provider's own message (non-409
  // responses propagate); there is no silent fallback to a smaller disk.
  /** Returns true when this call created the volume, false when it already existed. */
  private async ensureHomeVolume(name: string, sizeMb: number): Promise<boolean> {
    try {
      await blaxelFetch("POST", `${CONTROL_PLANE_BASE}/volumes`, {
        metadata: { name },
        spec: { size: sizeMb },
      });
      return true;
    } catch (err) {
      // An existing volume is the expected steady state; anything else is fatal.
      const conflict = err instanceof ProviderError && /-> 409/.test(err.message);
      if (!conflict) throw err;
      return false;
    }
  }

  // Blaxel deletes sandboxes asynchronously and keeps a volume's attachment record
  // alive until that finishes, answering 409 in the window. ~7.5 s of backoff covers it.
  private static readonly HOME_VOLUME_DELETE_RETRY_DELAYS_MS: readonly number[] = [500, 1000, 2000, 4000];

  /**
   * Delete a persistent home volume (`DELETE /volumes/{name}`). A 404 is success —
   * the volume is already gone. A 409 (still attached while the owning sandbox
   * finishes deleting) is retried with bounded backoff; anything else, or an
   * exhausted retry budget, throws so the caller can record the leak. Ownership is
   * the caller's judgment: only a volume owned solely by a destroyed machine may
   * be passed here.
   */
  async deleteHomeVolume(volumeName: string, opts?: { retryDelaysMs?: readonly number[] }): Promise<void> {
    const name = volumeName.trim();
    if (!name) throw new ProviderError("blaxel", "deleteHomeVolume requires a volume name");
    await withVmSpan(
      "cmux.vm.provider.delete_home_volume",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "delete_home_volume", "cmux.vm.volume": name },
      async () => {
        const delays = opts?.retryDelaysMs ?? BlaxelProvider.HOME_VOLUME_DELETE_RETRY_DELAYS_MS;
        for (let attempt = 0; ; attempt += 1) {
          try {
            // This method owns a narrower policy: only the provider's transient
            // "still attached" 409 is retried below. Do not add the generic
            // idempotent 5xx retry on top of that bounded cleanup loop.
            await blaxelFetch(
              "DELETE",
              `${CONTROL_PLANE_BASE}/volumes/${encodeURIComponent(name)}`,
              undefined,
              { retry: false },
            );
            return;
          } catch (err) {
            const gone = err instanceof ProviderError && /-> 404/.test(err.message);
            if (gone) return;
            const attached = err instanceof ProviderError && /-> 409/.test(err.message);
            if (!attached || attempt >= delays.length) {
              throw err instanceof ProviderError
                ? err
                : new ProviderError("blaxel", `deleteHomeVolume(${name}) failed`, err);
            }
            await new Promise((resolve) => setTimeout(resolve, delays[attempt]));
          }
        }
      },
    );
  }

  /**
   * Resurrection: a persistent-home machine whose sandbox is gone (TTL expiry, provider loss)
   * is recreated around the same volume and re-bootstrapped, so from the user's side the
   * machine never died — its compute was just asleep somewhere deeper. Only possible when the
   * VM row's providerMetadata carries homeVolume + image from the original create.
   */
  private async resurrectSandbox(
    vmId: string,
    metadata: Record<string, unknown>,
  ): Promise<BlaxelSandbox | null> {
    const homeVolume = typeof metadata.homeVolume === "string" ? metadata.homeVolume : null;
    const image = typeof metadata.image === "string" ? metadata.image : null;
    if (!homeVolume || !image) return null;
    const memoryMb = resolveMemoryMb(
      typeof metadata.memoryMb === "number" ? metadata.memoryMb : undefined,
    );
    // The volume already exists (409 → steady state); the size only matters if it was lost.
    const homeVolumeMb = typeof metadata.homeVolumeMb === "number" && metadata.homeVolumeMb > 0
      ? metadata.homeVolumeMb
      : resolveHomeVolumeMb(memoryMb);
    await this.ensureHomeVolume(homeVolume, homeVolumeMb);
    const created = await blaxelFetch<BlaxelSandbox>("POST", `${CONTROL_PLANE_BASE}/sandboxes`, {
      metadata: { name: vmId },
      spec: {
        runtime: {
          image,
          memory: memoryMb,
          // Create-time model-plane envs are gone here by design; the machine
          // re-sources them from the home volume (see sandboxEnvs).
          envs: sandboxEnvs(),
          ports: sandboxPorts(),
        },
        volumes: [{ name: homeVolume, mountPath: HOME_VOLUME_MOUNT_PATH }],
      },
    });
    const sandboxUrl = created.metadata?.url;
    if (!sandboxUrl) {
      throw new ProviderError("blaxel", `resurrect(${vmId}) returned no sandbox url`);
    }
    await this.bootstrapMachine(vmId, sandboxUrl, true);
    return created;
  }

  private async sandboxApiUrl(vmId: string): Promise<string> {
    const sandbox = await this.getSandbox(vmId);
    const url = sandbox.metadata?.url;
    if (!url) {
      throw new ProviderError("blaxel", `sandbox ${vmId} has no API url (status ${sandbox.status ?? "unknown"})`);
    }
    return url;
  }

  private handleFromSandbox(vmId: string, sandbox: BlaxelSandbox): VMHandle {
    return {
      provider: "blaxel",
      providerVmId: vmId,
      status: mapStatus(sandbox),
      image: sandbox.spec?.runtime?.image ?? "unknown",
      createdAt: sandbox.metadata?.createdAt ? Date.parse(sandbox.metadata.createdAt) : Date.now(),
      providerMetadata: sandbox.metadata?.url ? { sandboxUrl: sandbox.metadata.url } : undefined,
    };
  }

  /** Runs the bounded sudo heal and records a deliberate root fallback on failure. */
  private async healSudo(sandboxUrl: string, context: string): Promise<void> {
    try {
      const result = await this.sandboxExec(sandboxUrl, CMUX_SUDO_INSTALL_COMMAND, CMUX_SUDO_INSTALL_TIMEOUT_MS);
      if (result.exitCode !== 0) {
        console.warn(`[blaxel] ${context}: sudo heal exited ${result.exitCode}; root fallback remains active`);
      }
    } catch {
      console.warn(`[blaxel] ${context}: sudo heal request failed; root fallback remains active`);
    }
  }

  private async sandboxExec(sandboxUrl: string, command: string, timeoutMs = EXEC_DEFAULT_TIMEOUT_MS): Promise<ExecResult> {
    const result = await blaxelFetch<BlaxelProcess>(
      "POST",
      `${sandboxUrl}/process`,
      { command, waitForCompletion: true, timeout: Math.ceil(timeoutMs / 1000) },
      { timeoutMs: timeoutMs + 30_000 },
    );
    return {
      exitCode: result.exitCode ?? (result.status === "completed" ? 0 : 1),
      stdout: result.stdout ?? "",
      stderr: result.stderr ?? "",
    };
  }

  // One in-flight ensure per (machine, preview): a create that races the attach it triggers
  // must not mint the same preview twice. Cross-process races are handled below by re-reading
  // the preview after a failed branded create instead of clobbering it.
  private readonly inflightPreviews = new Map<string, Promise<string>>();

  private ensurePreview(
    vmId: string,
    previewName: string,
    port: number,
    options: { branded?: boolean } = {},
  ): Promise<string> {
    const key = `${vmId}/${previewName}`;
    const inflight = this.inflightPreviews.get(key);
    if (inflight) return inflight;
    const task = this.ensurePreviewUncoalesced(vmId, previewName, port, options.branded !== false).finally(() => {
      this.inflightPreviews.delete(key);
    });
    this.inflightPreviews.set(key, task);
    return task;
  }

  // `branded: false` keeps the preview on Blaxel's own opaque `<hash>.preview.bl.run` host.
  // The cmux-tui daemon has one of each: the branded machine host sits behind an ingress
  // that refuses WebSocket upgrades without a User-Agent, so only clients advertising
  // `direct-ws-user-agent` are routed there (see cmuxTuiPreviewBranded); everything else
  // dials the raw host. Browser-facing port previews keep the branded, cookie-friendly host.
  private async ensurePreviewUncoalesced(vmId: string, previewName: string, port: number, branded = true): Promise<string> {
    const base = `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}/previews`;
    const readExisting = () =>
      blaxelFetch<BlaxelPreview>("GET", `${base}/${previewName}`).catch(() => null);
    const prefixUrl = branded ? brandedPreviewPrefix(vmId, previewName, port) : null;
    const customDomain = prefixUrl ? await verifiedCustomDomain() : null;
    const existing = await readExisting();
    const existingUrl = usablePrivatePreviewUrl(existing);
    if (existingUrl && !branded) {
      // An unbranded preview must not carry a prefix or custom domain; rotate one that does.
      const spec = existing?.spec ?? {};
      const isBranded = !!(spec.prefixUrl?.trim() || spec.customDomain?.trim());
      if (!isBranded) return existingUrl;
      await blaxelFetch("DELETE", `${base}/${previewName}`).catch(() => undefined);
    } else if (existingUrl) {
      const existingCustomDomain = existing?.spec?.customDomain?.trim().toLowerCase();
      const existingHost = (() => {
        try {
          return new URL(existingUrl).hostname.toLowerCase();
        } catch {
          return "";
        }
      })();
      const alreadyOnCustomDomain =
        !!customDomain &&
        (existingCustomDomain === customDomain.toLowerCase() ||
          existingHost.endsWith(`.${customDomain.toLowerCase()}`));
      if (!customDomain || alreadyOnCustomDomain) return existingUrl;
      // The custom domain became verified after this preview was created. Rotate only the
      // ingress record (never the sandbox or its files) so existing machines converge to
      // the cmux-owned hostname on their next attach/open-port request.
      await blaxelFetch("DELETE", `${base}/${previewName}`).catch(() => undefined);
    }
    if (existing?.spec?.url && !existingUrl) {
      // The preview exists but is public; drop it and recreate private below.
      await blaxelFetch("DELETE", `${base}/${previewName}`);
    }
    // Branded subdomains: Blaxel renders prefixUrl as https://<prefix>-<workspace>.preview.bl.run,
    // so with the cmux workspace the daemon preview reads noble-wren-cmux.preview.bl.run and a
    // port preview noble-wren-3000-cmux.preview.bl.run — the machine's name is its address. A
    // rejected prefix (collision, length, validation) falls back to the opaque hash URL rather
    // than failing the attach.
    const brandedSpecs: Array<{ label: string; spec: Record<string, unknown> }> = [];
    if (prefixUrl && customDomain) {
      // Blaxel's API takes the bare verified domain in customDomain and composes the
      // host from prefixUrl: {prefixUrl: "noble-wren", customDomain: "vm.cmux.sh"} →
      // https://noble-wren.vm.cmux.sh. Passing the full host 404s ("Custom domain not found").
      brandedSpecs.push({ label: "custom-domain", spec: { port, public: false, prefixUrl, customDomain } });
    }
    if (prefixUrl) {
      brandedSpecs.push({ label: "branded", spec: { port, public: false, prefixUrl } });
    }
    for (const attempt of brandedSpecs) {
      try {
        const created = await blaxelFetch<BlaxelPreview>("POST", base, {
          metadata: { name: previewName },
          spec: attempt.spec,
        });
        const url = usablePrivatePreviewUrl(created);
        if (url) return url;
      } catch (error) {
        // The usual reason a branded create fails is that another caller (a second server
        // instance, or the attach racing the create that spawned it) minted this preview a
        // moment ago under the same prefix. Adopt that one; an unbranded create here would
        // upsert the name and replace the machine-name URL with an opaque hash.
        const raced = usablePrivatePreviewUrl(await readExisting());
        if (raced) return raced;
        console.warn(
          `[blaxel] ${attempt.label} preview create failed for ${vmId}/${previewName}; falling back:`,
          error instanceof Error ? error.message : String(error),
        );
      }
    }
    const created = await blaxelFetch<BlaxelPreview>("POST", base, {
      metadata: { name: previewName },
      spec: { port, public: false },
    });
    const url = usablePrivatePreviewUrl(created);
    if (!url) {
      throw new ProviderError("blaxel", `preview create for ${vmId} returned no url or came back public`);
    }
    return url;
  }

  private async mintPreviewToken(
    vmId: string,
    previewName: string,
    ttlSeconds = PREVIEW_TOKEN_TTL_SECONDS,
  ): Promise<string> {
    const expiresAt = new Date(Date.now() + ttlSeconds * 1000).toISOString();
    const created = await blaxelFetch<{ spec?: { token?: string } }>(
      "POST",
      `${CONTROL_PLANE_BASE}/sandboxes/${encodeURIComponent(vmId)}/previews/${previewName}/tokens`,
      { spec: { expiresAt } },
    );
    const token = created.spec?.token;
    if (!token) {
      throw new ProviderError("blaxel", `preview token mint for ${vmId} returned no token`);
    }
    return token;
  }

  // The Cloud panel's activity view. A control-plane read tells us whether the machine is
  // awake; only then do we exec on it (an exec would wake a sleeping machine, and a
  // sleeping machine costs nothing — the panel should show that, not defeat it).
  async getStats(vmId: string): Promise<VMStats> {
    return withVmSpan("vm.stats", { "cmux.vm.provider": "blaxel", "cmux.vm.id": vmId }, async () => {
      const sandbox = await this.getSandbox(vmId);
      const memoryTotalMb = sandbox.spec?.runtime?.memory;
      const rawState = (sandbox.state ?? "").toUpperCase();
      const state: VMStats["state"] = rawState === "RUNNING" ? "awake" : rawState ? "asleep" : "unknown";
      const sampledAt = Date.now();
      const sandboxUrl = sandbox.metadata?.url;
      if (state !== "awake" || !sandboxUrl) {
        return { state, sampledAt, memoryTotalMb };
      }
      const result = await this.sandboxExec(sandboxUrl, MACHINE_STATS_COMMAND, 15_000);
      return { state, sampledAt, ...parseMachineStats(result.stdout, memoryTotalMb) };
    });
  }

  // The exe.dev "https://vmname.exe.xyz:3456" equivalent: a private, token-gated preview URL
  // for any HTTP port on the machine. The token rides as ?bl_preview_token=... (the gateway
  // sets a cookie on first load, so pages and their websockets keep working in a browser).
  async openPort(vmId: string, port: number): Promise<{ url: string; token: string; openUrl: string }> {
    return withVmSpan(
      "cmux.vm.provider.open_port",
      { "cmux.vm.provider": "blaxel", "cmux.vm.operation": "open_port", "cmux.vm.id": vmId, "cmux.vm.port": port },
      async () => {
        if (!Number.isInteger(port) || port < 1 || port > 65535 || port === CMUX_SANDBOX_API_PORT) {
          throw new ProviderError("blaxel", `openPort(${vmId}) requires a valid port other than ${CMUX_SANDBOX_API_PORT}`);
        }
        // Wake the sandbox (status read) so the preview answers immediately.
        await this.getSandbox(vmId);
        const previewName = `port-${port}`;
        const url = await this.ensurePreview(vmId, previewName, port);
        const expiresAtMs = Date.now() + PREVIEW_OPEN_TOKEN_TTL_SECONDS * 1000;
        const token = await this.mintPreviewToken(vmId, previewName, PREVIEW_OPEN_TOKEN_TTL_SECONDS);
        const openUrl = `${url.replace(/\/+$/, "")}/?bl_preview_token=${encodeURIComponent(token)}`;
        return { url, token, openUrl, expiresAtMs };
      },
    );
  }
}

// Preview subdomain prefix: the machine name for the daemon preview, machine-port for port
// previews. Only lowercase alphanumerics and hyphens survive; anything else (or an
// over-long result) disables branding for that preview rather than risking a failed create.
// Fully-owned machine URLs: when CMUX_VM_BLAXEL_CUSTOM_DOMAIN names a domain that is
// registered AND verified on the workspace (e.g. vm.cmux.sh with its wildcard CNAME live),
// previews are created on <prefix>.<domain> — noble-wren.vm.cmux.sh — instead of bl.run.
// Blaxel rejects customDomain while verification is pending, so the driver checks status
// (cached briefly) and silently keeps the prefix/hash URL until DNS is live.
let cachedCustomDomain: { value: string | null; checkedAt: number } | null = null;
const CUSTOM_DOMAIN_CACHE_MS = 5 * 60 * 1000;

async function verifiedCustomDomain(): Promise<string | null> {
  const domain = env("CMUX_VM_BLAXEL_CUSTOM_DOMAIN");
  if (!domain) return null;
  if (cachedCustomDomain && Date.now() - cachedCustomDomain.checkedAt < CUSTOM_DOMAIN_CACHE_MS) {
    return cachedCustomDomain.value;
  }
  let value: string | null = null;
  try {
    const record = await blaxelFetch<{ spec?: { status?: string } }>(
      "GET",
      `${CONTROL_PLANE_BASE}/customdomains/${encodeURIComponent(domain)}`,
    );
    value = record.spec?.status === "verified" ? domain : null;
  } catch {
    value = null;
  }
  cachedCustomDomain = { value, checkedAt: Date.now() };
  return value;
}

// One shell round-trip that samples everything the Cloud panel's activity view shows.
// Two /proc/stat reads half a second apart give a real CPU% (loadavg alone lags minutes).
// The disk row reads the persistent home volume wherever this machine holds it:
// the /home/cmux view on healthy machines, the raw backing mount when the view is
// missing (the degraded state sessions fail over to), /root on pre-layout sandboxes.
export const MACHINE_STATS_COMMAND =
  "head -1 /proc/stat; sleep 0.5; head -1 /proc/stat; cat /proc/loadavg; nproc; " +
  `grep -E '^(MemTotal|MemAvailable):' /proc/meminfo; ` +
  `(if mountpoint -q ${CMUX_CLOUD_HOME} 2>/dev/null; then df -kP ${CMUX_CLOUD_HOME}; ` +
  `elif mountpoint -q ${CMUX_HOME_VOLUME_BACKING_PATH} 2>/dev/null; then df -kP ${CMUX_HOME_VOLUME_BACKING_PATH}; ` +
  `else df -kP /root; fi) | tail -1`;

export function parseMachineStats(
  stdout: string,
  memoryTotalMbFallback?: number,
): Omit<VMStats, "state" | "sampledAt"> {
  const lines = stdout.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const cpuLines = lines.filter((l) => /^cpu\s/.test(l));
  let cpuPercent: number | undefined;
  if (cpuLines.length >= 2) {
    const sample = (line: string) => {
      const n = line.split(/\s+/).slice(1).map(Number);
      const idle = (n[3] ?? 0) + (n[4] ?? 0);
      const total = n.reduce((a, b) => a + (Number.isFinite(b) ? b : 0), 0);
      return { idle, total };
    };
    const a = sample(cpuLines[0]!);
    const b = sample(cpuLines[cpuLines.length - 1]!);
    const total = b.total - a.total;
    const idle = b.idle - a.idle;
    if (total > 0) cpuPercent = Math.max(0, Math.min(100, ((total - idle) / total) * 100));
  }
  const loadLine = lines.find((l) => /^\d+(\.\d+)?\s+\d+(\.\d+)?\s+\d+(\.\d+)?\s+\d+\/\d+/.test(l));
  const loadAverage1m = loadLine ? Number(loadLine.split(/\s+/)[0]) : undefined;
  const cpusLine = lines.find((l) => /^\d+$/.test(l));
  const cpus = cpusLine ? Number(cpusLine) : undefined;
  const memKb = (key: string) => {
    const line = lines.find((l) => l.startsWith(`${key}:`));
    const value = line ? Number(line.split(/\s+/)[1]) : NaN;
    return Number.isFinite(value) ? value : undefined;
  };
  const memTotalKb = memKb("MemTotal");
  const memAvailableKb = memKb("MemAvailable");
  const memoryTotalMb = memTotalKb !== undefined ? Math.round(memTotalKb / 1024) : memoryTotalMbFallback;
  const memoryUsedMb =
    memTotalKb !== undefined && memAvailableKb !== undefined
      ? Math.max(0, Math.round((memTotalKb - memAvailableKb) / 1024))
      : undefined;
  // df -kP: Filesystem 1024-blocks Used Available Capacity Mounted
  const dfLine = lines.find((l) => /^\S+\s+\d+\s+\d+\s+\d+\s+\d+%/.test(l));
  let diskTotalMb: number | undefined;
  let diskUsedMb: number | undefined;
  if (dfLine) {
    const cols = dfLine.split(/\s+/);
    diskTotalMb = Math.round(Number(cols[1]) / 1024);
    diskUsedMb = Math.round(Number(cols[2]) / 1024);
  }
  return { cpus, cpuPercent, loadAverage1m, memoryTotalMb, memoryUsedMb, diskTotalMb, diskUsedMb };
}

// The machine's bare name is its daemon address (`<machine>.vm.cmux.sh`); port previews
// hang off it as `<machine>-<port>`.
export function brandedPreviewPrefix(vmId: string, previewName: string, port: number): string | null {
  const machine = vmId.toLowerCase();
  if (!/^[a-z0-9][a-z0-9-]{0,40}$/.test(machine)) return null;
  const prefix = previewName === CMUX_TUI_PREVIEW_NAME ? machine : `${machine}-${port}`;
  return prefix.length <= 48 ? prefix : null;
}

function mapStatus(sandbox: BlaxelSandbox): VMStatus {
  switch (sandbox.status) {
    case "TERMINATED":
    case "DELETING":
      return "destroyed";
    case "UPLOADING":
    case "BUILDING":
    case "DEPLOYING":
      return "creating";
    default:
      // DEPLOYED covers both RUNNING and STANDBY states; standby wakes transparently on the
      // next request, so callers can treat it as running.
      return "running";
  }
}

// Machines are addressed by name everywhere (`cmux vm ssh brave-otter`), so names are
// generated memorable instead of opaque. Blaxel sandbox names ARE the provider VM id, so
// this is the whole naming story — no display-name mapping to keep in sync. Collisions
// retry with fresh picks, then fall back to a random suffix.
const NAME_ADJECTIVES = [
  "amber", "bold", "brave", "brisk", "calm", "clever", "coral", "crisp",
  "eager", "fleet", "gold", "happy", "keen", "kind", "lively", "lucid",
  "mellow", "noble", "quick", "quiet", "rapid", "sharp", "silver", "smooth",
  "solid", "spry", "steady", "sunny", "swift", "tidy", "vivid", "warm",
];
const NAME_ANIMALS = [
  "badger", "bison", "crane", "dolphin", "falcon", "finch", "fox", "gecko",
  "heron", "ibex", "jay", "koala", "lemur", "lynx", "marmot", "marten",
  "newt", "orca", "osprey", "otter", "owl", "panda", "petrel", "puffin",
  "raven", "seal", "sparrow", "stoat", "swan", "tern", "wombat", "wren",
];

export function sandboxPorts(): Array<{ name: string; protocol: "HTTP"; target: number }> {
  return [{ name: CMUX_TUI_PREVIEW_NAME, protocol: "HTTP", target: CMUX_TUI_PORT }];
}

/**
 * Machine-level env for the sandbox create payload: LANG always (PTYs from
 * the sandbox API do not inherit image ENV), plus caller-supplied env such
 * as the coderouter model-plane vars. Create-time only: Blaxel envs are
 * immutable after create and are NOT replayed on resurrect, so anything a
 * machine must keep across a resurrect is persisted onto the home volume by
 * /etc/cmux/agent-config.sh at first shell. LANG wins on name collision.
 */
export function sandboxEnvs(
  extra?: Readonly<Record<string, string>>,
): Array<{ name: string; value: string }> {
  const envs = Object.entries(extra ?? {})
    .filter(([name]) => name !== "LANG")
    .map(([name, value]) => ({ name, value }));
  return [{ name: "LANG", value: "C.UTF-8" }, ...envs];
}

export function friendlyVmName(withSuffix = false): string {
  const pick = (list: readonly string[]) => list[randomBytes(1)[0] % list.length];
  const base = `${pick(NAME_ADJECTIVES)}-${pick(NAME_ANIMALS)}`;
  if (!withSuffix) return base;
  const alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";
  const suffix = Array.from(randomBytes(4), (byte) => alphabet[byte % alphabet.length]).join("");
  return `${base}-${suffix}`;
}

export function resolveBlaxelMemoryMb(
  requested: number | undefined,
  envValues: Record<string, string | undefined> = process.env,
): number {
  if (requested !== undefined) {
    if (!Number.isSafeInteger(requested) || requested <= 0) {
      throw new ProviderError("blaxel", "memoryMb must be a positive integer");
    }
    return requested;
  }
  const raw = envValues.CMUX_VM_BLAXEL_MEMORY_MB?.trim();
  if (!raw) return DEFAULT_MEMORY_MB;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_MEMORY_MB;
}

function resolveMemoryMb(requested: number | undefined): number {
  return resolveBlaxelMemoryMb(requested);
}
