use super::*;

#[test]
fn wheel_and_motion_reports_are_lossy_in_every_encoding() {
    // SGR wheel up and down, wheel with Shift, any-event motion.
    assert!(is_lossy_mouse_input(b"\x1b[<64;27;20M"));
    assert!(is_lossy_mouse_input(b"\x1b[<65;27;20M\x1b[<65;27;20M"));
    assert!(is_lossy_mouse_input(b"\x1b[<68;1;1M"));
    assert!(is_lossy_mouse_input(b"\x1b[<35;10;5M"));
    // X10 wheel (cb 64 + 32) and URXVT motion (cb 35 + 32).
    assert!(is_lossy_mouse_input(b"\x1b[M`!!"));
    assert!(is_lossy_mouse_input(b"\x1b[67;10;5M"));
}

#[test]
fn clicks_keys_text_and_mixed_input_are_never_lossy() {
    for payload in [
        &b""[..],
        b"\x1b[<0;10;5M",
        b"\x1b[<0;10;5m",
        b"\x1b[<128;10;5M",
        b"\x1b[M !!",
        b"\x1b[32;10;5M",
        b"\x1b[A",
        b"\x1b",
        b"[<64;27;20M",
        b"\x1b[<64;27;20Mx",
        b"\x1b[<64;27;20M\x1b[A",
        b"\x1b[<64;27;20",
        b"hello",
    ] {
        assert!(!is_lossy_mouse_input(payload), "{payload:?}");
    }
}

#[cfg(target_os = "macos")]
mod queue {
    use super::*;
    use std::fs::File;
    use std::io::Read;
    use std::os::fd::{AsRawFd, FromRawFd};
    use std::sync::mpsc;
    use std::time::{Duration, Instant};

    /// The macOS PTY input queue holds 1022 bytes (TTYHOG - 2).
    const QUEUE: usize = 1022;
    const WHEEL: &[u8] = b"\x1b[<65;27;20M";

    fn raw_pty() -> (File, File) {
        let (mut master, mut slave) = (0, 0);
        // SAFETY: openpty writes the two descriptors into the borrowed ints;
        // null name, termios and winsize pointers are documented as allowed.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0, "openpty: {}", io::Error::last_os_error());
        // SAFETY: libc::termios is plain integers and arrays, so all-zero
        // bytes are a valid value; tcgetattr overwrites it.
        let mut termios: libc::termios = unsafe { std::mem::zeroed() };
        // SAFETY: `slave` is the descriptor openpty just opened; every call
        // reads or writes only the exclusively borrowed `termios`.
        unsafe {
            assert_eq!(libc::tcgetattr(slave, &mut termios), 0);
            libc::cfmakeraw(&mut termios);
            assert_eq!(libc::tcsetattr(slave, libc::TCSANOW, &termios), 0);
        }
        // SAFETY: openpty returned two fresh descriptors that nothing else
        // owns; each File takes sole ownership of one.
        unsafe { (File::from_raw_fd(master), File::from_raw_fd(slave)) }
    }

    fn pending(fd: RawFd) -> usize {
        let mut count: libc::c_int = 0;
        // SAFETY: the test's `slave` File keeps `fd` open; FIONREAD writes one
        // c_int into the exclusively borrowed `count`.
        let queried = unsafe { libc::ioctl(fd, libc::FIONREAD, &mut count) };
        assert_eq!(queried, 0);
        count as usize
    }

