//! IpcStats counts what its hooks report and nothing else.

use std::io::{self, Write};

use cmux_ipc::frame::FrameKind;

use super::*;

#[test]
fn streams_count_open_peak_and_opened() {
    let stats = IpcStats::default();
    let first = stats.stream_opened();
    let second = stats.stream_opened();
    drop(first);
    let snapshot = stats.snapshot().streams;
    assert_eq!(snapshot, IpcStreamsSnapshot { open: 1, peak: 2, opened: 2 });
    drop(second);
    assert_eq!(stats.snapshot().streams.open, 0);
}

#[test]
fn kinds_are_named_and_unseen_kinds_absent() {
    let stats = IpcStats::default();
    stats.line_received(10);
    stats.line_received(5);
    stats.frame_received(FrameKind::Request, 40);
    stats.frame_sent(FrameKind::Output, 100);
    let snapshot = stats.snapshot();
    assert_eq!(
        snapshot.received,
        vec![
            IpcKindSnapshot { kind: "line", messages: 2, bytes: 15 },
            IpcKindSnapshot { kind: "request", messages: 1, bytes: 40 },
        ]
    );
    assert_eq!(snapshot.sent, vec![IpcKindSnapshot { kind: "output", messages: 1, bytes: 100 }]);
    assert_eq!(snapshot.writes.messages, 1);
}

#[test]
fn every_frame_kind_has_a_slot() {
    let stats = IpcStats::default();
    for kind in FrameKind::ALL {
        stats.frame_received(kind, 1);
    }
    let names: Vec<_> = stats.snapshot().received.into_iter().map(|row| row.kind).collect();
    let expected: Vec<_> = FrameKind::ALL.into_iter().map(FrameKind::name).collect();
    assert_eq!(names, expected);
}

#[test]
fn parse_scopes_count_requests_and_parses_per_transport() {
    let stats = IpcStats::default();
    {
        let _scope = JsonParseScope::enter(&stats, IpcTransport::Lines);
        note_json_parse();
    }
    {
        let _scope = JsonParseScope::enter(&stats, IpcTransport::Lines);
        let _: serde_json::Value = crate::line_parses::parse("{}").unwrap();
        // A parse that fails still parsed the bytes.
        assert!(crate::line_parses::parse::<serde_json::Value>("{").is_err());
        note_json_parse();
    }
    {
        let _scope = JsonParseScope::enter(&stats, IpcTransport::Frames);
        note_json_parse();
    }
    let parses = stats.snapshot().parses;
    assert_eq!(
        parses.lines,
        IpcParseSnapshot { requests: 2, json_parses: 4, json_parses_per_request: 2.0 }
    );
    assert_eq!(
        parses.frames,
        IpcParseSnapshot { requests: 1, json_parses: 1, json_parses_per_request: 1.0 }
    );
}

#[test]
fn parses_outside_a_scope_never_reach_a_later_request() {
    let stats = IpcStats::default();
    note_json_parse();
    let _: serde_json::Result<serde_json::Value> = crate::line_parses::parse("{}");
    {
        let _scope = JsonParseScope::enter(&stats, IpcTransport::Lines);
    }
    note_json_parse();
    {
        let _scope = JsonParseScope::enter(&stats, IpcTransport::Lines);
        note_json_parse();
    }
    assert_eq!(
        stats.snapshot().parses.lines,
        IpcParseSnapshot { requests: 2, json_parses: 1, json_parses_per_request: 0.5 }
    );
}

#[test]
fn a_nested_scope_keeps_its_parses_apart_from_the_outer_one() {
    let outer_stats = IpcStats::default();
    let inner_stats = IpcStats::default();
    {
        let _outer = JsonParseScope::enter(&outer_stats, IpcTransport::Lines);
        note_json_parse();
        {
            let _inner = JsonParseScope::enter(&inner_stats, IpcTransport::Frames);
            note_json_parse();
            note_json_parse();
        }
        note_json_parse();
    }
    assert_eq!(outer_stats.snapshot().parses.lines.json_parses, 2);
    assert_eq!(inner_stats.snapshot().parses.frames.json_parses, 2);
}

/// A request handed to another thread (a line queued on its connection's
/// control sequence) counts once, where it began, with the parses of both
/// threads; one whose handoff is dropped unrun adds no parse.
#[test]
fn a_handed_off_request_counts_once_with_both_threads_parses() {
    let stats = IpcStats::default();
    let handoff = {
        let _scope = JsonParseScope::enter(&stats, IpcTransport::Lines);
        note_json_parse();
        JsonParseScope::handoff()
    };
    assert_eq!(stats.snapshot().parses.lines.requests, 1, "the reader's scope counts it");
    std::thread::spawn(move || {
        let _resumed = JsonParseScope::resume(handoff).expect("a scope was open");
        note_json_parse();
    })
    .join()
    .unwrap();
    {
        let _scope = JsonParseScope::enter(&stats, IpcTransport::Lines);
        note_json_parse();
        drop(JsonParseScope::handoff());
    }
    assert_eq!(
        stats.snapshot().parses.lines,
        IpcParseSnapshot { requests: 2, json_parses: 3, json_parses_per_request: 1.5 }
    );
}

/// Takes at most `chunk` bytes per call, like a socket with a full buffer.
struct Chunked {
    chunk: usize,
    taken: Vec<u8>,
}

impl Write for Chunked {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let n = buf.len().min(self.chunk);
        self.taken.extend_from_slice(&buf[..n]);
        Ok(n)
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn counted_writes_count_each_syscall() {
    let stats = IpcStats::default();
    let mut sink = Chunked { chunk: 4, taken: Vec::new() };
    stats.counted(&mut sink).write_all(b"0123456789").unwrap();
    stats.line_sent(10);
    assert_eq!(sink.taken, b"0123456789");
    let writes = stats.snapshot().writes;
    assert_eq!(writes.syscalls, 3, "4 + 4 + 2 bytes");
    assert_eq!(writes.messages, 1);
    assert_eq!(writes.syscalls_per_message, 3.0);
    assert_eq!(writes.stalls, 0);
}

/// Blocks each write past the stall threshold, like a peer that stopped reading.
struct Slow;

impl Write for Slow {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        std::thread::sleep(WRITE_STALL_THRESHOLD * 2);
        Ok(buf.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_blocked_write_is_a_stall() {
    let stats = IpcStats::default();
    stats.counted(&mut Slow).write_all(b"x").unwrap();
    assert_eq!(stats.snapshot().writes.stalls, 1);
}

#[test]
fn bad_message_and_depth_counters() {
    let stats = IpcStats::default();
    stats.bad_message();
    stats.sequence_depth(3);
    let snapshot = stats.snapshot();
    assert_eq!(snapshot.bad_message, 1);
    assert_eq!(snapshot.sequence_depth.count, 1);
    assert_eq!(snapshot.sequence_depth.max, 3);
}
