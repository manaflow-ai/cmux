import type { VmAgentUpdatesSetting } from "./agentUpdates";
import { shellQuote } from "./drivers/cmuxTuiDaemon";

/**
 * Coding-agent updates on a running Cloud machine (opt-in, "latest").
 *
 * The devbox bake installs exact npm pins with `npm install -g` on the base's
 * nvm Node and links every bin into /usr/local/bin (build-devbox-freestyle.ts,
 * step "agents"); opencode's /usr/local/bin entry is the /etc/cmux/opencode
 * wrapper, which execs /usr/local/libexec/cmux-opencode-real. A machine opted
 * into "latest" re-runs that install on attach with the registry's current
 * `latest` of each package, at most once a day, and re-asserts the same links.
 *
 * The attach exec only records the setting and launches a detached updater, so
 * attach never waits on the network. The updater serializes on a lock, skips
 * when the last successful check is under a day old, and records every outcome
 * in /etc/cmux/agent-updates.state. A failure (for example, a network policy
 * that blocks registry.npmjs.org) is recorded and retried on the next attach.
 * Running agents keep working: npm swaps package directories by rename.
 *
 * Machines from any image accept the command: it creates what it needs and
 * never assumes a file from a newer bake.
 */

/** The packages the devbox bakes, in Dockerfile order (AGENT_PIN_ARGS; a test keeps them equal). */
export const GUEST_AGENT_PACKAGES: readonly { readonly pkg: string; readonly binary: string }[] = [
  { pkg: "@anthropic-ai/claude-code", binary: "claude" },
  { pkg: "@openai/codex", binary: "codex" },
  { pkg: "opencode-ai", binary: "opencode" },
  { pkg: "@earendil-works/pi-coding-agent", binary: "pi" },
  { pkg: "agent-browser", binary: "agent-browser" },
];

export const GUEST_AGENT_UPDATES_LOG = "/var/log/cmux-agent-updates.log";
export const GUEST_AGENT_UPDATES_INTERVAL_SECONDS = 24 * 60 * 60;

export type GuestAgentUpdaterOptions = {
  readonly packages: readonly { readonly pkg: string; readonly binary: string }[];
  /** The Node the bake installed into; npm is its sibling. */
  readonly node: string;
  readonly binDir: string;
  readonly libexecDir: string;
  /** Seconds a successful check suppresses the next one. */
  readonly intervalSeconds: number;
};

export const GUEST_AGENT_UPDATER_DEFAULTS: GuestAgentUpdaterOptions = {
  packages: GUEST_AGENT_PACKAGES,
  node: "/usr/local/bin/node",
  binDir: "/usr/local/bin",
  libexecDir: "/usr/local/libexec",
  intervalSeconds: GUEST_AGENT_UPDATES_INTERVAL_SECONDS,
};

