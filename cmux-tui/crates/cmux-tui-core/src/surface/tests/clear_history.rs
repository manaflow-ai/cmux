//! Clear-history tests: emulator-side erase, partial VT sequences, key
//! fallback encoding, write deadlines and lock ordering.

use super::*;

#[test]
fn clear_history_updates_the_authoritative_terminal_and_attach_mirrors() {
    let mux = Mux::new_for_test("clear-history", SurfaceOptions::default());
    let events = mux.subscribe();
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.with_terminal(|term| {
        term.vt_write(b"\x1b]133;C\x07");
        for line in 0..40 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"visible");
    });
    let attach = surface.attach_stream().unwrap();
    let mut mirror = Terminal::new(attach.cols, attach.rows, 10_000, Callbacks::default()).unwrap();
    mirror.vt_write(&attach.replay);
    while events.try_recv().is_ok() {}

    surface.clear_history().unwrap();

    let AttachFrame::Output(bytes) = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap()
    else {
        panic!("clear did not reach the attach mirror");
    };
    mirror.vt_write(&bytes);
    let authoritative_after = surface
        .with_terminal(|term| {
            assert_eq!(term.history_rows(), 0);
            term.viewport_text().unwrap()
        })
        .unwrap();
    assert!(
        !authoritative_after.contains("history-"),
        "completed visible rows survived clear-history: {authoritative_after:?}"
    );
    assert!(
        authoritative_after.ends_with("visible"),
        "active row did not survive clear-history: {authoritative_after:?}"
    );
    assert_eq!(mirror.history_rows(), 0);
    assert_eq!(mirror.viewport_text().unwrap(), authoritative_after);
    assert!(events.try_iter().any(|event| matches!(event, MuxEvent::SurfaceOutput(1))));
}

