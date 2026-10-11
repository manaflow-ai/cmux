import type { VmAgentUpdatesSetting } from "./agentUpdates";
import { shellQuote } from "./drivers/cmuxTuiDaemon";
import {
  GITHUB_API_BASE,
  GITHUB_DOWNLOAD_BASE,
  GUEST_AGENT_MARKER,
  GUEST_AGENTS,
  GUEST_AGENTS_ROOT,
  type GuestAgent,
} from "./images/agents";

/**
 * Coding-agent installs and updates on a Cloud machine, without npm.
 *
 * Every agent comes from its own GitHub release asset (services/vms/images/agents.ts).
 * A version unpacks to /opt/cmux-agents/<binary>/<version>/, and
 * /usr/local/bin/<binary> links to the executable inside it. opencode's
 * /usr/local/bin entry stays the /etc/cmux/opencode wrapper, which execs
 * /usr/local/libexec/cmux-opencode-real, the link that moves instead.
 *
 * One script does both jobs:
 *
 * - `install` (the devbox bake): installs the Dockerfile's pins exactly,
 *   checking each download against the sha256 pinned beside the version. It
 *   never reads release metadata.
 * - `update` (a machine opted into "latest", started detached on attach): for
 *   each agent, installs the newest x.y.z release that has been public for at
 *   least GUEST_AGENT_MIN_RELEASE_AGE_SECONDS and is not above the repository's
 *   latest release, checking the download against the sha256 digest GitHub's
 *   releases API reports for the asset. A hijacked maintainer account publishes
 *   a malicious release that is usually found and pulled within hours; the wait
 *   keeps it off every opted-in machine. It never downgrades.
 *
 * A version is switched in only after it unpacked, matched its digest and
 * reported its own version, by an atomic symlink swap, so a running agent keeps
 * the files it started from and a failed update leaves the old link in place.
 * The update serializes on a lock, skips when the last successful check is
 * under a day old, and records every outcome in /etc/cmux/agent-updates.state.
 * A failure (a rate-limited API, a digest mismatch) is recorded and retried on
 * the next attach, which also re-asserts the links.
 *
 * Machines baked with the npm installs migrate on their first update: the
 * standalone release replaces the npm copy once the eligible release is at
 * least the installed version (never a downgrade; until then the npm copy
 * stays and the state says so). The migration removes the npm entry point from
 * nvm's bin dir, which login shells put first on PATH, and deletes the npm
 * package only when no process runs from it; otherwise the next run retries.
 * Old standalone versions are pruned the same way, keeping the previous one.
 *
 * Hosts: api.github.com, github.com, and GitHub's release-asset storage, all
 * in CMUX_REQUIRED_DOMAINS, so updates work in every network mode.
 */

export { GUEST_AGENTS } from "./images/agents";

export const GUEST_AGENT_UPDATES_LOG = "/var/log/cmux-agent-updates.log";
export const GUEST_AGENT_UPDATES_INTERVAL_SECONDS = 24 * 60 * 60;
export const GUEST_AGENT_MIN_RELEASE_AGE_SECONDS = 3 * 24 * 60 * 60;

export type GuestAgentPin = { readonly version: string; readonly sha256: string };

export type GuestAgentUpdaterOptions = {
  readonly agents: readonly GuestAgent[];
  /** GUEST_AGENTS_ROOT. */
  readonly root: string;
  readonly marker: string;
  /** Older images' npm lives beside this node (nvm); used only to retire the npm installs. */
  readonly node: string;
  readonly binDir: string;
  readonly libexecDir: string;
  /** Where running processes are looked up before a directory is deleted. */
  readonly procRoot: string;
  readonly apiBase: string;
  /** A release asset's URL must be exactly `${downloadBase}/<repo>/releases/download/<tag>/<asset>`. */
  readonly downloadBase: string;
  /** Seconds a successful check suppresses the next one. */
  readonly intervalSeconds: number;
  /** A release younger than this is not installed yet. */
  readonly minReleaseAgeSeconds: number;
  /** `install` mode: the exact versions and asset digests, keyed by binary. */
  readonly pins?: Readonly<Record<string, GuestAgentPin>>;
};

