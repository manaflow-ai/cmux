//! Hosted input through the host's input sink (p05-ipc-157,
//! `FLAG_INPUT_FAILURES`): a child that does not read never blocks the
//! client's frames, input the sink refuses comes back to its sender in one
//! `InputFailed` per refusal, a failed PTY reports each sender's queued
//! bytes once, and accepted input reaches the PTY in order.

use super::host_fixture::test_host_shared_with_input;
use super::*;
use crate::input_receipt::{InputFailure, InputReceipt};
use crate::pty_write::{INPUT_SINK_CAPACITY, LocalInput, PtyInputSink};
use crate::terminal_host_protocol::{
    FLAG_INPUT_FAILURES, INPUT_FAILED_OVERFLOW, INPUT_FAILED_WRITE, decode_input_failed,
    encode_input_failed,
};

/// A host whose PTY input goes through a real input sink, served to an
/// admin client that negotiated input failures. The child end of the PTY
/// is `pty`, which reads only when the test does.
struct Served {
    host: Arc<HostShared>,
    client: UnixStream,
    pty: UnixStream,
    _parser: Receiver<ParserCommand>,
    server: thread::JoinHandle<()>,
}

fn served_host_with_sink() -> Served {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, parser) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let (host_pty, pty) = UnixStream::pair().unwrap();
    let sink = PtyInputSink::new(host_pty.as_raw_fd(), std::sync::Weak::new()).unwrap();
    drop(host_pty);
    let host = test_host_shared_with_input(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        MAX_HOST_PARSER_QUEUED_BYTES,
        Some(LocalInput::new(sink)),
    );
    let (server_stream, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || {
        let _ =
            serve_client_with_snapshot_timeout(server_host, server_stream, Duration::from_secs(1));
    });
    let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
    hello.flags = FLAG_INPUT_FAILURES;
    write_frame(&mut client, &hello).unwrap();
    let host_hello = read_required_frame(&mut client, "host hello").unwrap();
    assert_eq!(host_hello.kind, MessageKind::HostHello);
    assert_ne!(host_hello.flags & FLAG_INPUT_FAILURES, 0, "the host grants input failures");
    assert_eq!(read_required_frame(&mut client, "snapshot").unwrap().kind, MessageKind::Snapshot);
    assert_eq!(read_required_frame(&mut client, "colors").unwrap().kind, MessageKind::Colors);
    Served { host, client, pty, _parser: parser, server }
}

/// Interactive input of `sender`.
fn sender_input(sender: u64, bytes: &[u8]) -> Frame {
    let mut frame = Frame::new(MessageKind::Input, bytes.to_vec());
    frame.flags = FLAG_INPUT_FAILURES;
    frame.request_id = sender;
    frame
}

/// A receipted empty Input: its InputAck comes after every frame the host
/// sent for the input before it.
fn fence(served: &mut Served, request_id: u64) -> Vec<Frame> {
    let mut frame = Frame::new(MessageKind::Input, Vec::new());
    frame.request_id = request_id;
    write_frame(&mut served.client, &frame).unwrap();
    let mut seen = Vec::new();
    loop {
        let frame = read_required_frame(&mut served.client, "a host frame").unwrap();
        if frame.kind == MessageKind::InputAck && frame.request_id == request_id {
            return seen;
        }
        seen.push(frame);
    }
}

fn finish(served: Served) {
    served.host.broadcast(MessageKind::Exit, Vec::new());
    let _ = served.client.shutdown(std::net::Shutdown::Both);
    served.server.join().unwrap();
}

