import { createHash } from "node:crypto";
import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH } from "../guestCli";
import { GUEST_BROWSER_FILES, guestBrowserInstallCommand } from "../guestBrowser";
import {
  defaultGuestCliDistribution,
  guestCliDistributionCommand,
  guestCliDistributionInstallPaths,
  guestCliDistributionPruneCommand,
  type GuestCliDistribution,
} from "../guestCliDistribution";
import { guestPromptInstallFiles, type GuestPromptIdentity } from "../guestPrompt";
import { shellQuote } from "./cmuxTuiDaemon";

const digest = createHash("sha256").update(GUEST_CMUX_SHIM).digest("hex");
function distributionPaths(manifest: GuestCliDistribution = defaultGuestCliDistribution): string[] {
  return guestCliDistributionInstallPaths(manifest);
}

const installPaths = [
  GUEST_CMUX_SHIM_PATH,
  ...GUEST_BROWSER_FILES.map(({ path }) => path),
  "/etc/cmux/browser-opener-version",
  "/etc/cmux/prompt.bash",
  "/etc/cmux/bashrc",
  "/etc/cmux/.prompt-identity",
  "/etc/cmux/vm-name",
  "/etc/bash.bashrc",
  "/etc/zsh/zshenv",
  ...distributionPaths(),
];
const promptName = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

