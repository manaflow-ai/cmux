//! The Unix parts of the client.

use std::io::{self, Read};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::process::CommandExt;

pub(super) const IDLE_ARGV: &[&[u8]] = &[b"/bin/sleep", b"1000000"];
pub(super) const ECHO_ARGV: &[&[u8]] = &[b"/bin/cat"];
pub(super) const ENTER: &[u8] = b"\n";

pub(super) fn cwd_bytes() -> Vec<u8> {
    std::env::current_dir().map(|p| p.as_os_str().as_bytes().to_vec()).unwrap_or_default()
}

/// Starts `daemon` in its own session and waits on a readiness pipe.
// The server outlives this client on purpose (it leaves our session with
// setsid); it is only waited for when it fails to start.
#[allow(clippy::zombie_processes)]
pub(super) fn spawn_server(daemon: &std::path::Path) -> io::Result<()> {
    let mut fds = [0; 2];
    // SAFETY: pipe writes two descriptors.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: both descriptors were just created and are owned here.
    let (rd, wr) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    let wr_fd = wr.as_raw_fd();
    let mut cmd = std::process::Command::new(daemon);
    cmd.env("MUX2_READY_FD", wr_fd.to_string())
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // SAFETY: setsid is async-signal-safe; the daemon leaves our session.
    unsafe {
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child = cmd
        .spawn()
        .map_err(|e| io::Error::other(format!("cannot start {}: {e}", daemon.display())))?;
    drop(wr);
    let mut byte = [0u8; 1];
    if std::fs::File::from(rd).read(&mut byte).unwrap_or(0) != 1 {
        let _ = child.wait();
        return Err(io::Error::other("server failed to start"));
    }
    Ok(())
}

pub(super) fn term_size() -> (u16, u16) {
    // SAFETY: TIOCGWINSZ into a zeroed winsize.
    let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
    if unsafe { libc::ioctl(1, libc::TIOCGWINSZ, &mut ws) } == 0 && ws.ws_col > 0 {
        (ws.ws_col, ws.ws_row)
    } else {
        (80, 24)
    }
}

pub(super) struct RawMode(libc::termios);

impl RawMode {
    pub(super) fn enter() -> Option<Self> {
        // SAFETY: tcgetattr/tcsetattr on stdin with valid termios storage.
        unsafe {
            let mut t: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &mut t) != 0 {
                return None;
            }
            let saved = t;
            libc::cfmakeraw(&mut t);
            libc::tcsetattr(0, libc::TCSANOW, &t);
            Some(RawMode(saved))
        }
    }
}

impl Drop for RawMode {
    fn drop(&mut self) {
        // SAFETY: restoring the saved termios.
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.0) };
    }
}

/// Calls `resized` on every SIGWINCH, from a sigwait thread, until it
/// returns false. Call before any other thread exists: SIGWINCH is blocked
/// in this thread, and threads started later inherit the mask.
pub(super) fn follow_resize(mut resized: impl FnMut() -> bool + Send + 'static) {
    // SAFETY: building and applying a signal mask.
    let mut winch: libc::sigset_t = unsafe { std::mem::zeroed() };
    unsafe {
        libc::sigemptyset(&mut winch);
        libc::sigaddset(&mut winch, libc::SIGWINCH);
        libc::pthread_sigmask(libc::SIG_BLOCK, &winch, std::ptr::null_mut());
    }
    std::thread::spawn(move || {
        loop {
            let mut sig = 0;
            // SAFETY: waiting on the blocked SIGWINCH set.
            if unsafe { libc::sigwait(&winch, &mut sig) } != 0 || !resized() {
                return;
            }
        }
    });
}