// argv: <config dir> <options JSON>. Runs as root. Exit 0 when skipped or
// updated, 1 when the check failed (the state file carries the error).
export const guestAgentUpdaterScript = String.raw`
import fcntl, json, os, re, subprocess, sys, tempfile, time
from datetime import datetime, timezone

config_dir = sys.argv[1]
options = json.loads(sys.argv[2])
setting_path = os.path.join(config_dir, "agent-updates")
state_path = os.path.join(config_dir, "agent-updates.state")
lock_path = os.path.join(config_dir, ".agent-updates.lock")
release = re.compile(r"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$")

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def log(message):
    print(now_iso() + " " + message, flush=True)

def write_atomic(path, content, mode=0o644):
    fd, temporary = tempfile.mkstemp(prefix=".agent-updates-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def link_atomic(target, path):
    temporary = os.path.join(os.path.dirname(path), ".agent-updates-link-" + str(os.getpid()))
    if os.path.lexists(temporary):
        os.unlink(temporary)
    os.symlink(target, temporary)
    os.replace(temporary, path)

def setting():
    try:
        with open(setting_path) as stream:
            return stream.read().strip()
    except OSError:
        return "image"

def checked_recently():
    try:
        with open(state_path) as stream:
            state = json.load(stream)
        checked = datetime.strptime(state["checkedAt"], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc).timestamp()
    except (OSError, ValueError, KeyError, TypeError):
        return False
    age = time.time() - checked
    return state.get("ok") is True and 0 <= age < options["intervalSeconds"]

os.makedirs(config_dir, exist_ok=True)
lock = open(lock_path, "a")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    log("another update is running")
    sys.exit(0)
if setting() != "latest":
    sys.exit(0)
if checked_recently():
    sys.exit(0)

nvm_bin = os.path.dirname(os.path.realpath(options["node"]))
npm = os.path.join(nvm_bin, "npm")
env = dict(os.environ)
env["PATH"] = nvm_bin + ":" + env.get("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
env.setdefault("HOME", "/root")
env.update({"npm_config_update_notifier": "false", "npm_config_fund": "false", "npm_config_audit": "false"})

def npm_run(args, timeout, check=True):
    result = subprocess.run([npm] + args, env=env, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode != 0:
        detail = (result.stderr or result.stdout).strip().splitlines()[-3:]
        raise RuntimeError("npm " + " ".join(args[:2]) + " exited " + str(result.returncode) + ": " + " | ".join(detail))
    return result.stdout

def installed_versions():
    # npm ls exits 1 for extraneous or invalid trees but still prints the tree.
    tree = json.loads(npm_run(["ls", "-g", "--json", "--depth=0"], 120, check=False) or "{}")
    dependencies = tree.get("dependencies") or {}
    return {p["pkg"]: (dependencies.get(p["pkg"]) or {}).get("version") for p in options["packages"]}

def relink():
    # The bake's links: every bin in /usr/local/bin, except opencode, whose
    # entry stays the /etc/cmux/opencode wrapper and whose real binary moves
    # to wherever npm put the new release.
    wrapper = os.path.join(config_dir, "opencode")
    for package in options["packages"]:
        binary = package["binary"]
        source = os.path.join(nvm_bin, binary)
        if not os.path.exists(source):
            raise RuntimeError(binary + " is missing from " + nvm_bin)
        entry = os.path.join(options["binDir"], binary)
        if binary == "opencode" and os.path.isfile(wrapper):
            real = os.path.join(options["libexecDir"], "cmux-opencode-real")
            os.makedirs(options["libexecDir"], exist_ok=True)
            link_atomic(os.path.realpath(source), real)
            link_atomic(wrapper, entry)
            if os.readlink(entry) != wrapper or not os.access(os.path.realpath(real), os.X_OK):
                raise RuntimeError("opencode wrapper chain is broken")
        else:
            link_atomic(source, entry)

versions = {}
try:
    versions = installed_versions()
    targets = {}
    for package in options["packages"]:
        name = package["pkg"]
        latest = npm_run(["view", name, "version", "--fetch-retries=1", "--fetch-timeout=30000"], 120).strip()
        if not release.match(latest):
            raise RuntimeError(name + ": registry latest " + repr(latest) + " is not a release")
        if versions.get(name) != latest:
            targets[name] = latest
    if targets:
        log("installing " + " ".join(name + "@" + version for name, version in sorted(targets.items())))
        npm_run(["install", "-g", "--foreground-scripts"] + [name + "@" + version for name, version in sorted(targets.items())], 900)
    relink()
    versions = installed_versions()
    mismatched = sorted(name for name, version in targets.items() if versions.get(name) != version)
    if mismatched:
        raise RuntimeError("not installed at latest: " + ", ".join(mismatched))
    write_atomic(state_path, json.dumps({"checkedAt": now_iso(), "ok": True, "versions": versions}) + "\n")
    log("up to date: " + json.dumps(versions, sort_keys=True))
except Exception as error:
    message = str(error)[:2000] or type(error).__name__
    write_atomic(state_path, json.dumps({"checkedAt": now_iso(), "ok": False, "versions": versions, "error": message}) + "\n")
    log("failed: " + message)
    sys.exit(1)
`;

/** The detached updater invocation; exported so tests can run it against a temp tree. */
export function guestAgentUpdaterCommand(
  configDir = "/etc/cmux",
  options: GuestAgentUpdaterOptions = GUEST_AGENT_UPDATER_DEFAULTS,
): string {
  return `python3 -c ${shellQuote(guestAgentUpdaterScript)} ${shellQuote(configDir)} ${shellQuote(JSON.stringify(options))}`;
}

export type GuestAgentUpdatesPaths = {
  readonly configDir: string;
  readonly log: string;
  readonly updater: GuestAgentUpdaterOptions;
};

const GUEST_AGENT_UPDATES_PATHS: GuestAgentUpdatesPaths = {
  configDir: "/etc/cmux",
  log: GUEST_AGENT_UPDATES_LOG,
  updater: GUEST_AGENT_UPDATER_DEFAULTS,
};

/**
 * The root shell script behind {@link guestAgentUpdatesCommand}: record the
 * setting atomically and, for "latest", start the updater detached (its own
 * session, no stdin, output appended to the log) so the script returns at once.
 */
export function guestAgentUpdatesScript(
  setting: VmAgentUpdatesSetting,
  paths: GuestAgentUpdatesPaths = GUEST_AGENT_UPDATES_PATHS,
): string {
  const { configDir } = paths;
  const record = [
    `mkdir -p ${shellQuote(configDir)}`,
    `tmp=$(mktemp ${shellQuote(`${configDir}/.agent-updates.XXXXXX`)})`,
    `printf '%s\\n' ${setting} > "$tmp"`,
    `chmod 644 "$tmp"`,
    `mv -f "$tmp" ${shellQuote(`${configDir}/agent-updates`)}`,
  ];
  const launch = setting === "latest"
    ? [`(setsid nohup ${guestAgentUpdaterCommand(configDir, paths.updater)} </dev/null >>${shellQuote(paths.log)} 2>&1 &)`]
    : [];
  return [...record, ...launch].join(" && ");
}

/**
 * The attach-time guest command. Runs the script as root, or through
 * passwordless sudo when the exec user is the work user.
 */
export function guestAgentUpdatesCommand(setting: VmAgentUpdatesSetting): string {
  const script = shellQuote(guestAgentUpdatesScript(setting));
  return `if [ "$(id -u)" = 0 ]; then sh -c ${script}; else sudo -n sh -c ${script}; fi`;
}
