use super::*;
use std::fs::File;
use std::io::Read;
use std::os::fd::FromRawFd;
use std::time::{Duration, Instant};

/// A raw PTY pair: the master for the writer, the slave as the program.
fn raw_pty() -> (OwnedFd, File) {
    let (mut master, mut slave) = (-1, -1);
    // SAFETY: out-pointers to live locals; null name, termios and size are
    // documented as allowed.
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
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    // SAFETY: termios calls on the slave this test owns.
    unsafe {
        let mut termios: libc::termios = std::mem::zeroed();
        assert_eq!(libc::tcgetattr(slave.as_raw_fd(), &mut termios), 0);
        libc::cfmakeraw(&mut termios);
        assert_eq!(libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios), 0);
    }
    (master, File::from(slave))
}

/// What the program reads within `timeout`: everything up to `want` bytes.
fn read_within(slave: &mut File, want: usize, timeout: Duration) -> Vec<u8> {
    let deadline = Instant::now() + timeout;
    let mut got = Vec::new();
    let mut buffer = vec![0u8; 64 * 1024];
    while got.len() < want {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        let mut fd = libc::pollfd { fd: slave.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one live pollfd on the slave this test owns.
        let ready = unsafe { libc::poll(&mut fd, 1, left.as_millis().clamp(1, 60_000) as i32) };
        if ready <= 0 {
            continue;
        }
        let read = slave.read(&mut buffer).unwrap();
        got.extend_from_slice(buffer.get(..read).unwrap());
    }
    got
}

fn wait_until(timeout: Duration, mut done: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if done() {
            return true;
        }
        std::thread::yield_now();
    }
    done()
}

/// The acceptance test of p01-process-123: a program that reads nothing
/// while a paste floods its terminal delays neither the sender nor a key to
/// another terminal.
#[test]
fn a_flood_into_one_terminal_does_not_delay_a_key_to_another() {
    let writer = PtyWriter::start().unwrap();
    let (flooded_master, _flooded_program) = raw_pty();
    let (typed_master, mut typed_program) = raw_pty();
    let flooded = writer.register(flooded_master).unwrap();
    let typed = writer.register(typed_master).unwrap();
    let flood = vec![b'x'; 4 * 1024 * 1024];
    let started = Instant::now();
    flooded.send(&flood, InputLane::Bulk).unwrap();
    assert!(started.elapsed() < Duration::from_millis(500), "the flood's send waited");
    // The writer filled the flooded master: its program reads nothing.
    assert!(
        wait_until(Duration::from_secs(5), || flooded.pending() < flood.len()),
        "the writer never wrote the flood's first bytes"
    );
    let sent = Instant::now();
    typed.send(b"k", InputLane::Key).unwrap();
    let echo = read_within(&mut typed_program, 1, Duration::from_secs(5));
    let waited = sent.elapsed();
    assert_eq!(echo, b"k", "the key never reached the other terminal");
    assert!(waited < Duration::from_millis(500), "the key waited {waited:?} behind the flood");
    assert!(flooded.pending() > 0, "the flood was not still waiting while the key went");
}

#[test]
fn send_never_blocks_and_a_full_queue_refuses_bulk_but_takes_keys() {
    let writer = PtyWriter::start().unwrap();
    let (master, _program) = raw_pty();
    let queue = writer.register(master).unwrap();
    let mib = vec![b'p'; 1024 * 1024];
    let started = Instant::now();
    let mut refused = None;
    for _ in 0..=QUEUE_LIMIT_BYTES / mib.len() + 1 {
        if let Err(error) = queue.send(&mib, InputLane::Bulk) {
            refused = Some(error);
            break;
        }
    }
    assert!(started.elapsed() < Duration::from_secs(2), "sends to a stalled program waited");
    let refused = refused.expect("a program that reads nothing has a bounded queue");
    assert_eq!(refused.kind(), io::ErrorKind::WouldBlock);
    assert!(queue.pending() <= QUEUE_LIMIT_BYTES);
    queue.send(b"\x03", InputLane::Key).expect("a key goes in behind a full queue");
}

#[test]
fn one_terminals_bytes_keep_their_order_across_lanes() {
    let writer = PtyWriter::start().unwrap();
    let (master, mut program) = raw_pty();
    let queue = writer.register(master).unwrap();
    let paste: Vec<u8> = (0..256 * 1024).map(|index| b'a' + (index % 26) as u8).collect();
    queue.send(&paste, InputLane::Bulk).unwrap();
    queue.send(b"1", InputLane::Key).unwrap();
    queue.send(b"tail", InputLane::Bulk).unwrap();
    queue.send(b"2", InputLane::Key).unwrap();
    let mut expected = paste;
    expected.extend_from_slice(b"1tail2");
    let got = read_within(&mut program, expected.len(), Duration::from_secs(10));
    assert!(got == expected, "the program read {} bytes out of order", got.len());
    assert!(wait_until(Duration::from_secs(5), || queue.pending() == 0));
}

