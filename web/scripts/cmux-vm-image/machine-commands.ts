/**
 * Guest commands and template reads the cmux-host image bake (bake.ts) and its smokes and probes run, moved here
 * from devbox-image-common.ts so the cmux-vm-image pipeline imports no devbox image code. devbox-image-common.ts
 * re-exports every name, so the devbox bake, verifier and their tests read the same functions.
 *
 * The template reads (devboxFileBytes, devboxGhosttyVersion) still read the devbox template directory
 * (web/services/vms/images/devbox/): the cmux-host image ships some of its files (the agent sign-in files,
 * terminfo, claude-onboarding) and takes the Ghostty pin from its Dockerfile.
 */
import { Buffer } from "node:buffer";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { CMUX_TUI_SESSION, cmuxTuiAsDaemonUser, cmuxTuiLayoutSelector, cmuxTuiRunCommand, shellQuote } from "../../services/vms/drivers/cmuxTuiDaemon";
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/workUser";
import { DEVBOX_HOSTNAME, DEVBOX_HOSTNAME_LOOPBACK, DEVBOX_PROVIDER_HOSTNAME } from "../../services/vms/identity";

const HERE = path.dirname(fileURLToPath(import.meta.url));
/** The devbox template directory (a Dockerfile plus the files it COPYs). */
export const devboxDir = path.resolve(HERE, "../../services/vms/images/devbox");
export const devboxDockerfilePath = path.join(devboxDir, "Dockerfile");

/**
 * Proves the guest resolves every TERM name cmux may export to the overlay,
 * including indexed bright colors instead of SGR 90. The explicit path check
 * ensures a stock entry or a user's home directory cannot shadow it.
 */
export const devboxTerminfoCheckCommand = [
  "for t in xterm-ghostty ghostty xterm-256color; do",
  '[ "$(tput -T$t colors)" = 256 ]',
  "&& infocmp -x $t | grep -qw Tc && infocmp -x $t | grep -qw Su",
  "&& infocmp -x $t | head -1 | grep -q /etc/terminfo/",
  "&& [ \"$(tput -T$t setaf 8 | od -An -tx1 | tr -d ' \\n')\" = 1b5b33383b353b386d ]",
  "&& [ \"$(tput -T$t setab 8 | od -An -tx1 | tr -d ' \\n')\" = 1b5b34383b353b386d ]",
  "&& [ \"$(tput -T$t setaf 7 | od -An -tx1 | tr -d ' \\n')\" = 1b5b33376d ]",
  "&& [ \"$(tput -T$t setaf 16 | od -An -tx1 | tr -d ' \\n')\" = 1b5b33383b353b31366d ]",
  '|| { echo "terminfo check failed for $t"; exit 1; }; done && echo terminfo-ok',
].join(" ");

/** Compile the checked-in overlay before any per-TERM cache is seeded. */
export const devboxTerminfoInstallCommand =
  `test -s /etc/cmux/terminfo.src && tic -x -o /etc/terminfo /etc/cmux/terminfo.src && chmod -R a+rX /etc/terminfo && ${devboxTerminfoCheckCommand}`;

/**
 * Proves the baked daemon's direct-WebSocket path, not only its TCP listener.
 * The client runs inside the guest, so this also works when the operator's
 * Mac has no IPv6 route or VPC tunnel. It enrolls a temporary device,
 * performs authenticated RPC, creates a PTY, takes a terminal snapshot,
 * reconnects, and confirms that the marker survives. Cleanup revokes the
 * temporary device and removes the workspace before a snapshot can capture
 * test state.
 */
export function cmuxTuiWebsocketSmokeCommand(session = "cloud", binary?: string): string {
  const encoded = Buffer.from(cmuxTuiWebsocketSmokeScript(session), "utf8").toString("base64");
  const script = "/tmp/cmux-tui-websocket-smoke.sh";
  return (
    `printf %s ${encoded} | base64 -d >${script} && chmod 755 ${script} && ` +
    `${cmuxTuiLayoutSelector()} && ` +
    // `binary` overrides only the client: the reachability check drives a
    // freshly downloaded build against the daemon the image baked. HOME still
    // comes from the layout, because enrollment reads the daemon's own state.
    `${cmuxTuiAsDaemonUser(`CMUX_TUI_BIN=${binary ? shellQuote(binary) : '"$CMUX_TUI_BIN"'} bash ${script}`)}`
  );
}

