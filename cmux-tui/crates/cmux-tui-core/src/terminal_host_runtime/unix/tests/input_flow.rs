//! Key-press flows on host input (`FLAG_INPUT_FLOW`, p09-observability-018):
//! the owner sends the trailer only to a host that negotiated it, the host
//! never writes it to the PTY and stamps its next read with the flow, and
//! records from before the flag still load.

use super::*;

/// A host served on one end of a socket pair whose PTY writer is the
/// returned stream; `flags` go on the owner's hello.
fn served_host(flags: u32) -> (Arc<HostShared>, UnixStream, UnixStream, thread::JoinHandle<()>) {
    let host = exited_host_fixture();
    let (pty_writer, pty_reader) = UnixStream::pair().unwrap();
    pty_reader.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
    *host.writer.lock().unwrap() = Box::new(pty_writer);
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
    assert_eq!(host_hello.flags & FLAG_INPUT_FLOW, flags & FLAG_INPUT_FLOW, "flag echoed");
    assert_eq!(read_required_frame(&mut client, "snapshot").unwrap().kind, MessageKind::Snapshot);
    assert_eq!(read_required_frame(&mut client, "colors").unwrap().kind, MessageKind::Colors);
    (host, client, pty_reader, server)
}

fn flagged_input(bytes: &[u8], flow: u64) -> Frame {
    let mut frame = Frame::new(MessageKind::Input, input_flow_payload(bytes, flow));
    frame.flags = FLAG_INPUT_FLOW;
    frame
}

fn finish(host: &HostShared, client: UnixStream, server: thread::JoinHandle<()>) {
    host.broadcast(MessageKind::Exit, Vec::new());
    let _ = client.shutdown(std::net::Shutdown::Both);
    server.join().unwrap();
}

#[test]
fn echo_flow_host_writes_the_input_and_stamps_the_next_read_once() {
    let (host, mut client, mut pty, server) = served_host(FLAG_INPUT_FLOW);
    write_frame(&mut client, &flagged_input(b"ls\r", 42)).unwrap();
    let mut written = [0u8; 3];
    pty.read_exact(&mut written).unwrap();
    assert_eq!(&written, b"ls\r");
    let mut more = [0u8; 1];
    assert!(pty.read(&mut more).is_err(), "the flow trailer reached the PTY");
    assert_eq!(host.take_input_flow(), 42, "the next PTY read carries flow 42");
    assert_eq!(host.take_input_flow(), 0, "only once");

    // Plain input on the same connection carries no flow.
    write_frame(&mut client, &Frame::new(MessageKind::Input, b"x".to_vec())).unwrap();
    pty.read_exact(&mut more).unwrap();
    assert_eq!(&more, b"x");
    assert_eq!(host.take_input_flow(), 0);
    finish(&host, client, server);
}

#[test]
fn echo_flow_host_refuses_a_trailer_it_did_not_negotiate() {
    let (host, mut client, mut pty, server) = served_host(0);
    write_frame(&mut client, &flagged_input(b"ls\r", 42)).unwrap();
    let mut byte = [0u8; 1];
    assert!(pty.read(&mut byte).is_err(), "an unnegotiated flagged input reached the PTY");
    assert_eq!(host.take_input_flow(), 0);
    finish(&host, client, server);
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
    assert_eq!(split_input_flow(flagged.flags, &flagged.payload), Some((&b"ls"[..], 42)));

    attachment.send_flow(MessageKind::Input, b"ls", 0).unwrap();
    assert_eq!(next().flags, 0, "no flow, no trailer");
    attachment.send_flow(MessageKind::Paste, b"ls", 42).unwrap();
    let paste = next();
    assert_eq!((paste.kind, paste.flags), (MessageKind::Paste, 0), "paste takes no trailer");
}

#[test]
fn echo_flow_split_rejects_a_short_trailer() {
    assert_eq!(split_input_flow(0, b"abc"), Some((&b"abc"[..], 0)));
    assert_eq!(split_input_flow(FLAG_INPUT_FLOW, &[1, 2, 3]), None);
    assert_eq!(split_input_flow(FLAG_INPUT_FLOW, &input_flow_payload(b"", 7)), Some((&[][..], 7)));
}

/// Records written before the flag existed load with no input flow, and a
/// pre-v4 record may not claim it.
#[test]
fn echo_flow_records_from_before_the_flag_still_load() {
    let (record_path, record, lease) = record_fixture("input-flow-old-record");
    let mut json = serde_json::to_value(&record).unwrap();
    json.as_object_mut().unwrap().remove("supports_input_flow");
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
