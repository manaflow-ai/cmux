/**
 * The devbox desktop contract: what a desktop-kind cmux Cloud machine promises
 * about its screen, shared by the image definition
 * (services/vms/images/devbox/desktop), the bake and verify scripts, the
 * Freestyle driver's port-open path, and the tests that pin all of them.
 *
 * The desktop is a TigerVNC X server (`Xvnc :1`) running an openbox session
 * with a tint2 dock, started and supervised as the work user by the
 * `cmux-desktop` systemd unit (desktop/start-vnc.sh, desktop/cmux-desktop-boot).
 * Two fixed ports carry it: RFB on 5901, loopback only and with no VNC-level
 * auth, and noVNC through websockify on 6901. The Mac app opens the noVNC page
 * (`CmuxTuiSnapshotParser.desktopPort`, CLI `cloudVMDesktopPort`), so these
 * values are a contract with shipped clients, not tunables.
 */

/** The X display the desktop session owns. */
export const DEVBOX_DESKTOP_DISPLAY = ":1";

/** TigerVNC's RFB listener: loopback only, reached through websockify. */
export const DEVBOX_DESKTOP_RFB_PORT = 5901;

/** noVNC (web client + websocket proxy), the port clients open. */
export const DEVBOX_DESKTOP_NOVNC_PORT = 6901;

/** The account the desktop session runs as: the base's uid-1000 work user. */
export const DEVBOX_DESKTOP_USER = "ubuntu";
export const DEVBOX_DESKTOP_HOME = `/home/${DEVBOX_DESKTOP_USER}`;

/** The systemd unit that supervises the desktop on a Freestyle machine. */
export const DEVBOX_DESKTOP_UNIT = "cmux-desktop";

/**
 * Runtime state the desktop session publishes for other processes: the shell
 * env file (DISPLAY, the accessibility bus) sourced by every login and pane
 * shell so browser automation and computer-use land on the screen a person
 * can watch. systemd creates it (`RuntimeDirectory=`) owned by the work user;
 * the container boot supervisor creates it the same way.
 */
export const DEVBOX_DESKTOP_RUNTIME_DIR = "/run/cmux-desktop";
export const DEVBOX_DESKTOP_ENV_FILE = `${DEVBOX_DESKTOP_RUNTIME_DIR}/env`;

/** Default screen size; `CMUX_VNC_GEOMETRY` overrides it. noVNC remote resize grows it live. */
export const DEVBOX_DESKTOP_GEOMETRY = "1440x900";

/** Where the desktop layer installs its entry points (the heal and supervisor contract). */
export const DEVBOX_DESKTOP_START_SCRIPT = "/usr/local/bin/start-vnc.sh";
export const DEVBOX_DESKTOP_SUPERVISOR = "/usr/local/bin/cmux-desktop-boot";

/** The noVNC page for a machine address (an IPv6 literal is bracketed). */
export function devboxDesktopBaseUrl(host: string): string {
  const trimmed = host.trim();
  const literal = trimmed.includes(":") && !trimmed.startsWith("[") ? `[${trimmed}]` : trimmed;
  return `http://${literal}:${DEVBOX_DESKTOP_NOVNC_PORT}/`;
}

/**
 * The noVNC page a pane opens. `path` names websockify's endpoint (noVNC's
 * own default) so the URL carries a query for clients to append their display
 * options to (`autoconnect`, `resize`, `reconnect`).
 */
export function devboxDesktopOpenUrl(host: string): string {
  return `${devboxDesktopBaseUrl(host)}vnc.html?path=websockify`;
}