/** Seconds the smoke waits, after approving its device, for the connector to record the daemon. */
export const CMUX_TUI_SMOKE_PIN_TIMEOUT_SECONDS = 60;

/** Seconds the smoke waits, after spawning its pane, for the pane to show the marker. */
export const CMUX_TUI_SMOKE_OUTPUT_TIMEOUT_SECONDS = 30;

/**
 * The guest-side script behind {@link cmuxTuiWebsocketSmokeCommand}. Exported
 * so a test can run it against a fake cmux-tui; CMUX_TUI_SMOKE_ROOT and
 * CMUX_TUI_SMOKE_PIN_TIMEOUT_SECONDS and CMUX_TUI_SMOKE_OUTPUT_TIMEOUT_SECONDS
 * exist for that test only.
 *
 * After the approval it waits until the connector has recorded the daemon in
 * its state dir (`remote known-daemons`), the record every later `remote rpc`
 * looks the route up in. It used to sleep a fixed 2 s and kill the connector:
 * a connector that had not recorded the daemon by then left an empty state
 * dir, and the first RPC failed with "no known daemon matches this route"
 * (derive runs 42548063748, 42653440036, 42697598946, 42968041813,
 * 43402345356). The wait is bounded; when it runs out, or the connector exits
 * first, the error names that and carries the timeline and the connector's
 * stderr. The success line carries the same timeline.
 */
