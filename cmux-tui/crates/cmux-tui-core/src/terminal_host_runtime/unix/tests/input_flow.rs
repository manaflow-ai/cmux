//! Key-press flows on host input and output (`FLAG_INPUT_FLOW`):
//! the owner sends the trailer only to a host that
//! negotiated it on the smart stream, the host never writes it to the PTY,
//! its next PTY read after the bytes reached the PTY takes the flow and its
//! Output frame carries it back, once; input that never reached the PTY arms
//! nothing, and records from before the flag still load.

use cmux_kitty_media::KittyMediaRewriter;

use super::super::super::shared::host_start::read_pty_once;
use super::host_fixture::test_host_shared_with_budget;
use super::*;

/// A host served on one end of a socket pair, with `flags` on the owner's
/// hello. What the host writes to its PTY is read on `pty`; what the test
/// writes on `pty` is the PTY's output, which [`read_once`] reads.
struct Served {
    host: Arc<HostShared>,
    client: UnixStream,
    pty: UnixStream,
    host_pty: UnixStream,
    _parser: Receiver<ParserCommand>,
    server: thread::JoinHandle<()>,
}

fn served_host(flags: u32) -> Served {
    // A parser queue with room for real PTY reads; nothing parses it.
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, parser) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = test_host_shared_with_budget(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        MAX_HOST_PARSER_QUEUED_BYTES,
    );
    let (host_pty, pty) = UnixStream::pair().unwrap();
    pty.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
    *host.writer.lock().unwrap() = Box::new(host_pty.try_clone().unwrap());
    let (server_stream, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || {
        let _ =
            serve_client_with_snapshot_timeout(server_host, server_stream, Duration::from_secs(1));
    });
    let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
    hello.flags = flags;
    write_frame(&mut client, &hello).unwrap();
    let host_hello = read_required_frame(&mut client, "host hello").unwrap();
    assert_eq!(host_hello.kind, MessageKind::HostHello);
    assert_eq!(read_required_frame(&mut client, "snapshot").unwrap().kind, MessageKind::Snapshot);
    assert_eq!(read_required_frame(&mut client, "colors").unwrap().kind, MessageKind::Colors);
    if host_hello.flags & FLAG_SMART_RENDERER != 0 {
        assert_eq!(read_required_frame(&mut client, "ready").unwrap().kind, MessageKind::Ready);
    }
    Served { host, client, pty, host_pty, _parser: parser, server }
}

/// The smart stream with key-press flows.
const SMART_FLOW: u32 = FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS | FLAG_INPUT_FLOW;

fn flagged_input(bytes: &[u8], flow: u64) -> Frame {
    let mut frame = Frame::new(MessageKind::Input, flow_trailer_payload(bytes, flow));
    frame.flags = FLAG_INPUT_FLOW;
    frame
}

/// One read of the host's PTY, as its `terminal-host-pty` thread does.
fn read_once(served: &Served) {
    let mut reader = served.host_pty.try_clone().unwrap();
    let mut buffer = [0u8; 64];
    let (mut kitty, mut scratch) = (KittyMediaRewriter::new(), Vec::new());
    let read = read_pty_once(&served.host, &mut reader, &mut buffer, &mut kitty, &mut scratch);
    assert!(!read.ends(), "the PTY read ended");
}

fn finish(served: Served) {
    served.host.broadcast(MessageKind::Exit, Vec::new());
    let _ = served.client.shutdown(std::net::Shutdown::Both);
    served.server.join().unwrap();
}

#[test]
fn echo_flow_host_writes_the_input_and_its_next_read_carries_the_flow_once() {
    let mut served = served_host(SMART_FLOW);
    write_frame(&mut served.client, &flagged_input(b"ls\r", 42)).unwrap();
    let mut written = [0u8; 3];
    served.pty.read_exact(&mut written).unwrap();
    assert_eq!(&written, b"ls\r");
    let mut more = [0u8; 1];
    assert!(served.pty.read(&mut more).is_err(), "the flow trailer reached the PTY");

    // The shell's echo: the host's read takes flow 42 (`host.pty.read`) and its Output carries it.
    served.pty.write_all(b"ls\r\n").unwrap();
    read_once(&served);
    let echo = read_required_frame(&mut served.client, "echo").unwrap();
    assert_eq!((echo.kind, echo.flags), (MessageKind::Output, FLAG_INPUT_FLOW));
    assert_eq!(split_flow_trailer(echo.flags, &echo.payload), Some((&b"ls\r\n"[..], 42)));
    assert_eq!(served.host.last_input_flow.take(), 0, "the read took it");

    // The next read is not the echo of anything.
    served.pty.write_all(b"$ ").unwrap();
    read_once(&served);
    let next = read_required_frame(&mut served.client, "prompt").unwrap();
    assert_eq!((next.kind, next.flags), (MessageKind::Output, 0), "only once");
    assert_eq!(next.payload, b"$ ");

    // Plain input on the same connection carries no flow.
    write_frame(&mut served.client, &Frame::new(MessageKind::Input, b"x".to_vec())).unwrap();
    served.pty.read_exact(&mut more).unwrap();
    assert_eq!(&more, b"x");
    assert_eq!(served.host.last_input_flow.take(), 0);
    finish(served);
}

