//! Per-machine identity: the CRNG reseed and the bound-id write on the
//! critical path, and the `rekey` job body (machine-id, systemd random
//! seed, SSH host key) that runs off it in a low-priority child.
//!
//! The agent runs as root and some directories it writes into are owned by
//! the work user (`/run/cmux`, the session host's home). Writes there never
//! follow a symlink: files are created with `O_NOFOLLOW`, and the remote
//! identity removal refuses a path with a symlinked component.

use std::fs::{self, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::config::{
    BOUND_INSTANCE_FILE, CLONE_STARTED_FILE, DBUS_MACHINE_ID_FILE, DRIVER_FILE_NAME, ETC_DIR, MACHINE_ID_FILE, Paths,
    RANDOM_SEED_FILE, RUN_DIR, SSH_DIR,
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
        return Err(io::Error::last_os_error());
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
    OpenOptions::new()
        .write(true)
        .create(true)
        .mode(0o644)
        .custom_flags(libc::O_NOFOLLOW)
        .open(paths.at(CLONE_STARTED_FILE))
        .map(drop)
}

pub fn remove_driver_file(paths: &Paths) -> io::Result<()> {
    match fs::remove_file(paths.at(RUN_DIR).join(DRIVER_FILE_NAME)) {
        Err(err) if err.kind() != io::ErrorKind::NotFound => Err(err),
        _ => Ok(()),
    }
}

/// `path` and every component below `base` exist as real directories (or
/// are absent); `Err` on a symlinked component.
fn no_symlink_below(base: &Path, path: &Path) -> io::Result<bool> {
    let rel = path.strip_prefix(base).map_err(io::Error::other)?;
    let mut at = base.to_path_buf();
    for part in rel.components() {
        at.push(part);
        match fs::symlink_metadata(&at) {
            Ok(meta) if meta.file_type().is_symlink() => {
                return Err(io::Error::other(format!("{} is a symlink", at.display())));
            }
            Ok(_) => {}
            Err(err) if err.kind() == io::ErrorKind::NotFound => return Ok(false),
            Err(err) => return Err(err),
        }
    }
    Ok(true)
}

/// Drops the remote identity and connection state a fork inherited:
/// `<home>/.local/state/cmux/remote/sessions/*/auth` and `connections`.
pub fn drop_remote_identity(home: &Path) -> io::Result<()> {
    let remote = home.join(".local/state/cmux/remote");
    if !no_symlink_below(home, &remote)? {
        return Ok(());
    }
    let sessions = remote.join("sessions");
    if no_symlink_below(home, &sessions)? {
        for entry in fs::read_dir(&sessions)? {
            let auth = entry?.path().join("auth");
            if no_symlink_below(home, &auth)? {
                fs::remove_dir_all(&auth)?;
            }
        }
    }
    let connections = remote.join("connections");
    if no_symlink_below(home, &connections)? {
        fs::remove_dir_all(&connections)?;
    }
    Ok(())
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
pub fn rekey(paths: &Paths, instance_id: &str) -> io::Result<()> {
    let machine_id = hex(&random_bytes::<16>()?);
    write_atomic(&paths.at(MACHINE_ID_FILE), format!("{machine_id}\n").as_bytes(), 0o444)?;
    relink(&paths.at(DBUS_MACHINE_ID_FILE), Path::new(MACHINE_ID_FILE))?;
    // journald keeps writing under the old id's directory until restarted.
    systemctl(paths, &["restart", "systemd-journald.service"]);
    let seed_dir = paths.at("/var/lib/systemd");
    if seed_dir.is_dir() {
        write_atomic(&paths.at(RANDOM_SEED_FILE), &random_bytes::<512>()?, 0o600)?;
    }
    rekey_ssh(paths, instance_id)?;
    eprintln!("cmux-host: rekey done machine-id={machine_id}");
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

fn rekey_ssh(paths: &Paths, instance_id: &str) -> io::Result<()> {
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
        .args(["-q", "-t", "ed25519", "-N", "", "-C", instance_id, "-f"])
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

    #[test]
    fn drop_remote_identity_removes_auth_and_connections_only() {
        let home = tempfile::tempdir().unwrap();
        let remote = home.path().join(".local/state/cmux/remote");
        fs::create_dir_all(remote.join("sessions/cloud/auth")).unwrap();
        fs::write(remote.join("sessions/cloud/auth/identity.json"), "{}").unwrap();
        fs::write(remote.join("sessions/cloud/keep"), "x").unwrap();
        fs::create_dir_all(remote.join("connections/a")).unwrap();
        drop_remote_identity(home.path()).unwrap();
        assert!(!remote.join("sessions/cloud/auth").exists());
        assert!(!remote.join("connections").exists());
        assert!(remote.join("sessions/cloud/keep").exists());
        // Nothing there: a no-op.
        let empty = tempfile::tempdir().unwrap();
        drop_remote_identity(empty.path()).unwrap();
    }

    #[test]
    fn drop_remote_identity_refuses_symlinked_components() {
        let home = tempfile::tempdir().unwrap();
        let target = tempfile::tempdir().unwrap();
        fs::create_dir_all(target.path().join("connections")).unwrap();
        fs::create_dir_all(home.path().join(".local/state/cmux")).unwrap();
        symlink(target.path(), home.path().join(".local/state/cmux/remote")).unwrap();
        assert!(drop_remote_identity(home.path()).is_err());
        assert!(target.path().join("connections").exists());
    }

    #[test]
    fn rekey_writes_new_ids_under_root() {
        let root = tempfile::tempdir().unwrap();
        let paths = Paths::new(root.path());
        fs::create_dir_all(paths.at("/var/lib/systemd")).unwrap();
        rekey(&paths, "vm-1").unwrap();
        let first = fs::read_to_string(paths.at(MACHINE_ID_FILE)).unwrap();
        assert_eq!(first.trim().len(), 32);
        assert_eq!(fs::read_link(paths.at(DBUS_MACHINE_ID_FILE)).unwrap(), PathBuf::from(MACHINE_ID_FILE));
        assert_eq!(fs::metadata(paths.at(RANDOM_SEED_FILE)).unwrap().len(), 512);
        rekey(&paths, "vm-1").unwrap();
        assert_ne!(fs::read_to_string(paths.at(MACHINE_ID_FILE)).unwrap(), first);
    }

    #[test]
    fn clone_started_never_follows_a_symlink() {
        let root = tempfile::tempdir().unwrap();
        let paths = Paths::new(root.path());
        let victim = root.path().join("victim");
        fs::write(&victim, "keep").unwrap();
        fs::create_dir_all(paths.at(RUN_DIR)).unwrap();
        symlink(&victim, paths.at(CLONE_STARTED_FILE)).unwrap();
        assert!(mark_clone_started(&paths).is_err());
        assert_eq!(fs::read_to_string(&victim).unwrap(), "keep");
        fs::remove_file(paths.at(CLONE_STARTED_FILE)).unwrap();
        mark_clone_started(&paths).unwrap();
        write_bound(&paths, "vm-2").unwrap();
        assert_eq!(fs::read_to_string(paths.at(BOUND_INSTANCE_FILE)).unwrap(), "vm-2\n");
    }
}
