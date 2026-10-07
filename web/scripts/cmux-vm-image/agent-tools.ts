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
 */
import { DEVBOX_WORK_HOME, DEVBOX_WORK_USER } from "../../services/vms/images/workUser";
import { firstUseInstallPhases } from "./browser-probe";
import { CURRENT_BIN, type InputsLock, type RolesManifest, rolesManifest, sq } from "./lock";

export const AGENT_TOOLS_DIR = "/opt/cmux/agent-tools";
export const AGENT_TOOLS_BIN = `${AGENT_TOOLS_DIR}/bin`;
export const DISPLAY_UNIT = "cmux-agent-display.service";
export const CUA_UNIT = "cmux-agent-cua.service";
/** One shared display per machine while cmux-cua holds one X11 connection (D-A3). */
export const AGENT_DISPLAY = ":99";
export const AGENT_DISPLAY_DIR = `${DEVBOX_WORK_HOME}/.cache/cmux-display`;
export const AGENT_XAUTHORITY = `${AGENT_DISPLAY_DIR}/Xauthority`;
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

/** Xvfb for computer use, as the work user, X11 over its Unix socket only, with a per-start cookie. */
export function displayUnit(): string {
  const n = AGENT_DISPLAY.slice(1);
  return [
    "[Unit]",
    "Description=cmux agent display (Xvfb) for computer use, started on demand by cmux-cua",
    "",
    "[Service]",
    "Type=simple",
    `User=${DEVBOX_WORK_USER}`,
    `Group=${DEVBOX_WORK_USER}`,
    `Environment=HOME=${DEVBOX_WORK_HOME}`,
    `ExecStartPre=/bin/sh -c 'install -d -m 0700 ${AGENT_DISPLAY_DIR} && rm -f ${AGENT_XAUTHORITY} && xauth -q -f ${AGENT_XAUTHORITY} add ${AGENT_DISPLAY} . "$(mcookie)" && chmod 0600 ${AGENT_XAUTHORITY}'`,
    `ExecStart=/usr/bin/Xvfb ${AGENT_DISPLAY} -screen 0 1280x800x24 -nolisten tcp -auth ${AGENT_XAUTHORITY} -s 0 -dpms`,
    `ExecStartPost=${waitForSocket(`/tmp/.X11-unix/X${n}`)}`,
    "Restart=on-failure",
    "RestartSec=2",
    "",
  ].join("\n");
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

/** `cmux-cua serve` on the agent display, as the work user, on its default socket. */
export function cuaUnit(): string {
  return [
    "[Unit]",
    "Description=cmux agent computer use (cmux-cua serve on the agent display), started on demand",
    `Requires=${DISPLAY_UNIT}`,
    `After=${DISPLAY_UNIT}`,
    "",
    "[Service]",
    "Type=simple",
    `User=${DEVBOX_WORK_USER}`,
    `Group=${DEVBOX_WORK_USER}`,
    `Environment=HOME=${DEVBOX_WORK_HOME}`,
    `Environment=DISPLAY=${AGENT_DISPLAY}`,
    `Environment=XAUTHORITY=${AGENT_XAUTHORITY}`,
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
    `install -d -o ${DEVBOX_WORK_USER} -g ${DEVBOX_WORK_USER} ${DEVBOX_WORK_HOME}/.config ${configDir}`,
    `if [ ! -e ${WORK_USER_CMUX_JSON} ]; then printf '%s' ${sq(WORK_USER_CMUX_JSON_TEXT)} > ${WORK_USER_CMUX_JSON} && chown ${DEVBOX_WORK_USER}:${DEVBOX_WORK_USER} ${WORK_USER_CMUX_JSON}; fi`,
    "systemctl daemon-reload",
    `! systemctl is-active --quiet ${DISPLAY_UNIT} && ! systemctl is-active --quiet ${CUA_UNIT}`,
    `${AGENT_TOOLS_BIN}/cmux --version`,
    "echo agent-tools-linked",
  ].join(" && ");
}

/** Files the install writes (path, text, mode). */
export function agentToolsFiles(): Array<{ path: string; text: string; mode: number }> {
  return [
    { path: `${AGENT_TOOLS_BIN}/cmux-cua`, text: cuaWrapperScript(), mode: 0o755 },
    { path: `/etc/systemd/system/${DISPLAY_UNIT}`, text: displayUnit(), mode: 0o644 },
    { path: `/etc/systemd/system/${CUA_UNIT}`, text: cuaUnit(), mode: 0o644 },
    { path: AGENT_TOOLS_PROFILE, text: agentToolsProfileScript(), mode: 0o644 },
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