#[test]
fn echo_flow_host_refuses_a_trailer_it_did_not_negotiate() {
    let mut served = served_host(FLAG_SMART_RENDERER | FLAG_VIEWER_SIZE_ACKS);
    write_frame(&mut served.client, &flagged_input(b"ls\r", 42)).unwrap();
    let mut byte = [0u8; 1];
    assert!(served.pty.read(&mut byte).is_err(), "an unnegotiated flagged input reached the PTY");
    assert_eq!(served.host.last_input_flow.take(), 0);
    finish(served);
}

/// Flows come back on the smart stream's Output frames only: a legacy
/// (parser-ordered) stream is never granted the flag.
#[test]
fn echo_flow_host_grants_the_flag_only_on_the_smart_stream() {
    let mut served = served_host(FLAG_INPUT_FLOW);
    write_frame(&mut served.client, &flagged_input(b"ls\r", 42)).unwrap();
    let mut byte = [0u8; 1];
    assert!(served.pty.read(&mut byte).is_err(), "a legacy stream took a flagged input");
    finish(served);
}

/// A client that did not negotiate the flag (a renderer) gets an echo
/// frame without flag and trailer.
#[test]
fn echo_flow_output_loses_the_trailer_toward_a_client_without_the_flag() {
    let mut echo = Frame::new(MessageKind::Output, flow_trailer_payload(b"ls", 42));
    echo.flags = FLAG_INPUT_FLOW;
    echo.sequence = 7;
    assert_eq!(&*client_wire_frame(&echo, true, false), &echo);
    let plain = client_wire_frame(&echo, false, false);
    assert_eq!((plain.flags, plain.sequence, plain.payload.as_slice()), (0, 7, &b"ls"[..]));
    let resized = Frame::new(MessageKind::Resized, vec![1, 0, 1, 0]);
    assert!(matches!(client_wire_frame(&resized, false, false), std::borrow::Cow::Borrowed(_)));
}

