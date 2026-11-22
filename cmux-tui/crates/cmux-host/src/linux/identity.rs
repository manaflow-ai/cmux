//! Per-machine identity: the CRNG reseed and the bound-id write on the
//! critical path, and the `rekey` job body (machine-id, systemd random
//! seed, SSH host key) that runs off it in a low-priority child.
//!
//! The agent runs as root and some directories it writes into are owned by
//! the work user (`/run/cmux`, the session host's home). Writes there never
//! follow a symlink: files are created with `O_NOFOLLOW`, and the remote
//! identity removal walks directory descriptors opened with `O_NOFOLLOW`.

use std::ffi::{CStr, CString};
use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::config::{
    BOUND_INSTANCE_FILE, CLONE_STARTED_FILE, DBUS_MACHINE_ID_FILE, DRIVER_FILE_NAME, ETC_DIR,
    MACHINE_ID_FILE, Paths, RANDOM_SEED_FILE, RUN_DIR, SSH_DIR,
};
use crate::linux::spawn::{has_systemd, which};

/// `RNDRESEEDCRNG`: force the kernel CRNG to reseed from the input pool.
const RNDRESEEDCRNG: libc::c_ulong = 0x5207;

fn random_bytes<const N: usize>() -> io::Result<[u8; N]> {
    let mut out = [0u8; N];
    let mut filled = 0;
    while filled < N {
        // SAFETY: writes at most N - filled bytes into `out`.
        let n = unsafe { libc::getrandom(out[filled..].as_mut_ptr().cast(), N - filled, 0) };
        if n < 0 {
            let err = io::Error::last_os_error();
            if err.raw_os_error() == Some(libc::EINTR) {
                continue;
            }
            return Err(err);
        }
        filled += n as usize;
    }
    Ok(out)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Mixes the instance id, fresh random bytes, the time and the pid into
/// the input pool, then forces a CRNG reseed. Runs before anything makes a
/// key: clones made seconds after a snapshot share CRNG output otherwise.
pub fn reseed(instance_id: &str) -> io::Result<()> {
    let mut urandom = OpenOptions::new().write(true).open("/dev/urandom")?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let fresh = random_bytes::<32>()?;
    let mix = format!("{instance_id}:{now}:{}:{}", std::process::id(), hex(&fresh));
    urandom.write_all(mix.as_bytes())?;
    // SAFETY: RNDRESEEDCRNG takes no argument.
    if unsafe { libc::ioctl(urandom.as_raw_fd(), RNDRESEEDCRNG as _, 0) } < 0 {
        let err = io::Error::last_os_error();
        // An unprivileged agent (a user-mode server, never a clone's
        // root agent) cannot force a reseed; the mixed-in bytes still
        // count. As root, EPERM is a real failure and stops the bind.
        // SAFETY: geteuid has no preconditions.
        if err.raw_os_error() == Some(libc::EPERM) && unsafe { libc::geteuid() } != 0 {
            eprintln!("cmux-host: reseed ioctl needs root; input pool mixed only");
            return Ok(());
        }
        return Err(err);
    }
    Ok(())
}

/// Writes `contents` to `path` through a same-directory temp file and a
/// rename, with `mode`.
pub fn write_atomic(path: &Path, contents: &[u8], mode: u32) -> io::Result<()> {
    let dir = path.parent().ok_or_else(|| io::Error::other("no parent"))?;
    fs::create_dir_all(dir)?;
    let name = path.file_name().ok_or_else(|| io::Error::other("no file name"))?.to_string_lossy();
    let tmp = dir.join(format!(".{name}.cmux-host-{}", std::process::id()));
    let _ = fs::remove_file(&tmp);
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(mode)
        .custom_flags(libc::O_NOFOLLOW)
        .open(&tmp)?;
    file.write_all(contents)?;
    file.set_permissions(fs::Permissions::from_mode(mode))?;
    file.sync_all()?;
    fs::rename(&tmp, path)
}

pub fn write_bound(paths: &Paths, instance_id: &str) -> io::Result<()> {
    fs::create_dir_all(paths.at(ETC_DIR))?;
    write_atomic(&paths.at(BOUND_INSTANCE_FILE), format!("{instance_id}\n").as_bytes(), 0o644)
}

/// Creates `/run/cmux/clone-started` (empty). The directory belongs to the
/// work user, so the file is created without following a symlink and is
/// never truncated.
pub fn mark_clone_started(paths: &Paths) -> io::Result<()> {
    fs::create_dir_all(paths.at(RUN_DIR))?;
    // O_NONBLOCK: a FIFO planted under this name must not block the agent.
    let file = OpenOptions::new()
        .write(true)
        .create(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(paths.at(CLONE_STARTED_FILE))?;
    if !file.metadata()?.file_type().is_file() {
        return Err(io::Error::other("clone-started is not a regular file"));
    }
    Ok(())
}

pub fn remove_driver_file(paths: &Paths) -> io::Result<()> {
    match fs::remove_file(paths.at(RUN_DIR).join(DRIVER_FILE_NAME)) {
        Err(err) if err.kind() != io::ErrorKind::NotFound => Err(err),
        _ => Ok(()),
    }
}

/// The remote state root below the session host's home.
const REMOTE_STATE_COMPONENTS: [&str; 4] = [".local", "state", "cmux", "remote"];
/// Deeper trees are refused, so a planted tree cannot exhaust descriptors.
const MAX_REMOVE_DEPTH: usize = 64;

/// Drops the remote daemon state a fork inherited: every session under
/// `<home>/.local/state/cmux/remote/sessions` (its identity and
/// authorization under `auth/`, and the lifecycle fence, shutdown record and
/// runtime metadata beside it) and `connections`.
///
/// The whole session goes, not only `auth/`: cmux-tui refuses to start a
/// session that holds a lifecycle fence but no `auth/` (it reads that as a
/// pre-fence daemon whose shutdown never finished), so dropping `auth/`
/// alone left every rebound machine's session host exiting at startup. The
/// session host is stopped before this runs (the bind waits for it), so no
/// live daemon owns the state.
///
/// The agent is root and the tree belongs to the work user, so every step
/// goes through a directory descriptor opened with `O_NOFOLLOW`: a
/// component swapped for a symlink at any moment is refused (on the way
/// to `remote`) or unlinked (below it), never followed.
pub fn drop_remote_identity(home: &Path) -> io::Result<()> {
    let mut dir = match open_dir(home) {
        Ok(fd) => fd,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err),
    };
    for component in REMOTE_STATE_COMPONENTS {
        dir = match open_dir_at(&dir, &c_name(component)?) {
            Ok(fd) => fd,
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
            Err(err) if is_not_a_directory(&err) => {
                return Err(io::Error::other(format!(
                    "{component} below {} is not a directory",
                    home.display()
                )));
            }
            Err(err) => return Err(err),
        };
    }
    remove_tree_at(&dir, &c_name("sessions")?, 0)?;
    remove_tree_at(&dir, &c_name("connections")?, 0)
}

fn c_name(name: &str) -> io::Result<CString> {
    CString::new(name).map_err(io::Error::other)
}

fn open_dir(path: &Path) -> io::Result<OwnedFd> {
    let path = CString::new(path.as_os_str().as_bytes()).map_err(io::Error::other)?;
    // SAFETY: a NUL-terminated path; the descriptor is owned at once.
    let fd =
        unsafe { libc::open(path.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` was just opened and is not owned elsewhere.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// `name` in `parent` as a directory, never through a symlink.
fn open_dir_at(parent: &OwnedFd, name: &CStr) -> io::Result<OwnedFd> {
    // SAFETY: a valid directory descriptor and a NUL-terminated name.
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
        )
    };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `fd` was just opened and is not owned elsewhere.
    Ok(unsafe { OwnedFd::from_raw_fd(fd) })
}

/// `O_NOFOLLOW | O_DIRECTORY` on a symlink or a file.
fn is_not_a_directory(err: &io::Error) -> bool {
    matches!(err.raw_os_error(), Some(libc::ELOOP) | Some(libc::ENOTDIR))
}

fn unlink_at(parent: &OwnedFd, name: &CStr, flags: libc::c_int) -> io::Result<()> {
    // SAFETY: a valid directory descriptor and a NUL-terminated name.
    if unsafe { libc::unlinkat(parent.as_raw_fd(), name.as_ptr(), flags) } < 0 {
        let err = io::Error::last_os_error();
        if err.kind() == io::ErrorKind::NotFound {
            return Ok(());
        }
        return Err(err);
    }
    Ok(())
}

/// Removes `name` in `parent`: a directory tree, or a file or symlink (the
/// entry itself). Absent is done.
fn remove_tree_at(parent: &OwnedFd, name: &CStr, depth: usize) -> io::Result<()> {
    let dir = match open_dir_at(parent, name) {
        Ok(fd) => fd,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(err) if is_not_a_directory(&err) => return unlink_at(parent, name, 0),
        Err(err) => return Err(err),
    };
    if depth >= MAX_REMOVE_DEPTH {
        return Err(io::Error::other("remote state tree is too deep to remove"));
    }
    for entry in dir_entries(&dir)? {
        remove_tree_at(&dir, &entry, depth + 1)?;
    }
    unlink_at(parent, name, libc::AT_REMOVEDIR)
}

/// The entry names of `dir`, without `.` and `..`.
fn dir_entries(dir: &OwnedFd) -> io::Result<Vec<CString>> {
    // fdopendir takes ownership of its descriptor: give it a duplicate.
    // SAFETY: duplicating a valid descriptor.
    let dup = unsafe { libc::fcntl(dir.as_raw_fd(), libc::F_DUPFD_CLOEXEC, 0) };
    if dup < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `dup` is a directory descriptor nothing else owns.
    let stream = unsafe { libc::fdopendir(dup) };
    if stream.is_null() {
        let err = io::Error::last_os_error();
        // SAFETY: fdopendir failed, so `dup` is still ours to close.
        unsafe { libc::close(dup) };
        return Err(err);
    }
    let mut names = Vec::new();
    let result = loop {
        // SAFETY: errno is thread-local; reset it to tell end from error.
        unsafe { *libc::__errno_location() = 0 };
        // SAFETY: `stream` is a valid open directory stream.
        let entry = unsafe { libc::readdir(stream) };
        if entry.is_null() {
            let err = io::Error::last_os_error();
            break if err.raw_os_error().unwrap_or(0) == 0 { Ok(()) } else { Err(err) };
        }
        // SAFETY: `d_name` is NUL-terminated and valid until the next readdir.
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) };
        if name.to_bytes() != b"." && name.to_bytes() != b".." {
            names.push(name.to_owned());
        }
    };
    // SAFETY: closes the stream and `dup` with it.
    unsafe { libc::closedir(stream) };
    result.map(|()| names)
}

fn systemctl(paths: &Paths, args: &[&str]) {
    if has_systemd(paths) {
        let _ = Command::new("systemctl").args(args).stdin(Stdio::null()).status();
    }
}

/// The `rekey` job: new machine-id (and the D-Bus link) then a journald
/// restart, a new systemd random seed, and a new ed25519 SSH host key
/// staged then renamed into place. Inherited RSA and ECDSA host keys are
/// removed: they are the snapshot builder's and shared by every clone.
///
/// Each step runs even when an earlier one failed; the first error is
/// returned at the end.
pub fn rekey(paths: &Paths, instance_id: &str) -> io::Result<()> {
    let mut first_error = None;
    let mut step = |name: &str, result: io::Result<()>| {
        if let Err(err) = result {
            eprintln!("cmux-host: rekey {name}: {err}");
            first_error.get_or_insert(err);
        }
    };
    step("machine-id", rekey_machine_id(paths));
    // journald keeps writing under the old id's directory until restarted.
    systemctl(paths, &["restart", "systemd-journald.service"]);
    let seed_dir = paths.at("/var/lib/systemd");
    if seed_dir.is_dir() {
        step(
            "random-seed",
            random_bytes::<512>()
                .and_then(|seed| write_atomic(&paths.at(RANDOM_SEED_FILE), &seed, 0o600)),
        );
    }
    eprintln!("cmux-host: rekey for instance {instance_id}");
    step("ssh", rekey_ssh(paths));
    match first_error {
        Some(err) => Err(err),
        None => Ok(()),
    }
}

fn rekey_machine_id(paths: &Paths) -> io::Result<()> {
    let machine_id = hex(&random_bytes::<16>()?);
    write_atomic(&paths.at(MACHINE_ID_FILE), format!("{machine_id}\n").as_bytes(), 0o444)?;
    relink(&paths.at(DBUS_MACHINE_ID_FILE), Path::new(MACHINE_ID_FILE))?;
    eprintln!("cmux-host: new machine-id={machine_id}");
    Ok(())
}

/// `link` -> `target`, replaced atomically.
fn relink(link: &Path, target: &Path) -> io::Result<()> {
    let dir = link.parent().ok_or_else(|| io::Error::other("no parent"))?;
    fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".machine-id.cmux-host-{}", std::process::id()));
    let _ = fs::remove_file(&tmp);
    symlink(target, &tmp)?;
    fs::rename(&tmp, link)
}

/// `root@<hostname>`, the comment `ssh-keygen -A` writes (the image identity
/// contract checks it). The static name in `/etc/hostname`, else the kernel's.
fn ssh_key_comment(paths: &Paths) -> String {
    let read = |path: PathBuf| fs::read_to_string(path).ok().map(|s| s.trim().to_owned());
    let host = read(paths.at("/etc/hostname"))
        .filter(|s| !s.is_empty())
        .or_else(|| read(PathBuf::from("/proc/sys/kernel/hostname")).filter(|s| !s.is_empty()))
        .unwrap_or_else(|| "localhost".to_owned());
    format!("root@{host}")
}

fn rekey_ssh(paths: &Paths) -> io::Result<()> {
    let ssh_dir = paths.at(SSH_DIR);
    let Some(keygen) = which("ssh-keygen") else { return Ok(()) };
    if !ssh_dir.is_dir() {
        return Ok(());
    }
    let stage = ssh_dir.join(format!(".cmux-rekey.{}", std::process::id()));
    let _ = fs::remove_dir_all(&stage);
    fs::create_dir(&stage)?;
    fs::set_permissions(&stage, fs::Permissions::from_mode(0o700))?;
    let key = stage.join("ssh_host_ed25519_key");
    let status = Command::new(keygen)
        .args(["-q", "-t", "ed25519", "-N", "", "-C", &ssh_key_comment(paths), "-f"])
        .arg(&key)
        .stdin(Stdio::null())
        .status();
    let result = match status {
        Ok(s) if s.success() && key.is_file() => install_ssh_key(&ssh_dir, &key),
        Ok(s) => Err(io::Error::other(format!("ssh-keygen exited {s}; keeping the existing keys"))),
        Err(err) => Err(err),
    };
    let _ = fs::remove_dir_all(&stage);
    result?;
    for old in ["ssh_host_rsa_key", "ssh_host_ecdsa_key", "ssh_host_dsa_key"] {
        for name in [old.to_owned(), format!("{old}.pub")] {
            let _ = fs::remove_file(ssh_dir.join(name));
        }
    }
    systemctl(paths, &["try-restart", "ssh.service"]);
    Ok(())
}

fn install_ssh_key(ssh_dir: &Path, key: &Path) -> io::Result<()> {
    let pub_key = PathBuf::from(format!("{}.pub", key.display()));
    fs::rename(&pub_key, ssh_dir.join("ssh_host_ed25519_key.pub"))?;
    fs::rename(key, ssh_dir.join("ssh_host_ed25519_key"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(home: &Path) -> PathBuf {
        home.join(".local/state/cmux/remote/sessions/Y2xvdWQ")
    }

    /// A rebind must not leave the shape cmux-tui refuses at startup: a
    /// lifecycle fence with no `auth/`.
    #[test]
    fn drop_remote_identity_removes_the_whole_session_with_its_lifecycle_fence() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path();
        let session = session(home);
        fs::create_dir_all(session.join("auth")).unwrap();
        fs::write(session.join("auth/devices.json"), "{}").unwrap();
        fs::write(session.join("lifecycle-fence.json"), "{}").unwrap();
        fs::write(session.join("runtime.json"), "{}").unwrap();
        let remote = home.join(".local/state/cmux/remote");
        fs::create_dir_all(remote.join("connections")).unwrap();
        fs::create_dir_all(remote.join("private")).unwrap();

        drop_remote_identity(home).unwrap();

        assert!(!session.join("lifecycle-fence.json").exists());
        assert!(!remote.join("sessions").exists());
        assert!(!remote.join("connections").exists());
        // Client-side state beside the sessions is not the daemon's.
        assert!(remote.join("private").is_dir());
        // Idempotent: a second bind finds nothing to drop.
        drop_remote_identity(home).unwrap();
    }

    /// A stranded session from an older agent (fence, no `auth/`) is
    /// repaired by the next bind too.
    #[test]
    fn drop_remote_identity_clears_a_fence_left_without_auth() {
        let dir = tempfile::tempdir().unwrap();
        let session = session(dir.path());
        fs::create_dir_all(&session).unwrap();
        fs::write(session.join("lifecycle-fence.json"), "{}").unwrap();

        drop_remote_identity(dir.path()).unwrap();

        assert!(!session.exists());
    }

    #[test]
    fn drop_remote_identity_unlinks_a_symlinked_sessions_dir_without_following_it() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let outside = dir.path().join("outside");
        fs::create_dir_all(outside.join("Y2xvdWQ/auth")).unwrap();
        let remote = home.join(".local/state/cmux/remote");
        fs::create_dir_all(&remote).unwrap();
        symlink(&outside, remote.join("sessions")).unwrap();

        drop_remote_identity(&home).unwrap();

        assert!(fs::symlink_metadata(remote.join("sessions")).is_err());
        assert!(outside.join("Y2xvdWQ/auth").is_dir());
    }

    #[test]
    fn drop_remote_identity_refuses_a_symlinked_component_above_sessions() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let outside = dir.path().join("outside");
        fs::create_dir_all(outside.join("sessions/Y2xvdWQ/auth")).unwrap();
        fs::create_dir_all(home.join(".local/state/cmux")).unwrap();
        symlink(&outside, home.join(".local/state/cmux/remote")).unwrap();

        assert!(drop_remote_identity(&home).is_err());
        assert!(outside.join("sessions/Y2xvdWQ/auth").is_dir());
    }

    #[test]
    fn drop_remote_identity_unlinks_nested_symlinks_without_following_them() {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let outside = dir.path().join("outside");
        fs::create_dir_all(outside.join("keep")).unwrap();
        let session = session(&home);
        fs::create_dir_all(session.join("auth")).unwrap();
        symlink(&outside, session.join("auth/link")).unwrap();

        drop_remote_identity(&home).unwrap();

        assert!(!session.exists());
        assert!(outside.join("keep").is_dir());
    }

    #[test]
    fn drop_remote_identity_without_remote_state_is_a_no_op() {
        let dir = tempfile::tempdir().unwrap();
        drop_remote_identity(dir.path()).unwrap();
        drop_remote_identity(&dir.path().join("missing-home")).unwrap();
    }
}