export function cmuxTuiWebsocketSmokeScript(session = "cloud"): string {
  const identity = `${DEVBOX_WORK_USER}@${DEVBOX_HOSTNAME}`;
  // Runs as the daemon's own user with the daemon's HOME: enrollment reads and
  // writes the session state the daemon owns, and as root that state dir is a
  // different (empty) one on a work-user machine.
  // The layout is selected by the caller (as root, the only user that can drop
  // privileges) and handed in: re-running the selector here, already dropped to
  // the daemon's user, would fail every probe and fall back to root's path.
  return `#!/usr/bin/env bash
set -euo pipefail
BIN="\${CMUX_TUI_BIN:?cmux-tui binary not provided}"
: "\${HOME:?home not provided}"
SESSION=${session}
ROOT="\${CMUX_TUI_SMOKE_ROOT:-/tmp/cmux-tui-websocket-smoke}"
PIN_TIMEOUT_SECONDS="\${CMUX_TUI_SMOKE_PIN_TIMEOUT_SECONDS:-${CMUX_TUI_SMOKE_PIN_TIMEOUT_SECONDS}}"
OUTPUT_TIMEOUT_SECONDS="\${CMUX_TUI_SMOKE_OUTPUT_TIMEOUT_SECONDS:-${CMUX_TUI_SMOKE_OUTPUT_TIMEOUT_SECONDS}}"
ROUTE='ws://[::1]:1337/v1/link'
MARKER="CMUX_WS_SMOKE_${session}_$$"
DEVICE_NAME="snapshot-websocket-smoke-$$"
T0="$(date +%s%3N)"
TIMELINE=""
mark() { TIMELINE="$TIMELINE $1=+$(( $(date +%s%3N) - T0 ))ms"; }
CONNECT_PID=""
INVITATION_ID=""
DEVICE_FINGERPRINT=""
WORKSPACE_ID=""
PROCESS_ID=""
rm -rf "$ROOT"
mkdir -m 700 -p "$ROOT/state"
rpc() {
  "$BIN" remote rpc "$ROUTE" --state-dir "$ROOT/state" --lanes single --connect-timeout-seconds 45 --reconnect-attempts 1 --request "$1" | tee "$ROOT/last-response"
}
cleanup() {
  if [ -n "$CONNECT_PID" ]; then
    kill "$CONNECT_PID" 2>/dev/null || true
    wait "$CONNECT_PID" 2>/dev/null || true
  fi
  if [ -n "$PROCESS_ID" ]; then
    KILL_REQUEST="$(jq -nc --arg process "$PROCESS_ID" '{type:"signal-process",process:$process,signal:"kill"}')"
    rpc "$KILL_REQUEST" >/dev/null 2>&1 || true
  fi
  if [ -n "$WORKSPACE_ID" ]; then
    CLOSE_REQUEST="$(jq -nc --arg workspace "$WORKSPACE_ID" '{type:"close-workspace",workspace:$workspace}')"
    rpc "$CLOSE_REQUEST" >/dev/null 2>&1 || true
  fi
  if [ -n "$DEVICE_FINGERPRINT" ]; then
    "$BIN" remote enroll revoke "$DEVICE_FINGERPRINT" --session "$SESSION" --json >/dev/null 2>&1 || true
  fi
  if [ -n "$INVITATION_ID" ]; then
    "$BIN" remote enroll deny "$INVITATION_ID" --session "$SESSION" --json >/dev/null 2>&1 || true
  fi
  rm -rf "$ROOT"
}
trap cleanup EXIT
# A bare \`test\` or \`jq -e\` that fails under set -e prints nothing; rebake
# run 45875662667 failed this step with empty stdout and stderr. Name the
# check that failed and the last RPC answer it judged.
trap 'echo "cmux-tui websocket smoke: line $LINENO failed: $BASH_COMMAND (timeline:$TIMELINE); last rpc response: $(tail -c 600 "$ROOT/last-response" 2>/dev/null | tr "\\n" " ")" >&2' ERR

"$BIN" remote enroll create --session "$SESSION" --ttl 300 --advertise "$ROUTE" --json >"$ROOT/create.json"
jq -r '.. | strings | select(startswith("cmux://enroll/"))' "$ROOT/create.json" | head -1 >"$ROOT/invitation"
test -s "$ROOT/invitation"
chmod 600 "$ROOT/invitation"
("$BIN" remote connect --invite-file "$ROOT/invitation" --device-name "$DEVICE_NAME" --state-dir "$ROOT/state" --session "$SESSION" --headless --json --lanes single --connect-timeout-seconds 60 --reconnect-attempts 2 >"$ROOT/connect.out" 2>"$ROOT/connect.err") &
CONNECT_PID=$!
mark connector
# This connector's own request: another pending one (a stale or concurrent
# enrollment) must not be the one approved. A daemon whose pending rows carry
# no device name is matched only when it lists exactly one.
PENDING_ROW='(if type == "array" then . else (.pending // .invitations // []) end) as $rows | ([$rows[] | select(.device_name == $name)] + (if ($rows | length) == 1 and ($rows[0].device_name == null) then $rows else [] end)) | .[0] // empty'
for attempt in $(seq 1 90); do
  PENDING="$("$BIN" remote enroll pending --session "$SESSION" --json 2>/dev/null || true)"
  INVITATION_ID="$(printf '%s' "$PENDING" | jq -r --arg name "$DEVICE_NAME" "$PENDING_ROW | .invitation_id // empty" 2>/dev/null || true)"
  DEVICE_FINGERPRINT="$(printf '%s' "$PENDING" | jq -r --arg name "$DEVICE_NAME" "$PENDING_ROW | .device_fingerprint // empty" 2>/dev/null || true)"
  if [ -n "$INVITATION_ID" ]; then break; fi
  if ! kill -0 "$CONNECT_PID" 2>/dev/null; then break; fi
  sleep 1
done
if [ -z "$INVITATION_ID" ]; then
  mark gave-up
  echo "cmux-tui websocket smoke: the connector's enrollment request never appeared in the daemon's pending list (timeline:$TIMELINE); connector stderr: $(tail -c 600 "$ROOT/connect.err" 2>/dev/null | tr '\\n' ' ')" >&2
  exit 1
fi
mark pending
"$BIN" remote enroll approve "$INVITATION_ID" --session "$SESSION" --json >/dev/null
mark approved
# Ready means the connector recorded the daemon: the record \`remote rpc\` reads.
pinned() { "$BIN" remote known-daemons --state-dir "$ROOT/state" --json 2>/dev/null | jq -e 'length > 0' >/dev/null 2>&1; }
PINNED=0
for attempt in $(seq 1 $(( PIN_TIMEOUT_SECONDS * 5 ))); do
  if pinned; then PINNED=1; break; fi
  if ! kill -0 "$CONNECT_PID" 2>/dev/null; then
    if pinned; then PINNED=1; fi
    break
  fi
  sleep 0.2
done
if [ "$PINNED" != 1 ]; then
  if kill -0 "$CONNECT_PID" 2>/dev/null; then
    REASON="not within \${PIN_TIMEOUT_SECONDS}s of the approval"
  else
    CONNECT_STATUS=0
    wait "$CONNECT_PID" 2>/dev/null || CONNECT_STATUS=$?
    CONNECT_PID=""
    REASON="the connector exited (status $CONNECT_STATUS) first"
  fi
  mark gave-up
  echo "cmux-tui websocket smoke: the connector never recorded the daemon in its state dir, $REASON (timeline:$TIMELINE); connector stderr: $(tail -c 600 "$ROOT/connect.err" 2>/dev/null | tr '\\n' ' ')" >&2
  exit 1
fi
mark pinned
kill "$CONNECT_PID" 2>/dev/null || true
wait "$CONNECT_PID" 2>/dev/null || true
CONNECT_PID=""

CAPABILITIES="$(rpc '{"type":"capabilities"}')"
echo "$CAPABILITIES" | jq -e '.type == "capabilities"' >/dev/null
WORKSPACE="$(rpc '{"type":"open-workspace","root":"/tmp"}')"
WORKSPACE_ID="$(echo "$WORKSPACE" | jq -r '.id // .result.Ok.id')"
test -n "$WORKSPACE_ID" && test "$WORKSPACE_ID" != "null"
SPAWN_REQUEST="$(jq -nc --arg workspace "$WORKSPACE_ID" --arg marker "$MARKER" '{type:"spawn-process",workspace:$workspace,argv:["bash","-lc",("printf %s:%s@%s "+$marker+" \\"$(id -un)\\" \\"$(hostname)\\"; sleep 60")],cwd:null,env:{},io:{type:"pty",cols:120,rows:40,term:"xterm-256color",eof:"control-d"},lifetime:"detached"}')"
SPAWN="$(rpc "$SPAWN_REQUEST")"
PROCESS_ID="$(echo "$SPAWN" | jq -r '.process // .result.Ok.process')"
test -n "$PROCESS_ID" && test "$PROCESS_ID" != "null"
mark spawned
# Snapshot until the pane shows the marker, bounded: a fixed 2 s sleep lost
# to a cold login shell on rebake run 45903367893, whose one snapshot was
# blank at through_sequence 0. A pane that never shows it fails below, on the
# check, with the last snapshot.
SNAPSHOT_REQUEST="$(jq -nc --arg process "$PROCESS_ID" '{type:"snapshot-process-terminal",process:$process}')"
FIRST=""
for attempt in $(seq 1 $(( OUTPUT_TIMEOUT_SECONDS * 2 ))); do
  FIRST="$(rpc "$SNAPSHOT_REQUEST")"
  if printf '%s' "$FIRST" | jq -e --arg marker "$MARKER" 'tostring | contains($marker)' >/dev/null 2>&1; then break; fi
  sleep 0.5
done
mark output
echo "$FIRST" | jq -e --arg marker "$MARKER" 'tostring | contains($marker)' >/dev/null
# The whole point of the daemon layout: a pane it opens is a shell of the work
# user on a machine named cmux, which is what the prompt shows a person.
echo "$FIRST" | jq -e --arg who "$MARKER:${identity}" 'tostring | contains($who)' >/dev/null
FIRST_SEQUENCE="$(echo "$FIRST" | jq -r '.snapshot.through_sequence // .result.Ok.snapshot.through_sequence')"
test "$FIRST_SEQUENCE" -ge 1
SECOND="$(rpc "$SNAPSHOT_REQUEST")"
echo "$SECOND" | jq -e --arg marker "$MARKER" 'tostring | contains($marker)' >/dev/null
SECOND_SEQUENCE="$(echo "$SECOND" | jq -r '.snapshot.through_sequence // .result.Ok.snapshot.through_sequence')"
test "$SECOND_SEQUENCE" -ge "$FIRST_SEQUENCE"
mark done
echo "websocket-smoke-ok marker=$MARKER through_sequence=$FIRST_SEQUENCE->$SECOND_SEQUENCE timeline:$TIMELINE"
`;
}

