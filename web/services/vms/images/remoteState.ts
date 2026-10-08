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

function devboxForkDaemonTimeoutReport(timeoutSeconds: number, boundInstanceFile: string): string {
  void timeoutSeconds;
  void boundInstanceFile;
  return 'echo "cmux fork daemon did not become ready" >&2; exit 1';
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
    ` done; ${devboxForkDaemonTimeoutReport(timeoutSeconds, boundInstanceFile)}`
  );
}
