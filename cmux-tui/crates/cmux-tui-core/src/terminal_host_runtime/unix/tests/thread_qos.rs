//! `SetThreadQos` (p02-threads-236): the owner sends it only to a host that
//! advertises it, the host stores the class for its PTY reader and parser,
//! a malformed one ends the connection, and records from before the field
//! still load.

use cmux_threads::ThreadQos;

use super::super::super::shared::thread_qos::encode_thread_qos;
use super::host_fixture::test_host_shared_with_budget;
use super::*;

#[test]
fn the_owner_sends_the_class_only_to_a_host_that_takes_it() {
    let (mut attachment, mut host) = input_ack_surface_fixture();
    host.set_read_timeout(Some(Duration::from_millis(200))).unwrap();
    assert!(!attachment.send_thread_qos(ThreadQos::Utility).unwrap(), "an older host");
    assert!(read_frame(&mut host, MAX_FRAME_PAYLOAD).is_err(), "it got a frame");

    attachment.record.supports_thread_qos = true;
    assert!(attachment.send_thread_qos(ThreadQos::Utility).unwrap());
    let frame = read_frame(&mut host, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!((frame.kind, frame.request_id), (MessageKind::SetThreadQos, 0));
    assert_eq!(frame.payload, encode_thread_qos(ThreadQos::Utility));
}

/// A host served on one end of a socket pair: the owner's connection.
fn served_host() -> (Arc<HostShared>, UnixStream, thread::JoinHandle<()>) {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, _parser) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host = test_host_shared_with_budget(
        term,
        parser_commands,
        ClipboardReads::new(Arc::new(SystemClock)),
        MAX_HOST_PARSER_QUEUED_BYTES,
    );
    let (server_stream, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(1))).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || {
        let _ =
            serve_client_with_snapshot_timeout(server_host, server_stream, Duration::from_secs(1));
    });
    let hello = snapshot_boundary_client_hello(&host, false).unwrap();
    write_frame(&mut client, &hello).unwrap();
    for label in ["host hello", "snapshot", "colors"] {
        read_required_frame(&mut client, label).unwrap();
    }
    (host, client, server)
}

fn wait_for_class(host: &HostShared, qos: ThreadQos) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while host.thread_qos.get() != qos {
        assert!(Instant::now() < deadline, "the host never took {qos:?}");
        thread::yield_now();
    }
}

#[test]
fn the_host_takes_the_class_for_its_terminal_threads() {
    let (host, mut client, server) = served_host();
    assert_eq!(host.thread_qos.get(), ThreadQos::UserInteractive);
    let set = |qos| Frame::new(MessageKind::SetThreadQos, encode_thread_qos(qos).to_vec());
    write_frame(&mut client, &set(ThreadQos::Utility)).unwrap();
    wait_for_class(&host, ThreadQos::Utility);
    write_frame(&mut client, &set(ThreadQos::UserInteractive)).unwrap();
    wait_for_class(&host, ThreadQos::UserInteractive);

    // An unknown class is a protocol error: the host ends the connection.
    write_frame(&mut client, &Frame::new(MessageKind::SetThreadQos, vec![9])).unwrap();
    server.join().unwrap();
    assert_eq!(host.thread_qos.get(), ThreadQos::UserInteractive);
}

#[test]
fn thread_qos_records_from_before_the_field_still_load() {
    let (record_path, record, lease) = record_fixture("thread-qos-old-record");
    let mut json = serde_json::to_value(&record).unwrap();
    json.as_object_mut().unwrap().remove("supports_thread_qos");
    let old: TerminalHostRecord = serde_json::from_value(json).unwrap();
    assert!(!old.supports_thread_qos);
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
        supports_trace_control: false,
        supports_input_flow: false,
        ..old
    };
    assert!(validate_terminal_host_record(&record_path, &pre_v4).is_ok());
    pre_v4.supports_thread_qos = true;
    assert!(validate_terminal_host_record(&record_path, &pre_v4).is_err());
    drop(lease);
    let _ = fs::remove_dir_all(record_path.parent().unwrap());
}