/**
 * Ghostty ships no upstream .deb; the Dockerfile pins a community build for
 * Ubuntu 24.04 by release tag (`ARG CMUX_IMAGE_GHOSTTY_DEB_URL=`), and the
 * Freestyle bake installs that exact file.
 */
export function devboxGhosttyDebUrl(dockerfile = readDevboxDockerfile()): string {
  const url = /^ARG CMUX_IMAGE_GHOSTTY_DEB_URL=(\S+)$/m.exec(dockerfile)?.[1];
  if (!url) throw new Error("devbox Dockerfile is missing ARG CMUX_IMAGE_GHOSTTY_DEB_URL");
  return url;
}

/**
 * The Ghostty release the image is built against, from the .deb pin, recorded
 * in /etc/cmux/ghostty-version (read by the acpmux daemon launch,
 * acpmuxPersonKey.ts). Base images ship no Ghostty binary, so the pin,
 * not `ghostty +version`, is the source.
 */
export function devboxGhosttyVersion(dockerfile = readDevboxDockerfile()): string {
  const version = /\/ghostty_(\d+\.\d+\.\d+)[-_]/.exec(devboxGhosttyDebUrl(dockerfile))?.[1];
  if (!version) throw new Error("devbox Dockerfile's CMUX_IMAGE_GHOSTTY_DEB_URL carries no ghostty_<x.y.z> version");
  return version;
}