#[test]
fn clear_history_waits_for_a_partial_vt_sequence_to_finish() {
    let mux = Mux::new_for_test("clear-history-partial-vt", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.with_terminal(|term| {
        for line in 0..40 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> ");
        term.vt_write(b"\x1b[31");
    });
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    let clear_surface = surface.clone();
    std::thread::spawn(move || {
        let _ = finished_tx.send(clear_surface.clear_history());
    });

    assert!(
        finished_rx.recv_timeout(Duration::from_millis(25)).is_err(),
        "clear-history acknowledged before the partial CSI reached a safe boundary"
    );
    surface.apply_stream_output_for_test(b"m").unwrap();
    finished_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("clear-history did not resume after the CSI completed")
        .unwrap();

    surface.with_terminal(|term| {
        assert_eq!(term.history_rows(), 0);
        let viewport = term.viewport_text().unwrap();
        assert!(viewport.contains("prompt>"));
        assert!(!viewport.contains("history-"));
    });
}

#[test]
fn clear_history_reports_a_partial_vt_sequence_that_does_not_finish() {
    let mux = Mux::new_for_test("clear-history-stalled-vt", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.with_terminal(|term| {
        term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
    });

    let error = surface.clear_history().unwrap_err();

    assert_eq!(error.to_string(), CLEAR_HISTORY_STREAM_TIMEOUT_ERROR);
}

#[test]
fn clear_history_reuses_timeout_until_stream_progress() {
    let mux = Mux::new_for_test("clear-history-shared-timeout", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.with_terminal(|term| {
        term.vt_write(b"history\r\n\x1b]133;A\x07prompt> \x1b[31");
    });

    let first_error = surface.clear_history().unwrap_err();
    assert_eq!(first_error.to_string(), CLEAR_HISTORY_STREAM_TIMEOUT_ERROR);

    let second_started = Instant::now();
    let second_error = surface.clear_history().unwrap_err();
    assert_eq!(second_error.to_string(), CLEAR_HISTORY_STREAM_TIMEOUT_ERROR);
    assert!(
        second_started.elapsed() < Duration::from_millis(100),
        "a repeated clear restarted the full stream wait"
    );

    surface.apply_stream_output_for_test(b"m\x1b[31").unwrap();
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    let clear_surface = surface.clone();
    std::thread::spawn(move || {
        let _ = finished_tx.send(clear_surface.clear_history());
    });
    assert!(
        finished_rx.recv_timeout(Duration::from_millis(25)).is_err(),
        "new stream progress did not restore the bounded clear wait"
    );
    surface.apply_stream_output_for_test(b"m").unwrap();
    finished_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
}

#[test]
fn clear_history_encodes_fallback_from_authoritative_keyboard_modes() {
    let mux = Mux::new_for_test("clear-history-key-mode", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));
    let input = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_K,
        mods: ghostty_vt::Mods::SUPER,
        unshifted_codepoint: 'k' as u32,
        action: Some(ghostty_vt::KeyAction::Press),
        ..Default::default()
    };

    surface.clear_history_or_encode_key(Some(&input)).unwrap();

    assert_eq!(&*writer.0.lock().unwrap(), b"\x1b[107;9u");
}

#[test]
fn clear_history_fallback_accepts_maximum_protocol_text_in_associated_text_mode() {
    let mux = Mux::new_for_test("clear-history-associated-text-limit", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>29u"));
    let input = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_K,
        utf8: "x".repeat(4 * 1024),
        unshifted_codepoint: 'k' as u32,
        action: Some(ghostty_vt::KeyAction::Press),
        ..Default::default()
    };

    surface.clear_history_or_encode_key(Some(&input)).unwrap();

    assert!(
        writer.0.lock().unwrap().len() > 8 * 1024,
        "associated text did not exercise the encoded fallback bound"
    );
}

#[test]
fn clear_history_reports_unencodable_alternate_screen_fallback() {
    let mux = Mux::new_for_test("clear-history-unencodable-key", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h"));
    let input = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_K,
        mods: ghostty_vt::Mods::SUPER,
        unshifted_codepoint: 'k' as u32,
        action: Some(ghostty_vt::KeyAction::Press),
        ..Default::default()
    };

    assert!(surface.clear_history_or_encode_key(Some(&input)).is_err());
    assert!(writer.0.lock().unwrap().is_empty());
}

#[test]
fn clear_history_enter_fallback_does_not_relock_the_terminal() {
    let mux = Mux::new_for_test("clear-history-enter-lock", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));
    let input = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_ENTER,
        mods: ghostty_vt::Mods::SUPER,
        action: Some(ghostty_vt::KeyAction::Press),
        ..Default::default()
    };
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();

    std::thread::spawn(move || {
        let _ = finished_tx.send(surface.clear_history_or_encode_key(Some(&input)));
    });
    finished_rx
        .recv_timeout(Duration::from_millis(250))
        .expect("alternate-screen Enter fallback deadlocked")
        .unwrap();

    assert_eq!(&*writer.0.lock().unwrap(), b"\x1b[13;9u");
}

#[test]
fn clear_history_fallback_releases_terminal_before_pty_write() {
    let mux = Mux::new_for_test("clear-history-write-lock", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let written = Arc::new(Mutex::new(Vec::new()));
    replace_local_writer(
        &surface,
        Box::new(TerminalProbeDuringWrite {
            written: written.clone(),
            surface: Arc::downgrade(&surface),
        }),
    );
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));
    let input = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_K,
        mods: ghostty_vt::Mods::SUPER,
        unshifted_codepoint: 'k' as u32,
        action: Some(ghostty_vt::KeyAction::Press),
        ..Default::default()
    };
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();

    std::thread::spawn(move || {
        let _ = finished_tx.send(surface.clear_history_or_encode_key(Some(&input)));
    });
    finished_rx
        .recv_timeout(Duration::from_millis(250))
        .expect("alternate-screen fallback blocked terminal updates during the PTY write")
        .unwrap();

    assert_eq!(&*written.lock().unwrap(), b"\x1b[107;9u");
}

