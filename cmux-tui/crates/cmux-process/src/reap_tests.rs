//! A handed-over child is waited for; a dropped one stays a zombie.

use std::io::Write as _;
use std::time::{Duration, Instant};

use crate::{Command, Stdio, reap_in_background};

/// Whether process `pid` still exists (running or a zombie): `kill(pid, 0)`
/// succeeds for a zombie and fails with ESRCH once it is reaped.
fn exists(pid: u32) -> bool {
    let pid = libc::pid_t::try_from(pid).unwrap();
    // SAFETY: signal 0 only checks that the process exists.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// Blocks until `pid` has ended, without reaping it (`WNOWAIT`).
fn wait_exited_unreaped(pid: u32) {
    let id = libc::id_t::try_from(pid).unwrap();
    // SAFETY: an all-zero siginfo_t is valid; waitid fills it.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: waitid writes only into `info`; WNOWAIT leaves the child waitable.
    let rc = unsafe { libc::waitid(libc::P_PID, id, &mut info, libc::WEXITED | libc::WNOWAIT) };
    assert_eq!(rc, 0, "waitid: {}", std::io::Error::last_os_error());
}

/// Whether `pid` is gone within `bound`: the reaper waits on another thread.
fn gone_within(pid: u32, bound: Duration) -> bool {
    let deadline = Instant::now() + bound;
    while Instant::now() < deadline {
        if !exists(pid) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    !exists(pid)
}

/// A child that runs until a line arrives on its stdin.
fn reader_child() -> std::process::Child {
    std::process::Command::new("sh")
        .args(["-c", "read line"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::null())
        .spawn()
        .unwrap()
}

#[test]
fn a_dropped_child_stays_a_zombie() {
    let mut child = reader_child();
    let pid = child.id();
    drop(child.stdin.take());
    drop(child);
    wait_exited_unreaped(pid);
    assert!(exists(pid), "an ended child nobody waited for is a zombie");
    // SAFETY: reaps this test's own child, so the test leaves no zombie.
    unsafe { libc::waitpid(libc::pid_t::try_from(pid).unwrap(), std::ptr::null_mut(), 0) };
}

#[test]
fn a_std_child_handed_to_the_reaper_is_reaped_when_it_ends() {
    let mut child = reader_child();
    let pid = child.id();
    let mut stdin = child.stdin.take().unwrap();
    reap_in_background(child).unwrap();
    assert!(exists(pid), "the reaper does not end the child");
    stdin.write_all(b"done\n").unwrap();
    drop(stdin);
    assert!(gone_within(pid, Duration::from_secs(10)), "the ended child was not reaped");
}

#[test]
fn a_cmux_process_child_handed_to_the_reaper_is_reaped_when_it_ends() {
    let child = Command::new("sh").args(["-c", "exit 0"]).stdin(Stdio::null()).spawn().unwrap();
    let pid = child.id();
    reap_in_background(child).unwrap();
    assert!(gone_within(pid, Duration::from_secs(10)), "the ended child was not reaped");
}
