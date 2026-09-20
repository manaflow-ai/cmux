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
  cmux_welcome_body="\$(
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
  )" || return 1
  python3 - "\$cmux_welcome_body" <<'CMUX_WELCOME_RENDER'
import os, sys, unicodedata

try:
    columns = os.get_terminal_size(1).columns
except OSError:
    try:
        with open('/dev/tty', 'rb', buffering=0) as tty:
            columns = os.get_terminal_size(tty.fileno()).columns
    except OSError:
        value = os.environ.get('COLUMNS', '80')
        columns = int(value) if value.isdecimal() else 80
width = max(20, min(columns, 80)) - 4
color = 'NO_COLOR' not in os.environ and os.environ.get('TERM') != 'dumb'
reset, bold, dim = ('\\x1b[0m', '\\x1b[1m', '\\x1b[2m') if color else ('', '', '')

def cells(text):
    return sum(0 if unicodedata.combining(c) else 2 if unicodedata.east_asian_width(c) in ('W', 'F') else 1 for c in text)

def wrap(text, limit):
    line = ''
    for char in text:
        if cells(line + char) > limit:
            cut = line.rfind(' ')
            if cut > limit // 2:
                yield line[:cut]
                line = line[cut + 1:]
            else:
                yield line
                line = ''
        line += char
    if line.strip():
        yield line.rstrip()

def emit(text, style=''):
    print('  ' + style + text + reset)

lines = sys.argv[1].splitlines()
intro, tagline = lines[:2]
shades = [(0,212,255),(24,181,250),(48,150,245),(72,119,241),(96,88,239),(110,73,238),(124,58,237)]
logo = ['::', '  ::::', '    ::::::', '      ::::::', '    ::::::', '  ::::', '::']
print()
for index, marks in enumerate(logo):
    shade = ('\\x1b[38;2;%d;%d;%dm' % shades[index]) if color else ''
    text = shade + marks + reset
    if width >= 58 and index in (1, 3, 4):
        label = {1:'cmux Cloud',3:intro,4:tagline}[index]
        text += ' ' * (22 - len(marks)) + (bold if index == 1 else dim) + label + reset
    emit(text)
if width < 58:
    for text in wrap(intro, width): emit(text, bold)
    for text in wrap(tagline, width): emit(text, dim)
for line in lines[2:]:
    if not line:
        print()
    elif '\\t' not in line:
        if line.startswith('cmux '):
            emit(line, bold)
        else:
            for text in wrap(line, width): emit(text, bold)
    else:
        label, text = line.split('\\t', 1)
        if width >= 58 and cells(label) < 22:
            for index, part in enumerate(wrap(text, width - 22)):
                lead = (bold + label + reset + ' ' * (22 - cells(label))) if index == 0 else ' ' * 22
                emit(lead + dim + part)
        else:
            emit(label, bold)
            for part in wrap(text, width - 2): emit('  ' + part, dim)
print()
CMUX_WELCOME_RENDER
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