#[cfg(unix)]
#[test]
fn clear_history_fallback_write_has_a_deadline_when_pty_input_is_full() {
    use std::os::fd::{AsRawFd, FromRawFd};

    let mux = Mux::new_for_test("clear-history-full-input", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    surface.with_terminal(|term| term.vt_write(b"\x1b[?1049h\x1b[>1u"));

    let mut pipe_fds = [0; 2];
    assert_eq!(unsafe { libc::pipe(pipe_fds.as_mut_ptr()) }, 0);
    let read_end = unsafe { std::fs::File::from_raw_fd(pipe_fds[0]) };
    let write_end = unsafe { std::fs::File::from_raw_fd(pipe_fds[1]) };
    let master_fd = unsafe { libc::dup(write_end.as_raw_fd()) };
    assert!(master_fd >= 0);
    let master_file = unsafe { std::fs::File::from_raw_fd(master_fd) };

    let write_fd = write_end.as_raw_fd();
    let original_flags = unsafe { libc::fcntl(write_fd, libc::F_GETFL) };
    assert!(original_flags >= 0);
    assert_eq!(
        unsafe { libc::fcntl(write_fd, libc::F_SETFL, original_flags | libc::O_NONBLOCK) },
        0
    );
    let fill = [b'x'; 4096];
    loop {
        let written = unsafe { libc::write(write_fd, fill.as_ptr().cast(), fill.len()) };
        if written > 0 {
            continue;
        }
        let error = std::io::Error::last_os_error();
        assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock);
        break;
    }
    assert_eq!(unsafe { libc::fcntl(write_fd, libc::F_SETFL, original_flags) }, 0);

    {
        let pty = surface.as_pty().unwrap();
        let mut runtime = pty.runtime.lock().unwrap();
        let PtyRuntime::Local { writer, master, .. } = &mut *runtime else {
            panic!("test surface unexpectedly uses a terminal host");
        };
        *writer = Box::new(write_end);
        *master = Some(Box::new(FdMasterPty {
            file: master_file,
            size: Mutex::new(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 }),
        }));
    }

    let input = KeyInput {
        key: ghostty_vt::sys::GHOSTTY_KEY_K,
        mods: ghostty_vt::Mods::SUPER,
        unshifted_codepoint: 'k' as u32,
        action: Some(ghostty_vt::KeyAction::Press),
        ..Default::default()
    };
    let clear_surface = surface;
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let _ =
            finished_tx.send(clear_surface.clear_history_or_encode_key_classified(Some(&input)));
    });

    let timely = finished_rx.recv_timeout(Duration::from_millis(600));
    let completed_before_drain = timely.is_ok();
    if !completed_before_drain {
        let mut drain = [0; 4096];
        assert!(
            unsafe { libc::read(read_end.as_raw_fd(), drain.as_mut_ptr().cast(), drain.len()) } > 0
        );
    }
    let result = timely.or_else(|_| finished_rx.recv_timeout(Duration::from_secs(1))).unwrap();

    assert!(completed_before_drain, "fallback write exceeded its deadline");
    assert!(result.is_err(), "a full PTY input queue unexpectedly accepted the fallback key");
    assert_eq!(result.as_ref().unwrap_err().delivery(), ClearHistoryDelivery::KnownNotDelivered);
    assert!(
        result.as_ref().is_err_and(|failure| failure.error().to_string().contains("timeout")),
        "fallback write did not return a stable timeout failure"
    );
}

