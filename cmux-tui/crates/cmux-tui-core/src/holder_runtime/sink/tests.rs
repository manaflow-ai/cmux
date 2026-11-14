use super::*;

#[test]
fn resent_bytes_are_dropped_and_the_end_follows_the_last_byte() {
    let sink = HolderSink::new(10);
    sink.data(10, b"abc");
    sink.data(11, b"bcde");
    sink.exit(ExitStatus::Exited(0), 15);
    let mut reader = SinkReader(sink.clone());
    let mut out = Vec::new();
    reader.read_to_end(&mut out).unwrap();
    assert_eq!(out, b"abcde");
    assert_eq!(sink.received(), 15);
    assert_eq!(sink.confirmed(), 15);
    assert_eq!(sink.wait_end(), SinkEnd::Exited(ExitStatus::Exited(0)));
}

#[test]
fn a_seed_comes_first_and_a_lost_holder_ends_the_stream() {
    let sink = HolderSink::new(0);
    sink.data(0, b"shell");
    sink.prepend(b"seed:");
    sink.lose();
    let mut out = Vec::new();
    SinkReader(sink.clone()).read_to_end(&mut out).unwrap();
    assert_eq!(out, b"seed:shell");
    assert_eq!(sink.received(), 5);
    assert_eq!(sink.wait_end(), SinkEnd::Lost);
}

#[test]
fn the_sink_acknowledges_what_the_parser_parsed_so_the_holder_sends_more() {
    let acks = Arc::new(Mutex::new(Vec::new()));
    let sink = HolderSink::new(0);
    sink.prepend(b"seed");
    let chunk = vec![b'a'; 100 * 1024];
    sink.data(0, &chunk);
    sink.data(chunk.len() as u64, &chunk);
    let recorded = acks.clone();
    sink.set_acker(Box::new(move |offset| recorded.lock().unwrap().push(offset)));
    // Nothing parsed yet: the first acknowledgement is the base.
    assert_eq!(*acks.lock().unwrap(), vec![0]);
    let mut reader = SinkReader(sink.clone());
    let mut buf = vec![0u8; 64 * 1024];
    let mut read = 0;
    while read < 4 + 2 * chunk.len() {
        read += reader.read(&mut buf).unwrap();
    }
    // The last chunk is parsed once the reader says so.
    sink.confirm_parsed();
    sink.exit(ExitStatus::Exited(0), 2 * chunk.len() as u64);
    assert_eq!(reader.read(&mut buf).unwrap(), 0);
    let acks = acks.lock().unwrap().clone();
    let last = *acks.last().unwrap();
    // The seed takes no holder offset: what the parser parsed of the
    // holder's bytes is acknowledged, every ACK_EVERY bytes.
    assert!(acks.len() >= 2, "{acks:?}");
    assert!(last >= ACK_EVERY && last <= 2 * chunk.len() as u64, "{acks:?}");
}

#[test]
fn missing_bytes_are_cancelled_not_spliced() {
    let sink = HolderSink::new(0);
    sink.data(0, b"\x1b[3");
    sink.data(10, b"1mx");
    sink.gap(13, 20);
    sink.data(20, b"y");
    sink.exit(ExitStatus::Exited(0), 21);
    let mut out = Vec::new();
    SinkReader(sink.clone()).read_to_end(&mut out).unwrap();
    assert_eq!(out, b"\x1b[3\x181mx\x18y");
    assert_eq!(sink.received(), 21);
    assert_eq!(sink.confirmed(), 21);
}

/// Review 1 of pl-holder-11: a holder killed inside a PTY read lost
/// the bytes that read took, however many. The dead holder's segment
/// names the offset ([`HolderSink::cut_at`]), and the parser gets a CAN
/// exactly there: inside a later chunk, between its bytes before and
/// after the cut, and at once when every byte before it was received.
/// A cut behind what was received names nothing.
#[test]
fn output_lost_where_a_holder_died_reading_is_cancelled_not_spliced() {
    let sink = HolderSink::new(0);
    sink.data(0, b"\x1b[3");
    sink.cut_at(5);
    sink.cut_at(1);
    sink.data(3, b"8;5;1");
    sink.cut_at(8);
    sink.data(8, b"x");
    sink.exit(ExitStatus::Exited(0), 9);
    let mut out = Vec::new();
    SinkReader(sink.clone()).read_to_end(&mut out).unwrap();
    assert_eq!(out, b"\x1b[38;\x185;1\x18x");
    assert_eq!((sink.received(), sink.confirmed()), (9, 9));
}

