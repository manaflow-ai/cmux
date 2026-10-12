import { createHash } from "node:crypto";
import { shellQuote } from "./drivers/cmuxTuiDaemon";

/** The computer-use driver already baked into the desktop devbox image. */
export const GUEST_CUA_DRIVER_PATH = "/usr/local/bin/cua-driver";
export const GUEST_CUA_USER = "cmux";
export const GUEST_CUA_HOME = "/home/cmux";
/** The VM exec endpoint's hard command-size ceiling. */
export const GUEST_CUA_MAX_COMMAND_BYTES = 64 * 1024;

/**
 * The only computer-use tools exposed by the Cloud MCP surface. Keeping this
 * list in the guest helper as well as the protocol layer makes the command
 * boundary auditable: a caller cannot turn the scoped exec seam into an
 * arbitrary `cua-driver` command.
 */
export const GUEST_CUA_TOOLS = [
  "get_desktop_state",
  "click",
  "type_text",
  "press_key",
  "scroll",
  "drag",
] as const;

export type GuestCuaTool = (typeof GUEST_CUA_TOOLS)[number];

/**
 * Linux's desktop-scope pixel path is supported directly for click, scroll,
 * and drag. Coordinate-bearing type/key calls use the driver's window-local
 * form, so the guest wrapper resolves the visible window under a screenshot
 * coordinate before invoking them. This is an internal fixed helper;
 * `list_windows` is never added to the Cloud MCP tool allow-list.
 */
const GUEST_CUA_WINDOW_TOOLS = new Set<GuestCuaTool>([
  "type_text",
  "press_key",
]);

function guestCuaNeedsWindowResolution(tool: GuestCuaTool, args: Record<string, unknown>): boolean {
  if (!GUEST_CUA_WINDOW_TOOLS.has(tool)) return false;
  // Linux type/key calls without a point target the focused application when
  // explicitly scoped to the desktop. A point-bearing call instead uses the
  // window-local fields required by the driver, after resolving the visible
  // window under the screenshot coordinate.
  if (tool === "type_text" || tool === "press_key") {
    return args.x !== undefined || args.y !== undefined;
  }
  return true;
}

/** Reads one fixed list_windows result and translates desktop pixels to the
 * window-local coordinates expected by Linux type/key/scroll/drag. */
const GUEST_CUA_WINDOW_RESOLVER_SCRIPT = String.raw`
import json, sys

tool = sys.argv[1]
args = json.loads(sys.stdin.readline())
envelope = json.load(sys.stdin)
structured = envelope.get("structuredContent") if isinstance(envelope, dict) else None
if not isinstance(structured, dict):
    structured = envelope if isinstance(envelope, dict) else {}
windows = structured.get("windows")
if not isinstance(windows, list):
    raise SystemExit("cua-driver list_windows returned no window list")

def number(value, default=None):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else default

def window_geometry(window):
    bounds = window.get("bounds") if isinstance(window, dict) else None
    if not isinstance(bounds, dict):
        bounds = window
    x = number(bounds.get("x"))
    y = number(bounds.get("y"))
    width = number(bounds.get("width"))
    height = number(bounds.get("height"))
    if None in (x, y, width, height) or width <= 0 or height <= 0:
        return None
    return x, y, width, height

def window_id(window):
    value = window.get("window_id") if isinstance(window, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) else None

def process_id(window):
    value = window.get("pid") if isinstance(window, dict) else None
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None

def z_order(window):
    value = window.get("z_index") if isinstance(window, dict) else None
    # Linux cannot always observe stacking order. The driver deliberately
    # returns null in that case; array order is not a front-to-back contract.
    return value if isinstance(value, int) and not isinstance(value, bool) else None

usable = []
for index, window in enumerate(windows):
    if not isinstance(window, dict) or window.get("is_on_screen") is False:
        continue
    geometry = window_geometry(window)
    wid = window_id(window)
    pid = process_id(window)
    if geometry is not None and wid is not None and pid is not None:
        usable.append((z_order(window), pid, wid, geometry))

point = None
if tool == "drag":
    point = (number(args.get("from_x")), number(args.get("from_y")))
elif "x" in args or "y" in args:
    point = (number(args.get("x")), number(args.get("y")))
if point is not None and None in point:
    raise SystemExit("screen coordinates must contain both x and y")

if point is None:
    candidates = usable
else:
    sx, sy = point
    candidates = [entry for entry in usable if entry[3][0] <= sx < entry[3][0] + entry[3][2] and entry[3][1] <= sy < entry[3][1] + entry[3][3]]
if not candidates:
    raise SystemExit("no visible desktop window contains the requested computer-use coordinate")

if len(candidates) > 1:
    # A coordinate can be covered by multiple windows. Select only when the
    # driver gave a unique stacking winner; never guess from list order or
    # from a null z_index.
    if any(entry[0] is None for entry in candidates):
        raise SystemExit("desktop window stacking order is unavailable for the requested coordinate")
    highest = max(entry[0] for entry in candidates)
    winners = [entry for entry in candidates if entry[0] == highest]
    if len(winners) != 1:
        raise SystemExit("multiple desktop windows share the requested coordinate")
    selected = winners[0]
else:
    selected = candidates[0]

_, pid, wid, (left, top, _, _) = selected
args["pid"] = pid
args["window_id"] = wid
if point is not None:
    sx, sy = point
    if tool == "drag":
        args["from_x"] = sx - left
        args["from_y"] = sy - top
        args["to_x"] = number(args.get("to_x")) - left
        args["to_y"] = number(args.get("to_y")) - top
    else:
        args["x"] = sx - left
        args["y"] = sy - top
print(json.dumps(args, separators=(",", ":")))
`;