#[test]
fn clear_history_does_not_hold_runtime_while_waiting_for_terminal() {
    let mux = Mux::new_for_test("clear-history-lock-order", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let terminal = pty.term.lock().unwrap();
    let runtime = pty.runtime.lock().unwrap();
    let (started_tx, started_rx) = std::sync::mpsc::channel();
    let (finished_tx, finished_rx) = std::sync::mpsc::channel();
    let clear_surface = surface.clone();
    std::thread::spawn(move || {
        started_tx.send(()).unwrap();
        let _ = finished_tx.send(clear_surface.clear_history());
    });
    started_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    drop(runtime);
    std::thread::sleep(Duration::from_millis(25));
    assert!(
        pty.runtime.try_lock().is_ok(),
        "clear-history held runtime while blocked on terminal, inverting resize lock order"
    );
    drop(terminal);
    finished_rx.recv_timeout(Duration::from_secs(1)).unwrap().unwrap();
}

#[test]
fn clear_history_fallback_capability_read_never_waits_for_runtime_writer() {
    let mux = Mux::new_for_test("clear-history-capability-lock", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let (locked_tx, locked_rx) = std::sync::mpsc::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    let locked_surface = surface.clone();
    let lock_holder = std::thread::spawn(move || {
        let pty = locked_surface.as_pty().unwrap();
        let _runtime = pty.runtime.lock().unwrap();
        locked_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    locked_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let (result_tx, result_rx) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        result_tx.send(surface.supports_clear_history_key_fallback()).unwrap();
    });
    let result = result_rx.recv_timeout(Duration::from_millis(100));
    release_tx.send(()).unwrap();
    lock_holder.join().unwrap();
    reader.join().unwrap();

    assert!(
        matches!(result, Ok(false)),
        "capability read waited for the PTY writer runtime: {result:?}"
    );
}

#[test]
fn clear_history_preserves_prompt_without_writing_to_the_child() {
    let mux = Mux::new_for_test("clear-prompt-history", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| {
        for line in 0..40 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> ");
        assert!(term.history_rows() > 0);
    });
    let attach = surface.attach_stream().unwrap();
    let mut mirror = Terminal::new(attach.cols, attach.rows, 10_000, Callbacks::default()).unwrap();
    mirror.vt_write(&attach.replay);

    surface.clear_history().unwrap();

    let AttachFrame::Output(clear) = attach.stream.recv_timeout(Duration::from_secs(1)).unwrap()
    else {
        panic!("clear did not reach the attach mirror");
    };
    mirror.vt_write(&clear);
    surface.with_terminal(|term| {
        assert_eq!(term.history_rows(), 0);
        let viewport = term.viewport_text().unwrap();
        assert!(viewport.contains("prompt>"));
        assert!(!viewport.contains("history-"));
        assert_eq!(mirror.viewport_text().unwrap(), viewport);
        assert_eq!(mirror.cursor_position(), term.cursor_position());
    });
    assert_eq!(mirror.history_rows(), 0);
    assert!(writer.0.lock().unwrap().is_empty());
}

#[test]
fn terminal_query_response_does_not_change_clear_history_safety() {
    let mux = Mux::new_for_test("clear-after-query-response", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| {
        for line in 0..40 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> ");
    });

    surface.write_bytes(b"\x1b[?1;2c").unwrap();
    surface.clear_history().unwrap();

    surface.with_terminal(|term| {
        let viewport = term.viewport_text().unwrap();
        assert_eq!(term.history_rows(), 0);
        assert!(viewport.contains("prompt>"));
        assert!(!viewport.contains("history-"));
    });
    assert_eq!(&*writer.0.lock().unwrap(), b"\x1b[?1;2c");
}

#[test]
fn clear_history_with_output_metadata_preserves_current_row_without_child_input() {
    let mux = Mux::new_for_test("clear-non-prompt-history", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| {
        term.vt_write(b"\x1b]133;C\x07");
        for line in 0..40 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"foreground-input");
        assert!(term.history_rows() > 0);
    });

    surface.clear_history().unwrap();

    surface.with_terminal(|term| {
        assert_eq!(term.history_rows(), 0);
        let viewport = term.viewport_text().unwrap();
        assert!(viewport.contains("foreground-input"));
        assert!(!viewport.contains("history-"));
    });
    assert!(writer.0.lock().unwrap().is_empty());
}

#[test]
fn clear_history_preserves_wrapped_prompt_input() {
    let mux = Mux::new_for_test("clear-wrapped-prompt-input", SurfaceOptions::default());
    let surface = Surface::spawn_for_test(
        1,
        SurfaceOptions { cols: 10, rows: 5, ..SurfaceOptions::default() },
        Arc::downgrade(&mux),
    )
    .unwrap();
    let writer = CapturingWriter::default();
    replace_local_writer(&surface, Box::new(writer.clone()));
    surface.with_terminal(|term| {
        for line in 0..12 {
            term.vt_write(format!("history-{line}\r\n").as_bytes());
        }
        term.vt_write(b"\x1b]133;A\x07prompt> \x1b]133;B\x07wrapped-edit-buffer");
        assert!(term.history_rows() > 0);
    });

    surface.clear_history().unwrap();

    surface.with_terminal(|term| {
        assert_eq!(term.history_rows(), 0);
        let viewport = term.viewport_text().unwrap();
        let compact =
            viewport.chars().filter(|character| !character.is_whitespace()).collect::<String>();
        assert!(compact.contains("prompt>wrapped-edit-buffer"));
        assert!(!viewport.contains("history-"));
    });
    assert!(writer.0.lock().unwrap().is_empty());
}
