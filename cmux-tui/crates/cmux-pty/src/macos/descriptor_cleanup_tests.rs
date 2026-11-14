use std::fs::File;
use std::os::fd::{AsRawFd, FromRawFd};

use super::{DescriptorCleanup, mark_inherited_descriptors_close_on_exec};

#[test]
fn cleanup_examines_the_open_descriptors_not_the_whole_limit() {
    let source = File::open("/dev/null").unwrap();
    let high = unsafe { libc::fcntl(source.as_raw_fd(), libc::F_DUPFD, 200) };
    assert!(high >= 200);
    let _inherited = unsafe { File::from_raw_fd(high) };
    let mut cleanup = DescriptorCleanup::new(65_536);
    let mut report = [-1; 2];
    assert_eq!(unsafe { libc::pipe(report.as_mut_ptr()) }, 0);
    let child = unsafe { libc::fork() };
    assert!(child >= 0);
    if child == 0 {
        // Only raw syscalls from here: the parent may have other threads.
        let code: u8 = match mark_inherited_descriptors_close_on_exec(&mut cleanup) {
            Ok(examined) => {
                let flags = unsafe { libc::fcntl(high, libc::F_GETFD) };
                if flags == -1 || flags & libc::FD_CLOEXEC == 0 {
                    2
                } else if examined > 1_000 {
                    3
                } else {
                    0
                }
            }
            Err(_) => 4,
        };
        unsafe {
            libc::write(report[1], (&raw const code).cast(), 1);
            libc::_exit(0);
        }
    }
    unsafe { libc::close(report[1]) };
    let mut code = 255_u8;
    assert_eq!(unsafe { libc::read(report[0], (&raw mut code).cast(), 1) }, 1);
    let mut status = 0;
    assert_eq!(unsafe { libc::waitpid(child, &mut status, 0) }, child);
    unsafe { libc::close(report[0]) };
    assert_ne!(code, 2, "the inherited descriptor {high} was left open across exec");
    assert_ne!(code, 4, "the descriptor cleanup failed");
    assert_eq!(
        code, 0,
        "the cleanup examined every descriptor number up to the 65,536 limit one by one"
    );
}