#[test]
fn async_input_sink_a_hosted_child_that_does_not_read_gets_overflow_reports_and_order() {
    let mut served = served_host_with_sink();
    const BLOCK: usize = 1 << 20;
    let blocks = INPUT_SINK_CAPACITY / BLOCK + 3;
    for index in 0..blocks {
        write_frame(&mut served.client, &sender_input(5, &vec![index as u8; BLOCK])).unwrap();
    }
    // The client's frames went on although the child reads nothing.
    let seen = fence(&mut served, 77);
    let refusals: Vec<&Frame> =
        seen.iter().filter(|frame| frame.kind == MessageKind::InputFailed).collect();
    assert!(!refusals.is_empty(), "the backlog took more than its capacity");
    for refusal in &refusals {
        assert_eq!(refusal.request_id, 5, "a refusal goes to its sender");
        assert_eq!(
            decode_input_failed(&refusal.payload),
            Some((INPUT_FAILED_OVERFLOW, BLOCK as u64)),
            "a refusal is whole"
        );
    }

    // Refusals are whole and every later block is refused while the backlog
    // is full: the accepted blocks are the first ones, in order.
    let accepted = blocks - refusals.len();
    served.pty.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let mut received = vec![0u8; accepted * BLOCK];
    served.pty.read_exact(&mut received).unwrap();
    for (index, block) in received.chunks(BLOCK).enumerate() {
        assert!(block.iter().all(|byte| *byte == index as u8), "block {index} out of order");
    }
    finish(served);
}

#[test]
fn async_input_sink_a_hosted_pty_that_fails_reports_each_senders_queued_bytes_once() {
    let mut served = served_host_with_sink();
    // Fill the PTY, then queue interleaved input of two senders.
    let fill = vec![b'f'; 64 * 1024];
    while served.host.queued_pty_input() == 0 {
        write_frame(&mut served.client, &sender_input(1, &fill)).unwrap();
        assert!(fence(&mut served, 2).is_empty(), "the fill was refused");
    }
    for _ in 0..100 {
        write_frame(&mut served.client, &sender_input(5, b"five")).unwrap();
        write_frame(&mut served.client, &sender_input(6, b"six!!!")).unwrap();
    }
    assert!(fence(&mut served, 3).is_empty(), "queued input was refused");

    // The child goes away: its PTY fails, and each sender hears once.
    let pty = std::mem::replace(&mut served.pty, UnixStream::pair().unwrap().0);
    drop(pty);
    let mut reports = Vec::new();
    while reports.len() < 2 {
        let frame = read_required_frame(&mut served.client, "a failure report").unwrap();
        if frame.kind == MessageKind::InputFailed && frame.request_id != 1 {
            reports.push((frame.request_id, decode_input_failed(&frame.payload)));
        }
    }
    reports.sort();
    assert_eq!(
        reports,
        vec![(5, Some((INPUT_FAILED_WRITE, 400))), (6, Some((INPUT_FAILED_WRITE, 600)))]
    );
    finish(served);
}

/// A flag the client did not negotiate, or a sender id of 0, closes it.
#[test]
fn async_input_sink_a_host_refuses_unnegotiated_or_unnamed_senders() {
    let host = test_host_shared();
    let (server_stream, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || {
        let _ =
            serve_client_with_snapshot_timeout(server_host, server_stream, Duration::from_secs(1));
    });
    write_frame(&mut client, &snapshot_boundary_client_hello(&host, false).unwrap()).unwrap();
    let host_hello = read_required_frame(&mut client, "host hello").unwrap();
    assert_eq!(host_hello.flags & FLAG_INPUT_FAILURES, 0);
    read_required_frame(&mut client, "snapshot").unwrap();
    read_required_frame(&mut client, "colors").unwrap();
    write_frame(&mut client, &sender_input(5, b"x")).unwrap();
    assert!(read_frame(&mut client, MAX_FRAME_PAYLOAD).unwrap().is_none(), "the host closed");
    server.join().unwrap();

    let mut served = served_host_with_sink();
    write_frame(&mut served.client, &sender_input(0, b"x")).unwrap();
    assert!(read_frame(&mut served.client, MAX_FRAME_PAYLOAD).unwrap().is_none());
    served.server.join().unwrap();
}

/// A sender that records what it hears.
#[derive(Default)]
struct Recorded(Mutex<Vec<(InputFailure, usize)>>);

impl InputReceipt for Recorded {
    fn failed(&self, reason: InputFailure, bytes: usize) {
        self.0.lock().unwrap().push((reason, bytes));
    }
}

