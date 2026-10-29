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
                run_host_parser(host, receiver, initial_colors, signals)
            })
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
            run_host_parser(host, parser_commands, initial_colors, ParserSignals::new())
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

/// A client's control sequence (where its frames run: every one waits
/// behind the frames read before it) is owned by the client's serve loop
/// and joined before that loop returns, so no thread of a client outlives
/// it. The control thread was started on the client's first frame that
/// waited for the parser and detached ("nothing joins it"): when the
/// host's terminal exited, `serve_client` returned while that thread still
/// waited for the client's next frame.
#[test]
fn blocking_cascade_a_clients_control_sequence_ends_before_its_serve_loop_returns() {
    const CONTROL: &str = "terminal-host-client-control";
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
    let server = {
        let host = host.clone();
        thread::spawn(move || serve_client(host, server_stream))
    };
    let mut hello = snapshot_boundary_client_hello(&host, false).unwrap();
    hello.flags = FLAG_SMART_RENDERER;
    write_frame(&mut client_stream, &hello).unwrap();
    for label in ["host hello", "snapshot", "colors", "ready"] {
        read_required_frame(&mut client_stream, label).unwrap();
    }
    let mut metrics = Frame::new(MessageKind::SetCellPixelSize, Vec::new());
    metrics.payload.extend_from_slice(&9u16.to_le_bytes());
    metrics.payload.extend_from_slice(&18u16.to_le_bytes());
    metrics.request_id = 7;
    write_frame(&mut client_stream, &metrics).unwrap();
    while read_required_frame(&mut client_stream, "the cell-metric acknowledgement").unwrap().kind
        != MessageKind::CellPixelSizeAck
    {}
    let cursor = host.smart.publish(Frame::new(MessageKind::Exit, Vec::new()));
    host.smart.mark_applied(cursor);
    while read_required_frame(&mut client_stream, "exit").unwrap().kind != MessageKind::Exit {}
    // The client is still connected: a loop that owns its control sequence
    // has not returned. A bounded look, so the test does not hang on one.
    let deadline = Instant::now() + Duration::from_millis(500);
    while !server.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    let returned = server.is_finished();
    let control_rows = declared(CONTROL).len();
    let _ = client_stream.shutdown(std::net::Shutdown::Both);
    server.join().unwrap().unwrap();
    assert!(
        !returned || control_rows == 0,
        "serve_client returned while {control_rows} control thread(s) of its client still ran"
    );
    assert!(declared(CONTROL).is_empty(), "the client's control thread ends with its serve loop");
    host.parser_commands.send(ParserCommand::Drain).unwrap();
    parser.join().unwrap();
}

/// A PTY master whose program never reads its input: its descriptor is one
/// end of a socket pair whose other end nobody reads, so a write blocks once
/// the socket buffer is full, as a PTY's does once its input queue is.
struct UnreadMaster {
    stream: UnixStream,
    size: Mutex<PtySize>,
}

impl MasterPty for UnreadMaster {
    fn resize(&self, size: PtySize) -> anyhow::Result<()> {
        *self.size.lock().unwrap() = size;
        Ok(())
    }

    fn get_size(&self) -> anyhow::Result<PtySize> {
        Ok(*self.size.lock().unwrap())
    }

    fn try_clone_reader(&self) -> anyhow::Result<Box<dyn Read + Send>> {
        Ok(Box::new(std::io::empty()))
    }

    fn take_writer(&self) -> anyhow::Result<Box<dyn Write + Send>> {
        Ok(Box::new(self.stream.try_clone()?))
    }

    fn process_group_leader(&self) -> Option<libc::pid_t> {
        None
    }

    fn as_raw_fd(&self) -> Option<RawFd> {
        Some(AsRawFd::as_raw_fd(&self.stream))
    }

    fn tty_name(&self) -> Option<PathBuf> {
        None
    }
}

/// A client's input write to a program that never reads its input blocks,
/// and then the client disconnects. The client's end must end that write
/// (its owner cancels it, no timer), so its serve loop returns and no
/// thread of the client is left. On the base the frame ran on
/// client-input, which stayed blocked in the write forever with no one to
/// end it; with the control thread joined, the serve loop never returned.
#[test]
fn blocking_cascade_a_disconnect_ends_a_blocked_input_write_and_the_serve_loop() {
    let host = exited_host_fixture();
    let (pty, _never_read) = UnixStream::pair().unwrap();
    let master =
        UnreadMaster { stream: pty, size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS)) };
    *host.writer.lock().unwrap() = master.take_writer().unwrap();
    *host.master.lock().unwrap() = Box::new(master);
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let server = {
        let host = host.clone();
        thread::spawn(move || serve_client(host, server_stream))
    };
    let hello = snapshot_boundary_client_hello(&host, false).unwrap();
    write_frame(&mut client_stream, &hello).unwrap();
    for label in ["host hello", "snapshot", "colors"] {
        read_required_frame(&mut client_stream, label).unwrap();
    }
    // Far more than any socket buffer: the write blocks part way.
    write_frame(&mut client_stream, &Frame::new(MessageKind::Input, vec![b'x'; 8 << 20])).unwrap();
    // The write is under way once the host's writer is held for it.
    let deadline = Instant::now() + Duration::from_secs(10);
    while host.writer.try_lock().is_ok() {
        assert!(Instant::now() < deadline, "the input write never started");
        thread::sleep(Duration::from_millis(5));
    }
    let _ = client_stream.shutdown(std::net::Shutdown::Both);
    drop(client_stream);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !server.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    let returned = server.is_finished();
    let left = ["terminal-host-client-input", "terminal-host-client-control"]
        .into_iter()
        .filter(|name| !declared(name).is_empty())
        .collect::<Vec<_>>();
    assert!(returned, "the serve loop did not return after its client disconnected");
    assert!(left.is_empty(), "threads of the disconnected client are left: {left:?}");
    let _ = server.join();
}