#[test]
fn a_program_that_hung_up_fails_its_queue_and_drops_what_waits() {
    let writer = PtyWriter::start().unwrap();
    let (master, program) = raw_pty();
    let queue = writer.register(master).unwrap();
    drop(program);
    // A master whose program hung up may still buffer some input; a
    // megabyte fills that buffer, and the master then reports the hang-up.
    queue.send(&vec![b'z'; 1024 * 1024], InputLane::Bulk).unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    let refused = loop {
        match queue.send(b"lost", InputLane::Key) {
            Err(error) => break Some(error),
            Ok(()) if Instant::now() >= deadline => break None,
            Ok(()) => std::thread::sleep(Duration::from_millis(5)),
        }
    };
    let refused = refused.expect("input to a PTY whose program hung up kept being accepted");
    assert_ne!(refused.kind(), io::ErrorKind::WouldBlock, "a hang-up is not a full queue");
    assert!(
        wait_until(Duration::from_secs(5), || queue.pending() == 0),
        "the dead queue kept bytes"
    );
}

#[test]
fn bulk_queues_take_turns_starting_one_later_each_turn() {
    assert_eq!(serve_order(3, 0).collect::<Vec<_>>(), [0, 1, 2]);
    assert_eq!(serve_order(3, 1).collect::<Vec<_>>(), [1, 2, 0]);
    assert_eq!(serve_order(3, 5).collect::<Vec<_>>(), [2, 0, 1]);
    assert_eq!(serve_order(0, 7).count(), 0);
}

