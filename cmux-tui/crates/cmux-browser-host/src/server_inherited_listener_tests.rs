use super::*;
use std::os::fd::AsRawFd;

#[test]
fn sealing_sets_close_on_exec_on_every_inherited_descriptor() {
    let file = std::fs::File::open("/dev/null").unwrap();
    // A leaked copy without close-on-exec, as a launcher would pass it.
    // SAFETY: fcntl(2) and close(2) on our own fds.
    let leaked = unsafe { libc::fcntl(file.as_raw_fd(), libc::F_DUPFD, 3) };
    assert!(leaked >= 3);
    assert_eq!(unsafe { libc::fcntl(leaked, libc::F_GETFD) } & libc::FD_CLOEXEC, 0);
    seal_inherited_descriptors().unwrap();
    let flags = unsafe { libc::fcntl(leaked, libc::F_GETFD) };
    assert_ne!(flags & libc::FD_CLOEXEC, 0, "the leaked descriptor closes on exec");
    assert!(unsafe { libc::fcntl(0, libc::F_GETFD) } >= 0, "stdin stays open");
    unsafe { libc::close(leaked) };
}

#[test]
fn an_inherited_listener_closes_on_exec_again() {
    let dir = std::env::temp_dir().join(format!("cmux-bh-inherit-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let listener = UnixListener::bind(dir.join("s.sock")).unwrap();
    // As the daemon passes it: a copy without close-on-exec.
    // SAFETY: fcntl(2) on our own fds.
    let passed = unsafe { libc::fcntl(listener.as_raw_fd(), libc::F_DUPFD, 3) };
    assert!(passed >= 3);
    assert_eq!(unsafe { libc::fcntl(passed, libc::F_GETFD) } & libc::FD_CLOEXEC, 0);
    let inherited = inherited_listener(passed).unwrap();
    let flags = unsafe { libc::fcntl(inherited.as_raw_fd(), libc::F_GETFD) };
    assert_ne!(flags & libc::FD_CLOEXEC, 0, "close-on-exec is set again");
    drop(inherited);
    let _ = std::fs::remove_dir_all(&dir);
}
