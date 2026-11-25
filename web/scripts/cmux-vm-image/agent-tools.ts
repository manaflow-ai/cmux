/**
 * Agent tools in the cmux VM image (bead cx-h8n; bake option `--agent-tools`, dev snapshots only).
 *
 * An agent session that runs ON the machine is local to it, so the machine's acpmux gives it
 * the same tools a session on a Mac gets (cmux-tui/crates/acpmux/src/agent_tools.rs): the
 * `cmux-cua` MCP server, the `cmux` MCP server (`cmux mcp serve`, browser_repl_* tools) and
 * the `cmux:cmux-browser` and `cmux:cmux-cua` skills. acpmux does not change. The image only
 * gives it what it looks for, in the places it looks:
 *
 * - `CMUX_AGENT_TOOLS_BIN_DIR` = AGENT_TOOLS_BIN, which holds `cmux` (the store's cmux-tui;
 *   cmux and acpmux are one binary) and `cmux-cua` (a wrapper, below). acpmux's own default
 *   (the folder of its executable) is the cmux-tui store entry, which holds neither.
 * - Computer use (cmux-tui since #37003): acpmux attaches `acpmux computer-use-mcp` (server
 *   `cmux-computer-use`), whose calls go to the worker the cmux-tui daemon starts on the first
 *   call (cmux-tui-core computer_use_host.rs). The daemon has no display, so the worker launcher
 *   runs the machine's desktop starter, DESKTOP_STARTER (root-owned: the only one it trusts): it
 *   starts DISPLAY_UNIT (Xvfb on AGENT_DISPLAY) and A11Y_UNIT (its AT-SPI bus) and names them to
 *   the worker, with CUA_REFUSE_DIR first on its PATH and no right to gain privileges, so the
 *   display runs only once an agent asks and nothing the worker starts can install software.
 *   Images whose cmux-tui predates #37003 attach `cmux-cua mcp` (CMUX_CUA_MCP_FORCE_PROXY=1),
 *   which on Linux needs a running `cmux-cua serve`: its wrapper starts CUA_UNIT (and through it
 *   DISPLAY_UNIT) before it execs the real proxy.
 * - Browser: the browser role is installed at bake (its first-use closure and programs, as
 *   browser-probe.ts installs them), and the daemon unit names the host binary and Chrome.
 *   The daemon socket-activates the host on the first agent connect and the host exits
 *   after 5 idle minutes (cmux-tui-core/src/browser_host.rs), so nothing runs while idle.
 *   Every terminal the daemon creates gets CMUX_BROWSER_HOST_SOCKET; an acpmux daemon
 *   started from such a terminal passes it to `cmux mcp serve`.
 * - `cmux mcp serve` runs only when cmux.json sets `"mcp": {"enabled": true}`, and acpmux
 *   attaches it only when `agents.cmuxMcp` is `on` (the person's yes to cmux's tools in agents
 *   cmux starts; a chat started from a Mac follows that Mac's answer instead). The image writes
 *   both for the work user when the file does not exist (the machine has no app to ask). The
 *   Claude Code permission prompts and acpmux permission policies are unchanged.
 * - Desktop (role desktop): the person's view of the agent display is `cmux.rd/1` over the owner's
 *   carrier, service `desktop`. The boundary is the carrier's admission: the machine's carrier
 *   server (`cmux carrier serve`, which runs as the work user) admits only the owner's grant
 *   for `desktop`, then connects RD_SOCKET; systemd starts RD_UNIT,
 *   the `cmux-rd` host on the agent display as its own system user RD_USER (no shell, no home,
 *   not in the work user's group, no sudo), which takes connections from the work user's uid only.
 *   On the machine the socket is not a boundary against the agent: the agent already reaches
 *   `:99` (its own display) and has sudo. It keeps everyone else out, and keeps the host's files
 *   (cookie copy, state) out of the agent's reach. The host exits when idle.
 * - Desktop session: the host's unit wants DESKTOP_SESSION_UNIT, openbox and a terminal on the
 *   agent display (1920x1080), so a viewer sees a desktop, not an empty black root window. Its
 *   start fails loudly when the display still shows no window (DESKTOP_CHECK_SCRIPT).
 */
