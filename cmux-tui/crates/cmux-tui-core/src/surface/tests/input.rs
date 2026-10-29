//! Input delivery tests: receipted writes, partial would-block writes, terminal
//! query answers, and deferred cell-pixel responses.

use super::*;

struct PartialWouldBlockWriter {
    accepted_prefix: bool,
}

impl Write for PartialWouldBlockWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if !self.accepted_prefix && !bytes.is_empty() {
            self.accepted_prefix = true;
            return Ok(1);
        }
        Err(std::io::Error::new(
            std::io::ErrorKind::WouldBlock,
            "synthetic partial local PTY write",
        ))
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

#[cfg(unix)]
#[test]
fn receipted_input_rejects_an_exited_host_before_effect() {
    let mux = Mux::new_for_test("receipted-input-exited-host", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    {
        let mut runtime = pty.runtime.lock().unwrap();
        *runtime = PtyRuntime::ExitedHosted;
    }

    let error = surface.write_bytes_confirmed(b"must-not-drop").unwrap_err();
    let ConfirmedInputFailure::Known(error) = error else {
        panic!("exited-host rejection became indeterminate");
    };
    assert_eq!(error.kind(), std::io::ErrorKind::NotConnected);
    assert!(error.to_string().contains("no live PTY owner"));
}

#[test]
fn receipted_input_local_partial_would_block_is_indeterminate() {
    let mux = Mux::new_for_test("receipted-input-local-partial", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    replace_local_writer(&surface, Box::new(PartialWouldBlockWriter { accepted_prefix: false }));

    let error = surface.write_bytes_confirmed(b"ab").unwrap_err();
    let ConfirmedInputFailure::Indeterminate(error) = error else {
        panic!("partial local PTY write was incorrectly classified as known-not-delivered");
    };
    assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
}

#[test]
fn test_surface_accepts_non_uuid_public_terminal_identity() {
    let mux = Mux::new_for_test("opaque-terminal-id", SurfaceOptions::default());
    let terminal = TerminalPublicId::parse("term_ffffffffffffffffffffffffffffffff").unwrap();
    let tab = crate::resource::TabPublicId::parse("tab_00000000000000000000000000000001").unwrap();
    let identity = TabResourceIdentity::persisted_terminal(tab, terminal);
    let surface = Surface::spawn_for_test_with_resource_identity(
        1,
        SurfaceOptions::default(),
        Arc::downgrade(&mux),
        Some(identity.clone()),
    )
    .unwrap();
    assert_eq!(surface.resource_identity(), Some(&identity));
}

#[cfg(unix)]
#[test]
fn hosted_mirror_never_answers_terminal_queries() {
    let callbacks = hosted_terminal_callbacks(
        &PendingBells::default(),
        Arc::new(AtomicBool::new(false)),
        Default::default(),
    );

    assert!(
        callbacks.on_pty_write.is_none(),
        "only the durable terminal host may answer Kitty/DA/DSR queries"
    );

    // Exercise the exact query that cmux-tui uses for Kitty graphics
    // detection. The mirror still parses it for screen state, but with no
    // PTY callback it cannot inject a duplicate `ESC_Gi=31;OK ESC\\` into
    // the child input after the authoritative host has already replied.
    let mut term = Terminal::new(80, 24, 0, callbacks).unwrap();
    term.vt_write(b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\\x1b[c");
}

#[cfg(unix)]
#[test]
fn deferred_cell_pixel_responses_run_on_the_bounded_mux_pool() {
    let mux = Mux::new_for_test("bounded-deferred-cell-pixel", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let responses = Arc::new(crate::terminal_host_runtime::ControlResponses::new_for_test());
    Surface::install_deferred_cell_pixel_handler(&surface, &responses);
    let (thread_name_tx, thread_name_rx) = std::sync::mpsc::channel();
    surface.as_pty().unwrap().deferred_cell_pixel_ack_test_hook.lock().unwrap().replace(Arc::new(
        move || {
            let name = std::thread::current().name().unwrap_or_default().to_owned();
            let _ = thread_name_tx.send(name);
        },
    ));

    let mut frame = Frame::new(MessageKind::CellPixelSizeAck, vec![8, 0, 16, 0]);
    frame.request_id = 1;
    responses.invoke_deferred_cell_pixel_handler_for_test(
        1,
        (8, 16),
        crate::terminal_host_runtime::DeferredCellPixelResolution::Response(frame),
    );

    let thread_name = thread_name_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(
        thread_name == "mux-deadline",
        "deferred acknowledgement ran on unbounded worker {thread_name:?}"
    );
}

#[cfg(unix)]
#[test]
fn disconnected_deferred_cell_pixel_resolutions_do_not_schedule_work() {
    let mux = Mux::new_for_test("disconnected-deferred-cell-pixel", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let responses = Arc::new(crate::terminal_host_runtime::ControlResponses::new_for_test());
    Surface::install_deferred_cell_pixel_handler(&surface, &responses);
    let (called_tx, called_rx) = std::sync::mpsc::channel();
    surface.as_pty().unwrap().deferred_cell_pixel_ack_test_hook.lock().unwrap().replace(Arc::new(
        move || {
            let _ = called_tx.send(());
        },
    ));

    responses.invoke_deferred_cell_pixel_handler_for_test(
        1,
        (8, 16),
        crate::terminal_host_runtime::DeferredCellPixelResolution::Disconnected,
    );

    assert!(
        called_rx.recv_timeout(Duration::from_millis(100)).is_err(),
        "a disconnect-only resolution spawned reconciliation work"
    );
}

/// `send-key` with a Command chord (`super+c`, `cmd+z`): a Kitty-protocol program gets
/// the CSI-u key, as Ghostty sends it; legacy encoding sends nothing for Command on macOS
/// (the app sends Cmd-C, Cmd-Z, Cmd-Shift-Z and Cmd-A this way when a TUI owns its keys).
#[test]
fn send_key_encodes_command_chords_from_authoritative_keyboard_modes() {
    let mux = Mux::new_for_test("send-key-command-chords", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let encode = |keys: &[&str]| {
        let mut encoder = KeyEncoder::new().unwrap();
        let mut encoded = Vec::new();
        surface.with_terminal(|term| {
            encoder.sync_from_terminal(term);
            for key in keys {
                let input = ghostty_vt::key_input_from_chord(key).expect(key);
                encoder.encode(&input, &mut encoded).unwrap();
            }
        });
        encoded
    };

    #[cfg(target_os = "macos")]
    assert!(
        encode(&["super+c", "cmd+z"]).is_empty(),
        "legacy encoding sent text for a Command chord"
    );
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>5u"));
    assert_eq!(
        encode(&["super+c", "cmd+z", "cmd+shift+z", "command+a"]),
        b"\x1b[99;9u\x1b[122;9u\x1b[122;10u\x1b[97;9u"
    );
}

/// The real master of a local terminal's PTY, written as the terminal's own
/// writer is (a descriptor of the same open master), that says when its first
/// write starts: from then on the write is in progress in the input turn.
#[cfg(unix)]
struct MasterWriteStarted {
    master: std::fs::File,
    started: Option<std::sync::mpsc::Sender<()>>,
}

#[cfg(unix)]
impl Write for MasterWriteStarted {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        if let Some(started) = self.started.take() {
            let _ = started.send(());
        }
        self.master.write(bytes)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.master.flush()
    }
}

/// A local PTY write waits while the child does not read its input; it must
/// not hold the runtime lock while it waits (`LocalWriter`), or a resize, the
/// foreground check behind `shell_idle` and closing the terminal all wait on a
/// child that does not read. The child turns its PTY raw (a full input queue
/// blocks the master write, as a cooked one with no newline would not) and
/// never reads; the input is far larger than any PTY input queue, so the write
/// cannot return while the child lives. Every wait ends on an event; `BOUND`
/// only stops a hang.
#[cfg(unix)]
#[test]
fn local_pty_write_blocked_on_a_child_that_does_not_read_leaves_the_runtime_lock_free() {
    const BOUND: Duration = Duration::from_secs(20);
    let mux = Mux::new_for_test("local-pty-write-blocked", SurfaceOptions::default());
    let surface = Surface::spawn(
        4301,
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                "stty raw -echo && printf LOCAL-WRITER-READY && exec sleep 600".into(),
            ]),
            ..SurfaceOptions::default()
        },
        Arc::downgrade(&mux),
    )
    .unwrap();

    // The PTY is raw once the child printed its marker.
    let deadline = Instant::now() + BOUND;
    loop {
        let text = surface.try_with_terminal(|terminal| terminal.viewport_text()).unwrap().unwrap();
        if text.contains("LOCAL-WRITER-READY") {
            break;
        }
        assert!(Instant::now() < deadline, "the child never turned its PTY raw: {text:?}");
        std::thread::sleep(Duration::from_millis(5));
    }

    let master = {
        let pty = surface.as_pty().unwrap();
        let runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { master: Some(master), holder: None, .. } = &*runtime else {
            panic!("the test needs a local terminal whose PTY the daemon writes itself");
        };
        let fd = master.as_raw_fd().expect("a unix PTY master has a descriptor");
        // SAFETY: the runtime keeps `fd` open while its lock is held here; the
        // borrow ends at the clone, which owns a new descriptor.
        let fd = unsafe { std::os::fd::BorrowedFd::borrow_raw(fd) }.try_clone_to_owned().unwrap();
        std::fs::File::from(fd)
    };
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    replace_local_writer(
        &surface,
        Box::new(MasterWriteStarted { master, started: Some(started_tx) }),
    );

    let (written_tx, written_rx) = std::sync::mpsc::channel();
    std::thread::spawn({
        let surface = surface.clone();
        move || {
            let _ = written_tx.send(surface.write_bytes(&b"x".repeat(1 << 20)));
        }
    });
    started_rx.recv_timeout(BOUND).expect("the PTY write started");

    let (resized_tx, resized_rx) = std::sync::mpsc::channel();
    std::thread::spawn({
        let surface = surface.clone();
        move || {
            let (cols, rows) = surface.size();
            let _ = resized_tx.send(surface.resize(cols + 3, rows + 2).map(|_| ()));
        }
    });
    resized_rx
        .recv_timeout(BOUND)
        .expect("a resize waited on a PTY write the child does not read (the runtime lock)")
        .unwrap();
    let written = written_rx.try_recv();
    assert!(
        matches!(written, Err(TryRecvError::Empty)),
        "the PTY write must still wait for the child when the resize finished: {written:?}"
    );

    let (killed_tx, killed_rx) = std::sync::mpsc::channel();
    std::thread::spawn({
        let surface = surface.clone();
        move || {
            surface.kill();
            let _ = killed_tx.send(());
        }
    });
    killed_rx
        .recv_timeout(BOUND)
        .expect("closing the terminal waited on a PTY write the child does not read");
}
