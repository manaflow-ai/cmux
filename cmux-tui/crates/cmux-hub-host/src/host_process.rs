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
#[path = "host_process_tests.rs"]
mod tests;