export function readDevboxDockerfile(): string {
  return readFileSync(devboxDockerfilePath, "utf8");
}

/** Raw bytes of a devbox template file (`desktop/<name>` for the desktop layer). */
export function devboxFileBytes(name: string): Uint8Array {
  const file = name.startsWith("desktop/")
    ? path.join(devboxDir, "desktop", name.slice("desktop/".length))
    : path.join(devboxDir, name);
  return new Uint8Array(readFileSync(file));
}

// ---------------------------------------------------------------------------
// Identity: the machine is `cmux` (services/vms/images/identity.ts). The bake
// runs the install command once, early; the verifier and the size derive run
// the check on machines booted from the snapshot.
// ---------------------------------------------------------------------------

/** The roots the residue audit walks: everything the machine speaks for itself from. */
export const DEVBOX_IDENTITY_RESIDUE_ROOTS: readonly string[] = ["/etc", "/home", "/root", "/usr/local", "/opt"];

/**
 * Rewrites the loopback alias line of an /etc/hosts file so the machine's own
 * name resolves: the first `127.0.1.1` line becomes `127.0.1.1<TAB><hostname>`,
 * further ones are dropped, and one is appended when none exists. Every other
 * line (localhost, the IPv6 entries, the provider's TLS-egress block) is kept
 * byte for byte, and the file is rewritten in place through `cat >` so its
 * inode (and a bind mount over it) survives. Portable awk only.
 */
export function devboxHostsAliasRewriteCommand(hostname = DEVBOX_HOSTNAME, hostsPath = "/etc/hosts"): string {
  const program =
    `BEGIN { done = 0 } ` +
    `$1 == "${DEVBOX_HOSTNAME_LOOPBACK}" { if (!done) { print "${DEVBOX_HOSTNAME_LOOPBACK}\\t" h; done = 1 }; next } ` +
    `{ print } ` +
    `END { if (!done) print "${DEVBOX_HOSTNAME_LOOPBACK}\\t" h }`;
  return `awk -v h=${hostname} '${program}' ${hostsPath} > ${hostsPath}.cmux-identity && cat ${hostsPath}.cmux-identity > ${hostsPath} && rm -f ${hostsPath}.cmux-identity`;
}

/**
 * New SSH host keys under the machine's current name (the base's keys were
 * generated when Freestyle built its rootfs and are shared by every VM booted
 * from that base). They are generated into a staging dir on the same
 * filesystem and moved over the old ones only once all of them exist, so a
 * failed generation fails the step with the previous keys still in place;
 * sshd loads keys at start, so it is restarted where systemd runs it and left
 * alone where nothing does. cmux-devbox-boot does the same on every clone.
 */
export function devboxSshHostKeyRegenerateCommand(): string {
  return [
    'staging="$(mktemp -d /etc/ssh/.cmux-rekey.XXXXXX)"',
    'mkdir -p "$staging/etc/ssh"',
    'ssh-keygen -A -f "$staging" >/dev/null',
    '[ -n "$(ls "$staging"/etc/ssh/ssh_host_*_key 2>/dev/null)" ]',
    'for key in "$staging"/etc/ssh/ssh_host_*_key; do mv -f "$key.pub" /etc/ssh/ && mv -f "$key" /etc/ssh/ || exit 1; done',
    'rm -rf "$staging"',
    "{ [ ! -d /run/systemd/system ] || systemctl try-restart ssh; }",
  ].join(" && ");
}

/**
 * Fails when the provider's machine name survives as a whole word in any
 * text file under `roots` (the `freestyle-vms` agent, units and resolver
 * drop-in do not match). Package trees are skipped: a third-party module
 * mentioning the name is not the machine speaking for itself, and walking
 * the agents' node_modules would cost minutes.
 */