export const GUEST_AGENT_UPDATER_DEFAULTS: GuestAgentUpdaterOptions = {
  agents: GUEST_AGENTS,
  root: GUEST_AGENTS_ROOT,
  marker: GUEST_AGENT_MARKER,
  node: "/usr/local/bin/node",
  binDir: "/usr/local/bin",
  libexecDir: "/usr/local/libexec",
  procRoot: "/proc",
  apiBase: GITHUB_API_BASE,
  downloadBase: GITHUB_DOWNLOAD_BASE,
  intervalSeconds: GUEST_AGENT_UPDATES_INTERVAL_SECONDS,
  minReleaseAgeSeconds: GUEST_AGENT_MIN_RELEASE_AGE_SECONDS,
};

// argv: <update|install> <config dir> <options JSON>. Runs as root. Exit 0
// when skipped or done, 1 when anything failed (update mode records it in the
// state file; install mode fails the bake step).
export const guestAgentUpdaterScript = String.raw`
import fcntl, hashlib, json, os, re, shutil, subprocess, sys, tarfile, tempfile, time, urllib.error, urllib.request
from datetime import datetime, timezone

mode = sys.argv[1]
config_dir = sys.argv[2]
options = json.loads(sys.argv[3])
agents = options["agents"]
root = options["root"]
setting_path = os.path.join(config_dir, "agent-updates")
state_path = os.path.join(config_dir, "agent-updates.state")
lock_path = os.path.join(config_dir, ".agent-updates.lock")
wrapper = os.path.join(config_dir, "opencode")
release = re.compile(r"^\d+\.\d+\.\d+$")
reported_version = re.compile(r"(\d+\.\d+\.\d+)")
sha256_digest = re.compile(r"^sha256:([0-9a-f]{64})$")
probe_env = dict(os.environ)
if not probe_env.get("HOME"):
    probe_env["HOME"] = "/root"

def release_key(version):
    return tuple(int(part) for part in version.split("."))

def now_iso():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def log(message):
    print(now_iso() + " " + mode + ": " + message, flush=True)

def write_atomic(path, content, mode_bits=0o644):
    fd, temporary = tempfile.mkstemp(prefix=".agent-updates-", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), mode_bits)
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

def fetch(url, timeout):
    request = urllib.request.Request(url, headers={
        "User-Agent": "cmux-agent-updates",
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    return urllib.request.urlopen(request, timeout=timeout)

def api(path):
    try:
        with fetch(options["apiBase"] + path, 30) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise RuntimeError("GET " + path + " -> HTTP " + str(error.code))
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise RuntimeError("GET " + path + ": " + str(getattr(error, "reason", error)))

def version_dir(agent, version):
    return os.path.join(root, agent["binary"], version)

def complete(agent, version):
    return os.path.isfile(os.path.join(version_dir(agent, version), options["marker"]))

def standalone_versions(agent):
    try:
        names = os.listdir(os.path.join(root, agent["binary"]))
    except OSError:
        return []
    return sorted((name for name in names if release.match(name) and complete(agent, name)), key=release_key)

def uses_wrapper(agent):
    return agent["binary"] == "opencode" and os.path.isfile(wrapper)

def entry(agent):
    return os.path.join(options["binDir"], agent["binary"])

def real_link(agent):
    # The link whose target is the tool itself: opencode's sits behind the wrapper.
    if uses_wrapper(agent):
        return os.path.join(options["libexecDir"], "cmux-opencode-real")
    return entry(agent)

def probe_version(path):
    try:
        result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=120, env=probe_env, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = reported_version.search(result.stdout or "")
    return match.group(1) if result.returncode == 0 and match else None

def link(agent, version):
    target = os.path.join(version_dir(agent, version), agent["member"])
    if uses_wrapper(agent):
        os.makedirs(options["libexecDir"], exist_ok=True)
        link_atomic(target, real_link(agent))
        link_atomic(wrapper, entry(agent))
    else:
        link_atomic(target, entry(agent))

def installed(agent):
    # (source, version): "standalone" (ours), "npm" (an older image's install),
    # "other" (anything else on the entry), or "missing".
    path = real_link(agent)
    real = os.path.realpath(path)
    prefix = os.path.join(os.path.realpath(root), agent["binary"]) + os.sep
    if real.startswith(prefix):
        version = real[len(prefix):].split(os.sep)[0]
        if release.match(version) and complete(agent, version) and os.path.isfile(real):
            if uses_wrapper(agent) and os.path.realpath(entry(agent)) != os.path.realpath(wrapper):
                link(agent, version)
            return "standalone", version
    if not os.path.isfile(real):
        # A lost or dangling link: repair it from the newest finished version.
        versions = standalone_versions(agent)
        if versions:
            link(agent, versions[-1])
            log("relinked " + agent["binary"] + " " + versions[-1])
            return "standalone", versions[-1]
        return "missing", None
    if os.sep + "node_modules" + os.sep in real:
        # Read the npm-installed copy's version from its package.json: running it
        # would start node (codex and pi are node scripts there).
        return "npm", npm_version(agent, real)
    return "other", probe_version(path)

def npm_version(agent, real):
    marker = os.sep + "node_modules" + os.sep + agent["npm"].replace("/", os.sep) + os.sep
    index = real.find(marker)
    if index < 0:
        return None
    try:
        with open(real[: index + len(marker)] + "package.json") as stream:
            version = json.load(stream).get("version")
    except (OSError, ValueError, AttributeError):
        return None
    return version if isinstance(version, str) and release.match(version) else None

def in_use(path, aliases=()):
    # Whether any process runs from, maps, or sits in path, or names one of
    # aliases on its command line (node runs an npm tool as "node <nvm bin>/<tool>",
    # a link that is already gone once the tool is retired). Without a process
    # table nothing can be proven unused, so nothing is deleted.
    proc = options["procRoot"]
    if not os.path.isdir(proc):
        return True
    prefix = os.path.realpath(path).rstrip(os.sep) + os.sep
    def under(value):
        return (value + os.sep).startswith(prefix) if value else False
    def named(arg):
        return arg in aliases or under(arg) or (arg.startswith(os.sep) and under(os.path.realpath(arg)))
    for pid in os.listdir(proc):
        if not pid.isdigit():
            continue
        base = os.path.join(proc, pid)
        for name in ("exe", "cwd"):
            try:
                if under(os.readlink(os.path.join(base, name))):
                    return True
            except OSError:
                pass
        try:
            with open(os.path.join(base, "cmdline"), "rb") as stream:
                if any(named(arg.decode("utf-8", "replace")) for arg in stream.read().split(b"\0")):
                    return True
        except OSError:
            pass
        try:
            # A tool may rewrite its command line (pi shows just "pi"); the
            # shell's "_" still names what it started.
            with open(os.path.join(base, "environ"), "rb") as stream:
                if any(named(item[2:].decode("utf-8", "replace")) for item in stream.read().split(b"\0") if item.startswith(b"_=")):
                    return True
        except OSError:
            pass
        try:
            with open(os.path.join(base, "maps"), errors="replace") as stream:
                if any(prefix in line for line in stream):
                    return True
        except OSError:
            pass
    return False

def remove_unused(path, what, aliases=()):
    if not os.path.lexists(path):
        return
    if in_use(path, aliases):
        log("kept " + what + " (in use); retrying next run")
        return
    shutil.rmtree(path, ignore_errors=True)
    log("removed " + what)

def unpack(agent, archive, destination):
    if agent["archive"] == "raw":
        target = os.path.join(destination, agent["member"])
        os.makedirs(os.path.dirname(target), exist_ok=True)
        os.replace(archive, target)
        os.chmod(target, 0o755)
        return
    with tarfile.open(archive, "r:gz") as tar:
        try:
            tar.extractall(destination, filter="data")
        except TypeError:
            for member in tar.getmembers():
                if member.name.startswith("/") or ".." in member.name.split("/") or member.issym() or member.islnk():
                    raise RuntimeError(agent["binary"] + ": unsafe archive member " + member.name)
            tar.extractall(destination)

def install(agent, version, url, sha256):
    final = version_dir(agent, version)
    if complete(agent, version):
        return
    base = os.path.dirname(final)
    os.makedirs(base, exist_ok=True)
    os.chmod(root, 0o755)
    os.chmod(base, 0o755)
    work = tempfile.mkdtemp(prefix=".install-" + version + "-", dir=base)
    try:
        archive = os.path.join(work, "download")
        digest = hashlib.sha256()
        with fetch(url, 900) as response, open(archive, "wb") as out:
            while True:
                chunk = response.read(1 << 20)
                if not chunk:
                    break
                digest.update(chunk)
                out.write(chunk)
        if digest.hexdigest() != sha256:
            raise RuntimeError(agent["binary"] + " " + version + ": sha256 " + digest.hexdigest() + " is not the release's " + sha256)
        tree = os.path.join(work, "tree")
        os.mkdir(tree, 0o755)
        unpack(agent, archive, tree)
        executable = os.path.join(tree, agent["member"])
        if not (os.path.isfile(executable) and os.access(executable, os.X_OK)):
            raise RuntimeError(agent["binary"] + " " + version + ": " + agent["member"] + " is not in the asset")
        reported = probe_version(executable)
        if reported != version:
            raise RuntimeError(agent["binary"] + " " + version + ": the unpacked binary reports " + repr(reported))
        with open(os.path.join(tree, options["marker"]), "w") as stream:
            json.dump({"version": version, "sha256": sha256, "url": url, "installedAt": now_iso()}, stream)
        os.chmod(tree, 0o755)
        if os.path.lexists(final):
            shutil.rmtree(final)
        os.rename(tree, final)
    finally:
        shutil.rmtree(work, ignore_errors=True)

def retire_npm(agent):
    # Only once our link is live: drop nvm's entry point (login shells put
    # nvm's bin dir first), then the package itself when nothing runs from it.
    node = options["node"]
    if not os.path.exists(node):
        return
    nvm_bin = os.path.dirname(os.path.realpath(node))
    shim = os.path.join(nvm_bin, agent["binary"])
    marker = "node_modules/" + agent["npm"] + "/"
    if os.path.islink(shim) and marker in os.readlink(shim) + "/":
        os.unlink(shim)
        log("removed npm entry point " + shim)
    remove_unused(os.path.join(os.path.dirname(nvm_bin), "lib", "node_modules", agent["npm"]), "npm package " + agent["npm"], (shim,))

def prune(agent, current):
    base = os.path.join(root, agent["binary"])
    try:
        names = os.listdir(base)
    except OSError:
        return
    older = sorted((name for name in names if release.match(name) and release_key(name) < release_key(current)), key=release_key)
    for name in older[:-1]:
        remove_unused(os.path.join(base, name), agent["binary"] + " " + name)
    for name in names:
        if name.startswith(".install-"):
            remove_unused(os.path.join(base, name), agent["binary"] + " leftover " + name)

def expected_url(agent, tag):
    return options["downloadBase"] + "/" + agent["repo"] + "/releases/download/" + tag + "/" + agent["asset"]

def published_at(stamp):
    return datetime.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()

def eligible_release(agent):
    # The newest x.y.z release at least minReleaseAgeSeconds old, not above the
    # repository's latest release, whose asset carries a sha256 digest.
    prefix = agent["tagPrefix"]
    latest_tag = api("/repos/" + agent["repo"] + "/releases/latest").get("tag_name") or ""
    latest = latest_tag[len(prefix):] if latest_tag.startswith(prefix) else ""
    if not release.match(latest):
        raise RuntimeError(agent["repo"] + ": latest release " + repr(latest_tag) + " is not a release")
    cutoff = time.time() - options["minReleaseAgeSeconds"]
    best = None
    for item in api("/repos/" + agent["repo"] + "/releases?per_page=100"):
        tag = item.get("tag_name") or ""
        version = tag[len(prefix):] if tag.startswith(prefix) else ""
        if item.get("draft") or item.get("prerelease") or not release.match(version):
            continue
        if release_key(version) > release_key(latest):
            continue
        try:
            if published_at(item["published_at"]) > cutoff:
                continue
        except (KeyError, TypeError, ValueError):
            continue
        asset = next((a for a in item.get("assets") or [] if a.get("name") == agent["asset"]), None)
        digest = sha256_digest.match((asset or {}).get("digest") or "")
        if not digest or asset.get("browser_download_url") != expected_url(agent, tag):
            continue
        if best is None or release_key(version) > release_key(best["version"]):
            best = {"version": version, "url": expected_url(agent, tag), "sha256": digest.group(1)}
    return best

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

def update_agent(agent):
    source, current = installed(agent)
    target = eligible_release(agent)
    if target and (
        current is None
        or release_key(target["version"]) > release_key(current)
        or (source != "standalone" and target["version"] == current)
    ):
        log("installing " + agent["binary"] + " " + target["version"] + " (was " + str(current) + ", " + source + ")")
        install(agent, target["version"], target["url"], target["sha256"])
        link(agent, target["version"])
        source, current = "standalone", target["version"]
    elif source != "standalone" and current:
        log(agent["binary"] + " " + current + " stays on " + source + " until a release at least as new is eligible")
    return source, current

def settle(agent, source, current):
    if source == "standalone":
        retire_npm(agent)
        prune(agent, current)

os.makedirs(config_dir, exist_ok=True)
lock = open(lock_path, "a")
try:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    log("another update is running")
    sys.exit(0)
os.makedirs(root, exist_ok=True)

if mode == "install":
    try:
        for agent in agents:
            pin = options["pins"][agent["binary"]]
            if not release.match(pin["version"]) or not re.match(r"^[0-9a-f]{64}$", pin["sha256"]):
                raise RuntimeError(agent["binary"] + ": pin " + repr(pin) + " is not an exact release and sha256")
            install(agent, pin["version"], expected_url(agent, agent["tagPrefix"] + pin["version"]), pin["sha256"])
            link(agent, pin["version"])
            settle(agent, "standalone", pin["version"])
            log(agent["binary"] + " " + pin["version"] + " installed")
    except Exception as error:
        log("failed: " + (str(error) or type(error).__name__))
        sys.exit(1)
    sys.exit(0)

if mode != "update":
    log("unknown mode")
    sys.exit(2)
if setting() != "latest":
    sys.exit(0)
if checked_recently():
    sys.exit(0)

versions, sources, errors = {}, {}, {}
for agent in agents:
    binary = agent["binary"]
    try:
        source, current = update_agent(agent)
        settle(agent, source, current)
    except Exception as error:
        errors[binary] = str(error)[:500] or type(error).__name__
        log("failed " + binary + ": " + errors[binary])
    try:
        source, current = installed(agent)
    except Exception:
        source, current = "unknown", None
    versions[binary], sources[binary] = current, source
state = {"checkedAt": now_iso(), "ok": not errors, "versions": versions, "sources": sources}
if errors:
    state["errors"] = errors
    state["error"] = "; ".join(binary + ": " + message for binary, message in sorted(errors.items()))[:2000]
write_atomic(state_path, json.dumps(state, sort_keys=True) + "\n")
if errors:
    sys.exit(1)
log("up to date: " + json.dumps(versions, sort_keys=True))
`;

export type GuestAgentUpdaterMode = "update" | "install";

/** The updater invocation; exported so tests can run it against a temp tree. */
export function guestAgentUpdaterCommand(
  configDir = "/etc/cmux",
  options: GuestAgentUpdaterOptions = GUEST_AGENT_UPDATER_DEFAULTS,
  mode: GuestAgentUpdaterMode = "update",
): string {
  return `python3 -c ${shellQuote(guestAgentUpdaterScript)} ${mode} ${shellQuote(configDir)} ${shellQuote(JSON.stringify(options))}`;
}

/**
 * The bake's agent step: install exactly `pins` (keyed by binary, from the
 * Dockerfile ARGs) through the same code the updater runs, so an image and an
 * updated machine share one layout.
 */
export function guestAgentInstallCommand(
  pins: Readonly<Record<string, GuestAgentPin>>,
  configDir = "/etc/cmux",
  options: GuestAgentUpdaterOptions = GUEST_AGENT_UPDATER_DEFAULTS,
): string {
  for (const agent of options.agents) {
    if (!pins[agent.binary]) throw new Error(`no pin for ${agent.binary}`);
  }
  return guestAgentUpdaterCommand(configDir, { ...options, pins }, "install");
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
