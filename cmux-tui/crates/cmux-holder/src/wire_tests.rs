use super::*;
use std::os::unix::net::UnixStream;

fn close_on_exec(fd: &OwnedFd) -> bool {
    // SAFETY: F_GETFD of a descriptor this test owns.
    let flags = unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_GETFD) };
    assert!(flags >= 0, "F_GETFD: {}", io::Error::last_os_error());
    flags & libc::FD_CLOEXEC != 0
}

/// Every descriptor a frame brings (the daemon's custody copy of a PTY
/// master, and of a terminal's ring segment) is close-on-exec once the
/// frame is read, though the sender's copies are not: no process the
/// multithreaded daemon spawns later inherits a shell's terminal or a
/// writable copy of its output.
#[test]
fn descriptors_a_frame_brings_are_close_on_exec() {
    let (sender, receiver) = UnixStream::pair().unwrap();
    let mut ends = [0; 2];
    // SAFETY: pipe fills two descriptors this test then owns.
    assert_eq!(unsafe { libc::pipe(ends.as_mut_ptr()) }, 0);
    // SAFETY: both are fresh descriptors nothing else owns.
    let (read_end, write_end) =
        unsafe { (OwnedFd::from_raw_fd(ends[0]), OwnedFd::from_raw_fd(ends[1])) };
    assert!(!close_on_exec(&read_end) && !close_on_exec(&write_end), "pipe() sets no flag");
    let frame = encode_with_fds(Kind::Spawned, FLAG_RING, 7, b"spawned", 2);
    send_all(sender.as_raw_fd(), &frame, &[raw(&read_end), raw(&write_end)]).unwrap();

    let mut reader = Reader::default();
    let frame = loop {
        if let Some(frame) = reader.next_frame().unwrap() {
            break frame;
        }
        assert!(reader.fill(receiver.as_raw_fd()).unwrap(), "the stream ended early");
    };
    assert_eq!((frame.kind, frame.chan), (Kind::Spawned as u16, 7));
    assert_eq!(frame.fds.len(), 2, "a ring spawn brings the master and the segment");
    for (index, fd) in frame.fds.iter().enumerate() {
        assert!(close_on_exec(fd), "descriptor {index} arrived without close-on-exec");
    }
}