export function devboxProviderResidueCommand(
  name = DEVBOX_PROVIDER_HOSTNAME,
  roots: readonly string[] = DEVBOX_IDENTITY_RESIDUE_ROOTS,
): string {
  const skip = ["node_modules", "nvm", ".npm", ".cache", ".bun", "python", "python3"].map((dir) => `--exclude-dir=${dir}`).join(" ");
  // `grep -l` exits 1 when nothing matches, which is the good case; the group
  // keeps a failure of an earlier `&&` link from being reported as residue.
  return `{ residue="$(grep -rIlE ${skip} '(^|[^[:alnum:]_-])${name}([^[:alnum:]_-]|$)' ${roots.join(" ")} 2>/dev/null || true)"; [ -z "$residue" ] || { printf '%s residue:\\n%s\\n' ${name} "$residue"; exit 1; }; }`;
}

/**
 * Start the machine's log at its own name: archive and drop the journal files
 * written under the provider's name (the base's boot, the bake's first steps).
 */
export const devboxJournalResetCommand = "journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1; true";

/**
 * Proves the identity from every angle a person or a program meets it: the
 * kernel's hostname, the static one, `hostnamectl`, `$HOSTNAME` in a clean
 * root login shell, the loopback alias resolving (exactly one alias line),
 * sudo not warning about an unresolvable host, the SSH host keys' comment,
 * and no provider residue (devboxProviderResidueCommand). Run as root.
 */
export function devboxIdentityCheckCommand(hostname = DEVBOX_HOSTNAME): string {
  return [
    `[ "$(hostname)" = ${hostname} ]`,
    `[ "$(cat /proc/sys/kernel/hostname)" = ${hostname} ]`,
    `[ "$(cat /etc/hostname)" = ${hostname} ]`,
    `[ "$(hostnamectl --static 2>/dev/null || cat /etc/hostname)" = ${hostname} ]`,
    `[ "$(env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin bash -lc 'echo "$HOSTNAME"')" = ${hostname} ]`,
    `getent hosts ${hostname} | grep -q '^${DEVBOX_HOSTNAME_LOOPBACK}[[:space:]]'`,
    `[ "$(grep -c '^${DEVBOX_HOSTNAME_LOOPBACK}[[:space:]]' /etc/hosts)" = 1 ]`,
    `! sudo -n true 2>&1 | grep -q 'unable to resolve host'`,
    `[ "$(awk '{ print $3 }' /etc/ssh/ssh_host_ed25519_key.pub)" = root@${hostname} ]`,
    devboxProviderResidueCommand(),
    `echo identity-${hostname}-ok`,
  ].join(" && ");
}

/**
 * The bake's identity step, run as root right after the base inventory, before
 * anything records the machine's name (SSH host keys, the ble.sh caches, the
 * daemon, the journal): the static and live hostname (systemd-hostnamed
 * activates over D-Bus on demand; an init without it gets the file plus
 * sethostname), the loopback alias, fresh host keys, and the check.
 */
export function devboxIdentityInstallCommand(hostname = DEVBOX_HOSTNAME): string {
  return [
    `{ hostnamectl set-hostname ${hostname} 2>/dev/null || { printf '%s\\n' ${hostname} > /etc/hostname && hostname ${hostname}; }; }`,
    `[ "$(cat /etc/hostname)" = ${hostname} ]`,
    devboxHostsAliasRewriteCommand(hostname),
    devboxSshHostKeyRegenerateCommand(),
    devboxIdentityCheckCommand(hostname),
  ].join(" && ");
}

/**
 * The platform's name for the machine running the command: the Firecracker
 * MMDS instance id (EC2-style token, then GET). Empty output means no metadata
 * service (a container). cmux-devbox-boot keys the daemon identity on it.
 */
export const DEVBOX_INSTANCE_ID_COMMAND =
  "curl -sf -m 2 -H \"X-aws-ec2-metadata-token: $(curl -sf -m 2 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60')\" http://169.254.169.254/latest/meta-data/instance-id";

/**
 * Guest-side condition for "the session daemon is fully up on THIS machine":
 * it answers on its control socket, it is listening dual-stack on 1337
 * (0x0539; a machine reached at a private VPC address needs the v6 table),
 * and the supervisor has bound its identity to this machine's instance id.
 *
 * This is the signal every phase used to approximate with `sleep 30`. It is
 * not slow: a machine resumed from a snapshot answers in well under a second
 * (the verifier prints the number), so waiting on it instead of on the clock
 * removes ~30 s per phase without weakening the check.
 */
