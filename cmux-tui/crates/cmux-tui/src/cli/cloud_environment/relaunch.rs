//! The app starts this helper before quitting for an environment switch.
//! Wait for that exact process's exit, then reopen the same bundle behind
//! the user's foreground app. No updater or fixed-delay relaunch is involved.

use std::path::Path;

#[cfg(target_os = "macos")]
pub(super) fn after_exit(pid: i32, bundle: &Path) -> Result<(), String> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::time::{Duration, Instant};

    // SAFETY: kqueue returns a new descriptor with no Rust owner.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    // SAFETY: this function now owns the successfully created descriptor.
    let queue = unsafe { OwnedFd::from_raw_fd(queue) };
    let change = libc::kevent {
        ident: pid as usize,
        filter: libc::EVFILT_PROC,
        flags: libc::EV_ADD | libc::EV_ENABLE | libc::EV_ONESHOT,
        fflags: libc::NOTE_EXIT,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return Err("the app did not finish quitting within 60 seconds".into());
        }
        let timeout =
            libc::timespec { tv_sec: left.as_secs() as _, tv_nsec: left.subsec_nanos() as _ };
        let mut event = libc::kevent { udata: std::ptr::null_mut(), ..change };
        // SAFETY: both event pointers and the timeout remain valid for this
        // call. kevent waits on a process event; it does not poll the process.
        let found = unsafe { libc::kevent(queue.as_raw_fd(), &change, 1, &mut event, 1, &timeout) };
        if found < 0 {
            let error = std::io::Error::last_os_error();
            match error.raw_os_error() {
                Some(libc::EINTR) => continue,
                Some(libc::ESRCH) => break,
                _ => return Err(error.to_string()),
            }
        }
        if found == 0 {
            return Err("the app did not finish quitting within 60 seconds".into());
        }
        if event.flags & libc::EV_ERROR != 0 {
            if event.data == libc::ESRCH as _ {
                break;
            }
            return Err(std::io::Error::from_raw_os_error(event.data as i32).to_string());
        }
        if event.fflags & libc::NOTE_EXIT != 0 {
            break;
        }
    }
    let status = std::process::Command::new("/usr/bin/open")
        .arg("-g")
        .arg("-n")
        .arg(bundle)
        .status()
        .map_err(|error| error.to_string())?;
    if status.success() { Ok(()) } else { Err(format!("could not reopen the app: {status}")) }
}

#[cfg(not(target_os = "macos"))]
pub(super) fn after_exit(_pid: i32, _bundle: &Path) -> Result<(), String> {
    Err("app relaunch is available on macOS".into())
}
