//! Offline renderer capture with an event-driven deadline and a byte budget.

use std::io::{self, Read};
use std::os::fd::AsRawFd;
use std::os::unix::process::CommandExt;
use std::process::{Child, Command, Output, Stdio};
use std::time::{Duration, Instant};

use crate::unix_process_scope::UnixChildExitSignal;

const MAX_OUTPUT: usize = 16 * 1024;

struct RendererChild {
    child: Child,
    exit: Option<UnixChildExitSignal>,
}

impl RendererChild {
    fn stop_group(&mut self) {
        // The child has not been reaped, so its dedicated PGID cannot have
        // been recycled. The renderer and its Python child share this group.
        if let Ok(group) = libc::pid_t::try_from(self.child.id()) {
            // SAFETY: process_group(0) assigned this still-owned child's PGID.
            unsafe { libc::killpg(group, libc::SIGKILL) };
        }
    }
}

impl Drop for RendererChild {
    fn drop(&mut self) {
        if let Some(exit) = self.exit.take() {
            self.stop_group();
            // The existing kernel exit observer also owns bounded cleanup:
            // a stalled child cannot hold the mux's creation lock indefinitely.
            exit.reap();
        }
    }
}

pub(super) fn capture(command: &mut Command, timeout: Duration) -> io::Result<Output> {
    let deadline = Instant::now() + timeout;
    command.process_group(0).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    let mut child = command.spawn()?;
    let exit = match UnixChildExitSignal::observe(child.id()) {
        Ok(exit) => exit,
        Err(error) => {
            if let Ok(group) = libc::pid_t::try_from(child.id()) {
                // SAFETY: this child owns its newly-created, unreaped group.
                unsafe { libc::killpg(group, libc::SIGKILL) };
            }
            let _ = child.wait();
            return Err(error);
        }
    };
    let mut owner = RendererChild { child, exit: Some(exit) };
    let mut pipe = owner.child.stdout.take().expect("renderer stdout is piped");
    let mut stdout = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "Cloud welcome renderer timed out",
            ));
        }
        let mut fd = libc::pollfd { fd: pipe.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let milliseconds = remaining.as_millis().clamp(1, i32::MAX as u128) as i32;
        // SAFETY: pipe owns this valid descriptor throughout poll.
        let ready = unsafe { libc::poll(&mut fd, 1, milliseconds) };
        if ready < 0 {
            let error = io::Error::last_os_error();
            if error.kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(error);
        }
        if ready == 0 {
            continue;
        }
        let mut buffer = [0u8; 1024];
        let count = pipe.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        if stdout.len() + count > MAX_OUTPUT {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Cloud welcome output exceeds its byte budget",
            ));
        }
        stdout.extend_from_slice(&buffer[..count]);
    }
    if !owner.exit.as_ref().expect("owned exit observer").wait_until(deadline)? {
        return Err(io::Error::new(io::ErrorKind::TimedOut, "Cloud welcome renderer timed out"));
    }
    owner.stop_group();
    let exit = owner.exit.take().expect("owned exit observer");
    let status = owner.child.wait();
    exit.finish();
    let status = status?;
    Ok(Output { status, stdout, stderr: Vec::new() })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cloud_bootstrap_renderer_bounds_time_and_output() {
        let mut fast = Command::new("/bin/sh");
        fast.args(["-c", "printf welcome"]);
        assert_eq!(capture(&mut fast, Duration::from_secs(2)).unwrap().stdout, b"welcome");
        let mut hung = Command::new("/bin/sh");
        hung.args(["-c", "exec sleep 60"]);
        let started = Instant::now();
        assert_eq!(
            capture(&mut hung, Duration::from_millis(50)).unwrap_err().kind(),
            io::ErrorKind::TimedOut
        );
        assert!(started.elapsed() < Duration::from_secs(2));
        let mut noisy = Command::new("/bin/sh");
        noisy.args(["-c", "while :; do printf 0123456789abcdef; done"]);
        assert_eq!(
            capture(&mut noisy, Duration::from_secs(2)).unwrap_err().kind(),
            io::ErrorKind::InvalidData
        );
    }
}