/// Input that never reached the PTY (here the write failed) arms nothing,
/// so the next unrelated read is not taken for its echo.
#[test]
fn echo_flow_a_failed_host_write_arms_nothing() {
    struct Failing;
    impl Write for Failing {
        fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
            Err(std::io::ErrorKind::BrokenPipe.into())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let host = exited_host_fixture();
    *host.writer.lock().unwrap() = Box::new(Failing);
    let (tap_sender, _tap_receiver) = mpsc_channel();
    let (socket, _peer) = UnixStream::pair().unwrap();
    let tap = HostTap::new(tap_sender, Arc::new(socket), usize::MAX);
    assert!(host.write_input(b"a", 0, 42, &tap), "interactive input stays best effort");
    assert_eq!(host.last_input_flow.take(), 0, "a failed write armed its flow");
}

#[test]
fn echo_flow_owner_sends_the_trailer_only_when_negotiated() {
    let (mut attachment, mut host) = input_ack_surface_fixture();
    host.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let mut next = || read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();

    attachment.send_flow(MessageKind::Input, b"ls", 42).unwrap();
    let plain = next();
    assert_eq!((plain.flags, plain.payload.as_slice()), (0, &b"ls"[..]), "an older host");

    attachment.input_flow = true;
    attachment.send_flow(MessageKind::Input, b"ls", 42).unwrap();
    let flagged = next();
    assert_eq!(flagged.flags, FLAG_INPUT_FLOW);
    assert_eq!(split_flow_trailer(flagged.flags, &flagged.payload), Some((&b"ls"[..], 42)));

    attachment.send_flow(MessageKind::Input, b"ls", 0).unwrap();
    assert_eq!(next().flags, 0, "no flow, no trailer");
    attachment.send_flow(MessageKind::Paste, b"ls", 42).unwrap();
    let paste = next();
    assert_eq!((paste.kind, paste.flags), (MessageKind::Paste, 0), "paste takes no trailer");
}

#[test]
fn echo_flow_split_rejects_a_short_trailer() {
    assert_eq!(split_flow_trailer(0, b"abc"), Some((&b"abc"[..], 0)));
    assert_eq!(split_flow_trailer(FLAG_INPUT_FLOW, &[1, 2, 3]), None);
    assert_eq!(
        split_flow_trailer(FLAG_INPUT_FLOW, &flow_trailer_payload(b"", 7)),
        Some((&[][..], 7))
    );
}

/// Records written before the flag existed load with no input flow, and a
/// pre-v4 record may not claim it.
#[test]
fn echo_flow_records_from_before_the_flag_still_load() {
    let (record_path, record, lease) = record_fixture("input-flow-old-record");
    let mut json = serde_json::to_value(&record).unwrap();
    json.as_object_mut().unwrap().remove("supports_input_flow");
    json.as_object_mut().unwrap().remove("supports_input_stages");
    let old: TerminalHostRecord = serde_json::from_value(json).unwrap();
    assert!(!old.supports_input_flow);
    assert!(validate_terminal_host_record(&record_path, &old).is_ok());

    let mut pre_v4 = TerminalHostRecord {
        record_version: 3,
        supports_terminal_metadata: false,
        supports_viewer_size_priority: false,
        supports_input_ack: false,
        supports_clipboard_read: false,
        supports_pty_custody: false,
        supports_program_status: false,
        supports_shell_activity: false,
        ..old
    };
    assert!(validate_terminal_host_record(&record_path, &pre_v4).is_ok());
    pre_v4.supports_input_flow = true;
    assert!(validate_terminal_host_record(&record_path, &pre_v4).is_err());
    drop(lease);
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

/// The smart stream with key-press flows and their stages.
const SMART_STAGES: u32 = SMART_FLOW | FLAG_INPUT_STAGES;

/// A host that negotiated key stages stamps its PTY write of
/// a flagged input and the read that echoes it, and the echo's Output frame
/// carries both with the flow, once.
#[test]
fn input_stages_host_echo_carries_its_write_and_read() {
    let mut served = served_host(SMART_STAGES);
    write_frame(&mut served.client, &flagged_input(b"ls\r", 42)).unwrap();
    let mut written = [0u8; 3];
    served.pty.read_exact(&mut written).unwrap();
    assert_eq!(&written, b"ls\r");

    served.pty.write_all(b"ls\r\n").unwrap();
    read_once(&served);
    let echo = read_required_frame(&mut served.client, "echo").unwrap();
    assert_eq!((echo.kind, echo.flags), (MessageKind::Output, FLAG_INPUT_FLOW | FLAG_INPUT_STAGES));
    let (bytes, flow, write_ns, read_ns) = split_stages_trailer(&echo.payload).unwrap();
    assert_eq!((bytes, flow), (&b"ls\r\n"[..], 42));
    assert!(write_ns != 0 && read_ns >= write_ns, "write {write_ns} read {read_ns}");

    served.pty.write_all(b"$ ").unwrap();
    read_once(&served);
    let next = read_required_frame(&mut served.client, "prompt").unwrap();
    assert_eq!((next.flags, next.payload.as_slice()), (0, &b"$ "[..]), "only once");
    finish(served);
}

/// A client that negotiated only the flow (an older daemon) gets the flow
/// trailer of a staged echo; one with neither gets the bytes alone.
#[test]
fn input_stages_output_keeps_only_what_the_client_negotiated() {
    let mut echo = Frame::new(MessageKind::Output, stages_trailer_payload(b"ls", 42, 10, 20));
    echo.flags = FLAG_INPUT_FLOW | FLAG_INPUT_STAGES;
    echo.sequence = 7;
    assert!(matches!(client_wire_frame(&echo, true, true), std::borrow::Cow::Borrowed(_)));
    let flow_only = client_wire_frame(&echo, true, false);
    assert_eq!((flow_only.flags, flow_only.sequence), (FLAG_INPUT_FLOW, 7));
    assert_eq!(split_flow_trailer(flow_only.flags, &flow_only.payload), Some((&b"ls"[..], 42)));
    let plain = client_wire_frame(&echo, false, false);
    assert_eq!((plain.flags, plain.payload.as_slice()), (0, &b"ls"[..]));
}

/// Stages ride on the flow: a record may not advertise them alone.
#[test]
fn input_stages_need_the_flow() {
    let (record_path, record, lease) = record_fixture("input-stages-record");
    let mut stages_only = record;
    stages_only.supports_input_flow = false;
    stages_only.supports_input_stages = true;
    assert!(validate_terminal_host_record(&record_path, &stages_only).is_err());
    drop(lease);
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}

#[test]
fn input_stages_split_rejects_a_short_trailer() {
    assert_eq!(split_stages_trailer(&[0; 23]), None);
    assert_eq!(
        split_stages_trailer(&stages_trailer_payload(b"", 7, 1, 2)),
        Some((&[][..], 7, 1, 2))
    );
}
