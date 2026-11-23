//! Whether the screen host (`cmux-rd linux-host run`) still runs, as a teardown sees it (review
//! F1 of #45369): whoever stops the host (cmux-rd's own teardown, `acpmux machine leave`) checks
//! that it is really gone instead of trusting `systemctl`, whether the unit started it, a person
//! did by hand or a restart did. The host holds an exclusive lock on [`PID_FILE`] in its config
//! directory for its whole life ([`hold`]) and writes its pid there. The kernel lets go of the
//! lock when the process ends, however it ends, so a stopper that takes the lock knows no host
//! runs; while the lock is held, the pid in the file is its holder's (its descriptor is
//! close-on-exec, so no child keeps it), and no process list is read.

use cmux_file_lock::{FileLock, Kind, LockError};
use std::fs::File;
use std::io::{Read, Write};
use std::path::Path;
use std::time::Duration;

/// In the host's config directory: locked by the running host, which writes its pid there.
pub const PID_FILE: &str = "host.pid";

/// How long a stopped host gets to end by itself before it is killed.
pub const STOP_WAIT: Duration = Duration::from_secs(5);

/// How long a killed host gets to be gone.
const KILL_WAIT: Duration = Duration::from_secs(2);

/// How often a stopper looks whether the host let go.
const STEP: Duration = Duration::from_millis(50);

/// Held by the running host while it lives.
#[derive(Debug)]
pub struct Running {
    _held: FileLock,
}

/// Taken by the host at start: an error when another host of `dir` already runs (its pid).
pub fn hold(dir: &Path) -> std::io::Result<Running> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(dir.join(PID_FILE))?;
    let mut held = match FileLock::try_take(file, Kind::Exclusive) {
        Ok(held) => held,
        Err(LockError::Busy(mut file)) => {
            return Err(std::io::Error::other(format!(
                "another screen host already runs{}",
                holder(&mut file).map(|pid| format!(" (pid {pid})")).unwrap_or_default()
            )));
        }
        Err(LockError::Io(e)) => return Err(e),
    };
    let file = held.file_mut();
    file.set_len(0)?;
    file.write_all(std::process::id().to_string().as_bytes())?;
    file.sync_all()?;
    Ok(Running { _held: held })
}

/// What a host of `dir` signs in with: while either is there, a host may serve from it.
const SIGN_IN_FILES: [&str; 2] = ["device.json", "account.json"];

/// Ok once no host of `dir` runs: at once when none holds [`PID_FILE`]; else after its holder
/// let go within `wait`, or was killed (its process group when it leads one, so its session
/// helpers go with it) and gone within two more seconds. Else the holder's pid, when the file
/// names one. With no [`PID_FILE`] at all, gone is proven only when `dir` has no sign-in either:
/// a host from a build older than the file (one a person started by hand, say) holds no lock,
/// so while a sign-in is there it may still run, and that is not verified (`Err(None)`).
pub fn ensure_gone(dir: &Path, wait: Duration) -> Result<(), Option<u32>> {
    let file = match File::open(dir.join(PID_FILE)) {
        Ok(file) => file,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            let signed_in = SIGN_IN_FILES.iter().any(|f| dir.join(f).symlink_metadata().is_ok());
            return if signed_in { Err(None) } else { Ok(()) };
        }
        Err(_) => return Err(None),
    };
    let mut file = match FileLock::take_within(file, Kind::Exclusive, wait, STEP) {
        Ok(_) => return Ok(()),
        Err(LockError::Busy(file)) => file,
        Err(LockError::Io(_)) => return Err(None),
    };
    let pid = holder(&mut file);
    if let Some(pid) = pid.and_then(|pid| libc::pid_t::try_from(pid).ok()) {
        // SAFETY: getpgrp, getpgid and kill take plain integers; a gone process only makes the
        // last two fail.
        unsafe {
            let ours = libc::getpgrp();
            if libc::getpgid(pid) == pid && pid != ours {
                libc::kill(-pid, libc::SIGKILL);
            } else {
                libc::kill(pid, libc::SIGKILL);
            }
        }
    }
    match FileLock::take_within(file, Kind::Exclusive, KILL_WAIT, STEP) {
        Ok(_) => Ok(()),
        Err(_) => Err(pid),
    }
}