export function devboxDaemonReadyCondition(): string {
  return (
    `${cmuxTuiRunCommand(`server status --session ${CMUX_TUI_SESSION}`)} >/dev/null 2>&1 && ` +
    `grep -qi ':0539 ' /proc/net/tcp6 && ` +
    // Not just "a marker exists": a machine cloned from a snapshot resumes the
    // SOURCE machine's daemon, which answers and listens with the source's
    // identity until cmux-devbox-boot notices the instance id changed and
    // re-keys it. A ready check that accepted the stale marker would hand the
    // next phase a daemon that is about to be stopped and rebuilt.
    //
    // Both sides must be non-empty. An unreachable metadata service yields an
    // empty id, and an unwritten marker reads empty too, so a bare comparison
    // would call "" = "" a bound identity and report ready immediately. This
    // command only ever runs on a Freestyle VM, which always has MMDS, so
    // failing closed here surfaces a broken machine instead of hiding it.
    `cmux_instance="$(${DEVBOX_INSTANCE_ID_COMMAND})" && [ -n "$cmux_instance" ] && ` +
    `[ "$(cat /etc/cmux/daemon-instance-id 2>/dev/null)" = "$cmux_instance" ]`
  );
}

/** Keep snapshot timers tied to the hypervisor, rather than a migrated host TSC. */
export const devboxSnapshotClockCommand =
  "grep -qw kvm-clock /sys/devices/system/clocksource/clocksource0/available_clocksource && " +
  "echo kvm-clock > /sys/devices/system/clocksource/clocksource0/current_clocksource && " +
  "test \"$(cat /sys/devices/system/clocksource/clocksource0/current_clocksource)\" = kvm-clock";

/**
 * Blocks in the guest until {@link devboxDaemonReadyCondition} holds, then
 * exits 0. Bounded: on timeout it exits 1 with the elapsed budget on stderr,
 * so a daemon that never comes up fails the bake instead of hanging it.
 */
export function devboxWaitForDaemonCommand(timeoutSeconds = 120): string {
  return (
    `cmux_ready=0; for i in $(seq 1 ${timeoutSeconds * 2}); do ` +
    `if ${devboxDaemonReadyCondition()}; then cmux_ready=1; break; fi; sleep 0.5; done; ` +
    `if [ "$cmux_ready" = 1 ]; then echo daemon-ready; else ` +
    `echo "cmux-tui daemon not ready after ${timeoutSeconds}s" >&2; exit 1; fi`
  );
}

/** Options for {@link devboxIdleWakeupCheckCommand}. `procRoot` and `pause` exist for tests. */
export interface DevboxIdleWakeupCheckOptions {
  /** Idle window over which voluntary context switches are counted. */
  readonly windowSeconds?: number;
  /** Most voluntary context switches one terminal host's main thread may make in the window. */
  readonly maxHostMainSwitches?: number;
  readonly procRoot?: string;
  /** The command that waits out the window (default `sleep <windowSeconds>`). */
  readonly pause?: string;
}

/**
 * Idle-wakeup smoke check (plans/cmux-next/vm-image.md, "Production promotion").
 * Counts voluntary context switches per thread of every cmux-tui terminal host
 * and of the daemon across an idle window, and fails when a terminal host's
 * main thread woke more than the bound. The old host accept loop polled its
 * listener every 20 ms (about 3,000 switches a minute); an event-driven host
 * blocks and makes a handful. Processes are found by argv (argv[1] is
 * `__terminal-host`, or `server start` for the daemon), never by a pattern over
 * the whole command line, which would also match this check's own shell. It
 * fails when no terminal host exists, so an empty machine never passes.
 */
