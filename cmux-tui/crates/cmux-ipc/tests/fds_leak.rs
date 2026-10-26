//! `cmux_ipc::fds` leaks no descriptor: taken, still queued, and (on Linux)
//! truncated ones all close. One test in its own binary, so no other test opens or
//! closes descriptors while it counts.

#![cfg(unix)]

mod cmux_ipc_fds {
    use cmux_ipc::fds::{self, FdReceiver};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::net::UnixStream;

    fn open_descriptors() -> usize {
        // SAFETY: F_GETFD only asks whether a descriptor number is open.
        (0..4096).filter(|&fd| unsafe { libc::fcntl(fd, libc::F_GETFD) } >= 0).count()
    }

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut ends = [0; 2];
        // SAFETY: pipe fills two descriptors this test then owns.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both are fresh descriptors nothing else owns.
        unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) }
    }

    #[test]
    fn no_descriptor_leaks() {
        let before = open_descriptors();
        {
            let (sender, receiver_end) = UnixStream::pair().unwrap();
            let (a, b) = pipe();
            let (c, d) = pipe();
            fds::send_all(sender.as_raw_fd(), b"one", &[a.as_raw_fd(), b.as_raw_fd()]).unwrap();
            fds::send_all(sender.as_raw_fd(), b"two", &[c.as_raw_fd(), d.as_raw_fd()]).unwrap();
            let mut receiver = FdReceiver::default();
            let mut buf = Vec::new();
            while buf.len() < 6 {
                receiver.recv(receiver_end.as_raw_fd(), &mut buf, 64, |_| {}).unwrap();
            }
            assert_eq!(receiver.queued(), 4);
            drop(receiver.take(1).unwrap());
            // Three stay queued: dropping the receiver closes them.
            drop(receiver);

            // Linux closes the descriptors a truncated read dropped; XNU
            // leaves them installed (FdReceiver::recv), so only Linux counts them.
            #[cfg(target_os = "linux")]
            {
                fds::send_all(
                    sender.as_raw_fd(),
                    b"x",
                    &[a.as_raw_fd(), b.as_raw_fd(), c.as_raw_fd()],
                )
                .unwrap();
                let mut small = FdReceiver::with_capacity(1);
                assert!(small.recv(receiver_end.as_raw_fd(), &mut Vec::new(), 16, |_| {}).is_err());
            }
        }
        assert_eq!(open_descriptors(), before, "a descriptor stayed open");
    }
}
