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
 * - Computer use: acpmux starts `cmux-cua mcp` with CMUX_CUA_MCP_FORCE_PROXY=1, which on
 *   Linux needs a running `cmux-cua serve`. The wrapper starts CUA_UNIT (and through it
 *   DISPLAY_UNIT, Xvfb on AGENT_DISPLAY) before it execs the real proxy, so the display and
 *   the driver run only once an agent session asks for computer use (the session host of
 *   cloud-automation.md 16 replaces this stand-in; it then owns display.acquire).
 * - Browser: the browser role is installed at bake (its first-use closure and programs, as
 *   browser-probe.ts installs them), and the daemon unit names the host binary and Chrome.
 *   The daemon socket-activates the host on the first agent connect and the host exits
 *   after 5 idle minutes (cmux-tui-core/src/browser_host.rs), so nothing runs while idle.
 *   Every terminal the daemon creates gets CMUX_BROWSER_HOST_SOCKET; an acpmux daemon
 *   started from such a terminal passes it to `cmux mcp serve`.
 * - `cmux mcp serve` runs only when cmux.json sets `"mcp": {"enabled": true}`. The image
 *   writes that for the work user when the file does not exist (the machine has no app to
 *   ask). The Claude Code permission prompts and acpmux permission policies are unchanged.
 * - Desktop (role desktop): the person's view of the agent display is `cmux.rd/1` over the owner's
 *   Native link, service `desktop`. The boundary is the link's admission: the machine's link
 *   receiver (the session daemon's `__receive-vm`, which runs as the work user) admits only the
 *   owner's one-time link token for `desktop`, then connects RD_SOCKET; systemd starts RD_UNIT,
 *   the `cmux-rd` host on the agent display as its own system user RD_USER (no shell, no home,
 *   not in the work user's group, no sudo), which takes connections from the work user's uid only.
 *   On the machine the socket is not a boundary against the agent: the agent already reaches
 *   `:99` (its own display) and has sudo. It keeps everyone else out, and keeps the host's files
 *   (cookie copy, state) out of the agent's reach. The host exits when idle.
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
 * First on the computer-use driver's PATH: `sudo`, `apt` and `apt-get` that refuse. cmux-cua's
 * install_ffmpeg tool runs `sudo -n apt-get install -y ffmpeg` from the driver; role cua-video
 * (ffmpeg, which pulls libx264) stays off on every machine until Lawrence decides (coordinator
 * legal rule, 2026-10-07). The unit also sets NoNewPrivileges, so no setuid program works there.
 */
export const CUA_REFUSE_DIR = `${AGENT_TOOLS_DIR}/cua-refuse`;
const CUA_REFUSED = ["sudo", "apt", "apt-get"] as const;

const BROWSER_ROLE = "browser";

function browserHostPaths(manifest: RolesManifest): { host: string; chromium: string } {
  const entry = manifest.roles[BROWSER_ROLE];
  const host = entry?.programs.find((p) => p.name === "cmux-browser-host");
  const chromium = entry?.env.CMUX_BROWSER_HOST_CHROMIUM;
  if (!entry || !host || !chromium) throw new Error("agent tools need the browser role with cmux-browser-host and Chrome in the lock");
  return { host: `${host.storeEntry}/${host.bin["cmux-browser-host"]}`, chromium };
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
    `ExecStart=/usr/bin/Xvfb ${display} -screen 0 1280x800x24 -nolisten tcp -auth ${xauthority} -s 0 -dpms${extraArgs}`,
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
import os, socket, struct, sys

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

def main():
    name, value = sys.argv[1].encode(), sys.argv[2].encode()
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
    (root,) = struct.unpack_from("<I", body, 32 + len(pad(b"v" * vendor)) + 8 * body[21])
    sock.sendall(struct.pack("<BBHHxx", 16, 0, 2 + len(pad(name)) // 4, len(name)) + pad(name))
    (atom,) = struct.unpack_from("<I", reply(sock), 8)
    sock.sendall(struct.pack("<BBHIIIB3xI", 18, 0, 6 + len(pad(value)) // 4, root, atom, 31, 8, len(value)) + pad(value))
    sock.sendall(struct.pack("<BxH", 43, 1))
    reply(sock)

main()
`;
}

/** A refusing stand-in for `name` on the driver's PATH (see CUA_REFUSE_DIR). */
export function cuaRefuseScript(name: string): string {
  return [
    "#!/bin/sh",
    "# cmux VM agent tools (images/cmux-vm, managed, do not edit).",
    `echo "cmux: '${name} $*' is refused for the computer-use driver on this machine. Role cua-video (ffmpeg, libx264) is off on cmux machines, so install_ffmpeg and video recording are not available; screenshots still work." >&2`,
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
/** StateDirectory: HOME and XDG_DATA_HOME of the host, where `cmux-rd openh264-install` puts Cisco's library. */
export const RD_STATE_DIR = "/var/lib/cmux-rd";
/** Written after the first successful `cmux-rd openh264-install`, so later starts skip the download. */
export const RD_OPENH264_MARKER = `${RD_STATE_DIR}/openh264-installed`;
export const RD_TMPFILES = "/etc/tmpfiles.d/cmux-rd.conf";
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
 * downloaded over HTTPS from Cisco, never bundled. The only RD_USER unit that may open network
 * sockets; the host itself is AF_UNIX only.
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
 * `cmux-rd host` on the agent display, socket-activated (an fd from systemd; each connection's
 * SO_PEERCRED uid must be RD_PEER_UID, the work user the link receiver runs as), as RD_USER, with no capabilities and Unix
 * sockets only. OpenH264 comes from RD_OPENH264_UNIT, ordered before. ProtectHome keeps
 * /home out of reach (the cookie copy above runs outside the sandbox); /tmp is private but for the
 * X11 socket dir.
 */
export function rdUnit(hostBin: string): string {
  return [
    "[Unit]",
    `Description=cmux remote desktop host (cmux-rd, cmux.rd/1) on the agent display ${AGENT_DISPLAY}, started by a connection to its socket`,
    // BindsTo, not only Requires: a restarted display has a new cookie, so the host restarts with it.
    `BindsTo=${DISPLAY_UNIT}`,
    `After=${DISPLAY_UNIT} ${RD_SOCKET_UNIT}`,
    `Requires=${RD_SOCKET_UNIT}`,
    // A skipped install (the marker exists) is not a failure; a failed first download is.
    `Requires=${RD_OPENH264_UNIT}`,
    `After=${RD_OPENH264_UNIT}`,
    // No start rate limit: a host that hits one puts its socket in failed (service-start-limit-hit),
    // and the desktop stays off until a reset-failed. Each start is one admitted owner connection;
    // a failing host just fails that connection, and the next one tries again.
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
    `ExecStartPre=+/bin/sh -c '${rdCookieCopy()}'`,
    `ExecStart=${hostBin} host --listen-systemd --peer-uid ${RD_PEER_UID} --display ${AGENT_DISPLAY} --xauthority ${RD_XAUTHORITY} --codec openh264`,
    ...RD_SANDBOX,
    "BindReadOnlyPaths=/tmp/.X11-unix",
    // The activated socket and the X display are Unix sockets; the host opens nothing else.
    "RestrictAddressFamilies=AF_UNIX",
    "",
  ].join("\n");
}

/**
 * The host's user, its run dir and socket: RD_USER (system, no home, nologin, in no group but its
 * own), then the socket enabled and listening (in the snapshot too) with the host not running.
 */
export function rdSetupCommand(): string {
  const units = [RD_SOCKET_UNIT, RD_UNIT, RD_OPENH264_UNIT].map((u) => `/etc/systemd/system/${u}`).join(" ");
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
    `systemd-analyze verify ${units}`,
    "systemctl daemon-reload",
    `command -v setpriv >/dev/null`,
    `systemctl enable --now --quiet ${RD_SOCKET_UNIT}`,
    `test -S ${RD_SOCKET} && test "$(stat -c '%a %U %G' ${RD_SOCKET})" = '660 root ${DEVBOX_WORK_USER}'`,
    `! systemctl is-active --quiet ${RD_UNIT}`,
    `! systemctl is-active --quiet ${RD_OPENH264_UNIT}`,
    `echo agent-desktop-ready`,
  ].join(" && ");
}

/** Login shells (ssh) get the same lookup dir as daemon terminals. */
export function agentToolsProfileScript(): string {
  return `# cmux VM agent tools (images/cmux-vm). Managed, do not edit.\nexport CMUX_AGENT_TOOLS_BIN_DIR=${AGENT_TOOLS_BIN}\n`;
}

/** The work user's cmux.json when it has none: the cmux MCP server on (browser_repl_* tools). */
export const WORK_USER_CMUX_JSON_TEXT = `${JSON.stringify({ mcp: { enabled: true } }, null, 2)}\n`;

/** Links the tool dir and writes cmux.json; the wrapper and units are written as files first (installFiles). */
export function agentToolsLinkCommand(): string {
  const configDir = WORK_USER_CMUX_JSON.slice(0, WORK_USER_CMUX_JSON.lastIndexOf("/"));
  return [
    `install -d -m 0755 ${AGENT_TOOLS_BIN}`,
    `ln -sfn ${CURRENT_BIN}/cmux-tui ${AGENT_TOOLS_BIN}/cmux`,
    `test -x ${AGENT_TOOLS_BIN}/cmux && test -x ${AGENT_TOOLS_BIN}/cmux-cua && test -x ${CURRENT_BIN}/cmux-cua`,
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
    { path: `/etc/systemd/system/${CUA_UNIT}`, text: cuaUnit(), mode: 0o644 },
    { path: `/etc/systemd/system/${DISPLAY_TEMPLATE_UNIT}`, text: displayTemplateUnit(), mode: 0o644 },
    { path: `/etc/systemd/system/${A11Y_TEMPLATE_UNIT}`, text: a11yTemplateUnit(), mode: 0o644 },
    { path: A11Y_SCRIPT, text: a11yScript(), mode: 0o755 },
    { path: ROOT_PROPERTY_SCRIPT, text: rootPropertyScript(), mode: 0o755 },
    { path: AGENT_TOOLS_PROFILE, text: agentToolsProfileScript(), mode: 0o644 },
    { path: RD_TMPFILES, text: rdTmpfiles(), mode: 0o644 },
    { path: `/etc/systemd/system/${RD_SOCKET_UNIT}`, text: rdSocketUnit(), mode: 0o644 },
    { path: `/etc/systemd/system/${RD_UNIT}`, text: rdUnit(rd), mode: 0o644 },
    { path: `/etc/systemd/system/${RD_OPENH264_UNIT}`, text: rdOpenh264Unit(rd), mode: 0o644 },
    ...CUA_REFUSED.map((name) => ({ path: `${CUA_REFUSE_DIR}/${name}`, text: cuaRefuseScript(name), mode: 0o755 })),
  ];
}

/** The browser role's first-use install at bake (apt closure from the dated snapshot, then programs), then its apt lists go. */
export function browserRoleBakePhases(lock: InputsLock): Array<{ name: string; command: string }> {
  return [
    ...firstUseInstallPhases(rolesManifest(lock), BROWSER_ROLE).map((p) => ({ name: `agent-tools-browser-${p.name}`, command: p.command })),
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
