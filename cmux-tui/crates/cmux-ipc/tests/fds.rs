//! `cmux_ipc::fds` over a real socketpair: order, the per-frame cap, a
//! truncated control buffer, the receive capacity, and close-on-exec.

#![cfg(unix)]

mod cmux_ipc_fds {
    use cmux_ipc::fds::{self, FdBadMessage, FdReceiver, MAX_FDS_PER_FRAME};
    use std::io;
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
    use std::os::unix::net::UnixStream;

    fn pipe() -> (OwnedFd, OwnedFd) {
        let mut ends = [0; 2];
        // SAFETY: pipe fills two descriptors this test then owns.
        assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
        // SAFETY: both are fresh descriptors nothing else owns.
        unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) }
    }

    /// The (device, inode, access mode) of the file a descriptor names: a
    /// received copy has another number but the same file and mode.
    fn identity(fd: RawFd) -> (u64, u64, libc::c_int) {
        // SAFETY: zeroed stat is a valid out-parameter.
        let mut st: libc::stat = unsafe { std::mem::zeroed() };
        // SAFETY: fstat writes one stat for a live descriptor.
        assert_eq!(unsafe { libc::fstat(fd, &mut st) }, 0, "{}", io::Error::last_os_error());
        // SAFETY: F_GETFL of a live descriptor.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFL) };
        assert!(flags >= 0, "F_GETFL: {}", io::Error::last_os_error());
        (st.st_dev as u64, st.st_ino as u64, flags & libc::O_ACCMODE)
    }

    fn is_open(fd: RawFd) -> bool {
        // SAFETY: F_GETFD only asks whether a descriptor number is open.
        unsafe { libc::fcntl(fd, libc::F_GETFD) >= 0 }
    }

    /// The `FdBadMessage` source of a receive error.
    fn bad_message(error: &io::Error) -> Option<FdBadMessage> {
        error.get_ref().and_then(|e| e.downcast_ref::<FdBadMessage>()).copied()
    }

    fn close_on_exec(fd: &OwnedFd) -> bool {
        // SAFETY: F_GETFD of a descriptor this test owns.
        let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
        assert!(flags >= 0, "F_GETFD: {}", io::Error::last_os_error());
        flags & libc::FD_CLOEXEC != 0
    }

    /// Read until `want` bytes arrived.
    fn recv_bytes(receiver: &mut FdReceiver, socket: &UnixStream, want: usize) -> Vec<u8> {
        let mut buf = Vec::new();
        while buf.len() < want {
            let n = receiver.recv(socket.as_raw_fd(), &mut buf, 64, |_| {}).unwrap();
            assert_ne!(n, 0, "the stream ended early");
        }
        buf
    }

    /// Three descriptors over two frames (two, then one) arrive in order:
    /// each frame takes its own, in the order it sent them, by file identity.
    #[test]
    fn three_fds_over_two_frames_arrive_in_order() {
        let (sender, receiver_end) = UnixStream::pair().unwrap();
        let (a, _a_write) = pipe();
        let (_b_read, b) = pipe();
        let (c, _c_write) = pipe();
        let sent = [identity(a.as_raw_fd()), identity(b.as_raw_fd()), identity(c.as_raw_fd())];
        assert!(
            sent[0] != sent[1] && sent[1] != sent[2] && sent[0] != sent[2],
            "the three descriptors must be told apart"
        );
        fds::send_all(sender.as_raw_fd(), b"frame-one", &[a.as_raw_fd(), b.as_raw_fd()]).unwrap();
        fds::send_all(sender.as_raw_fd(), b"frame-two", &[c.as_raw_fd()]).unwrap();

        let mut receiver = FdReceiver::default();
        let bytes = recv_bytes(&mut receiver, &receiver_end, 18);
        assert_eq!(bytes, b"frame-oneframe-two", "the bytes are unchanged");
        assert_eq!(receiver.queued(), 3);
        let first = receiver.take(2).unwrap();
        let second = receiver.take(1).unwrap();
        let ids =
            |fds: &[OwnedFd]| fds.iter().map(|fd| identity(fd.as_raw_fd())).collect::<Vec<_>>();
        assert_eq!(ids(&first), [identity(a.as_raw_fd()), identity(b.as_raw_fd())]);
        assert_eq!(ids(&second), [identity(c.as_raw_fd())]);
        assert_eq!(receiver.queued(), 0);
        assert!(receiver.take(1).unwrap().is_empty(), "an empty queue gives none");
    }

    /// Every received descriptor is close-on-exec, though the sender's are not.
    #[test]
    fn received_descriptors_are_close_on_exec() {
        let (sender, receiver_end) = UnixStream::pair().unwrap();
        let (read_end, write_end) = pipe();
        assert!(!close_on_exec(&read_end) && !close_on_exec(&write_end), "pipe() sets no flag");
        fds::send_all(sender.as_raw_fd(), b"x", &[read_end.as_raw_fd(), write_end.as_raw_fd()])
            .unwrap();
        let mut receiver = FdReceiver::default();
        let mut seen = 0;
        let mut buf = Vec::new();
        receiver.recv(receiver_end.as_raw_fd(), &mut buf, 16, |fds| seen = fds.len()).unwrap();
        assert_eq!(seen, 2, "the seam sees the read's descriptors");
        for fd in receiver.take(2).unwrap() {
            assert!(close_on_exec(&fd), "a descriptor arrived without close-on-exec");
        }
    }

    /// A frame may carry at most MAX_FDS_PER_FRAME: a send of more sends
    /// nothing, and a take of more takes nothing.
    #[test]
    fn more_than_the_per_frame_cap_is_bad_message() {
        let (sender, _receiver_end) = UnixStream::pair().unwrap();
        let (read_end, _write_end) = pipe();
        let raw = vec![read_end.as_raw_fd(); MAX_FDS_PER_FRAME + 1];
        let error = fds::send_with_fds(sender.as_raw_fd(), b"x", &raw).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
        assert_eq!(
            bad_message(&error),
            Some(FdBadMessage::TooManyFds { count: MAX_FDS_PER_FRAME + 1 })
        );
        fds::send_with_fds(sender.as_raw_fd(), b"x", &raw[..MAX_FDS_PER_FRAME]).unwrap();

        let mut receiver = FdReceiver::default();
        assert_eq!(
            receiver.take(MAX_FDS_PER_FRAME + 1).unwrap_err(),
            FdBadMessage::TooManyFds { count: MAX_FDS_PER_FRAME + 1 }
        );
    }

    /// More descriptors than the control buffer holds (`MSG_CTRUNC`) fails
    /// the read with BadMessage and queues none of them. It closes no
    /// descriptor it did not receive (XNU keeps the full `cmsg_len` of the
    /// message it cut short).
    #[test]
    fn a_truncated_control_buffer_is_bad_message() {
        let (sentinel, sentinel_write) = pipe();
        let (sender, receiver_end) = UnixStream::pair().unwrap();
        let (read_end, write_end) = pipe();
        let (other, _other_write) = pipe();
        fds::send_all(
            sender.as_raw_fd(),
            b"x",
            &[read_end.as_raw_fd(), write_end.as_raw_fd(), other.as_raw_fd()],
        )
        .unwrap();
        let mut receiver = FdReceiver::with_capacity(1);
        let mut buf = Vec::new();
        let error = receiver.recv(receiver_end.as_raw_fd(), &mut buf, 16, |_| {}).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(bad_message(&error), Some(FdBadMessage::ControlTruncated));
        assert_eq!(receiver.queued(), 0, "a truncated read queues nothing");
        for fd in [&sentinel, &sentinel_write, &read_end, &write_end, &other] {
            assert!(
                is_open(fd.as_raw_fd()),
                "the truncated read closed a descriptor it did not own"
            );
        }
    }

    /// A read of more descriptors than the capacity fails though the control
    /// buffer's alignment padding held them (on 64-bit Linux `CMSG_SPACE(4)`
    /// has room for two).
    #[test]
    fn more_than_the_capacity_is_bad_message() {
        let (sender, receiver_end) = UnixStream::pair().unwrap();
        let (read_end, write_end) = pipe();
        fds::send_all(sender.as_raw_fd(), b"x", &[read_end.as_raw_fd(), write_end.as_raw_fd()])
            .unwrap();
        let mut receiver = FdReceiver::with_capacity(1);
        let error =
            receiver.recv(receiver_end.as_raw_fd(), &mut Vec::new(), 16, |_| {}).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(bad_message(&error), Some(FdBadMessage::ControlTruncated));
        assert_eq!(receiver.queued(), 0);
    }

    /// End of stream is a read of 0 bytes, not an error.
    #[test]
    fn end_of_stream_reads_zero() {
        let (sender, receiver_end) = UnixStream::pair().unwrap();
        drop(sender);
        let mut receiver = FdReceiver::default();
        let mut buf = Vec::new();
        assert_eq!(receiver.recv(receiver_end.as_raw_fd(), &mut buf, 16, |_| {}).unwrap(), 0);
        assert!(buf.is_empty());
    }

    /// `recv_into` writes the bytes at the start of the caller's slice and
    /// queues the descriptors as `recv` does; its errors are `recv`'s.
    #[test]
    fn recv_into_fills_the_callers_slice() {
        let (sender, receiver_end) = UnixStream::pair().unwrap();
        let (read_end, _write_end) = pipe();
        fds::send_all(sender.as_raw_fd(), b"hello", &[read_end.as_raw_fd()]).unwrap();
        let mut receiver = FdReceiver::default();
        let mut room = [0xAAu8; 32];
        let n = receiver.recv_into(receiver_end.as_raw_fd(), &mut room, |_| {}).unwrap();
        assert_eq!(&room[..n], b"hello");
        assert!(room[n..].iter().all(|byte| *byte == 0xAA), "nothing past the read is written");
        let taken = receiver.take(1).unwrap();
        assert_eq!(identity(taken[0].as_raw_fd()), identity(read_end.as_raw_fd()));

        let (one, two) = pipe();
        fds::send_all(sender.as_raw_fd(), b"x", &[one.as_raw_fd(), two.as_raw_fd()]).unwrap();
        let mut small = FdReceiver::with_capacity(1);
        let error = small.recv_into(receiver_end.as_raw_fd(), &mut room, |_| {}).unwrap_err();
        assert_eq!(bad_message(&error), Some(FdBadMessage::ControlTruncated));
        drop(sender);
        assert_eq!(receiver.recv_into(receiver_end.as_raw_fd(), &mut room, |_| {}).unwrap(), 0);
    }
}
