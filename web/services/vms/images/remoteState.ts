/**
 * Remote daemon state on a clone of a running machine.
 *
 * A fork or checkpoint is a memory snapshot of a live machine, so the clone
 * resumes with the parent daemon's whole remote state dir
 * (~/.local/state/cmux/remote): its Noise identity and authorization under
 * sessions/<session>/auth, plus the lifecycle fence, shutdown record and
 * socket locks beside it. cmux-tui refuses to start when a session holds a
 * lifecycle fence but no auth dir (it reads that as a legacy daemon whose
 * shutdown never finished). The boot supervisor (cmux-devbox-boot) deletes
 * only auth/ and connections/ on clone, so every fork strands its session
 * in exactly that state: the daemon crash-loops and port 1337 never listens.
 * The bake avoids it by removing the whole remote dir before its snapshot
 * (devboxParkDaemonCommand); a fork snapshots a live machine and cannot.
 *
 * The repair removes only sessions in that state. A live daemon always holds
 * its auth dir, so the repair never touches a working session, and it stays a
 * no-op once a bake's supervisor drops the whole dir on clone. The
 * supervisor restarts the daemon on its next tick, about a second later.
 */
const DEVBOX_REMOTE_STATE_HOMES = ["/home/cmux", "/root"] as const;
/** The supervisor's BOUND_INSTANCE_FILE: the machine whose identity the daemon state holds. */
const DEVBOX_BOUND_INSTANCE_FILE = "/etc/cmux/daemon-instance-id";
/** The supervisor's instance_id(): the platform metadata service's id for this machine. */
const DEVBOX_METADATA_INSTANCE_ID_COMMAND =
  "curl -sf -m 1 -H \"X-aws-ec2-metadata-token: $(curl -sf -m 1 -X PUT http://169.254.169.254/latest/api/token -H 'X-metadata-token-ttl-seconds: 60')\" http://169.254.169.254/latest/meta-data/instance-id";

export function devboxStrandedRemoteSessionRepairCommand(homes: readonly string[] = DEVBOX_REMOTE_STATE_HOMES): string {
  const dirs = homes.map((home) => `"${home}"/.local/state/cmux/remote/sessions/*`).join(" ");
  return (
    `for cmux_session in ${dirs}; do` +
    ' if [ -f "$cmux_session/lifecycle-fence.json" ] && [ ! -e "$cmux_session/auth" ]; then rm -rf "$cmux_session"; fi;' +
    " done; true"
  );
}

/** The systemd unit that runs the boot supervisor (cmux-devbox-boot) on a Freestyle image. */
const DEVBOX_SUPERVISOR_UNIT = "cmux-tui-daemon.service";

/**
 * Starts the supervisor unit when it is not running. A memory snapshot
 * resumes the source's processes and never re-runs boot, so a snapshot taken
 * while the owner had stopped the unit resumes with no supervisor: nothing
 * binds the clone or starts its daemon. The unit is enabled in every image,
 * so starting it does what a boot of that machine would have done. On a
 * running supervisor this is one `is-active` call.
 */
function devboxStartSupervisorCommand(): string {
  return (
    `command -v systemctl >/dev/null 2>&1 && { systemctl is-active --quiet ${DEVBOX_SUPERVISOR_UNIT} >/dev/null 2>&1` +
    ` || systemctl start --no-block ${DEVBOX_SUPERVISOR_UNIT} >/dev/null 2>&1; };`
  );
}

/** The first stderr line of a readiness timeout; `freestyleForkReadinessStage` parses it. */
export const DEVBOX_FORK_DAEMON_NOT_READY = "cmux fork daemon did not become ready";

/**
 * The timeout report. Its first line names the stalled stage from a fixed
 * vocabulary, safe to store and alert on:
 *   metadata-unavailable  the clone never read its own instance id
 *   unbound               the supervisor never bound the clone (daemon-instance-id)
 *   daemon-absent         bound, but no cmux-tui server process runs
 *   daemon-not-listening  bound and running, but nothing listens on 1337
 * plus the supervisor unit's state reduced to [a-z-]. The unit's last log
 * lines follow on later lines for the server log only: they are guest text.
 */
