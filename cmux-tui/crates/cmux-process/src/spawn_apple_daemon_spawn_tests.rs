use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

use crate::Command;

/// A descriptor that already sits at the number the child should get it
/// at, close-on-exec (as every descriptor the daemon owns is), still
/// reaches the child (finding 2 of PL-daemon's review: `adddup2(fd, fd)`
/// keeps close-on-exec on macOS, and CLOEXEC_DEFAULT then closes it).
#[test]
fn a_descriptor_already_at_its_target_number_reaches_the_child() {
    const AT: i32 = 777;
    let mut fds = [0; 2];
    // SAFETY: pipe fills two descriptors.
    assert_eq!(unsafe { libc::pipe(fds.as_mut_ptr()) }, 0);
    // SAFETY: two new descriptors the test owns.
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    // SAFETY: dup2 onto a number no other test uses; F_SETFD on it.
    let at = unsafe {
        assert_eq!(libc::dup2(write.as_raw_fd(), AT), AT);
        assert_eq!(libc::fcntl(AT, libc::F_SETFD, libc::FD_CLOEXEC), 0);
        OwnedFd::from_raw_fd(AT)
    };
    drop(write);
    let mut command = Command::new("/bin/sh");
    command.args(["-c", "echo at-777 >&777"]);
    // Placed directly: `inherit_fd` would duplicate it to another number.
    command.inherit.push((at, AT));
    let mut child = command.spawn().unwrap();
    drop(command);
    assert!(child.wait().unwrap().success(), "the child could not write to 777");
    let mut got = String::new();
    std::fs::File::from(read).read_to_string(&mut got).unwrap();
    assert_eq!(got, "at-777\n");
}

/// A child that exited before `wait_timeout` registered its kqueue event
/// (a zombie: `EV_ADD` fails with ESRCH) is seen at once and reaped, not
/// waited on until the limit (finding 1 of PL-daemon's review).
#[test]
fn a_child_that_exited_before_the_registration_is_seen_at_once() {
    let mut child = Command::new("/usr/bin/true").spawn().unwrap();
    let pid = child.id() as libc::pid_t;
    // Block until it exited, without reaping it (WNOWAIT): a zombie.
    // SAFETY: zeroed siginfo is valid output storage for waitid.
    let mut info: libc::siginfo_t = unsafe { std::mem::zeroed() };
    // SAFETY: waitid writes one siginfo for this child.
    assert_eq!(
        unsafe {
            libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT)
        },
        0
    );
    let started = std::time::Instant::now();
    crate::child::exit_event_within(pid, std::time::Duration::from_secs(30)).unwrap();
    assert!(
        started.elapsed() < std::time::Duration::from_secs(5),
        "waited {:?} for a child that had exited",
        started.elapsed()
    );
    assert!(child.try_wait().unwrap().expect("reaped after the event").success());
}