/// The pid the holder of `file` wrote; None when it wrote none (yet).
fn holder(file: &mut File) -> Option<u32> {
    let mut text = String::new();
    file.read_to_string(&mut text).ok()?;
    text.trim().parse().ok().filter(|&pid| pid > 1)
}

#[cfg(test)]
#[cfg(target_os = "linux")]
mod tests {
    use super::*;
    use std::os::fd::AsFd;
    use std::time::Instant;

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("hub-host-process-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A host of `dir` that never stops by itself: a process in a group of its own that holds
    /// the lock on [`PID_FILE`] (its copy of the description) and wrote its pid there.
    fn stuck_host(dir: &Path) -> cmux_process::Child {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(dir.join(PID_FILE))
            .unwrap();
        file.lock().unwrap();
        let mut child = cmux_process::Command::new("sh");
        child.args(["-c", "trap '' TERM; sleep 30; :"]).process_group(0);
        child.inherit_fd(file.as_fd(), 9).unwrap();
        let child = child.spawn().unwrap();
        (&file).write_all(child.id().to_string().as_bytes()).unwrap();
        // Closed without unlocking: the child's copy keeps the lock.
        drop(file);
        child
    }

    #[test]
    fn a_host_that_does_not_stop_is_killed_and_then_gone() {
        let dir = scratch("stuck");
        let mut child = stuck_host(&dir);
        let other = hold(&dir).unwrap_err().to_string();
        assert!(other.contains(&format!("pid {}", child.id())), "{other}");
        let started = Instant::now();
        assert_eq!(ensure_gone(&dir, Duration::from_millis(100)), Ok(()));
        assert!(started.elapsed() < Duration::from_secs(2));
        let status = child.wait_timeout(Duration::from_secs(2)).unwrap().expect("still running");
        assert!(!status.success());
        // Gone: the next host starts and names itself.
        let _running = hold(&dir).unwrap();
        let text = std::fs::read_to_string(dir.join(PID_FILE)).unwrap();
        assert_eq!(text, std::process::id().to_string());
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Review of #45369: with a sign-in but no pid file, a host from an older build may run
    /// unseen, so gone is not verified; with neither, nothing can serve.
    #[test]
    fn a_sign_in_without_a_pid_file_is_not_verified_gone() {
        let dir = scratch("old-build");
        for file in SIGN_IN_FILES {
            std::fs::write(dir.join(file), b"{}").unwrap();
            assert_eq!(ensure_gone(&dir, Duration::from_millis(50)), Err(None), "{file}");
            std::fs::remove_file(dir.join(file)).unwrap();
        }
        assert_eq!(ensure_gone(&dir, Duration::from_millis(50)), Ok(()));
        // A host of this build that ran and stopped left its file: gone is proven by its lock.
        std::fs::write(dir.join("device.json"), b"{}").unwrap();
        drop(hold(&dir).unwrap());
        assert_eq!(ensure_gone(&dir, Duration::from_millis(50)), Ok(()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn no_host_is_gone_at_once_and_a_held_lock_is_one() {
        let dir = scratch("none");
        assert_eq!(ensure_gone(&dir, Duration::from_secs(5)), Ok(()), "no file");
        let running = hold(&dir).unwrap();
        assert!(hold(&dir).is_err(), "a second host started");
        drop(running);
        let started = Instant::now();
        assert_eq!(ensure_gone(&dir, Duration::from_secs(5)), Ok(()), "a host that stopped");
        assert!(started.elapsed() < Duration::from_secs(1));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
