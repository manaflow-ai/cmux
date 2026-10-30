//! p02-threads task 210: an accepted terminal-host client is served by echo
//! path threads, and its output loop writes its own socket through the
//! checked own-descriptor path.

use super::super::super::shared::host_accept::serve_accepted;
use super::*;
use crate::echo_thread::ECHO_PATH_QOS;

fn declared(name: &str) -> Vec<cmux_threads::ThreadQos> {
    cmux_threads::snapshot()
        .into_iter()
        .filter(|row| row.name == name)
        .map(|row| row.declared)
        .collect()
}

#[test]
fn an_accepted_client_is_served_by_echo_path_threads() {
    let host = exited_host_fixture();
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    serve_accepted(&host, server_stream).unwrap();

    let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
    hello.flags = FLAG_SMART_RENDERER;
    write_frame(&mut client_stream, &hello).unwrap();
    for (label, kind) in [
        ("host hello", MessageKind::HostHello),
        ("snapshot", MessageKind::Snapshot),
        ("colors", MessageKind::Colors),
        ("ready", MessageKind::Ready),
    ] {
        assert_eq!(read_required_frame(&mut client_stream, label).unwrap().kind, kind);
    }
    // Client-input starts right after Ready; both threads serve until Exit.
    for name in ["terminal-host-client", "terminal-host-client-input"] {
        let deadline = Instant::now() + Duration::from_secs(5);
        let rows = loop {
            let rows = declared(name);
            if !rows.is_empty() || Instant::now() >= deadline {
                break rows;
            }
            thread::yield_now();
        };
        assert!(!rows.is_empty(), "{name} is registered while it serves");
        assert!(rows.iter().all(|qos| *qos == ECHO_PATH_QOS), "{name}: {rows:?}");
    }

    let cursor = host.smart.publish(Frame::new(MessageKind::Output, b"echo".to_vec()));
    host.smart.mark_applied(cursor);
    let output = read_required_frame(&mut client_stream, "output").unwrap();
    assert_eq!((output.kind, output.payload.as_slice()), (MessageKind::Output, &b"echo"[..]));
    let echo_thread_file =
        file!().replace("terminal_host_runtime/unix/tests/echo_threads.rs", "echo_thread.rs");
    let sites = cmux_threads::blocking::snapshot();
    assert!(
        sites.sites.iter().all(|site| site.file != echo_thread_file),
        "the output loop writes its own socket without a violation: {sites:?}"
    );

    let cursor = host.smart.publish(Frame::new(MessageKind::Exit, Vec::new()));
    host.smart.mark_applied(cursor);
    assert_eq!(read_required_frame(&mut client_stream, "exit").unwrap().kind, MessageKind::Exit);
    let _ = client_stream.shutdown(std::net::Shutdown::Both);
}

/// The parser (`terminal-host-parser`, an echo thread with blocking
/// disallowed) waits for its next command at the top of its loop. That wait
/// is the thread being idle, not a blocking call: in the detector's panic
/// mode (the Debug default) the parser waited through a checked `recv` and
/// panicked before its first command, so the host never published output.
#[test]
fn the_parser_waits_for_its_next_command_on_an_echo_thread_without_a_violation() {
    let term = Terminal::new(80, 24, 0, Callbacks::default()).unwrap();
    let (parser_commands, receiver) = sync_channel(HOST_PARSER_QUEUE_CAPACITY);
    let host =
        test_host_shared_with(term, parser_commands, ClipboardReads::new(Arc::new(SystemClock)));
    let initial_colors = host.term.lock().unwrap().color_overrides();
    let signals = ParserSignals {
        pending_responses: Arc::new(Mutex::new(Vec::new())),
        title_changed: Arc::new(AtomicBool::new(false)),
        bell: Arc::new(AtomicBool::new(false)),
        program_status: Default::default(),
    };
    let parser = {
        let host = host.clone();
        crate::echo_thread::spawn("terminal-host-parser-idle-test", move || {
            cmux_threads::blocking::with_mode(cmux_threads::BlockingMode::Panic, || {
                run_host_parser(host, receiver, initial_colors, signals);
            });
        })
        .unwrap()
    };
    // The queue is empty: the parser reaches its wait before the command.
    thread::sleep(Duration::from_millis(100));
    let cursor = host.smart.publish(Frame::new(MessageKind::Output, b"idle".to_vec()));
    host.parser_commands
        .send(ParserCommand::Output {
            bytes: b"idle".to_vec(),
            source_cursor: cursor,
            accounted_bytes: 0,
        })
        .unwrap();
    host.parser_commands.send(ParserCommand::Drain).unwrap();
    parser.join().expect("the parser's idle wait is not a violation");
    assert!(host.smart.applied_cursor.load(Ordering::Acquire) >= cursor);
}

/// A client's cell-metric commit waits for the host's parser to apply what
/// was queued before it (metric_commits.rs), and so do its resize, default
/// color, Kitty-limit and clear-history commits. They ran on
/// terminal-host-client-input, an echo thread with blocking disallowed: in
/// the detector's panic mode (the Debug default) the thread panicked at the
/// wait, the client got no acknowledgement and its connection stayed open,
/// so the daemon waited for the reply forever.
#[test]
fn a_client_commit_that_waits_for_the_parser_is_acknowledged_in_panic_mode() {
    cmux_threads::blocking::set_mode(cmux_threads::BlockingMode::Panic);
    let (host, parser_commands) = exited_host_fixture_with_parser();
    let initial_colors = host.term.lock().unwrap().color_overrides();
    let parser = {
        let host = host.clone();
        thread::spawn(move || {
            run_host_parser(host, parser_commands, initial_colors, ParserSignals::new());
        })
    };
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    serve_accepted(&host, server_stream).unwrap();
    let hello = snapshot_boundary_client_hello(&host, false).unwrap();
    write_frame(&mut client_stream, &hello).unwrap();
    for label in ["host hello", "snapshot", "colors"] {
        read_required_frame(&mut client_stream, label).unwrap();
    }
    let mut metrics = Frame::new(MessageKind::SetCellPixelSize, Vec::new());
    metrics.payload.extend_from_slice(&9u16.to_le_bytes());
    metrics.payload.extend_from_slice(&18u16.to_le_bytes());
    metrics.request_id = 7;
    write_frame(&mut client_stream, &metrics).unwrap();
    let ack = loop {
        let frame = read_required_frame(&mut client_stream, "the cell-metric acknowledgement")
            .expect("the host acknowledges the commit before the read timeout");
        if frame.kind == MessageKind::CellPixelSizeAck {
            break frame;
        }
    };
    assert_eq!(ack.request_id, 7);
    let _ = client_stream.shutdown(std::net::Shutdown::Both);
    host.parser_commands.send(ParserCommand::Drain).unwrap();
    parser.join().unwrap();
}