/// The owner names each sender once per connection, hands a report to it,
/// drops reports for a sender that went away, and ends on a malformed one.
#[test]
fn async_input_sink_the_owner_routes_reports_to_their_sender() {
    let senders = shared::input_failures::InputSenders::default();
    let first = Arc::new(Recorded::default());
    let second = Arc::new(Recorded::default());
    let first_dyn: Arc<dyn InputReceipt> = first.clone();
    let second_dyn: Arc<dyn InputReceipt> = second.clone();
    let first_id = senders.id_of(&first_dyn);
    assert_ne!(first_id, 0);
    assert_eq!(senders.id_of(&first_dyn), first_id, "one id per sender");
    let second_id = senders.id_of(&second_dyn);
    assert_ne!(second_id, first_id);

    let report = |id: u64, payload: Vec<u8>| {
        let mut frame = Frame::new(MessageKind::InputFailed, payload);
        frame.request_id = id;
        frame
    };
    let overflow = encode_input_failed(INPUT_FAILED_OVERFLOW, 12);
    assert!(senders.report(&report(second_id, overflow.clone()), PROTOCOL_VERSION));
    assert_eq!(*second.0.lock().unwrap(), vec![(InputFailure::Overflow, 12)]);
    assert!(first.0.lock().unwrap().is_empty());

    drop((first_dyn, first));
    assert!(senders.report(&report(first_id, overflow), PROTOCOL_VERSION), "a gone sender");
    assert!(!senders.report(&report(second_id, vec![9, 0]), PROTOCOL_VERSION), "malformed");
    assert!(!senders.report(&report(second_id, encode_input_failed(9, 1)), PROTOCOL_VERSION));
}

#[test]
fn async_input_sink_the_owner_names_the_sender_only_when_negotiated() {
    let (mut attachment, mut host) = input_ack_surface_fixture();
    host.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let mut next = || read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    let sender: Arc<dyn InputReceipt> = Arc::new(Recorded::default());

    attachment.send_input(MessageKind::Input, b"ls", 0, Some(&sender)).unwrap();
    let plain = next();
    assert_eq!((plain.flags, plain.request_id), (0, 0), "an older host");

    attachment.input_failures = true;
    attachment.input_flow = true;
    attachment.send_input(MessageKind::Input, b"ls", 42, Some(&sender)).unwrap();
    let named = next();
    assert_eq!(named.flags, FLAG_INPUT_FAILURES | FLAG_INPUT_FLOW);
    assert_ne!(named.request_id, 0);
    assert_eq!(split_flow_trailer(named.flags, &named.payload), Some((&b"ls"[..], 42)));
    attachment.send_input(MessageKind::Input, b"cd", 0, Some(&sender)).unwrap();
    let again = next();
    assert_eq!((again.flags, again.request_id), (FLAG_INPUT_FAILURES, named.request_id));
    assert_eq!(again.payload, b"cd");
    attachment.send_input(MessageKind::Paste, b"p", 0, Some(&sender)).unwrap();
    assert_eq!(next().flags, 0, "a paste names no sender");
}

/// Records written before the flag existed load without it, and a pre-v4
/// record may not claim it.
#[test]
fn async_input_sink_records_from_before_the_flag_still_load() {
    let (record_path, record, lease) = record_fixture("input-failures-old-record");
    let mut json = serde_json::to_value(&record).unwrap();
    json.as_object_mut().unwrap().remove("supports_input_failures");
    let old: TerminalHostRecord = serde_json::from_value(json).unwrap();
    assert!(!old.supports_input_failures);
    assert!(validate_terminal_host_record(&record_path, &old).is_ok());
    let mut v4 = old.clone();
    v4.supports_input_failures = true;
    assert!(validate_terminal_host_record(&record_path, &v4).is_ok());
    let mut pre_v4 = TerminalHostRecord {
        record_version: 3,
        supports_terminal_metadata: false,
        supports_viewer_size_priority: false,
        supports_input_ack: false,
        supports_clipboard_read: false,
        supports_pty_custody: false,
        supports_program_status: false,
        supports_shell_activity: false,
        supports_trace_control: false,
        supports_input_flow: false,
        supports_thread_qos: false,
        ..old
    };
    assert!(validate_terminal_host_record(&record_path, &pre_v4).is_ok());
    pre_v4.supports_input_failures = true;
    assert!(validate_terminal_host_record(&record_path, &pre_v4).is_err());
    drop(lease);
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}