    /// A program that stops reading while the wheel turns (Codex redrawing)
    /// must never find a report cut by a full queue: a read that ends right
    /// after its ESC reaches crossterm as Esc, and the rest as typed text.
    #[test]
    fn a_wheel_flood_never_leaves_a_partial_report_in_the_input_queue() {
        let (master, mut slave) = raw_pty();
        let master_fd = master.as_raw_fd();
        let (done, finished) = mpsc::channel();
        let writer = std::thread::spawn(move || {
            let mut master = master;
            let mut dropped = 0;
            for _ in 0..(QUEUE / WHEEL.len()) * 2 {
                if !write_input_fd(Some(master_fd), &mut master, WHEEL).unwrap() {
                    dropped += 1;
                }
            }
            let _ = done.send(dropped);
            master
        });

        // Wait until every write returned, or one blocks on a full queue.
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut dropped = None;
        while dropped.is_none() && pending(slave.as_raw_fd()) < QUEUE {
            assert!(Instant::now() < deadline, "the writer neither finished nor filled the queue");
            dropped = finished.recv_timeout(Duration::from_millis(5)).ok();
        }

        let mut chunk = [0u8; 1024];
        let read = slave.read(&mut chunk).unwrap();
        let chunk = &chunk[..read];
        // Unblock a writer stuck on the full queue before asserting.
        // SAFETY: `slave` owns the descriptor and outlives both fcntl calls,
        // which touch no memory.
        unsafe {
            let flags = libc::fcntl(slave.as_raw_fd(), libc::F_GETFL);
            libc::fcntl(slave.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
        while dropped.is_none() {
            let _ = slave.read(&mut [0u8; 1024]);
            dropped = finished.recv_timeout(Duration::from_millis(5)).ok();
        }
        let _master = writer.join().unwrap();

        assert!(
            chunk.len() % WHEEL.len() == 0
                && chunk.chunks(WHEEL.len()).all(|report| report == WHEEL),
            "the queue held a partial report: read {} bytes ending {:?}",
            chunk.len(),
            &chunk[chunk.len().saturating_sub(4)..]
        );
        assert!(dropped.unwrap() > 0, "a flood larger than the queue drops wheel reports");
    }

    /// Keys always go through, even behind a queue the wheel filled.
    #[test]
    fn keys_are_written_whatever_the_queue_holds() {
        let (mut master, mut slave) = raw_pty();
        let master_fd = master.as_raw_fd();
        // Past the wheel's share of the queue, with room left for 12 bytes.
        let filler = vec![b'x'; QUEUE - 100];
        assert!(write_input_fd(Some(master_fd), &mut master, &filler).unwrap());
        assert!(write_input_fd(Some(master_fd), &mut master, b"\x1b[A").unwrap());
        assert!(!write_input_fd(Some(master_fd), &mut master, WHEEL).unwrap());
        assert_eq!(pending(slave.as_raw_fd()), filler.len() + 3);
        let mut read = Vec::new();
        while read.len() < filler.len() + 3 {
            let mut chunk = [0u8; 1024];
            let count = slave.read(&mut chunk).unwrap();
            read.extend_from_slice(&chunk[..count]);
        }
        assert!(read.ends_with(b"x\x1b[A"));
    }
}

#[cfg(unix)]
mod queued {
    use super::*;
    use crate::pty_write::{InputLane, PtyInputQueue, PtyWriter};
    use std::os::fd::{FromRawFd, OwnedFd};
    use std::time::{Duration, Instant};

    const WHEEL: &[u8] = b"\x1b[<65;27;20M";

    /// A PTY master on `writer` whose program (the returned slave) never
    /// reads.
    fn stalled_queue(writer: &PtyWriter) -> (PtyInputQueue, OwnedFd) {
        let (mut master, mut slave) = (-1, -1);
        // SAFETY: out-pointers to live locals; null name, termios and size
        // are documented as allowed.
        let opened = unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
            )
        };
        assert_eq!(opened, 0, "openpty: {}", io::Error::last_os_error());
        // SAFETY: openpty returned two fresh descriptors this test owns.
        let (master, slave) =
            unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
        (writer.register(master).unwrap(), slave)
    }

    /// Wheel reports behind input the program has not read are dropped, as
    /// with a full PTY queue; keys still go in, in the key lane.
    #[test]
    fn a_wheel_report_behind_queued_input_is_dropped_but_a_key_is_queued() {
        let writer = PtyWriter::start().unwrap();
        let (queue, _program) = stalled_queue(&writer);
        assert!(queue_input(None, &queue, WHEEL).unwrap(), "an idle queue takes the wheel");
        let paste = vec![b'x'; 1024 * 1024];
        queue.send(&paste, InputLane::Bulk).unwrap();
        let deadline = Instant::now() + Duration::from_secs(5);
        while queue.pending() >= paste.len() && Instant::now() < deadline {
            std::thread::yield_now();
        }
        assert!(queue.pending() > 0, "the program reads nothing, so the paste waits");
        assert!(!queue_input(None, &queue, WHEEL).unwrap(), "a wheel report grew the backlog");
        assert!(queue_input(None, &queue, b"\x1b[A").unwrap(), "a key was dropped");
    }
}