/// The writer closes its master once the terminal's last queue handle goes:
/// the program then sees its terminal hang up, as no other copy of the
/// master is left.
#[test]
fn a_dropped_queue_closes_its_master() {
    let writer = PtyWriter::start().unwrap();
    let (master, program) = raw_pty();
    let queue = writer.register(master).unwrap();
    let copy = queue.clone();
    drop(queue);
    copy.send(b"still open", InputLane::Key).expect("a clone keeps the queue open");
    drop(copy);
    let hung_up = wait_until(Duration::from_secs(5), || {
        let mut fd = libc::pollfd { fd: program.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        // SAFETY: one live pollfd on the slave this test owns; no wait.
        unsafe { libc::poll(&mut fd, 1, 0) };
        fd.revents & libc::POLLHUP != 0
    });
    assert!(hung_up, "the writer kept the closed terminal's master open");
}

/// Input the program has not read yet, counted on its side of the PTY.
fn unread(program: &File) -> usize {
    let mut count: libc::c_int = 0;
    // SAFETY: FIONREAD writes one c_int into the live local `count`; the
    // slave is open for the call.
    let status = unsafe { libc::ioctl(program.as_raw_fd(), libc::FIONREAD, &mut count) };
    assert_eq!(status, 0, "FIONREAD: {}", io::Error::last_os_error());
    usize::try_from(count).unwrap()
}

/// #22265 on the `pty-writer`: a macOS PTY queues at most 1,022 bytes of
/// input and a write cut where the queue fills can end right after an ESC.
/// crossterm reads a short read that ends in ESC as the Esc key and types
/// the rest of the report as text. The writer must start an escape sequence
/// only when it fits whole. On macOS the kernel's queue is the real one; on
/// Linux the room is read the same way, from the program's side.
#[test]
fn a_full_input_queue_never_ends_in_a_lone_escape() {
    const WHEEL_UP: &[u8] = b"\x1b[<65;30;7M";
    let (master, mut program) = raw_pty();
    let program_fd = program.as_raw_fd();
    let checks = Arc::new(AtomicUsize::new(0));
    let counted = checks.clone();
    let room: RoomProbe = Arc::new(move |master| {
        counted.fetch_add(1, Ordering::AcqRel);
        if cfg!(target_vendor = "apple") {
            return platform_room(master);
        }
        let mut count: libc::c_int = 0;
        // SAFETY: FIONREAD writes one c_int into the live local `count`;
        // the test keeps the slave open while the queue is registered.
        let status = unsafe { libc::ioctl(program_fd, libc::FIONREAD, &mut count) };
        (status == 0)
            .then(|| input_queue::CAPACITY.saturating_sub(usize::try_from(count).unwrap_or(0)))
    });
    let writer = PtyWriter::start_with_room(room).unwrap();
    let queue = writer.register(master).unwrap();
    // The program is busy: its queue holds 1,021 bytes, one short of full.
    queue.send(&[b'x'; 1021], InputLane::Key).unwrap();
    assert!(
        wait_until(Duration::from_secs(5), || unread(&program) == 1021),
        "the program's queue never held the first 1,021 bytes"
    );
    let before = checks.load(Ordering::Acquire);
    queue.send(WHEEL_UP, InputLane::Key).unwrap();
    // The writer either waits for room, checking it again, or wrote the
    // report into a queue that has no room for it.
    assert!(
        wait_until(Duration::from_secs(5), || {
            checks.load(Ordering::Acquire) >= before + 2 || unread(&program) > 1021
        }),
        "the writer never wrote the report nor waited for room"
    );
    let queued = unread(&program);
    assert!(
        queued <= input_queue::CAPACITY,
        "the writer queued {queued} bytes, more than the program's queue holds"
    );

    // crossterm reads 1,024 bytes at a time.
    let mut buffer = [0u8; 1024];
    let first = program.read(&mut buffer).unwrap();
    assert!(
        first <= input_queue::CAPACITY,
        "the writer queued {first} bytes, more than the program's queue holds"
    );
    assert_ne!(
        buffer.get(first - 1),
        Some(&0x1b),
        "the program read {first} bytes ending in a lone ESC: the wheel report was cut after it"
    );
    let mut got = buffer.get(..first).unwrap().to_vec();
    got.extend(read_within(&mut program, 1021 + WHEEL_UP.len() - first, Duration::from_secs(5)));
    assert_eq!(got.get(1021..), Some(WHEEL_UP), "the wheel report arrived changed");
    drop(queue);
}

#[test]
fn a_receipt_resolves_once_the_pty_took_the_last_byte() {
    let writer = PtyWriter::start().unwrap();
    let (master, mut program) = raw_pty();
    let queue = writer.register(master).unwrap();
    let receipt = queue.send_receipted(b"hello", InputLane::Bulk).unwrap();
    receipt.wait().expect("the PTY took every byte");
    assert_eq!(read_within(&mut program, 5, Duration::from_secs(5)), b"hello");
    queue.send_receipted(b"", InputLane::Key).unwrap().wait().expect("nothing to deliver");
}

/// Queued bytes the terminal drops are never reported delivered: a receipt
/// waiting behind a stalled paste fails, as not delivered, when the
/// terminal closes.
#[test]
fn a_receipt_of_input_the_closed_terminal_dropped_fails_not_delivered() {
    let writer = PtyWriter::start().unwrap();
    let (master, _program) = raw_pty();
    let queue = writer.register(master).unwrap();
    queue.send(&vec![b'p'; 1024 * 1024], InputLane::Bulk).unwrap();
    let receipt = queue.send_receipted(b"k", InputLane::Key).unwrap();
    drop(queue);
    match receipt.wait() {
        Err(DeliveryFailure::NotDelivered(error)) => {
            assert_eq!(error.kind(), io::ErrorKind::BrokenPipe);
        }
        other => panic!("a dropped key was reported {other:?}"),
    }
}

#[test]
fn a_receipt_on_a_terminal_whose_program_hung_up_fails() {
    let writer = PtyWriter::start().unwrap();
    let (master, program) = raw_pty();
    let queue = writer.register(master).unwrap();
    drop(program);
    // A master whose program hung up may still buffer some input; a
    // megabyte fills that buffer, and the master then reports the hang-up.
    let receipt = queue.send_receipted(&vec![b'z'; 1024 * 1024], InputLane::Bulk).unwrap();
    assert!(receipt.wait().is_err(), "a megabyte to a hung-up program was reported delivered");
    match queue.send_receipted(b"late", InputLane::Key) {
        Err(error) => assert_ne!(error.kind(), io::ErrorKind::WouldBlock),
        Ok(receipt) => {
            assert!(matches!(receipt.wait(), Err(DeliveryFailure::NotDelivered(_))));
        }
    }
}

/// A receipt whose wait runs out before the PTY took a byte takes its bytes
/// back: it is known not delivered, and the program never reads them.
#[test]
fn a_receipt_that_times_out_untouched_is_taken_back() {
    let writer = PtyWriter::start().unwrap();
    let (master, mut program) = raw_pty();
    let queue = writer.register(master).unwrap();
    let paste = vec![b'p'; 1024 * 1024];
    queue.send(&paste, InputLane::Bulk).unwrap();
    let receipt = queue.send_receipted(b"k", InputLane::Key).unwrap();
    let deadline = Instant::now() + Duration::from_millis(50);
    match receipt.wait_until(deadline, "test timeout") {
        Err(DeliveryFailure::NotDelivered(error)) => {
            assert_eq!(error.kind(), io::ErrorKind::TimedOut);
            assert_eq!(error.to_string(), "test timeout");
        }
        other => panic!("a key behind a stalled paste was reported {other:?}"),
    }
    let got = read_within(&mut program, paste.len(), Duration::from_secs(10));
    assert!(got == paste, "the program read {} bytes, not the paste", got.len());
    assert!(
        read_within(&mut program, 1, Duration::from_millis(200)).is_empty(),
        "the program read the key that was taken back"
    );
    assert!(wait_until(Duration::from_secs(5), || queue.pending() == 0), "the key stayed queued");
}
