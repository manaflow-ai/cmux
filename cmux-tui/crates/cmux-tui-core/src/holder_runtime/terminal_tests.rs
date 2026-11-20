use std::io::Read;
use std::os::fd::FromRawFd;

use super::*;

/// A raw PTY pair whose master is non-blocking, as the holder leaves it.
fn nonblocking_pty() -> (OwnedFd, std::fs::File) {
    let (mut master, mut slave) = (-1, -1);
    // SAFETY: out-pointers to live locals; default termios and size.
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
    // SAFETY: termios calls on the slave this test owns; fcntl on its master.
    unsafe {
        let mut termios: libc::termios = std::mem::zeroed();
        assert_eq!(libc::tcgetattr(slave.as_raw_fd(), &mut termios), 0);
        libc::cfmakeraw(&mut termios);
        assert_eq!(libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &termios), 0);
        let flags = libc::fcntl(master.as_raw_fd(), libc::F_GETFL);
        libc::fcntl(master.as_raw_fd(), libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
    (master, std::fs::File::from(slave))
}

#[test]
fn a_kept_ring_segment_that_ends_before_the_received_offset_is_not_handed_on() {
    let segment = cmux_holder::ring::create_segment(100, 4096).unwrap();
    assert!(continues_at(&segment, 100), "a segment at the received offset continues");
    assert!(continues_at(&segment, 40), "a segment past the received offset continues");
    assert!(!continues_at(&segment, 101), "a segment behind the received offset is stale");
}

/// An ended terminal drops the custody dup of its ring segment (no
/// holder takes it over again; up to a MiB of output would stay mapped
/// by nobody for the surface's life), and an adoption's late answer does
/// not bring one back.
#[test]
fn an_ended_terminal_drops_its_ring_segment_for_good() {
    use cmux_holder::link::TerminalSink;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let root =
        std::env::temp_dir().join(format!("cmux-holder-ring-drop-{}-{stamp}", std::process::id()));
    let service = HolderService::for_root(&root).unwrap();
    let (master, _slave) = nonblocking_pty();
    let sink = HolderSink::new(0);
    let segment = || cmux_holder::ring::create_segment(0, 4096).unwrap();
    let terminal = Arc::new(HolderTerminal {
        chan: 1,
        id: [1; 16],
        pid: 0,
        custody: master,
        ring: std::sync::Mutex::new(Some(segment())),
        sink: sink.clone(),
        service,
        replay: std::sync::Mutex::new(None),
    });
    let launch = holder_local_launch(&terminal, Vec::new(), None).unwrap();
    sink.exit(ExitStatus::Exited(0), 0);
    let wait = launch.wait;
    let _ = wait();
    assert!(terminal.ring.lock().unwrap().is_none(), "the ended terminal kept its segment");
    terminal.keep_ring(Some(segment()));
    assert!(terminal.ring.lock().unwrap().is_none(), "an ended terminal took a segment back");
    let _ = std::fs::remove_dir_all(&root);
}

/// A terminal on a holder that is gone, with `segment` as its custody
/// ring and `received` as every byte it received, from offset 0.
fn orphaned_terminal(
    name: &str,
    segment: OwnedFd,
    received: &[u8],
) -> (Arc<HolderTerminal>, std::path::PathBuf) {
    use cmux_holder::link::TerminalSink;
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.subsec_nanos());
    let root = std::env::temp_dir().join(format!("{name}-{}-{stamp}", std::process::id()));
    let (master, _slave) = nonblocking_pty();
    let sink = HolderSink::new(0);
    sink.data(0, received);
    let terminal = Arc::new(HolderTerminal {
        chan: 1,
        id: [1; 16],
        pid: 0,
        custody: master,
        ring: std::sync::Mutex::new(Some(segment)),
        sink,
        service: HolderService::for_root(&root).unwrap(),
        replay: std::sync::Mutex::new(None),
    });
    (terminal, root)
}

/// Everything the terminal's parser gets, once its stream ended.
fn parsed(terminal: &HolderTerminal, end: u64) -> Vec<u8> {
    use cmux_holder::link::TerminalSink;
    terminal.sink.exit(ExitStatus::Exited(0), end);
    let mut out = Vec::new();
    super::super::sink::SinkReader(terminal.sink.clone()).read_to_end(&mut out).unwrap();
    out
}

