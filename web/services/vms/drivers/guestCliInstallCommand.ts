import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { GUEST_CMUX_SHIM, GUEST_CMUX_SHIM_PATH } from "../guestCli";
import { GUEST_BROWSER_FILES, guestBrowserInstallCommand } from "../guestBrowser";
import type { GuestPromptIdentity } from "../guestPrompt";
import { shellQuote } from "./cmuxTuiDaemon";

const digest = createHash("sha256").update(GUEST_CMUX_SHIM).digest("hex");
const promptAsset = (name: string) => readFileSync(
  fileURLToPath(new URL(`../images/devbox/${name}`, import.meta.url).toString()), "utf8",
);
const promptBash = promptAsset("cmux-prompt.bash");
const promptBashrc = promptAsset("cmux-bashrc");
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
];
const promptName = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/;

// Validate, stage, and publish the shim and its companion files as one guest
// transaction. The prompt lock is held across the browser and prompt writes,
// so a rename cannot observe or race a partially-installed generation.
const install = String.raw`
import fcntl, hashlib, json, os, pwd, shutil, stat, subprocess, sys, tempfile
source, target, digest, browser, prompt_json, paths_json = sys.argv[1:]
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
            home = pwd.getpwnam(username).pw_dir
        except KeyError:
            continue
        try:
            if not os.access(home, os.R_OK | os.X_OK):
                continue
        except OSError:
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
    parent for path in paths + [lock_path] for parent in parent_dirs(path)
))

def validate_target(path):
    if os.path.lexists(path):
        if os.path.isdir(path) and not os.path.islink(path):
            raise IsADirectoryError(path)
        if not os.path.islink(path) and not stat.S_ISREG(os.lstat(path).st_mode):
            raise ValueError("target is not a regular file")
    for parent in parent_dirs(path):
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
    shutil.copy2(path, backup)
    backups[path] = ("file", backup)

def restore_paths():
    failures = []
    for path, backup in reversed(list(backups.items())):
        try:
            remove_path(path)
            if backup is None:
                continue
            kind, value = backup
            os.makedirs(os.path.dirname(path), exist_ok=True)
            if kind == "link":
                os.symlink(value, path)
            else:
                shutil.copy2(value, path)
        except Exception as error:
            failures.append(error)
    if failures:
        raise RuntimeError("rollback failed")

def remember_directory_entries():
    return {
        path: set(os.listdir(path)) if os.path.isdir(path) else set()
        for path in directory_paths
    }

def cleanup_generated(entries):
    failures = []
    prefixes = [os.path.basename(path) + "." for path in paths]
    prefixes.append(".prompt-")
    for directory, before in entries.items():
        if not os.path.isdir(directory):
            continue
        try:
            for name in os.listdir(directory):
                if name in before or not any(name.startswith(prefix) for prefix in prefixes):
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
    fd, temporary = tempfile.mkstemp(prefix=".prompt-", dir=directory)
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
    before_entries = remember_directory_entries()
    stage = "verify"
    subprocess.run([source, "--help"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stage = "browser"
    subprocess.run(["/bin/sh", "-c", browser], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    stage = "prompt"
    install_prompt(json.loads(prompt_json) if prompt_json else None)
    stage = "publish"
    os.replace(source, target)
    cleanup_generated(before_entries)
    shutil.rmtree(backup_root)
    backup_root = None
except Exception as error:
    rollback_error = None
    try:
        cleanup_generated(before_entries if "before_entries" in globals() else {})
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
        "error": "RollbackError" if rollback_error else type(error).__name__,
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

export function guestCliInstallCommand(temporaryPath: string, identity?: GuestPromptIdentity): string {
  if (identity && (!promptName.test(identity.name) || !Number.isSafeInteger(identity.revision))) {
    throw new Error("Invalid Cloud prompt identity");
  }
  const prompt = identity ? JSON.stringify({
    identity,
    files: {
      "prompt.bash": promptBash,
      bashrc: promptBashrc,
    },
  }) : "";
  return `python3 -c ${shellQuote(install)} ${shellQuote(temporaryPath)} ${shellQuote(GUEST_CMUX_SHIM_PATH)} ${shellQuote(digest)} ${shellQuote(guestBrowserInstallCommand())} ${shellQuote(prompt)} ${shellQuote(JSON.stringify(installPaths))}`;
}
