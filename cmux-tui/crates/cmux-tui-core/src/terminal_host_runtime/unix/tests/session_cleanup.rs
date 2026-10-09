use std::io::{BufRead, BufReader, Write};
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdout, Command, Stdio};

use super::*;

struct SessionProcess {
    child: Child,
    output: BufReader<ChildStdout>,
}

impl SessionProcess {
    fn start() -> Self {
        let mut command = Command::new("/bin/sh");
        command
            .args([
                "-c",
                "trap '' HUP; printf 'ready\\n'; while IFS= read -r line; do printf '%s\\n' \"$line\"; done",
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped());
        // SAFETY: setsid is async-signal-safe and affects only our test child.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
            });
        }
        let mut child = command.spawn().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        let mut process = Self { child, output };
        process.expect_line("ready");
        process
    }

    fn expect_line(&mut self, expected: &str) {
        let mut line = String::new();
        self.output.read_line(&mut line).unwrap();
        assert_eq!(line.trim_end(), expected);
    }

    fn assert_responsive(&mut self) {
        self.child.stdin.as_mut().unwrap().write_all(b"still-alive\n").unwrap();
        self.expect_line("still-alive");
    }

    fn stop(&mut self) {
        if self.child.try_wait().unwrap().is_none() {
            let _ = self.child.kill();
            self.child.wait().unwrap();
        }
    }

    fn signal(&self, cleanup: &SessionCleanup, signal: libc::c_int, capture_allowed: bool) {
        // SAFETY: getpgrp has no preconditions.
        let host_group = unsafe { libc::getpgrp() };
        cleanup.signal(None, Some(self.child.id()), signal, host_group, capture_allowed);
    }
}

impl Drop for SessionProcess {
    fn drop(&mut self) {
        self.stop();
    }
}

#[test]
fn stale_session_identity_cannot_capture_or_signal_a_replacement_process() {
    let mut replacement = SessionProcess::start();
    let cleanup = SessionCleanup::new();
    replacement.signal(&cleanup, libc::SIGHUP, false);
    replacement.signal(&cleanup, libc::SIGKILL, false);
    replacement.assert_responsive();
}

#[test]
fn completed_session_cleanup_cannot_retarget_a_later_session() {
    let mut original = SessionProcess::start();
    let cleanup = SessionCleanup::new();
    original.signal(&cleanup, libc::SIGHUP, true);
    original.stop();
    assert!(cleanup.wait_for_exit(Duration::from_secs(1)));

    // A later Drop/Terminate must not bind this completed cleanup to a
    // session whose numeric PID is now reported by a stale caller.
    let mut replacement = SessionProcess::start();
    replacement.signal(&cleanup, libc::SIGHUP, true);
    replacement.signal(&cleanup, libc::SIGKILL, false);
    replacement.assert_responsive();
}

#[test]
fn live_session_members_cannot_complete_cleanup_at_the_wait_deadline() {
    let mut process = SessionProcess::start();
    let cleanup = SessionCleanup::new();
    process.signal(&cleanup, libc::SIGHUP, true);
    assert!(!cleanup.wait_for_exit(Duration::ZERO));
    process.assert_responsive();
    process.signal(&cleanup, libc::SIGKILL, false);
    process.child.wait().unwrap();
    assert!(cleanup.wait_for_exit(Duration::from_secs(1)));
}

#[test]
fn failed_session_scan_cannot_complete_cleanup() {
    let cleanup = SessionCleanup { captured: Mutex::new(CaptureState::ScanFailed) };
    assert!(!cleanup.wait_for_exit(Duration::ZERO));
}
