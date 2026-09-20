import { shellQuote } from "./drivers/cmuxTuiDaemon";

/**
 * The offline Cloud welcome shown by the in-VM `cmux welcome` command.
 *
 * Rendering never reads stdin or fetches data. Automatic delivery is an
 * explicit startup-only caller; manual replay never touches its ledger.
 */
export const GUEST_CMUX_WELCOME_IDENTITY_PATH = "/etc/cmux/.cloud-welcome-machine-id";
export const GUEST_CMUX_WELCOME_PENDING_PATH = "/etc/cmux/.cloud-welcome-pending";

/** Mirrors the repository grant during the existing attach preparation exec. */
export function guestWelcomeEligibilityCommand(machineId: string, eligible: boolean): string {
  const value = shellQuote(eligible ? machineId : "");
  return `(mkdir -p /etc/cmux && temporary=$(mktemp '${GUEST_CMUX_WELCOME_PENDING_PATH}.XXXXXX') && `
    + `trap 'rm -f "$temporary"' EXIT && printf '%s\\n' ${value} > "$temporary" && chmod 0644 "$temporary" && `
    + `mv -f "$temporary" '${GUEST_CMUX_WELCOME_PENDING_PATH}') >/dev/null 2>&1 || :`;
}

export const GUEST_CMUX_WELCOME_SHELL = `guest_welcome_display_available() {
  [ -n "\${DISPLAY:-}" ] && return 0
  [ -r /run/cmux-desktop/env ] && return 0
  return 1
}

guest_welcome_render() {
  cmux_welcome_reset='\\033[0m'
  cmux_welcome_c1='\\033[38;2;0;212;255m'
  cmux_welcome_c2='\\033[38;2;24;181;250m'
  cmux_welcome_c3='\\033[38;2;48;150;245m'
  cmux_welcome_c4='\\033[38;2;72;119;241m'
  cmux_welcome_c5='\\033[38;2;96;88;239m'
  cmux_welcome_c6='\\033[38;2;110;73;238m'
  cmux_welcome_c7='\\033[38;2;124;58;237m'

  printf '\\n'
  printf '%b  ::%b\\n' "\$cmux_welcome_c1" "\$cmux_welcome_reset"
  printf '%b    ::::              %bc%bm%bu%bx cloud%b\\n' \\
    "\$cmux_welcome_c2" "\$cmux_welcome_c1" "\$cmux_welcome_c2" "\$cmux_welcome_c3" "\$cmux_welcome_c7" "\$cmux_welcome_reset"
  printf '%b      ::::::%b\\n' "\$cmux_welcome_c3" "\$cmux_welcome_reset"
  printf '%b        ::::::%b\\n' "\$cmux_welcome_c4" "\$cmux_welcome_reset"
  printf '%b      ::::::%b\\n' "\$cmux_welcome_c5" "\$cmux_welcome_reset"
  printf '%b    ::::%b\\n' "\$cmux_welcome_c6" "\$cmux_welcome_reset"
  printf '%b  ::%b\\n' "\$cmux_welcome_c7" "\$cmux_welcome_reset"
  printf '\\n'

  cmux_message welcomeIntro
  cmux_message welcomeCodeRouter
  cmux_message welcomeWorkspaces
  if guest_welcome_display_available; then
    cmux_message welcomeDisplays
  else
    cmux_message welcomeNoDisplays
  fi
  cmux_message welcomePorts
  cmux_message welcomeFiles
  cmux_message welcomeReplay
  printf '\\n'
}

# Only the user's first machine can be eligible. The provider pins the gate
# to that machine id; cloning its disk cannot transfer eligibility.
guest_welcome_auto() {
  [ "\${CMUX_CLOUD_WELCOME:-1}" != 0 ] || return 0
  [ -z "\${CMUX_CLOUD_WELCOME_SHOWN:-}" ] || return 0
  cmux_welcome_pending_gate="\${CMUX_CLOUD_WELCOME_PENDING_PATH:-${GUEST_CMUX_WELCOME_PENDING_PATH}}"
  [ -e "\$cmux_welcome_pending_gate" ] || return 0
  cmux_welcome_state="\${CMUX_GUEST_HOME:-\${HOME:-/root}/.cmux}/cloud-welcome"
  cmux_welcome_marker="\$cmux_welcome_state/shown"
  cmux_welcome_identity_file="\${CMUX_CLOUD_WELCOME_IDENTITY_PATH:-${GUEST_CMUX_WELCOME_IDENTITY_PATH}}"
  cmux_welcome_identity="\$(cat "\$cmux_welcome_identity_file" 2>/dev/null)" || return 0
  [ -n "\$cmux_welcome_identity" ] || return 0
  [ "\$(cat "\$cmux_welcome_pending_gate" 2>/dev/null)" = "\$cmux_welcome_identity" ] || return 0
  mkdir -p "\$cmux_welcome_state" 2>/dev/null || return 0
  cmux_welcome_text="\$(guest_welcome_render)" || return 1
  # Kernel locking releases even on abrupt process exit. Record only after
  # the complete output write; never unlink a lock another process may hold.
  python3 -c '
import fcntl, os, pathlib, sys, tempfile
marker = pathlib.Path(sys.argv[1])
identity = sys.argv[2]
with open(str(marker) + ".lock", "a") as lock:
    try: fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit(0)
    if marker.exists() and marker.read_text().strip() == identity: sys.exit(0)
    data = (sys.argv[3] + "\\n").encode()
    while data:
        written = os.write(1, data)
        if written == 0: raise OSError("welcome output closed")
        data = data[written:]
    fd, temporary = tempfile.mkstemp(prefix=".shown-", dir=marker.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(identity + "\\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, marker)
    finally:
        if os.path.exists(temporary): os.unlink(temporary)
' "\$cmux_welcome_marker" "\$cmux_welcome_identity" "\$cmux_welcome_text"
}

guest_welcome_command() {
  cmux_welcome_auto=0
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --auto) cmux_welcome_auto=1; shift ;;
      --help|-h) cmux_message welcomeUsage; return 0 ;;
      *) die_message 2 welcomeOption "\$1" ;;
    esac
  done
  if [ "\$cmux_welcome_auto" = 1 ]; then
    guest_welcome_auto
  else
    guest_welcome_render
  fi
}
`;