/**
 * Idempotently adds the CUA stdio server to the three supported agent
 * configuration formats. The script deliberately only adds a missing
 * `cua-driver` entry; malformed files and entries owned by the user are left
 * alone. It runs as root during a scoped VM exec and writes the work user's
 * files with their existing mode and ownership.
 */
export const GUEST_CUA_CONFIG_SCRIPT = String.raw`
import json, os, pathlib, stat, tempfile
try:
    import tomllib
except ImportError:
    tomllib = None

home = pathlib.Path(os.environ.get("CMUX_CUA_HOME", "/home/cmux"))
driver = os.environ.get("CMUX_CUA_DRIVER_BIN", "/usr/local/bin/cua-driver")

def atomic_json(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o600
    fd, temporary = tempfile.mkstemp(prefix=".cmux-cua-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(document, stream, indent=2)
            stream.write("\n")
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def load_json(path):
    # Never replace a user-owned link, including a dangling one.
    if path.is_symlink():
        return None
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text())
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None

# Claude Code's user scope lives at the top level of ~/.claude.json. Project
# entries remain untouched, so a project can still override the server. Keep
# Claude's stable public name distinct from the Codex/OpenCode entry because
# Claude's MCP discovery uses the name in diagnostics and permission prompts.
claude = home / ".claude.json"
document = load_json(claude)
if document is not None:
    servers = document.get("mcpServers")
    if servers is None:
        document["mcpServers"] = {"cua-computer-use": {"command": driver, "args": ["mcp", "--claude-code-computer-use-compat"]}}
        atomic_json(claude, document)
    elif isinstance(servers, dict) and "cua-computer-use" not in servers:
        servers["cua-computer-use"] = {"command": driver, "args": ["mcp", "--claude-code-computer-use-compat"]}
        atomic_json(claude, document)

# Codex uses TOML. Appending a new table retains every existing comment and
# setting. Validate the result before replacing the file so an unusual but
# valid user config is never left half-written.
codex = home / ".codex" / "config.toml"
try:
    raw = codex.read_text() if codex.exists() else ""
    if codex.is_symlink():
        raise ValueError("refusing to replace a symlinked Codex config")
    if raw and tomllib is None:
        raise ValueError("Python 3.11 or newer is required to safely merge an existing TOML config")
    parsed = tomllib.loads(raw) if raw else {}
    servers = parsed.get("mcp_servers", {})
    if isinstance(servers, dict) and "cua-driver" not in servers:
        addition = "\n[mcp_servers.cua-driver]\ncommand = " + json.dumps(driver) + "\nargs = [\"mcp\"]\n"
        candidate = raw.rstrip() + addition
        if tomllib is not None:
            tomllib.loads(candidate)
        codex.parent.mkdir(parents=True, exist_ok=True)
        mode = stat.S_IMODE(codex.stat().st_mode) if codex.exists() else 0o600
        fd, temporary = tempfile.mkstemp(prefix=".cmux-cua-", dir=str(codex.parent))
        try:
            with os.fdopen(fd, "w") as stream:
                stream.write(candidate)
                os.fchmod(stream.fileno(), mode)
            os.replace(temporary, codex)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
except (OSError, ValueError, TypeError):
    pass

# OpenCode's config is JSON and keeps MCP servers under the mcp key. Existing
# provider/model settings and unknown keys are retained verbatim in meaning.
opencode = home / ".config" / "opencode" / "opencode.json"
document = load_json(opencode)
if document is not None:
    servers = document.get("mcp")
    if servers is None:
        document["mcp"] = {"cua-driver": {"type": "local", "command": [driver, "mcp"], "enabled": True}}
        atomic_json(opencode, document)
    elif isinstance(servers, dict) and "cua-driver" not in servers:
        servers["cua-driver"] = {"type": "local", "command": [driver, "mcp"], "enabled": True}
        atomic_json(opencode, document)
`;