import { DEVBOX_WORK_HOME, DEVBOX_WORK_UID, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { firstUseInstallPhases } from "./browser-probe";
import { CURRENT_BIN, type InputsLock, type RolesManifest, rolesManifest, sq, storeEntry } from "./lock";

export const AGENT_TOOLS_DIR = "/opt/cmux/agent-tools";
export const AGENT_TOOLS_BIN = `${AGENT_TOOLS_DIR}/bin`;
/** One shared display per machine while cmux-cua holds one X11 connection (D-A3). */
const AGENT_DISPLAY_NUMBER = "99";
export const AGENT_DISPLAY = `:${AGENT_DISPLAY_NUMBER}`;
/**
 * The shared display is display `:99` of the per-display template (displayTemplateUnit), so its
 * AT-SPI bus (A11Y_UNIT, a11yTemplateUnit) follows it; without that bus cmux-cua returns empty
 * accessibility trees and can type only into the globally focused window.
 */
export const DISPLAY_UNIT = `cmux-agent-display@${AGENT_DISPLAY_NUMBER}.service`;
/** The shared display's AT-SPI bus. */
export const A11Y_UNIT = `cmux-agent-a11y@${AGENT_DISPLAY_NUMBER}.service`;
export const CUA_UNIT = "cmux-agent-cua.service";
export const AGENT_DISPLAY_DIR = `${DEVBOX_WORK_HOME}/.cache/cmux-display`;
/** cmux-cua's Linux default socket (`$HOME/.cache/cmux-cua/cmux-cua.sock`), which the proxy dials. */
export const CUA_SOCKET = `${DEVBOX_WORK_HOME}/.cache/cmux-cua/cmux-cua.sock`;
export const WORK_USER_CMUX_JSON = `${DEVBOX_WORK_HOME}/.config/cmux/cmux.json`;
export const AGENT_TOOLS_PROFILE = "/etc/profile.d/cmux-agent-tools.sh";
/**
 * First on the computer-use driver's PATH: `sudo`, `apt`, `apt-get`, `ffmpeg` and `ffprobe` that
 * refuse. cmux-cua's install_ffmpeg tool runs `sudo -n apt-get install -y ffmpeg` from the driver;
 * role cua-video (screen recording by the driver) stays off on every machine until Lawrence decides
 * (coordinator legal rule, 2026-10-07). The image itself carries ffmpeg for people's own media
 * (images/cmux-vm/graduated.json, Leo 2026-11-25), so the driver finds refusing ffmpeg and ffprobe
 * first instead. The unit also sets NoNewPrivileges, so no setuid program works there.
 */
export const CUA_REFUSE_DIR = `${AGENT_TOOLS_DIR}/cua-refuse`;
/**
 * The machine's desktop starter, which cmux-tui's Computer Use worker launcher runs when its daemon
 * has no display (cmux-tui-core computer_use_host/linux.rs DESKTOP_STARTER). Root owns it and its
 * folders and nobody else can write them, or the launcher refuses it.
 */
export const DESKTOP_STARTER = "/etc/cmux/computer-use-desktop";
/** The worker's switch that takes away its right to gain privileges (cmux-tui-core NO_NEW_PRIVS_ENV). */
export const NO_NEW_PRIVS_ENV = "CMUX_CU_NO_NEW_PRIVS";
const CUA_REFUSED = ["sudo", "apt", "apt-get", "ffmpeg", "ffprobe"] as const;

const BROWSER_ROLE = "browser";

function browserHostPaths(manifest: RolesManifest): { host: string; chromium: string } {
  const entry = manifest.roles[BROWSER_ROLE];
  const host = entry?.programs.find((p) => p.name === "cmux-browser-host");
  const chromium = entry?.env.CMUX_BROWSER_HOST_CHROMIUM;
  if (!entry || !host || !chromium) throw new Error("agent tools need the browser role with cmux-browser-host and Chrome in the lock");
  return { host: `${host.storeEntry}/${host.bin["cmux-browser-host"]}`, chromium };
}

/** The baked Chrome's binary (the browser role's store entry). */
export function browserChromiumPath(lock: InputsLock): string {
  return browserHostPaths(rolesManifest(lock)).chromium;
}

/**
 * Environment of the cmux-tui daemon (and so of every terminal it creates and every acpmux
 * daemon started from one): where acpmux finds the tool binaries, and the browser host the
 * daemon supervises with the browser role's env.
 */
export function agentToolsDaemonEnv(lock: InputsLock): Record<string, string> {
  const manifest = rolesManifest(lock);
  const { host } = browserHostPaths(manifest);
  return {
    CMUX_AGENT_TOOLS_BIN_DIR: AGENT_TOOLS_BIN,
    CMUX_BROWSER_HOST_BIN: host,
    ...manifest.roles[BROWSER_ROLE].env,
  };
}

/**
 * `cmux-cua` as acpmux starts it: `mcp` first starts the machine's computer-use driver (and its
 * display) and waits for its socket (systemctl returns after ExecStartPost), then execs the real
 * binary with every argument. Any other verb passes straight through.
 */
export function cuaWrapperScript(realCua = `${CURRENT_BIN}/cmux-cua`, unit = CUA_UNIT): string {
  return [
    "#!/bin/sh",
    "# cmux VM agent tools (images/cmux-vm, managed, do not edit): computer use drives this",
    "# machine's own display. `mcp` starts the driver first; it then stays up until the machine stops.",
    `if [ "\${1:-}" = mcp ]; then`,
    `  sudo -n systemctl start ${unit} || echo "cmux-cua: the machine's computer-use driver did not start (systemctl status ${unit})" >&2`,
    "fi",
    `exec ${sq(realCua)} "$@"`,
    "",
  ].join("\n");
}

/** Waits (bounded, 10 s) for a Unix socket; ExecStartPost of a Type=simple unit, so `systemctl start` returns once it listens. */
function waitForSocket(path: string): string {
  return `/bin/sh -c 'for i in $(seq 1 100); do [ -S ${path} ] && exit 0; sleep 0.1; done; echo "no socket ${path}" >&2; exit 1'`;
}

/** Waits (bounded, `seconds`) for a non-empty file, the ready marker a unit's script writes last. */
function waitForFile(path: string, seconds: number): string {
  return `/bin/sh -c 'for i in $(seq 1 ${seconds * 10}); do [ -s ${path} ] && exit 0; sleep 0.1; done; echo "no ${path}" >&2; exit 1'`;
}

/** The agent displays' size: a common monitor size, so a person's view of the desktop is not a small box. */
export const AGENT_DISPLAY_SIZE = "1920x1080";

/** Xvfb as the work user, X11 over its Unix socket only, with a per-start cookie in `xauthority`. */
function xvfbUnit(description: string, display: string, xauthority: string, extraArgs = ""): string {
  return [
    "[Unit]",
    `Description=${description}`,
    "",
    "[Service]",
    "Type=simple",
    `User=${DEVBOX_WORK_USER}`,
    `Group=${DEVBOX_WORK_USER}`,
    `Environment=HOME=${DEVBOX_WORK_HOME}`,
    `ExecStartPre=/bin/sh -c 'install -d -m 0700 ${AGENT_DISPLAY_DIR} && rm -f ${xauthority} && xauth -q -f ${xauthority} add ${display} . "$(mcookie)" && chmod 0600 ${xauthority}'`,
    `ExecStart=/usr/bin/Xvfb ${display} -screen 0 ${AGENT_DISPLAY_SIZE}x24 -nolisten tcp -auth ${xauthority} -s 0 -dpms${extraArgs}`,
    `ExecStartPost=${waitForSocket(`/tmp/.X11-unix/X${display.slice(1)}`)}`,
    "Restart=on-failure",
    "RestartSec=2",
    "",
  ].join("\n");
}

/**
 * Per-workspace displays (bead cx-ncc.5): `cmux-agent-display@N.service` is Xvfb on `:N` and
 * `cmux-agent-a11y@N.service` its AT-SPI bus. cmux-cua takes a display per call (the proxy env
 * CMUX_CUA_DISPLAY=:N), so one machine can give each workspace its own. Nothing allocates
 * displays per workspace yet; the shared display is instance 99 (DISPLAY_UNIT, A11Y_UNIT), which
 * cmux-cua's unit starts. Like the units above they have no [Install] and stay off.
 */
export const DISPLAY_TEMPLATE_UNIT = "cmux-agent-display@.service";
export const A11Y_TEMPLATE_UNIT = "cmux-agent-a11y@.service";
const A11Y_RUNTIME_NAME = "cmux-agent-a11y";
/** The cookie file of display `:n` (`%i` inside a template unit). */
export function agentXauthority(n: string): string {
  return `${AGENT_DISPLAY_DIR}/Xauthority-${n}`;
}
/** The shared display's cookie file. */
export const AGENT_XAUTHORITY = agentXauthority(AGENT_DISPLAY_NUMBER);
/** Display `:n`'s runtime dir (session bus socket, a11y bus, ready marker): owned by the work user, 0700, removed when the a11y unit stops. */
export function a11yRuntimeDir(n: string): string {
  return `/run/${A11Y_RUNTIME_NAME}-${n}`;
}
/** Starts display `:N`'s session bus and AT-SPI bus and publishes AT_SPI_BUS (a11yScript). */
export const A11Y_SCRIPT = `${AGENT_TOOLS_DIR}/cmux-agent-a11y`;
/** Sets a STRING property on the root window (rootPropertyScript). */
export const ROOT_PROPERTY_SCRIPT = `${AGENT_TOOLS_DIR}/cmux-x11-set-root-property`;
export const AT_SPI_BUS_LAUNCHER = "/usr/libexec/at-spi-bus-launcher";

/**
 * Xvfb on `:%i`. `-noreset`: Xvfb otherwise resets when its last client disconnects, which
 * clears the root window properties, so AT_SPI_BUS would vanish as soon as its writer exits.
 */
export function displayTemplateUnit(): string {
  return xvfbUnit("cmux agent display :%i (Xvfb) for computer use, started on demand", ":%i", agentXauthority("%i"), " -noreset");
}

/**
 * The AT-SPI bus of display `:%i`: A11Y_SCRIPT as the work user with that display's cookie and
 * a private runtime dir. `systemctl start` returns once the script has published the address.
 */
export function a11yTemplateUnit(): string {
  const display = "cmux-agent-display@%i.service";
  return [
    "[Unit]",
    "Description=cmux agent accessibility bus (AT-SPI) for display :%i, started on demand",
    // BindsTo, not Requires: when Xvfb restarts, its root window loses AT_SPI_BUS, so this unit
    // restarts with it and publishes the address again.
    `BindsTo=${display}`,
    `After=${display}`,
    // A launcher that keeps failing (about 12 s per attempt) stops after 5 tries in 2 minutes.
    "StartLimitIntervalSec=120",
    "StartLimitBurst=5",
    "",
    "[Service]",
    "Type=simple",
    `User=${DEVBOX_WORK_USER}`,
    `Group=${DEVBOX_WORK_USER}`,
    `Environment=HOME=${DEVBOX_WORK_HOME}`,
    "Environment=DISPLAY=:%i",
    `Environment=XAUTHORITY=${agentXauthority("%i")}`,
    `Environment=XDG_RUNTIME_DIR=${a11yRuntimeDir("%i")}`,
    `RuntimeDirectory=${A11Y_RUNTIME_NAME}-%i`,
    "RuntimeDirectoryMode=0700",
    "NoNewPrivileges=yes",
    `ExecStart=${A11Y_SCRIPT}`,
    `ExecStartPost=${waitForFile(`${a11yRuntimeDir("%i")}/at-spi-bus`, 45)}`,
    "Restart=on-failure",
    "RestartSec=2",
    "",
  ].join("\n");
}

/**
 * A11Y_SCRIPT. Ubuntu's at-spi-bus-launcher is built without X11 and never writes AT_SPI_BUS,
 * where cmux-cua reads a display's a11y bus address, so this does: a session dbus-daemon at
 * $XDG_RUNTIME_DIR/bus, the launcher on it, then the address on the root window. It waits for
 * the launcher to own org.a11y.Bus before asking for the address (asking earlier would make the
 * bus activate a second launcher) and stays in the foreground; when either child exits it
 * exits 1, so the unit restarts. dbus-daemon and dbus-send are in the base image.
 */
export function a11yScript(launcher = AT_SPI_BUS_LAUNCHER, setRootProperty = ROOT_PROPERTY_SCRIPT): string {
  const send = "dbus-send --session --reply-timeout=5000 --print-reply=literal";
  return [
    "#!/bin/bash",
    "# cmux VM agent tools (images/cmux-vm, managed, do not edit): the AT-SPI bus of one agent display.",
    "# Run by cmux-agent-a11y@N.service, which sets DISPLAY, XAUTHORITY and XDG_RUNTIME_DIR for display :N.",
    "set -u",
    'dir="$XDG_RUNTIME_DIR"',
    'rm -f "$dir/bus" "$dir/at-spi-bus"',
    'export DBUS_SESSION_BUS_ADDRESS="unix:path=$dir/bus"',
    'dbus-daemon --session --nofork --nopidfile --address="$DBUS_SESSION_BUS_ADDRESS" &',
    "bus=$!",
    "launcher_pid=",
    'fail() { echo "cmux-agent-a11y: $1 on $DISPLAY" >&2; kill "$bus" $launcher_pid 2>/dev/null; exit 1; }',
    'for i in $(seq 1 100); do [ -S "$dir/bus" ] && break; sleep 0.1; done',
    '[ -S "$dir/bus" ] || fail "the session bus did not start"',
    `${sq(launcher)} --launch-immediately &`,
    "launcher_pid=$!",
    "owned=",
    `for i in $(seq 1 100); do if ${send} --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.NameHasOwner string:org.a11y.Bus 2>/dev/null | grep -q true; then owned=1; break; fi; sleep 0.1; done`,
    '[ -n "$owned" ] || fail "at-spi-bus-launcher did not take org.a11y.Bus"',
    `addr=$(${send} --dest=org.a11y.Bus /org/a11y/bus org.a11y.Bus.GetAddress 2>/dev/null | tr -d '[:space:]')`,
    '[ -n "$addr" ] || fail "org.a11y.Bus gave no address"',
    `${sq(setRootProperty)} AT_SPI_BUS "$addr" || fail "could not set AT_SPI_BUS"`,
    `printf '%s\\n' "$addr" > "$dir/at-spi-bus"`,
    'wait -n "$bus" "$launcher_pid"',
    'fail "the session bus or at-spi-bus-launcher exited"',
    "",
  ].join("\n");
}

/**
 * ROOT_PROPERTY_SCRIPT `NAME VALUE`: what `xprop -root -f NAME 8s -set NAME VALUE` does, over the
 * display's Unix socket with the cookie in $XAUTHORITY. xprop is in x11-utils, whose closure
 * (fontconfig, libxft2, libgl1) is not baked and overlaps role display-wm's first-use closure.
 */
export function rootPropertyScript(): string {
  return `#!/usr/bin/python3 -I
# cmux VM agent tools (images/cmux-vm, managed, do not edit): sets one STRING property on the
# root window of $DISPLAY (Unix socket) with the MIT-MAGIC-COOKIE-1 in $XAUTHORITY.
${X11_CLIENT_PY}
def main():
    name, value = sys.argv[1].encode(), sys.argv[2].encode()
    sock, root, _, _ = connect()
    sock.sendall(struct.pack("<BBHHxx", 16, 0, 2 + len(pad(name)) // 4, len(name)) + pad(name))
    (atom,) = struct.unpack_from("<I", reply(sock), 8)
    sock.sendall(struct.pack("<BBHIIIB3xI", 18, 0, 6 + len(pad(value)) // 4, root, atom, 31, 8, len(value)) + pad(value))
    sock.sendall(struct.pack("<BxH", 43, 1))
    reply(sock)

main()
`;
}

/**
 * A minimal X11 client for the scripts above and below: `connect()` opens $DISPLAY's Unix socket
 * with the MIT-MAGIC-COOKIE-1 in $XAUTHORITY and returns the socket, the root window and the
 * screen's width and height. python3 only: x11-utils is not on every image.
 */
const X11_CLIENT_PY = `import os, socket, struct, sys

def pad(b):
    return b + b"\\0" * (-len(b) % 4)

def cookie(number):
    path = os.environ.get("XAUTHORITY", "")
    data = open(path, "rb").read() if path and os.path.exists(path) else b""
    i = 0
    while i + 2 <= len(data):
        i += 2
        fields = []
        for _ in range(4):
            (n,) = struct.unpack(">H", data[i:i + 2])
            fields.append(data[i + 2:i + 2 + n])
            i += 2 + n
        if fields[1] == number.encode() and fields[2] == b"MIT-MAGIC-COOKIE-1":
            return fields[2], fields[3]
    return b"", b""

def recv(sock, n):
    out = b""
    while len(out) < n:
        chunk = sock.recv(n - len(out))
        if not chunk:
            sys.exit("x11: the display closed the connection")
        out += chunk
    return out

def reply(sock):
    while True:
        head = recv(sock, 32)
        if head[0] == 0:
            sys.exit("x11: error %d for request %d" % (head[1], head[10]))
        if head[0] == 1:
            return head + recv(sock, 4 * struct.unpack_from("<I", head, 4)[0])

def connect():
    number = os.environ["DISPLAY"].split(":", 1)[1].split(".")[0]
    auth_name, auth_data = cookie(number)
    sock = socket.socket(socket.AF_UNIX)
    sock.connect("/tmp/.X11-unix/X" + number)
    sock.sendall(struct.pack("<BxHHHHxx", 0x6C, 11, 0, len(auth_name), len(auth_data)) + pad(auth_name) + pad(auth_data))
    head = recv(sock, 8)
    body = recv(sock, 4 * struct.unpack_from("<H", head, 6)[0])
    if head[0] != 1:
        sys.exit("x11: connection refused: " + body[:head[1]].decode(errors="replace"))
    vendor = struct.unpack_from("<H", body, 16)[0]
    screen = 32 + len(pad(b"v" * vendor)) + 8 * body[21]
    (root,) = struct.unpack_from("<I", body, screen)
    width, height = struct.unpack_from("<HH", body, screen + 20)
    return sock, root, width, height
`;

/**
 * The person's desktop on the agent display (ask-da398bba67, Leo 2026-11-16): before it, the display
 * was a bare Xvfb, and a viewer saw its empty black root window. DESKTOP_SESSION_UNIT runs a window
 * manager (openbox, role display-wm, baked with the agent tools) and a terminal (xterm) on it as the
 * work user, so the first frame a viewer sees has a window in it. The remote desktop host's unit
 * wants it, so the first desktop connection starts it; nothing runs while nobody looks.
 */
export const DESKTOP_SESSION_UNIT = "cmux-agent-desktop-session.service";
/** The session's ExecStart (desktopSessionScript). */
export const DESKTOP_SESSION_SCRIPT = `${AGENT_TOOLS_DIR}/cmux-agent-desktop-session`;
/** Checks that a display shows something (desktopCheckScript): the session's ExecStartPost and the image probe. */
export const DESKTOP_CHECK_SCRIPT = `${AGENT_TOOLS_DIR}/cmux-agent-desktop-check`;
/** How long the session's start waits for a window on the display before it fails. */
export const DESKTOP_CHECK_SECONDS = 20;

/**
 * DESKTOP_SESSION_SCRIPT: openbox, then a terminal in the work user's home; it stays in the
 * foreground with the window manager and exits 1 when that exits, so the unit restarts. Closing
 * the terminal leaves the desktop (openbox's right-click menu opens another).
 */
export function desktopSessionScript(): string {
  return [
    "#!/bin/sh",
    "# cmux VM agent tools (images/cmux-vm, managed, do not edit): the desktop session on the agent display.",
    "# Run by cmux-agent-desktop-session.service, which sets DISPLAY and XAUTHORITY.",
    "set -u",
    'cd "$HOME" || exit 1',
    "openbox --sm-disable &",
    "wm=$!",
    "xterm -title Terminal -geometry 120x36+60+60 -fa Monospace -fs 11 -bg '#1d1f21' -fg '#c5c8c6' &",
    'wait "$wm"',
    'echo "<3>cmux-agent-desktop-session: openbox exited on $DISPLAY" >&2',
    "exit 1",
    "",
  ].join("\n");
}

/**
 * DESKTOP_CHECK_SCRIPT `[--wait SECONDS]`: prints `windows=N viewable=N nonblack=N` for $DISPLAY
 * (top-level windows, those mapped and viewable, and how many of a sample of the root's pixels are
 * not black) and exits 0 when there is a viewable window and a non-black pixel. Otherwise, after
 * up to SECONDS, it says on stderr at error level that the display is black and exits 1.
 */
export function desktopCheckScript(): string {
  return `#!/usr/bin/python3 -I
# cmux VM agent tools (images/cmux-vm, managed, do not edit): fails loudly when $DISPLAY shows nothing.
${X11_CLIENT_PY}
import time

def look(sock, root, width, height):
    sock.sendall(struct.pack("<BxHI", 15, 2, root))
    r = reply(sock)
    (n,) = struct.unpack_from("<H", r, 16)
    children = struct.unpack_from("<%dI" % n, r, 32)
    viewable = 0
    for w in children:
        sock.sendall(struct.pack("<BxHI", 3, 2, w))
        if reply(sock)[26] == 2:
            viewable += 1
    nonblack = 0
    rows = 8
    for i in range(rows):
        y = (2 * i + 1) * height // (2 * rows)
        sock.sendall(struct.pack("<BBHIhhHHI", 73, 2, 5, root, 0, y, width, 1, 0xFFFFFFFF))
        line = reply(sock)[32:32 + 4 * width]
        nonblack += sum(1 for (p,) in struct.iter_unpack("<I", line) if p & 0xFFFFFF)
    return n, viewable, nonblack

def main():
    wait = float(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[1] == "--wait" else 0.0
    sock, root, width, height = connect()
    deadline = time.monotonic() + wait
    while True:
        n, viewable, nonblack = look(sock, root, width, height)
        if (viewable and nonblack) or time.monotonic() >= deadline:
            break
        time.sleep(0.5)
    print("windows=%d viewable=%d nonblack=%d size=%dx%d" % (n, viewable, nonblack, width, height))
    if not (viewable and nonblack):
        print("<3>cmux-agent-desktop-check: display %s shows a black screen: %d window(s), %d viewable, no lit pixel after %ds" % (os.environ["DISPLAY"], n, viewable, wait), file=sys.stderr)
        sys.exit(1)

main()
`;
}

/**
 * DESKTOP_SESSION_SCRIPT as the work user on the agent display. BindsTo the display: it stops with
 * it, and the next desktop connection starts both again. ExecStartPost is the check: a session that
 * shows no window within DESKTOP_CHECK_SECONDS fails the unit with an error-level journal line, and
 * after 5 such starts in 2 minutes the unit stays failed.
 */
export function desktopSessionUnit(): string {
  return [
    "[Unit]",
    `Description=cmux agent desktop session (openbox and a terminal) on the agent display ${AGENT_DISPLAY}, started with the remote desktop host`,
    `BindsTo=${DISPLAY_UNIT}`,
    `After=${DISPLAY_UNIT}`,
    "StartLimitIntervalSec=120",
    "StartLimitBurst=5",
    "",
    "[Service]",
    "Type=simple",
    `User=${DEVBOX_WORK_USER}`,
    `Group=${DEVBOX_WORK_USER}`,
    `Environment=HOME=${DEVBOX_WORK_HOME}`,
    `Environment=DISPLAY=${AGENT_DISPLAY}`,
    `Environment=XAUTHORITY=${AGENT_XAUTHORITY}`,
    `ExecStart=${DESKTOP_SESSION_SCRIPT}`,
    `ExecStartPost=${DESKTOP_CHECK_SCRIPT} --wait ${DESKTOP_CHECK_SECONDS}`,
    "Restart=on-failure",
    "RestartSec=2",
    "",
  ].join("\n");
}

/**
 * DESKTOP_STARTER: run by the cmux-tui daemon as the work user (who has sudo for the units), with
 * the daemon's environment. It starts the shared display (required: no display, no desktop) and its
 * AT-SPI bus (optional: without it the worker still has screenshots and X11 input), then prints the
 * worker's variables, one KEY=VALUE per line; what it says on stderr is the reason the launcher
 * gives when it fails.
 */
export function desktopStarterScript(x11Dir = "/tmp/.X11-unix"): string {
  const bus = `${a11yRuntimeDir(AGENT_DISPLAY_NUMBER)}/bus`;
  return [
    "#!/bin/sh",
    "# cmux VM agent tools (images/cmux-vm, managed, do not edit): the agent display for cmux Computer Use.",
    "# cmux-tui's worker launcher runs this when its daemon has no display; it prints the worker's variables.",
    `sudo -n systemctl start ${DISPLAY_UNIT} >&2 || { echo "cmux: the agent display did not start (systemctl status ${DISPLAY_UNIT})" >&2; exit 1; }`,
    `[ -S ${x11Dir}/X${AGENT_DISPLAY_NUMBER} ] || { echo "cmux: the agent display ${AGENT_DISPLAY} has no socket" >&2; exit 1; }`,
    `echo DISPLAY=${AGENT_DISPLAY}`,
    `echo XAUTHORITY=${AGENT_XAUTHORITY}`,
    // Nobody shares this display: the worker never waits for a person's input on it.
    "echo CMUX_CU_HEADLESS=1",
    // Role cua-video stays off for the driver: sudo, apt, apt-get, ffmpeg and ffprobe refuse first, and no setuid program works.
    `echo "PATH=${CUA_REFUSE_DIR}:$PATH"`,
    `echo ${NO_NEW_PRIVS_ENV}=1`,
    `if sudo -n systemctl start ${A11Y_UNIT} >&2; then echo DBUS_SESSION_BUS_ADDRESS=unix:path=${bus}; else echo "cmux: the AT-SPI bus did not start (systemctl status ${A11Y_UNIT}); accessibility trees stay empty" >&2; fi`,
    "",
  ].join("\n");
}

/** A refusing stand-in for `name` on the driver's PATH (see CUA_REFUSE_DIR). */
export function cuaRefuseScript(name: string): string {
  return [
    "#!/bin/sh",
    "# cmux VM agent tools (images/cmux-vm, managed, do not edit).",
    `echo "cmux: '${name} $*' is refused for the computer-use driver on this machine. Role cua-video is off for computer use on cmux machines, so install_ffmpeg and video recording are not available to it; screenshots still work." >&2`,
    "exit 1",
    "",
  ].join("\n");
}

/**
 * `cmux-cua serve` on the agent display, as the work user, on its default socket, with the
 * display's AT-SPI session bus: cmux-cua reads trees and types through AT-SPI there, and the apps
 * it launches inherit the bus. `Wants`, not `Requires`: a bus that fails to start leaves the
 * driver running with screenshots and X11 input.
 */
export function cuaUnit(): string {
  return [
    "[Unit]",
    "Description=cmux agent computer use (cmux-cua serve on the agent display), started on demand",
    `Requires=${DISPLAY_UNIT}`,
    `Wants=${A11Y_UNIT}`,
    `After=${DISPLAY_UNIT} ${A11Y_UNIT}`,
    "",
    "[Service]",
    "Type=simple",
    `User=${DEVBOX_WORK_USER}`,
    `Group=${DEVBOX_WORK_USER}`,
    `Environment=HOME=${DEVBOX_WORK_HOME}`,
    `Environment=DISPLAY=${AGENT_DISPLAY}`,
    `Environment=XAUTHORITY=${AGENT_XAUTHORITY}`,
    `Environment=XDG_RUNTIME_DIR=${a11yRuntimeDir(AGENT_DISPLAY_NUMBER)}`,
    `Environment=DBUS_SESSION_BUS_ADDRESS=unix:path=${a11yRuntimeDir(AGENT_DISPLAY_NUMBER)}/bus`,
    `Environment=PATH=${CUA_REFUSE_DIR}:${CURRENT_BIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`,
    "NoNewPrivileges=yes",
    "Environment=CMUX_CUA_TELEMETRY_ENABLED=false",
    "Environment=CMUX_CUA_UPDATE_CHECK=false",
    `ExecStart=${CURRENT_BIN}/cmux-cua serve`,
    `ExecStartPost=${waitForSocket(CUA_SOCKET)}`,
    "Restart=on-failure",
    "RestartSec=2",
    "",
  ].join("\n");
}

/** The remote desktop host's system user: no shell, no home, not in the work user's group, no sudo. */
export const RD_USER = "cmux-rd";
export const RD_SOCKET_UNIT = "cmux-agent-rd.socket";
export const RD_UNIT = "cmux-agent-rd.service";
/** Cisco's OpenH264 into the host's state dir, once: its own unit, so only it may open network sockets. */
export const RD_OPENH264_UNIT = "cmux-agent-rd-openh264.service";
/** The largest display cookie the host accepts (one MIT-MAGIC-COOKIE-1 entry is about 50 bytes). */
export const RD_XAUTHORITY_MAX_BYTES = 4096;
/** The socket's dir: 0711 root:root, so the work user can reach the socket by name and list nothing. */
export const RD_RUN_DIR = "/run/cmux-rd";
/** The socket the link receiver (as the work user) connects for link service `desktop`: 0660 root:work user. */
export const RD_SOCKET = `${RD_RUN_DIR}/desktop.sock`;
/** The only uid the host accepts a connection from (SO_PEERCRED): the work user's, which the link receiver runs as. */
export const RD_PEER_UID = DEVBOX_WORK_UID;
/** The host's own runtime dir (RuntimeDirectory, RD_USER 0700, removed when the host stops): the cookie copy lives here. */
export const RD_HOST_DIR = "/run/cmux-rd-host";
/** The host's copy of the agent display's cookie (RD_USER 0600), made at each host start. */
export const RD_XAUTHORITY = `${RD_HOST_DIR}/Xauthority-${AGENT_DISPLAY_NUMBER}`;
/**
 * The STUN server the cmux-rd host asks for its reflexive address when a session negotiates the
 * UDP datagram link (cap link.udp, cmux-rd 0.2.3+). It resolves only then, so a host with no
 * session holds no UDP socket; an unresolvable name leaves the link to host and relay candidates.
 */
export const RD_LINK_STUN = "stun.cloudflare.com:3478";
/** StateDirectory: HOME and XDG_DATA_HOME of the host, where `cmux-rd openh264-install` puts Cisco's library. */
export const RD_STATE_DIR = "/var/lib/cmux-rd";
/** Written after the first successful `cmux-rd openh264-install`, so later starts skip the download. */
export const RD_OPENH264_MARKER = `${RD_STATE_DIR}/openh264-installed`;
export const RD_TMPFILES = "/etc/tmpfiles.d/cmux-rd.conf";
/** The host unit's ExecStart (rdStartScript): checks the host's preconditions, then execs the host or closes the queued connection. */
export const RD_START_SCRIPT = `${AGENT_TOOLS_DIR}/cmux-rd-start`;
const RD_PROGRAM = "cmux-rd";
const DESKTOP_ROLE = "desktop";

/**
 * The cmux-rd binary in the store, from its lock entry. A lock without one (the release
 * `cmux-rd-v<V>` is not pinned yet) fails the agent tools bake here, before any file is written.
 */
export function rdHostPath(lock: InputsLock): string {
  const program = lock.programs.find((p) => p.name === RD_PROGRAM);
  if (!program || !(program.roles ?? []).includes(DESKTOP_ROLE) || !program.bin[RD_PROGRAM]) {
    throw new Error(
      "agent tools need cmux-rd in the lock (role desktop): pin the manaflow-ai/cmux release cmux-rd-v<version> " +
        "(cmux-rd-<version>-x86_64-unknown-linux-gnu.tar.gz and checksums.txt, lock.ts cmuxRdReleaseShape) in images/cmux-vm/inputs.lock.json",
    );
  }
  return `${storeEntry(program.sha256)}/${program.bin[RD_PROGRAM]}`;
}

/** Creates RD_RUN_DIR at boot before sockets.target (the socket unit's DirectoryMode makes the same). */
export function rdTmpfiles(): string {
  return `# cmux VM agent tools (images/cmux-vm, managed, do not edit): the remote desktop socket dir.\nd ${RD_RUN_DIR} 0711 root root -\n`;
}

/**
 * The socket of link service `desktop`: root-owned, group the work user (the link receiver runs as
 * it), 0660. Enabled at boot; nothing runs until the receiver connects.
 */
export function rdSocketUnit(): string {
  return [
    "[Unit]",
    `Description=cmux remote desktop of the agent display ${AGENT_DISPLAY} (cmux.rd/1): the link receiver's socket for service desktop`,
    "",
    "[Socket]",
    `ListenStream=${RD_SOCKET}`,
    "SocketUser=root",
    `SocketGroup=${DEVBOX_WORK_USER}`,
    "SocketMode=0660",
    "DirectoryMode=0711",
    "Accept=no",
    `Service=${RD_UNIT}`,
    "",
    "[Install]",
    "WantedBy=sockets.target",
    "",
  ].join("\n");
}

/**
 * Before the host starts, as root (`+`, outside the sandbox), in RD_HOST_DIR (RuntimeDirectory,
 * made by systemd before this runs): a bounded wait for the display's X socket (the display unit writes its cookie before Xvfb
 * starts), then the cookie copied for RD_USER. The source is in the work user's home, which the
 * agent controls, so root never opens it: it is read as the work user with no groups and no
 * capabilities (a symlink can only reach what that user can already read), only when it is a
 * regular file, bounded in time and size, into a root-only temp file in RD_HOST_DIR that is then
 * handed to RD_USER and renamed into place. The display makes a new cookie at each start, and
 * BindsTo restarts the host with it, so each start copies it again.
 */
export function rdCookieCopy(): string {
  const src = AGENT_XAUTHORITY;
  const x11 = `/tmp/.X11-unix/X${AGENT_DISPLAY_NUMBER}`;
  const tmp = `${RD_XAUTHORITY}.new`;
  const asWorkUser = `setpriv --reuid=${DEVBOX_WORK_USER} --regid=${DEVBOX_WORK_USER} --clear-groups --inh-caps=-all --bounding-set=-all --no-new-privs`;
  const fail = (why: string) => `{ echo "${why}" >&2; rm -f ${tmp}; exit 1; }`;
  // RD_HOST_DIR belongs to RD_USER, so root's writes there never follow a link: the temp file is
  // created exclusively (noclobber), chowned without following links, and 0600 from the umask.
  return [
    "umask 077",
    "set -C",
    // No `%` here: systemd expands specifiers in Exec lines.
    `test -d ${RD_HOST_DIR} && test ! -L ${RD_HOST_DIR} && test -n "$(find ${RD_HOST_DIR} -maxdepth 0 -user ${RD_USER} -perm 0700)" || ${fail(`${RD_HOST_DIR} is not the runtime dir of ${RD_USER}`)}`,
    `for i in $(seq 1 100); do [ -S ${x11} ] && break; sleep 0.1; done`,
    `[ -S ${x11} ] || ${fail(`no socket ${x11} for display ${AGENT_DISPLAY}`)}`,
    `rm -f ${tmp}`,
    `timeout 5 ${asWorkUser} /bin/sh -c "test -f ${src} && test ! -L ${src} && head -c ${RD_XAUTHORITY_MAX_BYTES + 1} ${src}" > ${tmp} || ${fail(`the display cookie is not a regular file ${DEVBOX_WORK_USER} can read`)}`,
    `test -s ${tmp} && test "$(wc -c < ${tmp})" -le ${RD_XAUTHORITY_MAX_BYTES} || ${fail(`the display cookie is empty or larger than ${RD_XAUTHORITY_MAX_BYTES} bytes`)}`,
    `chown -h ${RD_USER}:${RD_USER} ${tmp} && mv -f ${tmp} ${RD_XAUTHORITY}`,
  ].join("; ");
}

/** The sandbox both RD_USER units share. */
const RD_SANDBOX = [
  "NoNewPrivileges=yes",
  "CapabilityBoundingSet=",
  "AmbientCapabilities=",
  "ProtectHome=yes",
  "ProtectSystem=strict",
  "PrivateTmp=yes",
  "PrivateDevices=yes",
  "ProtectKernelTunables=yes",
  "ProtectKernelModules=yes",
  "ProtectKernelLogs=yes",
  "ProtectControlGroups=yes",
  "ProtectClock=yes",
  "ProtectHostname=yes",
  "RestrictNamespaces=yes",
  "RestrictRealtime=yes",
  "RestrictSUIDSGID=yes",
  "LockPersonality=yes",
] as const;

/**
 * `cmux-rd openh264-install` as RD_USER into its state dir, once (the marker): Cisco's binary,
 * downloaded over HTTPS from Cisco, never bundled. The host itself opens no TCP socket, and UDP
 * only for a session's datagram link (rdUnit).
 */
export function rdOpenh264Unit(hostBin: string): string {
  return [
    "[Unit]",
    "Description=cmux remote desktop host: Cisco's OpenH264 into its state dir (first start only)",
    `ConditionPathExists=!${RD_OPENH264_MARKER}`,
    "",
    "[Service]",
    "Type=oneshot",
    `User=${RD_USER}`,
    `Group=${RD_USER}`,
    `Environment=HOME=${RD_STATE_DIR}`,
    `Environment=XDG_DATA_HOME=${RD_STATE_DIR}`,
    `StateDirectory=${RD_USER}`,
    "StateDirectoryMode=0700",
    `ExecStart=${hostBin} openh264-install`,
    `ExecStartPost=/usr/bin/touch ${RD_OPENH264_MARKER}`,
    "TimeoutStartSec=120",
    ...RD_SANDBOX,
    // HTTPS to Cisco (and the resolver).
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK",
    "",
  ].join("\n");
}

/**
 * RD_START_SCRIPT, the host unit's ExecStart, as RD_USER. With `Accept=no` systemd starts the
 * host for a connection the host has not accepted yet; a start that fails before the accept would
 * leave it queued, and systemd would start the host again for it at once (fast failures run into
 * the socket's trigger limit and leave the socket failed; slow ones, a failed OpenH264 download or
 * a display that does not start, retry forever). So every start takes its connection: the script
 * checks what the host needs (the display's X socket, the cookie copy, OpenH264) and, if one is
 * missing, accepts every queued connection on the passed socket, closes it, logs why and exits 1;
 * otherwise it execs the host, which keeps the pid systemd passed the socket to (LISTEN_PID).
 * Each connection then costs at most one attempt, an OpenH264 download included.
 */
export function rdStartScript(
  hostBin: string,
  paths: { x11Socket?: string; xauthority?: string; openh264Marker?: string } = {},
): string {
  const x11 = paths.x11Socket ?? `/tmp/.X11-unix/X${AGENT_DISPLAY_NUMBER}`;
  const xauthority = paths.xauthority ?? RD_XAUTHORITY;
  const marker = paths.openh264Marker ?? RD_OPENH264_MARKER;
  const drainPy = [
    "import socket, sys",
    "s = socket.socket(fileno=3)",
    "s.setblocking(False)",
    "n = 0",
    "while True:",
    "    try:",
    "        c, _ = s.accept()",
    // Any accept error ends the drain (EAGAIN: none queued; EMFILE and the like: nothing more can be taken).
    "    except OSError:",
    "        break",
    "    c.close()",
    "    n += 1",
    "s.detach()",
    "print(n)",
  ].join("\n");
  return [
    "#!/bin/sh",
    "# cmux VM agent tools (images/cmux-vm, managed, do not edit): starts the cmux-rd host for a",
    `# connection to ${RD_SOCKET}, or closes the connection when the host cannot start.`,
    "set -u",
    'if [ "${LISTEN_FDS:-0}" != 1 ] || [ "${LISTEN_PID:-}" != "$$" ]; then echo "cmux-rd-start: no socket from systemd" >&2; exit 1; fi',
    "drain() {",
    `  n=$(/usr/bin/python3 -I -c ${sq(drainPy)})`,
    '  echo "cmux-rd-start: $1; closed ${n:-0} queued desktop connection(s)" >&2',
    "  exit 1",
    "}",
    `[ -S ${sq(x11)} ] || drain "display ${AGENT_DISPLAY} is not running"`,
    `[ -s ${sq(xauthority)} ] || drain "no copy of the display cookie at ${xauthority}"`,
    `[ -e ${sq(marker)} ] || drain "OpenH264 is not installed (${RD_OPENH264_UNIT} failed; the next connection tries again)"`,
    // The host streams whatever the display shows; when the desktop session never puts a window on it,
    // the host's own journal says so at error level (the check's stderr), next to the session unit's failure.
    `( XAUTHORITY=${sq(xauthority)} DISPLAY=${AGENT_DISPLAY} ${DESKTOP_CHECK_SCRIPT} --wait ${DESKTOP_CHECK_SECONDS + 10} >/dev/null || echo "<3>cmux-rd-start: display ${AGENT_DISPLAY} has no windows; the viewer sees a black screen (systemctl status ${DESKTOP_SESSION_UNIT})" >&2 ) &`,
    `exec ${sq(hostBin)} host --listen-systemd --peer-uid ${RD_PEER_UID} --display ${AGENT_DISPLAY} --xauthority ${RD_XAUTHORITY} --codec openh264 --link-stun ${RD_LINK_STUN}`,
    "",
  ].join("\n");
}

/**
 * The cmux-rd host's unit, started by a connection to RD_SOCKET (an fd from systemd; each
 * connection's SO_PEERCRED uid must be RD_PEER_UID, the work user the link receiver runs as), as
 * RD_USER, with no capabilities and Unix sockets only. ProtectHome keeps /home out of reach (the
 * cookie copy runs outside the sandbox); /tmp is private but for the X11 socket dir.
 *
 * Nothing before RD_START_SCRIPT may fail the start, or the connection stays queued (see there):
 * no unit the host depends on is ordered before it with a requirement (a failed dependency would
 * fail the start job before RD_START_SCRIPT runs), and the cookie copy's failure is ignored (`-`);
 * RD_START_SCRIPT finds what is missing and closes the connection.
 *
 * The display is BindsTo without After. BindsTo pulls it in at start and stops the host whenever
 * the display goes inactive or failed, for any reason: a stop, a restart, or a crash (systemd's
 * default RestartMode=normal takes a crashed Xvfb through failed before its Restart=on-failure
 * brings it back). The host never outlives the cookie it copied; the next connection starts it
 * again with a fresh copy. Without After, a display that fails to start does not fail the host's
 * start job; the cookie copy waits (bounded) for the display's X socket, which orders a normal
 * start, and RD_START_SCRIPT closes the connection when the display never came up.
 */
export function rdUnit(): string {
  return [
    "[Unit]",
    `Description=cmux remote desktop host (cmux-rd, cmux.rd/1) on the agent display ${AGENT_DISPLAY}, started by a connection to its socket`,
    // No After= on the display (see above): BindsTo for the lifetime, not for the start.
    `BindsTo=${DISPLAY_UNIT}`,
    // OpenH264 first, but its failure does not fail the start (the marker check in RD_START_SCRIPT).
    `Wants=${RD_OPENH264_UNIT}`,
    // The person's desktop on the display, so a viewer never streams an empty root window. Wants
    // without After: the host does not wait for it, and a session that fails its check fails
    // loudly on its own (desktopSessionUnit) without failing the host's start.
    `Wants=${DESKTOP_SESSION_UNIT}`,
    `After=${RD_OPENH264_UNIT} ${RD_SOCKET_UNIT}`,
    `Requires=${RD_SOCKET_UNIT}`,
    // Every start takes its connection (RD_START_SCRIPT), so systemd never starts the host again
    // for a queued one, and a run of failed starts must not trip a start limit that would leave
    // the socket failed (service-start-limit-hit). Starts are bounded by the connections the link
    // admits.
    "StartLimitIntervalSec=0",
    "",
    "[Service]",
    "Type=simple",
    `User=${RD_USER}`,
    `Group=${RD_USER}`,
    `Environment=HOME=${RD_STATE_DIR}`,
    `Environment=XDG_DATA_HOME=${RD_STATE_DIR}`,
    `Environment=DISPLAY=${AGENT_DISPLAY}`,
    `Environment=XAUTHORITY=${RD_XAUTHORITY}`,
    `StateDirectory=${RD_USER}`,
    "StateDirectoryMode=0700",
    `RuntimeDirectory=${RD_HOST_DIR.slice("/run/".length)}`,
    "RuntimeDirectoryMode=0700",
    // `-`: a failed copy leaves no cookie, and RD_START_SCRIPT closes the connection.
    `ExecStartPre=-+/bin/sh -c '${rdCookieCopy()}'`,
    `ExecStart=${RD_START_SCRIPT}`,
    ...RD_SANDBOX,
    "BindReadOnlyPaths=/tmp/.X11-unix",
    // The activated socket and the X display are Unix sockets. AF_INET is the desktop's datagram
    // link (cmuxterm-hq#7976): one ephemeral UDP socket per session the viewer offered a link for,
    // reached only by that viewer's authenticated link, never a listening port; AF_NETLINK lists the
    // interfaces for its host routes. Without them the host keeps every datagram on the stream.
    "RestrictAddressFamilies=AF_UNIX AF_INET AF_NETLINK",
    "",
  ].join("\n");
}

/**
 * The host's user, its run dir and socket: RD_USER (system, no home, nologin, in no group but its
 * own), then the socket enabled and listening (in the snapshot too) with the host not running.
 */
export function rdSetupCommand(): string {
  const units = [RD_SOCKET_UNIT, RD_UNIT, RD_OPENH264_UNIT, DESKTOP_SESSION_UNIT].map((u) => `/etc/systemd/system/${u}`).join(" ");
  return [
    `{ id -u ${RD_USER} >/dev/null 2>&1 || useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin ${RD_USER}; }`,
    `test "$(id -nG ${RD_USER})" = ${RD_USER}`,
    `test "$(getent passwd ${RD_USER} | cut -d: -f7)" = /usr/sbin/nologin`,
    `test ! -e /nonexistent`,
    `sudo -l -U ${RD_USER} 2>&1 | grep -q 'not allowed'`,
    `! id -nG ${DEVBOX_WORK_USER} | tr ' ' '\\n' | grep -qx ${RD_USER}`,
    `systemd-tmpfiles --create ${RD_TMPFILES}`,
    `test "$(stat -c '%a %U %G' ${RD_RUN_DIR})" = '711 root root'`,
    `test "$(id -u ${DEVBOX_WORK_USER})" = ${RD_PEER_UID}`,
    // The start script's drain runs python3; without it a failed start could not close its connection.
    `sh -n ${RD_START_SCRIPT} && test -x ${RD_START_SCRIPT} && test -x /usr/bin/python3`,
    // The desktop session's programs (role display-wm, baked by displayWmBakePhases) and its scripts.
    `command -v openbox >/dev/null && command -v xterm >/dev/null && sh -n ${DESKTOP_SESSION_SCRIPT} && test -x ${DESKTOP_SESSION_SCRIPT}`,
    `python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' ${DESKTOP_CHECK_SCRIPT} && test -x ${DESKTOP_CHECK_SCRIPT}`,
    `systemd-analyze verify ${units}`,
    "systemctl daemon-reload",
    `command -v setpriv >/dev/null`,
    `systemctl enable --now --quiet ${RD_SOCKET_UNIT}`,
    `test -S ${RD_SOCKET} && test "$(stat -c '%a %U %G' ${RD_SOCKET})" = '660 root ${DEVBOX_WORK_USER}'`,
    `! systemctl is-active --quiet ${RD_UNIT}`,
    `! systemctl is-active --quiet ${RD_OPENH264_UNIT}`,
    `! systemctl is-active --quiet ${DESKTOP_SESSION_UNIT}`,
    `echo agent-desktop-ready`,
  ].join(" && ");
}

/** Login shells (ssh) get the same lookup dir as daemon terminals. */
export function agentToolsProfileScript(chromium?: string): string {
  const lines = ["# cmux VM agent tools (images/cmux-vm). Managed, do not edit.", `export CMUX_AGENT_TOOLS_BIN_DIR=${AGENT_TOOLS_BIN}`];
  // The baked browser is a store path only the daemon env named; agents and Playwright look on PATH or in these variables.
  if (chromium) lines.push(`export CHROME_BIN=${chromium}`, `export CHROME_PATH=${chromium}`);
  return `${lines.join("\n")}\n`;
}

/** Names agents, Playwright (channel "chrome") and scripts look for the browser under; each links to the baked Chrome. */
export const BROWSER_LINKS = ["/usr/local/bin/chromium", "/usr/local/bin/chromium-browser", "/usr/local/bin/chrome", "/usr/local/bin/google-chrome", "/opt/google/chrome/chrome"] as const;

/** Links the browser under BROWSER_LINKS and runs it headless once (as the work user): the image build's browser smoke. */
export function browserLinkCommand(chromium: string): string {
  return [
    `test -x ${sq(chromium)}`,
    "install -d -m 0755 /opt/google/chrome",
    ...BROWSER_LINKS.map((l) => `ln -sfn ${sq(chromium)} ${l}`),
    `sudo -n -u ${DEVBOX_WORK_USER} -H sh -c 'chromium --version && chromium --headless=new --disable-gpu --user-data-dir=$(mktemp -d) --dump-dom "data:text/html,<title>cmux</title><h1>ok</h1>" 2>/dev/null | grep -q "<h1>ok</h1>"'`,
    "echo browser-linked",
  ].join(" && ");
}

/** Build-time smoke of the tools Cloud machines promise: each runs once, so a missing or broken one fails the bake. */
export function imageToolsSmokeCommand(): string {
  return [
    `test "$(echo '2^10 + 1' | bc)" = 1025`,
    "command -v chromium >/dev/null && chromium --version >/dev/null",
    "echo image-tools-ok",
  ].join(" && ");
}

/**
 * The work user's cmux.json when it has none: the cmux MCP server on (browser_repl_* tools), and the
 * machine's yes to it in the agents cmux starts (acpmux agent_tools.rs AGENTS_CMUX_MCP_KEY).
 */
export const WORK_USER_CMUX_JSON_TEXT = `${JSON.stringify({ mcp: { enabled: true }, agents: { cmuxMcp: "on" } }, null, 2)}\n`;

/** Links the tool dir and writes cmux.json; the wrapper and units are written as files first (installFiles). */
export function agentToolsLinkCommand(chromium?: string): string {
  const configDir = WORK_USER_CMUX_JSON.slice(0, WORK_USER_CMUX_JSON.lastIndexOf("/"));
  return [
    ...(chromium ? [browserLinkCommand(chromium)] : []),
    `install -d -m 0755 ${AGENT_TOOLS_BIN}`,
    `ln -sfn ${CURRENT_BIN}/cmux-tui ${AGENT_TOOLS_BIN}/cmux`,
    `test -x ${AGENT_TOOLS_BIN}/cmux && test -x ${AGENT_TOOLS_BIN}/cmux-cua && test -x ${CURRENT_BIN}/cmux-cua`,
    `sh -n ${DESKTOP_STARTER} && test "$(stat -c '%U:%G %a' ${DESKTOP_STARTER} /etc/cmux | tr '\\n' ' ')" = 'root:root 755 root:root 755 '`,
    `bash -n ${A11Y_SCRIPT} && python3 -I -c 'import ast, sys; ast.parse(open(sys.argv[1]).read())' ${ROOT_PROPERTY_SCRIPT} && test -x ${AT_SPI_BUS_LAUNCHER} && command -v dbus-daemon >/dev/null && command -v dbus-send >/dev/null`,
    `install -d -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${DEVBOX_WORK_HOME}/.config ${configDir}`,
    `if [ ! -e ${WORK_USER_CMUX_JSON} ]; then printf '%s' ${sq(WORK_USER_CMUX_JSON_TEXT)} > ${WORK_USER_CMUX_JSON} && chown ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${WORK_USER_CMUX_JSON}; fi`,
    "systemctl daemon-reload",
    `! systemctl is-active --quiet ${DISPLAY_UNIT} && ! systemctl is-active --quiet ${CUA_UNIT}`,
    `${AGENT_TOOLS_BIN}/cmux --version`,
    "echo agent-tools-linked",
  ].join(" && ");
}

/** Files the install writes (path, text, mode). Throws when the lock has no cmux-rd (rdHostPath). */
export function agentToolsFiles(lock: InputsLock): Array<{ path: string; text: string; mode: number }> {
  const rd = rdHostPath(lock);
  return [
    { path: `${AGENT_TOOLS_BIN}/cmux-cua`, text: cuaWrapperScript(), mode: 0o755 },
    { path: DESKTOP_STARTER, text: desktopStarterScript(), mode: 0o755 },
    { path: `/etc/systemd/system/${CUA_UNIT}`, text: cuaUnit(), mode: 0o644 },
    { path: `/etc/systemd/system/${DISPLAY_TEMPLATE_UNIT}`, text: displayTemplateUnit(), mode: 0o644 },
    { path: `/etc/systemd/system/${A11Y_TEMPLATE_UNIT}`, text: a11yTemplateUnit(), mode: 0o644 },
    { path: A11Y_SCRIPT, text: a11yScript(), mode: 0o755 },
    { path: ROOT_PROPERTY_SCRIPT, text: rootPropertyScript(), mode: 0o755 },
    { path: AGENT_TOOLS_PROFILE, text: agentToolsProfileScript(browserHostPaths(rolesManifest(lock)).chromium), mode: 0o644 },
    { path: RD_TMPFILES, text: rdTmpfiles(), mode: 0o644 },
    { path: `/etc/systemd/system/${RD_SOCKET_UNIT}`, text: rdSocketUnit(), mode: 0o644 },
    { path: `/etc/systemd/system/${RD_UNIT}`, text: rdUnit(), mode: 0o644 },
    { path: RD_START_SCRIPT, text: rdStartScript(rd), mode: 0o755 },
    { path: `/etc/systemd/system/${RD_OPENH264_UNIT}`, text: rdOpenh264Unit(rd), mode: 0o644 },
    { path: `/etc/systemd/system/${DESKTOP_SESSION_UNIT}`, text: desktopSessionUnit(), mode: 0o644 },
    { path: DESKTOP_SESSION_SCRIPT, text: desktopSessionScript(), mode: 0o755 },
    { path: DESKTOP_CHECK_SCRIPT, text: desktopCheckScript(), mode: 0o755 },
    ...CUA_REFUSED.map((name) => ({ path: `${CUA_REFUSE_DIR}/${name}`, text: cuaRefuseScript(name), mode: 0o755 })),
  ];
}

/** The names an agent types for a headless browser (`chromium --headless`), on every PATH. */
export const BROWSER_PATH_NAMES = ["chromium", "chromium-browser", "google-chrome"] as const;

/**
 * Links the baked Chrome for Testing into /usr/local/bin under the names agents look for. Without
 * them the image carried Chrome only at its store path (the browser host's env), and an agent's
 * `command -v chromium` found nothing (the AutoCloud proof's missing browser).
 */
export function browserPathCommand(chrome: string): string {
  return [
    `test -x ${sq(chrome)}`,
    ...BROWSER_PATH_NAMES.map((name) => `ln -sfn ${sq(chrome)} /usr/local/bin/${name}`),
    "chromium --version",
  ].join(" && ");
}

/** The role whose closure the desktop session runs (openbox, xterm), baked with the agent tools. */
export const DISPLAY_WM_ROLE = "display-wm";
/** The first-use roles the agent tools bake in: their closures are installed, not refused (bake.ts refusedFirstUsePackages). */
export const AGENT_TOOLS_BAKED_ROLES = [BROWSER_ROLE, DISPLAY_WM_ROLE] as const;

/**
 * The browser role's and role display-wm's first-use installs at bake (each closure's .debs by
 * content, then programs), then the fetched files go.
 */
export function browserRoleBakePhases(lock: InputsLock): Array<{ name: string; command: string }> {
  const manifest = rolesManifest(lock);
  return [
    ...firstUseInstallPhases(manifest, BROWSER_ROLE).map((p) => ({ name: `agent-tools-browser-${p.name}`, command: p.command })),
    ...firstUseInstallPhases(manifest, DISPLAY_WM_ROLE).map((p) => ({ name: `agent-tools-display-wm-${p.name}`, command: p.command })),
    { name: "agent-tools-browser-path", command: browserPathCommand(browserHostPaths(manifest).chromium) },
    { name: "agent-tools-browser-lists", command: "rm -rf /var/lib/cmux/apt-snapshot && echo browser-role-baked" },
  ];
}

/** systemd `Environment=` lines for agentToolsDaemonEnv (values carry no spaces or quotes). */
export function daemonEnvLines(env: Readonly<Record<string, string>>): string[] {
  return Object.entries(env).map(([key, value]) => {
    if (/[\s"'\\]/.test(value)) throw new Error(`daemon env ${key} has a character a unit line cannot carry`);
    return `Environment=${key}=${value}`;
  });
}