// Validate, stage, and publish the shim and its companion files as one guest
// transaction. The prompt lock is held across the browser and prompt writes,
// so a rename cannot observe or race a partially-installed generation.
const install = String.raw`
import fcntl, hashlib, json, os, shutil, stat, subprocess, sys, tempfile
source, target, digest, browser, distribution, prompt_json, paths_json, transaction_token, cleanup = sys.argv[1:]
stage = "validate"
lock = None
backup_root = None
backups = {}
paths = list(dict.fromkeys(json.loads(paths_json)))
lock_path = "/etc/cmux/.prompt-lock"

def mime_paths():
    result = []
    for username in ("root", "cmux", "ubuntu"):
        try:
            lookup = subprocess.run(["getent", "passwd", username], check=False,
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError:
            continue
        fields = lookup.stdout.strip().split(":") if lookup.returncode == 0 else []
        home = fields[5] if len(fields) > 5 else ""
        if not home.startswith("/"):
            continue
        result.extend([
            os.path.join(home, ".config/mimeapps.list"),
            os.path.join(home, ".local/share/applications/mimeapps.list"),
        ])
    return result

paths = list(dict.fromkeys(paths + mime_paths()))

def parent_dirs(path):
    result = []
    current = os.path.dirname(path)
    while current and current != "/":
        result.append(current)
        current = os.path.dirname(current)
    return result

directory_paths = list(dict.fromkeys(
    os.path.dirname(path) for path in paths + [lock_path] if os.path.dirname(path)
))

def unsafe_symlink_target(path):
    return path.endswith("/bash.bashrc") or path.endswith("/zshenv") or path.endswith("/.config/mimeapps.list") or path.endswith("/.local/share/applications/mimeapps.list")

def validate_target(path):
    if os.path.lexists(path):
        if os.path.isdir(path) and not os.path.islink(path):
            raise IsADirectoryError(path)
        if os.path.islink(path) and unsafe_symlink_target(path):
            raise ValueError("refusing to mutate a symlink target")
        if not os.path.islink(path) and not stat.S_ISREG(os.lstat(path).st_mode):
            raise ValueError("target is not a regular file")
    parent = os.path.dirname(path)
    if os.path.islink(parent):
        raise ValueError("refusing a symlink parent directory")
    if os.path.lexists(parent) and not os.path.isdir(parent):
        raise NotADirectoryError(parent)

def remove_path(path):
    if not os.path.lexists(path):
        return
    if os.path.islink(path) or os.path.isfile(path):
        os.unlink(path)
        return
    if os.path.isdir(path):
        # Never recursively delete a guest directory while rolling back a
        # file install. An empty directory created by a failed shell command
        # is safe to remove; user data makes the rollback explicitly fail.
        os.rmdir(path)
        return
    raise ValueError("refusing to remove a non-file install target")

def snapshot_path(path):
    if not os.path.lexists(path):
        backups[path] = None
        return
    if os.path.isdir(path) and not os.path.islink(path):
        raise IsADirectoryError(path)
    if os.path.islink(path):
        backups[path] = ("link", os.readlink(path))
        return
    if not stat.S_ISREG(os.lstat(path).st_mode):
        raise ValueError("install target is not a regular file")
    backup = os.path.join(backup_root, str(len(backups)))
    metadata = os.stat(path, follow_symlinks=False)
    shutil.copyfile(path, backup)
    backups[path] = ("file", backup, metadata.st_mode, metadata.st_uid, metadata.st_gid, metadata.st_atime_ns, metadata.st_mtime_ns)

def restore_paths():
    failures = []
    for path, backup in reversed(list(backups.items())):
        try:
            remove_path(path)
            if backup is None:
                continue
            kind, value, *metadata = backup
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if kind == "link":
                os.symlink(value, path)
            else:
                shutil.copyfile(value, path)
                mode, uid, gid, atime_ns, mtime_ns = metadata
                os.chmod(path, stat.S_IMODE(mode), follow_symlinks=False)
                os.chown(path, uid, gid, follow_symlinks=False)
                os.utime(path, ns=(atime_ns, mtime_ns), follow_symlinks=False)
        except Exception as error:
            failures.append(error)
    if failures:
        raise RuntimeError("rollback failed")

def cleanup_generated():
    failures = []
    prefixes = [".prompt-" + transaction_token + "-", ".cmux-cli-", ".cmux-link-"]
    prefixes.extend(os.path.basename(path) + "." + transaction_token + "." for path in paths)
    for directory in directory_paths:
        if not os.path.isdir(directory) or os.path.islink(directory):
            continue
        try:
            for name in os.listdir(directory):
                if not any(name.startswith(prefix) for prefix in prefixes):
                    continue
                candidate = os.path.join(directory, name)
                if os.path.isfile(candidate) or os.path.islink(candidate):
                    os.unlink(candidate)
        except Exception as error:
            failures.append(error)
    if failures:
        raise RuntimeError("temporary cleanup failed")

def cleanup_created_directories(before):
    for directory in sorted(directory_paths, key=len, reverse=True):
        if before.get(directory, False) or not os.path.isdir(directory) or os.path.islink(directory):
            continue
        try:
            os.rmdir(directory)
        except OSError:
            # Non-empty directories are never recursively removed. They may
            # contain an existing guest file created outside this transaction.
            continue

def replace_file(directory, name, content):
    target_path = os.path.join(directory, name)
    if os.path.isfile(target_path) and not os.path.islink(target_path):
        with open(target_path, "r") as stream:
            if stream.read() == content:
                return
    fd, temporary = tempfile.mkstemp(prefix=".prompt-" + transaction_token + "-", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            os.fchmod(stream.fileno(), 0o644)
        os.replace(temporary, target_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

def install_prompt(payload):
    if not payload:
        return
    directory = "/etc/cmux"
    os.makedirs(directory, exist_ok=True)
    incoming = payload["identity"]
    try:
        with open(os.path.join(directory, ".prompt-identity")) as stream:
            current = json.load(stream)
    except (FileNotFoundError, ValueError, OSError):
        current = {}
    if not isinstance(current, dict) or not isinstance(current.get("revision", -1), int):
        current = {}
    if current.get("machineId") != incoming["machineId"] or current.get("revision", -1) <= incoming["revision"]:
        replace_file(directory, "vm-name", incoming["name"] + "\n")
        replace_file(directory, ".prompt-identity", json.dumps(incoming))
    for name, content in payload["files"].items():
        replace_file(directory, name, content)

try:
    os.makedirs(os.path.dirname(lock_path), exist_ok=True)
    lock = open(lock_path, "a+")
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    before_directories = {
        path: os.path.isdir(path) for path in directory_paths
    }
    for path in paths:
        validate_target(path)
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("upload is not a regular file")
        if hashlib.sha256(stream.read()).hexdigest() != digest:
            raise ValueError("upload checksum mismatch")
        os.fchmod(stream.fileno(), 0o755)
    backup_root = tempfile.mkdtemp(prefix=".cmux-install-", dir=os.path.dirname(lock_path))
    for path in paths:
        snapshot_path(path)
    stage = "verify"
    subprocess.run([source, "--help"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stage = "browser"
    subprocess.run(["/bin/sh", "-c", browser], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stage = "publish"
    subprocess.run(["/bin/sh", "-c", distribution], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stage = "prompt"
    install_prompt(json.loads(prompt_json) if prompt_json else None)
    stage = "publish"
    os.replace(source, target)
    # Distribution releases and aliases were snapshotted with the rest of the
    # install. Prune old releases only after every generation has published;
    # cleanup is best effort so a stale cache cannot turn a successful install
    # into a rollback after the active files are already committed.
    if cleanup:
        subprocess.run(["/bin/sh", "-c", cleanup], check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    cleanup_generated()
    shutil.rmtree(backup_root)
    backup_root = None
except Exception as error:
    rollback_error = None
    try:
        cleanup_generated()
    except Exception as cleanup_error:
        rollback_error = cleanup_error
    try:
        if backups:
            restore_paths()
    except Exception as restore_error:
        rollback_error = restore_error
    try:
        cleanup_created_directories(before_directories if "before_directories" in globals() else {})
    except Exception as directory_error:
        rollback_error = directory_error
    if backup_root:
        try:
            shutil.rmtree(backup_root)
        except Exception as backup_error:
            rollback_error = backup_error
    detail = {
        "stage": stage,
        "error": type(error).__name__,
        "rollbackError": type(rollback_error).__name__ if rollback_error else None,
        "errno": getattr(error, "errno", None),
        "exitCode": getattr(error, "returncode", None),
    }
    print("CMUX_GUEST_INSTALL_FAILURE=" + json.dumps(detail), file=sys.stderr)
    sys.exit(1)
finally:
    if lock is not None:
        fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        lock.close()
`;