export function devboxIdleWakeupCheckCommand(options: DevboxIdleWakeupCheckOptions = {}): string {
  const windowSeconds = options.windowSeconds ?? 60;
  const max = options.maxHostMainSwitches ?? 30;
  const proc = options.procRoot ?? "/proc";
  const pause = options.pause ?? `sleep ${windowSeconds}`;
  // No shell `${...}` below: this is a TypeScript template.
  const script = String.raw`P='@PROC@'; hosts=''; daemon=''
for d in "$P"/[0-9]*; do
  a1=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | sed -n 2p)
  a2=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | sed -n 3p)
  if [ "$a1" = __terminal-host ]; then hosts="$hosts $(basename "$d")"
  elif [ "$a1" = server ] && [ "$a2" = start ]; then daemon="$daemon $(basename "$d")"; fi
done
[ -n "$hosts" ] || { echo 'idle-wakeups: FAIL no terminal host to measure'; exit 1; }
snap() {
  for p in $hosts; do for t in "$P/$p"/task/*; do
    printf 'host %s %s %s %s\n' "$p" "$(basename "$t")" "$(awk '/^voluntary_ctxt_switches/ { print $2 }' "$t/status" 2>/dev/null)" "$(cat "$t/comm" 2>/dev/null)"
  done; done
  for p in $daemon; do for t in "$P/$p"/task/*; do
    printf 'daemon %s %s %s %s\n' "$p" "$(basename "$t")" "$(awk '/^voluntary_ctxt_switches/ { print $2 }' "$t/status" 2>/dev/null)" "$(cat "$t/comm" 2>/dev/null)"
  done; done
}
before=$(snap); @PAUSE@; after=$(snap)
printf '%s\n--\n%s\n' "$before" "$after" | awk -v max=@MAX@ -v window=@WINDOW@ '
  $0 == "--" { second = 1; next }
  $4 !~ /^[0-9]+$/ { next }
  !second { start[$1 " " $2 " " $3] = $4; next }
  {
    key = $1 " " $2 " " $3
    if (!(key in start)) next
    d = $4 - start[key]; comm = $5
    for (i = 6; i <= NF; i++) comm = comm " " $i
    tag = ($2 == $3) ? " main" : ""
    printf "idle-wakeups: %s %s thread %s (%s%s): %d voluntary switches in %ds\n", $1, $2, $3, comm, tag, d, window
    if ($1 == "host" && $2 == $3) { hosts++; if (d > max) bad++ }
  }
  END {
    if (hosts == 0) { print "idle-wakeups: FAIL no terminal host main thread measured"; exit 1 }
    if (bad) { printf "idle-wakeups: FAIL %d terminal host main thread(s) over %d switches in %ds\n", bad, max, window; exit 1 }
    printf "idle-wakeups: PASS %d terminal host main thread(s) at or under %d switches in %ds\n", hosts, max, window
  }'`;
  return script
    .replace("@PROC@", proc)
    .replace("@PAUSE@", pause)
    .replace("@MAX@", String(max))
    .replace("@WINDOW@", String(windowSeconds));
}

/**
 * cmux's Claude Code defaults (claude-onboarding.py `SETTINGS_DEFAULTS`: `crossSessionInbound: "accept"`, so
 * messages from the person's other sessions are delivered, not held) in the user settings of root and the work
 * user. A key a file already sets keeps its value. They are user settings, not managed ones: managed settings
 * rank above the person's own, and a person's `"refuse"` must win. Leo, 2026-11-18, on a Claude Code holding
 * another session's message: "can you make this accept", "they shouldnt hold em".
 */
export function devboxClaudeSettingsDefaultsCommand(): string {
  const seed = "python3 -I /etc/cmux/claude-onboarding.py --settings-default";
  return `${seed} /root/.claude/settings.json && sudo -n -u ${DEVBOX_WORK_USER} ${seed} ${DEVBOX_WORK_HOME}/.claude/settings.json && ${devboxClaudeSettingsDefaultsCheckCommand()}`;
}

/** Fails unless both homes' Claude user settings carry a valid default or explicit choice. */
export function devboxClaudeSettingsDefaultsCheckCommand(
  files: readonly string[] = ["/root/.claude/settings.json", `${DEVBOX_WORK_HOME}/.claude/settings.json`],
  expectedWorkUser: string | null = DEVBOX_WORK_USER,
): string {
  const encodedFiles = JSON.stringify(files);
  const ownership = expectedWorkUser === null ? "" : ` && [ "$(stat -c %U ${files[1] ?? files[0]})" = ${expectedWorkUser} ]`;
  return `python3 -c 'import glob, json, os; rows = [json.load(open(p)) for p in ${encodedFiles}]; assert all("crossSessionInbound" in r and r["crossSessionInbound"] in ("accept", "hold", "refuse") for r in rows), rows; managed = ["/etc/claude-code/managed-settings.json"] if os.path.exists("/etc/claude-code/managed-settings.json") else []; managed += glob.glob("/etc/claude-code/managed-settings.d/*.json"); assert all("crossSessionInbound" not in json.load(open(p)) for p in managed), managed'${ownership} && echo claude-settings-defaults-ok`;
}