/// Two clients of one host whose program never reads its input: client A's
/// input write blocks while it holds the host's PTY writer, and client B's
/// input waits behind it. B then disconnects. B's end must end B's wait for
/// the writer too, not only a write B already started, so B's serve loop
/// returns while A's write is still blocked.
#[test]
fn blocking_cascade_a_disconnect_ends_a_wait_for_another_clients_blocked_write() {
    let host = exited_host_fixture();
    let (pty, _never_read) = UnixStream::pair().unwrap();
    let master =
        UnreadMaster { stream: pty, size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS)) };
    *host.writer.lock().unwrap() = master.take_writer().unwrap();
    *host.master.lock().unwrap() = Box::new(master);
    let connect = |host: &Arc<HostShared>| {
        let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
        client_stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let server = {
            let host = host.clone();
            thread::spawn(move || serve_client(host, server_stream))
        };
        let hello = snapshot_boundary_client_hello(host, false).unwrap();
        write_frame(&mut client_stream, &hello).unwrap();
        for label in ["host hello", "snapshot", "colors"] {
            read_required_frame(&mut client_stream, label).unwrap();
        }
        (server, client_stream)
    };
    let (server_a, mut client_a) = connect(&host);
    let (server_b, mut client_b) = connect(&host);
    write_frame(&mut client_a, &Frame::new(MessageKind::Input, vec![b'a'; 8 << 20])).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while host.writer.try_lock().is_ok() {
        assert!(Instant::now() < deadline, "client A's input write never started");
        thread::sleep(Duration::from_millis(5));
    }
    write_frame(&mut client_b, &Frame::new(MessageKind::Input, b"b".to_vec())).unwrap();
    // B's frame reaches its control thread, which waits behind A's write.
    thread::sleep(Duration::from_millis(200));
    let _ = client_b.shutdown(std::net::Shutdown::Both);
    drop(client_b);
    let deadline = Instant::now() + Duration::from_secs(5);
    while !server_b.is_finished() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    let b_returned = server_b.is_finished();
    let a_still_writing = host.writer.try_lock().is_err();
    let _ = client_a.shutdown(std::net::Shutdown::Both);
    drop(client_a);
    let _ = server_a.join();
    let _ = server_b.join();
    assert!(a_still_writing, "client A's write ended before B's check: the test proves nothing");
    assert!(b_returned, "client B's serve loop did not return while it waited for A's write");
}

/// A client that sends its input and then closes its sending side
/// (half-close) still gets that input written when the program has room:
/// the client's end of input ends only a write that would wait (for the
/// program, or behind another writer), never one that can be made at once.
/// The Input frame here waits behind a cell-metric commit until the
/// client's end of input has been read, then finds the writer free.
#[test]
fn blocking_cascade_input_queued_before_a_half_close_is_written() {
    let (host, parser_commands) = exited_host_fixture_with_parser();
    let (pty, program) = UnixStream::pair().unwrap();
    program.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let master =
        UnreadMaster { stream: pty, size: Mutex::new(pty_size(80, 24, DEFAULT_CELL_PIXELS)) };
    *host.writer.lock().unwrap() = master.take_writer().unwrap();
    *host.master.lock().unwrap() = Box::new(master);
    let (server_stream, mut client_stream) = UnixStream::pair().unwrap();
    client_stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let server = {
        let host = host.clone();
        thread::spawn(move || serve_client(host, server_stream))
    };
    let hello = snapshot_boundary_client_hello(&host, false).unwrap();
    write_frame(&mut client_stream, &hello).unwrap();
    for label in ["host hello", "snapshot", "colors"] {
        read_required_frame(&mut client_stream, label).unwrap();
    }
    // The commit waits for the parser, which is not running yet, so the
    // Input queues behind it on the client's control thread.
    let mut metrics = Frame::new(MessageKind::SetCellPixelSize, Vec::new());
    metrics.payload.extend_from_slice(&9u16.to_le_bytes());
    metrics.payload.extend_from_slice(&18u16.to_le_bytes());
    metrics.request_id = 7;
    write_frame(&mut client_stream, &metrics).unwrap();
    write_frame(&mut client_stream, &Frame::new(MessageKind::Input, b"typed".to_vec())).unwrap();
    client_stream.shutdown(std::net::Shutdown::Write).unwrap();
    // client-input reads the end of input, then the parser runs the commit.
    thread::sleep(Duration::from_millis(200));
    let initial_colors = host.term.lock().unwrap().color_overrides();
    let parser = {
        let host = host.clone();
        thread::spawn(move || {
            run_host_parser(host, parser_commands, initial_colors, ParserSignals::new());
        })
    };
    let mut typed = [0u8; 5];
    let read = (&program).read_exact(&mut typed);
    let _ = client_stream.shutdown(std::net::Shutdown::Both);
    drop(client_stream);
    let _ = server.join();
    host.parser_commands.send(ParserCommand::Drain).unwrap();
    parser.join().unwrap();
    assert!(read.is_ok(), "the input queued before the half-close never reached the program");
    assert_eq!(&typed, b"typed");
}
