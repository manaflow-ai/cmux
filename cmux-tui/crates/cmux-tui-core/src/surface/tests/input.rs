//! Input delivery tests: receipted writes, partial would-block writes, terminal
//! query answers, deferred cell-pixel responses, and a hosted terminal with no
//! input route.

#[cfg(unix)]
use super::hosted::{frames_until_quiet, hosted_typing_surface};
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
        thread_name.starts_with("mux-deadline-"),
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

/// A hosted terminal publishes its input route when its runtime is made and at every runtime swap
/// (`PtyTerminalRuntime::replace_runtime`), so its keys and pastes go through its input port. A hosted terminal
/// with no route breaks that rule: its input must fail with a typed error (`cmux send` exits non-zero, the
/// creating-input flush gives the bytes back), never go to the host connection around the port (with no reconnect
/// wait and out of order with the port's frames), and never panic (plans/cmux-next/rust-panic-free.md rule 1).
#[cfg(unix)]
#[test]
fn input_to_a_hosted_terminal_with_no_input_route_fails_and_does_not_panic() {
    let (mux, surface, mut host) = hosted_typing_surface("hosted-input-no-route");
    let pty = surface.as_pty().expect("a terminal");
    pty.input_route.store(None);
    let key = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| surface.write_bytes(b"k")));
    let paste =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| surface.write_paste(b"p")));
    let written: Vec<MessageKind> = frames_until_quiet(&mut host, Duration::from_millis(300))
        .into_iter()
        .map(|frame| frame.kind)
        .filter(|kind| matches!(kind, MessageKind::Input | MessageKind::Paste))
        .collect();
    let outcome = |what: &str, result: std::thread::Result<std::io::Result<()>>| match result {
        Ok(Err(error)) if error.kind() == std::io::ErrorKind::NotConnected => None,
        Ok(Err(error)) => {
            Some(format!("the {what} failed with another error: {error} ({:?})", error.kind()))
        }
        Ok(Ok(())) => Some(format!("the {what} was answered ok")),
        Err(_) => Some(format!("the {what} panicked")),
    };
    let paste_panicked = paste.is_err();
    let mut wrong: Vec<String> =
        [outcome("key", key), outcome("paste", paste)].into_iter().flatten().collect();
    if !written.is_empty() {
        wrong.push(format!("input reached the host around the input port: {written:?}"));
    }
    if paste_panicked {
        // The panic poisoned the terminal's runtime lock, so the surface's teardown would panic a second time.
        std::mem::forget(surface);
        std::mem::forget(mux);
    }
    assert!(
        wrong.is_empty(),
        "input to a hosted terminal with no input route: {}",
        wrong.join("; ")
    );
}