function guestCuaConfigCommand(): string {
  const script = GUEST_CUA_CONFIG_SCRIPT.replace(/'/g, `'\\''`);
  return `CMUX_CUA_HOME="$CMUX_CUA_HOME" CMUX_CUA_DRIVER_BIN=${shellQuote(GUEST_CUA_DRIVER_PATH)} python3 -c '${script}'`;
}

function guestCuaUserCommand(command: string): string {
  const desktopSessionBus = "${CMUX_DESKTOP_SESSION_BUS:-${DBUS_SESSION_BUS_ADDRESS-}}";
  const environment =
    `env HOME="$CMUX_CUA_HOME" USER="$CMUX_CUA_USER" DISPLAY="$DISPLAY" ` +
    `DBUS_SESSION_BUS_ADDRESS="${desktopSessionBus}"`;
  return `if [ "$CMUX_CUA_USER" = root ]; then ${environment} ${command}; else ` +
    `setpriv --reuid="$CMUX_CUA_USER" --regid="$CMUX_CUA_USER" --init-groups ${environment} ${command}; fi`;
}

function guestCuaWindowResolverCommand(tool: GuestCuaTool, argsJson: string): string {
  const script = GUEST_CUA_WINDOW_RESOLVER_SCRIPT.replace(/'/g, `'\\''`);
  const quotedTool = shellQuote(tool);
  const quotedArgs = shellQuote(argsJson);
  const listWindows = guestCuaUserCommand(
    `${shellQuote(GUEST_CUA_DRIVER_PATH)} call list_windows ${shellQuote('{"on_screen_only":true}')}`,
  );
  return [
    `window_json=$(${listWindows})`,
    `resolved_json=$(printf '%s\\n%s' ${quotedArgs} "$window_json" | python3 -c '${script}' -- ${quotedTool})`,
  ].join("; ");
}

/**
 * CUA sessions are intentionally stable across MCP reconnects but opaque to
 * the guest and the driver. The machine id is part of the input so a caller
 * cannot accidentally reuse state from another VM.
 */
export function guestCuaSession(userId: string, machineId: string): string {
  return `cmux-cloud-${createHash("sha256").update(`${userId}\0${machineId}`).digest("hex").slice(0, 32)}`;
}

/**
 * Build one bounded guest invocation. The command starts the per-VM driver
 * daemon when the desktop supervisor has not done so yet, then invokes exactly
 * one allow-listed tool. Each call uses the same user HOME and daemon, so
 * driver configuration and accessibility snapshots survive separate MCP requests,
 * VM pause/resume, and reconnects as long as the machine's home is retained.
 */
export function guestCuaCommand(tool: GuestCuaTool, args: Record<string, unknown>): string {
  if (!GUEST_CUA_TOOLS.includes(tool)) throw new Error(`unsupported CUA tool: ${tool}`);
  const resolveWindow = guestCuaNeedsWindowResolution(tool, args);
  const callArgs = !resolveWindow && (tool === "type_text" || tool === "press_key")
    ? { ...args, scope: "desktop" }
    : args;
  const json = JSON.stringify(callArgs);
  const quotedTool = shellQuote(tool);
  const quotedJson = shellQuote(json);
  const start = guestCuaUserCommand(
    `sh -c ${shellQuote(`exec 9>&-; exec nohup ${shellQuote(GUEST_CUA_DRIVER_PATH)} serve --no-permissions-gate >/dev/null 2>&1`)}`,
  );
  const status = guestCuaUserCommand(`${shellQuote(GUEST_CUA_DRIVER_PATH)} status >/dev/null 2>&1`);
  const statusProbe =
    `env CMUX_CUA_USER="$CMUX_CUA_USER" CMUX_CUA_HOME="$CMUX_CUA_HOME" ` +
    `CMUX_DESKTOP_SESSION_BUS="\${CMUX_DESKTOP_SESSION_BUS-}" DISPLAY="$DISPLAY" ` +
    `DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS-}" sh -c ${shellQuote(status)}`;
  const statusWait =
    `env CMUX_CUA_USER="$CMUX_CUA_USER" CMUX_CUA_HOME="$CMUX_CUA_HOME" ` +
    `CMUX_DESKTOP_SESSION_BUS="\${CMUX_DESKTOP_SESSION_BUS-}" DISPLAY="$DISPLAY" ` +
    `DBUS_SESSION_BUS_ADDRESS="\${DBUS_SESSION_BUS_ADDRESS-}" ` +
    `timeout 15 sh -c ${shellQuote(`until ${status}; do :; done`)}`;
  // A provider resume reports the VM as running before the desktop supervisor
  // has published its display/accessibility environment. Wait on the files
  // written by that lifecycle owner instead of failing the first CUA request
  // after a pause/resume. The X socket check also rejects an env file left
  // behind by a desktop restart.
  const desktopReadyWait =
    `if command -v timeout >/dev/null 2>&1; then ` +
    `timeout 30 sh -c ${shellQuote("until [ -r /run/cmux-desktop/env ] && [ -S /tmp/.X11-unix/X1 ]; do :; done")}; ` +
    `else [ -r /run/cmux-desktop/env ] && [ -S /tmp/.X11-unix/X1 ]; fi`;
  const call = resolveWindow
    ? guestCuaUserCommand(
      `${shellQuote(GUEST_CUA_DRIVER_PATH)} call ${quotedTool} "\$resolved_json"`,
    )
    : guestCuaUserCommand(`${shellQuote(GUEST_CUA_DRIVER_PATH)} call ${quotedTool} ${quotedJson}`);
  return [
    "set -eu",
    `test -x ${shellQuote(GUEST_CUA_DRIVER_PATH)} || { echo 'cua-driver is not installed on this machine' >&2; exit 69; }`,
    `${desktopReadyWait} || { echo 'desktop is not ready for computer use' >&2; exit 70; }`,
    // The current image runs the desktop as cmux, while older desktop images
    // used ubuntu. Resolve the owner of the live display instead of assuming
    // the current image's account, and source its bus before the generic
    // desktop-env shim can clear the discovery variables.
    `. /run/cmux-desktop/env; desktop_uid="\${CMUX_DESKTOP_UID-}"; desktop_bus="\${CMUX_DESKTOP_SESSION_BUS-}"; if [ -z "$desktop_uid" ] && [ -S /tmp/.X11-unix/X1 ]; then desktop_uid=\$(stat -c %u /tmp/.X11-unix/X1 2>/dev/null || true); fi; desktop_passwd="\$(getent passwd "$desktop_uid" 2>/dev/null || true)"; if [ -n "$desktop_passwd" ]; then CMUX_CUA_USER="\$(printf '%s' "$desktop_passwd" | cut -d: -f1)"; CMUX_CUA_HOME="\$(printf '%s' "$desktop_passwd" | cut -d: -f6)"; elif id -u ${GUEST_CUA_USER} >/dev/null 2>&1 && test -d ${shellQuote(GUEST_CUA_HOME)}; then CMUX_CUA_USER=${GUEST_CUA_USER}; CMUX_CUA_HOME=${shellQuote(GUEST_CUA_HOME)}; else CMUX_CUA_USER=root; CMUX_CUA_HOME=/root; fi; . /etc/cmux/desktop-env.sh; CMUX_DESKTOP_SESSION_BUS="$desktop_bus"`,
    guestCuaUserCommand(guestCuaConfigCommand()),
    // A stale process can keep the socket path occupied while accepting no
    // requests. Trust the driver's status endpoint, then kill only matching
    // serve processes for the resolved desktop user before starting a heal.
    `cua_lock_path="/tmp/cmux-cua-\$(id -u "$CMUX_CUA_USER").lock"; cua_lock_held=0; if command -v flock >/dev/null 2>&1; then cua_old_umask=\$(umask); umask 000; exec 9>"$cua_lock_path"; umask "$cua_old_umask"; flock -x 9; cua_lock_held=1; fi; if ! ${statusProbe}; then stale_cua_pids=\$(pgrep -u "\$(id -u "$CMUX_CUA_USER")" -f '[c]ua-driver serve' 2>/dev/null || true); if [ -n "$stale_cua_pids" ]; then kill -KILL $stale_cua_pids 2>/dev/null || true; fi; if ! ${statusProbe}; then ( ${start} ) & fi; fi`,
    // A VM created from an older image may not have the desktop supervisor's
    // daemon yet. Wait on its own socket/status lifecycle signal instead of
    // sleeping for an assumed startup interval. `timeout` bounds a driver
    // that crashes before binding the socket; the fallback probe is retained
    // for minimal images without coreutils timeout.
    `(if command -v timeout >/dev/null 2>&1; then ${statusWait}; else ${statusProbe}; fi) || { echo 'cua-driver daemon did not become ready' >&2; exit 71; }; if [ "$cua_lock_held" = 1 ]; then exec 9>&-; fi`,
    ...(resolveWindow ? [guestCuaWindowResolverCommand(tool, json)] : []),
    call,
  ].join("; ");
}