#[test]
fn a_snapshot_is_due_after_a_burst_once_the_stream_is_idle() {
    let sink = HolderSink::new(0);
    let burst = vec![b'a'; SNAPSHOT_IDLE_BYTES as usize];
    sink.data(0, &burst);
    // Queued, not parsed: the screen is not the screen at any offset yet.
    assert_eq!(sink.snapshot_due(), None);
    let mut buf = vec![0u8; burst.len()];
    let mut reader = SinkReader(sink.clone());
    let mut read = 0;
    while read < burst.len() {
        read += reader.read(&mut buf).unwrap();
    }
    assert_eq!(sink.snapshot_due(), Some(burst.len() as u64));
    sink.snapshot_taken(burst.len() as u64, true);
    // An echo after it costs no replay.
    sink.data(burst.len() as u64, b"x");
    assert_eq!(reader.read(&mut buf).unwrap(), 1);
    assert_eq!(sink.snapshot_due(), None);
}

#[test]
fn a_prologue_older_than_the_ring_is_followed_by_a_cancel() {
    let sink = HolderSink::new(100);
    sink.prologue(40, b"<screen>");
    sink.data(100, b"tail");
    sink.exit(ExitStatus::Exited(0), 104);
    let mut out = Vec::new();
    SinkReader(sink).read_to_end(&mut out).unwrap();
    assert_eq!(out, b"<screen>\x18tail");
    // A current prologue sets where the stream continues.
    let sink = HolderSink::new(100);
    sink.prologue(150, b"<screen>");
    sink.data(150, b"tail");
    assert_eq!(sink.received(), 154);
}

#[test]
fn a_detach_ends_the_reader_and_the_wait_without_an_end() {
    let sink = HolderSink::new(0);
    sink.data(0, b"kept by the holder");
    sink.detach();
    let mut buf = [0u8; 8];
    assert_eq!(SinkReader(sink.clone()).read(&mut buf).unwrap(), 0);
    assert_eq!(sink.wait_end(), SinkEnd::Detached);
}

/// A reopened terminal's seed (and a prologue) is not the shell's
/// output: a read says how many of its bytes come before the first
/// holder byte, so first-output marks skip them.
#[test]
fn a_read_says_how_many_leading_bytes_are_not_holder_output() {
    let sink = HolderSink::new(0);
    sink.prepend(b"replayed screen");
    sink.data(0, b"$ ");
    let mut buf = [0u8; 8];
    assert_eq!(sink.read(&mut buf), (8, 8), "the seed's first bytes");
    let mut buf = [0u8; 64];
    assert_eq!(sink.read(&mut buf), (9, 7), "the seed's rest, then the shell's prompt");
    assert_eq!(&buf[7..9], b"$ ");
    sink.data(2, b"ls");
    assert_eq!(sink.read(&mut buf), (2, 0), "only the shell's output");
}

/// The replay race (holder item 1): a chunk the reader took but has not
/// parsed is still pending, and the confirmed offset stays before it,
/// so a hand-off to a new holder never claims a byte the screen does
/// not show yet.
#[test]
fn a_taken_chunk_stays_pending_until_the_parser_confirms_it() {
    let sink = HolderSink::new(0);
    sink.prepend(b"seed");
    sink.data(0, b"\x1b[38;5;1");
    sink.data(8, b"96mRED");
    let mut buf = [0u8; 8];
    let mut reader = SinkReader(sink.clone());
    // The reader takes "seed\x1b[38" and is still parsing it.
    assert_eq!(reader.read(&mut buf).unwrap(), 8);
    let pending = sink.pending();
    assert_eq!((pending.confirmed, pending.received), (0, 14));
    assert_eq!(pending.head, b"seed");
    assert_eq!(pending.all, b"seed\x1b[38;5;196mRED");
    // Parsed: the confirmed offset moves past its holder bytes only.
    sink.confirm_parsed();
    let pending = sink.pending();
    assert_eq!((pending.confirmed, pending.received), (4, 14));
    assert!(pending.head.is_empty());
    assert_eq!(pending.all, b";5;196mRED");
}
