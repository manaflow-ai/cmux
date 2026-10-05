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

export function devboxStrandedRemoteSessionRepairCommand(homes: readonly string[] = DEVBOX_REMOTE_STATE_HOMES): string {
  const dirs = homes.map((home) => `"${home}"/.local/state/cmux/remote/sessions/*`).join(" ");
  return (
    `for cmux_session in ${dirs}; do` +
    ' if [ -f "$cmux_session/lifecycle-fence.json" ] && [ ! -e "$cmux_session/auth" ]; then rm -rf "$cmux_session"; fi;' +
    " done; true"
  );
}

/** Waits for the daemon's remote listener (port 1337) on any address family. */
export function devboxRemoteListenerWaitCommand(timeoutSeconds: number): string {
  return (
    `for cmux_try in $(seq 1 ${timeoutSeconds * 2}); do` +
    " if ss -Hltn 2>/dev/null | grep -q ':1337 '; then exit 0; fi; sleep 0.5;" +
    ` done; echo "cmux-tui daemon did not listen on port 1337 within ${timeoutSeconds}s" >&2; exit 1`
  );
}
