//! The terminal host's trace slices (p09-observability-016): `task.host_pty_read` per PTY read,
//! `task.host_parse` per parser command and `task.host_input_write` per client-input write, each
//! with the terminal's hash. `task` is recording-only, so the black box never holds them.
//!
//! The ring is per process and other tests run beside these, so each test finds its records by
//! its own host's terminal hash.

use std::sync::OnceLock;

use cmux_kitty_media::KittyMediaRewriter;
use cmux_trace::{Decoded, DecodedRecord, Phase, Role, category, decode};

use super::super::super::shared::host_parser::parser_command_trace_arg;
use super::super::super::shared::host_start::{PtyRead, read_pty_once};
use super::host_fixture::test_host_shared_with_budget;
use super::*;

/// Starts this test process's ring and a `task` recording once; it runs until the process ends.
fn recording() {
    static STARTED: OnceLock<()> = OnceLock::new();
    STARTED.get_or_init(|| {
        let dir = std::env::temp_dir()
            .join(format!("cmux-host-spans-{}", std::process::id()))
            .join("rings");
        let _open = cmux_trace::init_blackbox(dir, Role::TerminalHost);
        cmux_trace::start_recording(category::TASK).expect("a recording starts");
    });
    assert!(cmux_trace::enabled(category::TASK));
}

/// The ring's records named `name` with arg0 `hash`, in the order their thread wrote them.
fn records(name: &str, hash: u64) -> Vec<DecodedRecord> {
    let decoded: Decoded =
        decode(&cmux_trace::snapshot_active().expect("tracing started")).expect("the ring decodes");
    let mut named: Vec<DecodedRecord> = decoded
        .records
        .iter()
        .filter(|record| decoded.name(record.name) == Some(name))
        .copied()
        .collect();
    named.sort_by_key(|record| {
        (record.thread_index, record.thread_generation, record.position, record.slot)
    });
    // An end record carries its own numbers: keep each end that follows a begin of this hash on
    // its thread.
    let mut kept = Vec::new();
    let mut open_on = None;
    for record in named {
        let thread = (record.thread_index, record.thread_generation);
        if record.phase == Phase::Begin as u8 {
            open_on = (record.arg0 == hash).then_some(thread);
            if open_on.is_some() {
                kept.push(record);
            }
        } else if record.phase == Phase::End as u8 {
            if open_on.take() == Some(thread) {
                kept.push(record);
            }
        } else if record.arg0 == hash {
            kept.push(record);
        }
    }
    kept
}

fn host_with_parser_queue() -> (Arc<HostShared>, Receiver<ParserCommand>) {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = test_host_shared_with_budget(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        MAX_HOST_PARSER_QUEUED_BYTES,
    );
    (host, receiver)
}

fn hash_of(host: &HostShared) -> u64 {
    cmux_trace::terminal_hash(host.terminal_id.as_bytes())
}

#[test]
fn host_spans_one_pty_read_slice_per_read_with_its_byte_count() {
    recording();
    let (host, receiver) = host_with_parser_queue();
    let (mut pty, mut reader) = UnixStream::pair().unwrap();
    pty.write_all(b"hello").unwrap();
    let mut buffer = [0u8; 64];
    let (mut kitty, mut scratch) = (KittyMediaRewriter::new(), Vec::new());

    let read = read_pty_once(&host, &mut reader, &mut buffer, &mut kitty, &mut scratch);
    assert_eq!(read, PtyRead::Published);
    assert!(
        matches!(receiver.try_recv(), Ok(ParserCommand::Output { bytes, .. }) if bytes == b"hello")
    );
    drop(pty);
    let read = read_pty_once(&host, &mut reader, &mut buffer, &mut kitty, &mut scratch);
    assert_eq!(read, PtyRead::End, "end of file ends the reader");

    let slices = records("task.host_pty_read", hash_of(&host));
    let phases: Vec<u8> = slices.iter().map(|record| record.phase).collect();
    let (begin, end) = (Phase::Begin as u8, Phase::End as u8);
    assert_eq!(phases, [begin, end, begin, end], "one slice per read: {slices:?}");
    assert_eq!(slices[1].arg0, 5, "the first read's end carries its bytes");
    assert_eq!(slices[3].arg0, 0, "the end of file read nothing");
    assert!(slices[0].t_ns <= slices[1].t_ns);
}

#[test]
fn host_spans_one_parse_slice_per_parser_command() {
    recording();
    let (host, receiver) = host_with_parser_queue();
    let initial_colors = host.term.lock().unwrap().color_overrides();
    let parser_host = host.clone();
    let parser = thread::spawn(move || {
        run_host_parser(parser_host, receiver, initial_colors, ParserSignals::new());
    });
    let output = ParserCommand::Output {
        bytes: b"parsed".to_vec(),
        source_cursor: host.smart.publish(Frame::new(MessageKind::Output, b"parsed".to_vec())),
        accounted_bytes: 0,
    };
    let output_arg = parser_command_trace_arg(&output);
    assert_eq!(output_arg, 6, "an Output's arg is kind 0 and its byte count");
    host.parser_commands.send(output).unwrap();
    assert_eq!(parser_command_trace_arg(&ParserCommand::Drain), 6 << 56);
    host.parser_commands.send(ParserCommand::Drain).unwrap();
    parser.join().expect("the parser applied every command");

    let slices = records("task.host_parse", hash_of(&host));
    let begins: Vec<u64> = slices
        .iter()
        .filter(|record| record.phase == Phase::Begin as u8)
        .map(|record| record.arg1)
        .collect();
    assert_eq!(begins, [output_arg, 6 << 56], "one slice per command: {slices:?}");
    let ends = slices.iter().filter(|record| record.phase == Phase::End as u8).count();
    assert_eq!(ends, 2, "every command's slice ended: {slices:?}");
}

#[test]
fn host_spans_one_input_write_slice_per_client_write() {
    recording();
    let host = test_host_shared();
    let (pty_writer, mut pty_reader) = UnixStream::pair().unwrap();
    *host.writer.lock().unwrap() = Box::new(pty_writer);
    let (target_socket, _target_peer) = UnixStream::pair().unwrap();
    let (target_tx, _target_rx) = mpsc_channel();
    let target = HostTap::new(target_tx, Arc::new(target_socket), usize::MAX);

    assert!(host.write_input(b"typed", 0, &target));
    let mut typed = [0u8; 5];
    pty_reader.read_exact(&mut typed).unwrap();
    assert_eq!(&typed, b"typed");

    let slices = records("task.host_input_write", hash_of(&host));
    let phases: Vec<u8> = slices.iter().map(|record| record.phase).collect();
    assert_eq!(phases, [Phase::Begin as u8, Phase::End as u8], "{slices:?}");
    assert_eq!(slices[0].arg1, 5, "the begin carries the payload's bytes");
}