function devboxForkDaemonTimeoutReport(boundInstanceFile: string): string {
  return (
    `cmux_unit=$(systemctl is-active ${DEVBOX_SUPERVISOR_UNIT} 2>/dev/null | head -n 1 | tr -cd 'a-z-'); [ -n "$cmux_unit" ] || cmux_unit=unknown;` +
    ' if [ -z "$cmux_id" ]; then cmux_stage=metadata-unavailable;' +
    ` elif [ "$cmux_id" != "$(cat "${boundInstanceFile}" 2>/dev/null)" ]; then cmux_stage=unbound;` +
    " elif ! pgrep -f 'cmux-tui server [s]tart' >/dev/null 2>&1; then cmux_stage=daemon-absent;" +
    " else cmux_stage=daemon-not-listening; fi;" +
    ` echo "${DEVBOX_FORK_DAEMON_NOT_READY}: stage=$cmux_stage supervisor=$cmux_unit" >&2;` +
    ` journalctl -u ${DEVBOX_SUPERVISOR_UNIT} -n 5 -o cat --no-pager >&2 2>/dev/null; exit 1`
  );
}

const FORK_READINESS_STAGE_LINE = new RegExp(`^${DEVBOX_FORK_DAEMON_NOT_READY}: (stage=[a-z-]{1,32} supervisor=[a-z-]{1,32})$`);

/**
 * The stage summary from a readiness answer's first stderr line, or
 * `stage=unknown` when the answer is not the report's shape (an older image
 * command, an exec failure). Never returns other guest text.
 */
export function devboxForkReadinessStage(stderr: string | undefined): string {
  const first = (stderr ?? "").split("\n", 1)[0]?.trim() ?? "";
  return FORK_READINESS_STAGE_LINE.exec(first)?.[1] ?? "stage=unknown";
}

/**
 * Repairs a clone's stranded session and waits until THIS machine's daemon
 * listens on port 1337.
 *
 * When create returns, the clone may still be running the source's resumed
 * daemon, listening on 1337 with the source's identity: the supervisor
 * notices the clone only on its next tick. Neither the listener nor the
 * session state means anything until the supervisor has run its clone branch
 * (stop the source daemon, delete auth/, write daemon-instance-id), so the
 * loop first waits for daemon-instance-id to name this machine's metadata
 * instance id. From then on any listener belongs to a daemon started on this
 * machine. The repair runs on every pass because the supervisor deletes
 * auth/, the step that strands the session, only inside that branch. Every
 * pass also starts a stopped supervisor (devboxStartSupervisorCommand).
 */
/** `homes` and `boundInstanceFile` exist for tests. */
export interface DevboxForkDaemonReadyOptions {
  readonly homes?: readonly string[];
  readonly boundInstanceFile?: string;
}

export function devboxForkDaemonReadyCommand(timeoutSeconds: number, options: DevboxForkDaemonReadyOptions = {}): string {
  const boundInstanceFile = options.boundInstanceFile ?? DEVBOX_BOUND_INSTANCE_FILE;
  return (
    'cmux_id=""; ' +
    `for cmux_try in $(seq 1 ${timeoutSeconds * 2}); do` +
    ` ${devboxStartSupervisorCommand()}` +
    ` [ -n "$cmux_id" ] || cmux_id=$(${DEVBOX_METADATA_INSTANCE_ID_COMMAND} 2>/dev/null) || cmux_id="";` +
    ` if [ -n "$cmux_id" ] && [ "$cmux_id" = "$(cat "${boundInstanceFile}" 2>/dev/null)" ]; then` +
    ` ${devboxStrandedRemoteSessionRepairCommand(options.homes)};` +
    " if ss -Hltn 2>/dev/null | grep -q ':1337 '; then exit 0; fi;" +
    " fi; sleep 0.5;" +
    ` done; ${devboxForkDaemonTimeoutReport(boundInstanceFile)}`
  );
}
