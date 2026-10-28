//! `SetThreadQos`: the owner sends it only to a host that
//! advertises it, the host stores the class for its PTY reader and parser,
//! which run at it after their next byte, a malformed one ends the
//! connection, and records from before the field still load.

use cmux_threads::{QosChange, ThreadInfo, ThreadQos};

use super::super::super::shared::thread_qos::encode_thread_qos;
use super::host_fixture::test_host_shared_with_budget;
use super::*;
use crate::panic_free::RecoverPoison;

fn find_row(name: &str) -> Option<ThreadInfo> {
    cmux_threads::snapshot().into_iter().find(|row| row.name == name)
}

/// Waits until `name` is registered and its spawn applied or refused its
/// class: the start state, whatever nice the runner starts at.
fn wait_started(name: &str) -> ThreadInfo {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Some(row) = find_row(name)
            && (row.effective.is_some() || row.refused_changes > 0)
        {
            return row;
        }
        assert!(Instant::now() < deadline, "{name} never started: {:?}", find_row(name));
        thread::sleep(Duration::from_millis(5));
    }
}

/// Waits until `name` acted on a request for `qos` after `before`: it runs
/// at it, or refused it once more (an unprivileged Linux thread that could
/// never come back from a raised nice).
fn wait_acted(name: &str, qos: ThreadQos, before: &ThreadInfo) -> ThreadInfo {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let row = find_row(name).unwrap_or_else(|| panic!("{name} ended"));
        if row.effective == Some(qos) || row.refused_changes > before.refused_changes {
            return row;
        }
        assert!(Instant::now() < deadline, "{name} never acted on {qos:?}: {row:?}");
        thread::sleep(Duration::from_millis(5));
    }
}

/// A real host in this process: its PTY runs `cat`, and its
/// `terminal-host-pty` and `terminal-host-parser` threads run as in the
/// `__terminal-host` process.
fn real_host(name: &str) -> (Arc<HostShared>, PathBuf) {
    let dir = std::env::temp_dir().join(format!(
        "cmux-host-thread-qos-{name}-{}-{}",
        std::process::id(),
        RECORD_TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ));
    prepare_private_dir(&dir).unwrap();
    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id: TerminalId::random().unwrap(),
        owner_token: CapabilityToken::random().unwrap(),
    };
    let mut request = Vec::new();
    write_frame(&mut request, &bootstrap.into_frame(1)).unwrap();
    let bootstrapped = crate::terminal_host::bootstrap_stdio_once(
        &mut std::io::Cursor::new(request),
        &mut Vec::new(),
    )
    .unwrap();
    let launch = HostLaunch {
        endpoint: dir.join("host.sock").to_string_lossy().into_owned(),
        record_path: dir.join("host.json").to_string_lossy().into_owned(),
        term: "xterm-256color".into(),
        cols: 80,
        rows: 24,
        cell_pixels: DEFAULT_CELL_PIXELS,
        scrollback: 1024,
        cwd: None,
        command: vec!["cat".into()],
        extra_env: Vec::new(),
        default_colors: DefaultColors::default(),
        kitty_graphics_limits: KittyGraphicsLimits::default(),
        seed: Vec::new(),
        workspace_key: String::new(),
    };
    let host = spawn_host_runtime(&launch, &bootstrapped).unwrap();
    // The launch owner's stream is up: the PTY reader starts reading.
    host.mark_launch_owner_stream_ready();
    (host, dir)
}

/// The owner's connection to `host`, served on one end of a socket pair.
fn owner_connection(host: &Arc<HostShared>) -> (UnixStream, thread::JoinHandle<()>) {
    let (server_stream, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let server_host = host.clone();
    let server = thread::spawn(move || {
        let _ =
            serve_client_with_snapshot_timeout(server_host, server_stream, Duration::from_secs(5));
    });
    let hello = snapshot_boundary_client_hello(host, false).unwrap();
    write_frame(&mut client, &hello).unwrap();
    for label in ["host hello", "snapshot", "colors"] {
        read_required_frame(&mut client, label).unwrap();
    }
    (client, server)
}

/// The acceptance of p02-threads task 236 on the hosted runtime: the daemon
/// hides the terminal (`SetThreadQos` utility), one byte through the PTY,
/// and the host's PTY reader and parser run at utility; shown again and one
/// more byte, they run at the echo class again. Relative to the runner's
/// start state, so it holds under `nice -n 10` too.
#[test]
fn a_hidden_hosts_pty_reader_and_parser_apply_utility_after_one_byte() {
    // The host's threads wait on their queue and PTY (known sites, as in
    // the `__terminal-host` process): record them, as the local reader's
    // test does.
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Record);
    let (host, dir) = real_host("follow");
    let names = ["terminal-host-pty", "terminal-host-parser"];
    let start = names.map(wait_started);
    let (mut owner, server) = owner_connection(&host);
    let set = |qos| Frame::new(MessageKind::SetThreadQos, encode_thread_qos(qos).to_vec());
    let demoted = if cmux_threads::reversible(ThreadQos::Utility) {
        QosChange::Applied
    } else {
        QosChange::Refused
    };

    write_frame(&mut owner, &set(ThreadQos::Utility)).unwrap();
    wait_for_class(&host, ThreadQos::Utility);
    // The PTY echoes the byte: the reader wakes, and its output wakes the parser.
    host.writer.lock().recover_poison().write_all(b"a").unwrap();
    let hidden = [0, 1].map(|index| {
        let row = wait_acted(names[index], ThreadQos::Utility, &start[index]);
        assert_eq!(row.desired, ThreadQos::Utility, "{row:?}");
        if demoted == QosChange::Applied {
            assert_eq!(row.effective, Some(ThreadQos::Utility), "{row:?}");
            #[cfg(target_vendor = "apple")]
            assert_eq!(row.live, cmux_threads::LiveQos::Class(ThreadQos::Utility), "{row:?}");
        } else {
            assert_eq!(row.refused_changes, start[index].refused_changes + 1, "{row:?}");
        }
        row
    });

    write_frame(&mut owner, &set(ThreadQos::UserInteractive)).unwrap();
    wait_for_class(&host, ThreadQos::UserInteractive);
    host.writer.lock().recover_poison().write_all(b"b").unwrap();
    if demoted == QosChange::Applied {
        for (name, before) in names.iter().zip(&hidden) {
            let row = wait_acted(name, ThreadQos::UserInteractive, before);
            assert_eq!(row.effective, Some(ThreadQos::UserInteractive), "{row:?}");
            #[cfg(target_vendor = "apple")]
            assert_eq!(
                row.live,
                cmux_threads::LiveQos::Class(ThreadQos::UserInteractive),
                "{row:?}"
            );
        }
    }

    let _ = host.killer.lock().recover_poison().kill();
    let _ = owner.shutdown(std::net::Shutdown::Both);
    let _ = server.join();
    let _ = fs::remove_dir_all(dir);
}

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