/// Review 1 of pl-holder-11: output a dead holder took from the PTY and
/// no holder hands on is lost, never spliced. A holder killed inside a
/// PTY read leaves its ring saying so (the adoption here runs while the
/// read is in flight, as after a holder SIGKILLed there): the parser
/// gets a CAN at that offset, before the new holder's first byte. And
/// when the new holder takes no ring segment, the bytes the dead holder
/// read past what the daemon received are lost: a CAN there too.
#[test]
fn output_a_dead_holder_took_and_nobody_hands_on_is_cancelled_not_spliced() {
    use cmux_holder::link::TerminalSink;
    let mut ring = cmux_holder::ring::Ring::new(0, 4096);
    let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
    ring.push(b"0123456789");
    let (terminal, root) = orphaned_terminal("cmux-holder-cut", segment, b"0123456789");
    ring.read_with(64, |room| {
        room[..3].copy_from_slice(b"lst");
        // The holder dies here: the read took 3 bytes, its end is not
        // published. A new holder that takes rings continues at 10.
        let adoption = terminal.adoption(true, ADOPT_PROLOGUE_MAX_BYTES);
        assert!(adoption.ring.is_some(), "the segment goes to the new holder");
        assert_eq!(adoption.resume, 10);
        3
    });
    // The new holder continues the segment: its ADOPTED names its end.
    terminal.sink.adopted(10);
    terminal.sink.data(10, b"new");
    assert_eq!(parsed(&terminal, 13), b"0123456789\x18new", "the lost read was spliced");
    let _ = std::fs::remove_dir_all(&root);

    // The dead holder published 10 bytes, the daemon received 5, and
    // the new holder takes no segment: 5 bytes are gone.
    let mut ring = cmux_holder::ring::Ring::new(0, 4096);
    let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
    ring.push(b"0123456789");
    drop(ring);
    let (terminal, root) = orphaned_terminal("cmux-holder-cut-fresh", segment, b"01234");
    let adoption = terminal.adoption(false, ADOPT_PROLOGUE_MAX_BYTES);
    assert!(adoption.ring.is_none());
    assert_eq!(adoption.resume, 5);
    terminal.sink.data(5, b"new");
    assert_eq!(parsed(&terminal, 8), b"01234\x18new", "the unsent bytes were spliced");
    let _ = std::fs::remove_dir_all(&root);
}

/// A dead holder's segment with 10 bytes published and a read in
/// flight at 10, for a terminal that received the first 5: the
/// adoption hands the segment on, resuming at 5.
fn adoption_past_what_was_received(name: &str) -> (Arc<HolderTerminal>, std::path::PathBuf) {
    let mut ring = cmux_holder::ring::Ring::new(0, 4096);
    let segment = ring.segment().expect("a shared ring").try_clone().unwrap();
    ring.push(b"0123456789");
    let mut handed = None;
    ring.read_with(64, |room| {
        room[..3].copy_from_slice(b"lst");
        // The holder dies inside this read.
        let (terminal, root) = orphaned_terminal(name, segment.try_clone().unwrap(), b"01234");
        let adoption = terminal.adoption(true, ADOPT_PROLOGUE_MAX_BYTES);
        assert!(adoption.ring.is_some(), "the segment goes to the new holder");
        assert_eq!(adoption.resume, 5);
        handed = Some((terminal, root));
        3
    });
    handed.unwrap()
}

/// Review 2 of pl-holder-11: which loss an adoption marks follows the
/// new holder's ADOPTED answer, not a guess made before the ADOPT. The
/// dead holder read past what the daemon received (10 bytes published,
/// 5 received) and died inside a read at 10:
///
/// - the new holder refuses the segment and starts a fresh ring at 5
///   (its answer ends at 5): bytes 5..10 are gone, so the parser gets
///   one CAN at 5 and none at 10, where the new stream is valid output;
/// - it continues the segment (its answer ends at 10): it resends 5..10
///   from the ring and only the read at 10 is lost: one CAN at 10;
/// - nobody answers (the link ended) and the next adoption has no
///   segment: a fresh ring at 5 again, one CAN at 5.
///
/// Before, the cut was always at 10 for a handed segment: the refused
/// case spliced 5..10 silently and put a false CAN inside new output.
#[test]
fn the_new_holders_answer_decides_where_lost_output_is_cancelled() {
    use cmux_holder::link::TerminalSink;
    let (terminal, root) = adoption_past_what_was_received("cmux-holder-cut-refused");
    terminal.sink.adopted(5);
    terminal.sink.data(5, b"abcdefgh");
    assert_eq!(parsed(&terminal, 13), b"01234\x18abcdefgh", "a refused segment");
    let _ = std::fs::remove_dir_all(&root);

    let (terminal, root) = adoption_past_what_was_received("cmux-holder-cut-continued");
    terminal.sink.adopted(10);
    terminal.sink.data(5, b"56789");
    terminal.sink.data(10, b"new");
    assert_eq!(parsed(&terminal, 13), b"0123456789\x18new", "a continued segment");
    let _ = std::fs::remove_dir_all(&root);

    let (terminal, root) = adoption_past_what_was_received("cmux-holder-cut-unanswered");
    // readopt keeps no custody segment when no answer came.
    terminal.keep_ring(None);
    let adoption = terminal.adoption(true, ADOPT_PROLOGUE_MAX_BYTES);
    assert_eq!(adoption.resume, 5);
    terminal.sink.data(5, b"abcdefgh");
    assert_eq!(parsed(&terminal, 13), b"01234\x18abcdefgh", "an unanswered adoption");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn a_paste_bigger_than_the_input_queue_waits_for_a_slow_program() {
    let (master, mut slave) = nonblocking_pty();
    let paste: Vec<u8> = (0..64 * 1024).map(|index| b'a' + (index % 26) as u8).collect();
    let expected = paste.clone();
    // The program reads nothing for a while, then everything.
    let program = std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(300));
        let mut got = vec![0u8; expected.len()];
        slave.read_exact(&mut got).unwrap();
        got == expected
    });
    let pty = cmux_pty::adopt_master(master.try_clone().unwrap()).unwrap();
    let mut writer = WaitingWriter { inner: pty.take_writer().unwrap(), master };
    writer.write_all(&paste).expect("the paste waits for room instead of failing");
    writer.flush().unwrap();
    assert!(program.join().unwrap(), "the program got every byte, in order");
}