export function guestCliInstallCommand(
  temporaryPath: string,
  identity?: GuestPromptIdentity,
  manifest: GuestCliDistribution = defaultGuestCliDistribution,
): string {
  if (identity && (!promptName.test(identity.name) || !Number.isSafeInteger(identity.revision))) {
    throw new Error("Invalid Cloud prompt identity");
  }
  const prompt = identity ? JSON.stringify({
    identity,
    files: guestPromptInstallFiles,
  }) : "";
  const transactionToken = temporaryPath.replace(/[^A-Za-z0-9_-]/g, "_");
  const browser = guestBrowserInstallCommand().replaceAll("XXXXXX", `${transactionToken}.XXXXXX`);
  const distribution = guestCliDistributionCommand(false, manifest, undefined, undefined, false);
  const cleanup = guestCliDistributionPruneCommand(manifest);
  const paths = manifest === defaultGuestCliDistribution
    ? installPaths
    : [
        ...installPaths.filter((path) => !path.startsWith("/usr/local/libexec/cmux-cloud-")),
        ...distributionPaths(manifest),
      ];
  return `python3 -c ${shellQuote(install)} ${shellQuote(temporaryPath)} ${shellQuote(GUEST_CMUX_SHIM_PATH)} ${shellQuote(digest)} ${shellQuote(browser)} ${shellQuote(distribution)} ${shellQuote(prompt)} ${shellQuote(JSON.stringify(paths))} ${shellQuote(transactionToken)} ${shellQuote(cleanup)}`;
}
