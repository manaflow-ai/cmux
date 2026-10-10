//! Tests: input classes, the crossterm reader, host input ingress and
//! runtime shutdown, host keyboard protocol negotiation, and text input.

use super::*;

#[test]
fn input_class_groups_routing_semantics() {
    let cases = [
        (crate::app::InputClass::Keyboard, true, true, true),
        (crate::app::InputClass::FrontendAction, true, true, true),
        (crate::app::InputClass::ClearHistoryKey, true, true, true),
        (crate::app::InputClass::Paste, true, true, false),
        (crate::app::InputClass::Mouse, true, false, false),
        (crate::app::InputClass::Focus, false, false, false),
        (crate::app::InputClass::Resize, false, false, false),
    ];

    for (class, routable, keyboard_or_paste, keyboard_command) in cases {
        assert_eq!(class.is_routable(), routable, "{class:?}");
        assert_eq!(class.is_keyboard_or_paste(), keyboard_or_paste, "{class:?}");
        assert_eq!(class.is_keyboard_command(), keyboard_command, "{class:?}");
    }
}

#[test]
fn crossterm_reader_uses_bounded_polls_for_all_reads() {
    let event = Event::Resize(80, 24);
    let mut poll_calls = 0;
    let mut read_calls = 0;
    let mut poll_durations = Vec::new();

    let fixed_now = Instant::now();
    let blocking = crate::app::read_crossterm_event_with_clock(
        None,
        |timeout| {
            poll_calls += 1;
            poll_durations.push(timeout);
            Ok(true)
        },
        || {
            read_calls += 1;
            Ok(event.clone())
        },
        || fixed_now,
    )
    .unwrap();
    assert_eq!(blocking, Some(event.clone()));
    assert_eq!((poll_calls, read_calls), (1, 1));

    let timed_out = crate::app::read_crossterm_event_with_clock(
        Some(Duration::from_millis(10)),
        |timeout| {
            poll_calls += 1;
            poll_durations.push(timeout);
            Ok(false)
        },
        || {
            read_calls += 1;
            Ok(event.clone())
        },
        || fixed_now,
    )
    .unwrap();
    assert_eq!(timed_out, None);
    assert_eq!((poll_calls, read_calls), (2, 1));

    let ready = crate::app::read_crossterm_event_with_clock(
        Some(Duration::from_millis(10)),
        |timeout| {
            poll_calls += 1;
            poll_durations.push(timeout);
            Ok(true)
        },
        || {
            read_calls += 1;
            Ok(event.clone())
        },
        || fixed_now,
    )
    .unwrap();
    assert_eq!(ready, Some(event));
    assert_eq!((poll_calls, read_calls), (3, 2));
    assert_eq!(
        poll_durations,
        vec![Duration::from_millis(100), Duration::from_millis(10), Duration::from_millis(10),]
    );
}

#[test]
fn crossterm_reader_propagates_poll_errors_without_reading() {
    let mut read_calls = 0;
    let error = std::io::Error::other("poll failed");
    let mut poll_calls = 0;

    let result = crate::app::read_crossterm_event(
        None,
        |_| {
            poll_calls += 1;
            if poll_calls == 1 {
                Err(std::io::Error::from(std::io::ErrorKind::Interrupted))
            } else {
                Err(std::io::Error::new(error.kind(), error.to_string()))
            }
        },
        || {
            read_calls += 1;
            Ok(Event::Resize(80, 24))
        },
    );

    assert_eq!(result.unwrap_err().kind(), std::io::ErrorKind::Other);
    assert_eq!(read_calls, 0);
    assert!(poll_calls >= 1);
}

#[test]
fn crossterm_reader_retries_interrupted_poll_and_read() {
    let mut poll_calls = 0;
    let mut read_calls = 0;
    let event = Event::Resize(80, 24);
    let result = crate::app::read_crossterm_event(
        None,
        |_| {
            poll_calls += 1;
            if poll_calls == 1 {
                Err(std::io::Error::from(std::io::ErrorKind::Interrupted))
            } else {
                Ok(true)
            }
        },
        || {
            read_calls += 1;
            if read_calls == 1 {
                Err(std::io::Error::from(std::io::ErrorKind::Interrupted))
            } else {
                Ok(event.clone())
            }
        },
    )
    .unwrap();
    assert_eq!(result, Some(event));
    assert_eq!((poll_calls, read_calls), (2, 2));
}

#[test]
fn crossterm_reader_limits_consecutive_interrupted_poll_and_read() {
    let fixed_now = Instant::now();
    let mut poll_calls = 0;
    let poll_result = crate::app::read_crossterm_event_with_clock(
        None,
        |_| {
            poll_calls += 1;
            Err(std::io::Error::from(std::io::ErrorKind::Interrupted))
        },
        || Ok(Event::Resize(80, 24)),
        || fixed_now,
    );
    assert_eq!(poll_result.unwrap_err().kind(), std::io::ErrorKind::Interrupted);
    assert_eq!(poll_calls, 8);

    let mut read_calls = 0;
    let read_result = crate::app::read_crossterm_event_with_clock(
        None,
        |_| Ok(true),
        || {
            read_calls += 1;
            Err(std::io::Error::from(std::io::ErrorKind::Interrupted))
        },
        || fixed_now,
    );
    assert_eq!(read_result.unwrap_err().kind(), std::io::ErrorKind::Interrupted);
    assert_eq!(read_calls, 8);
}

#[test]
fn crossterm_reader_returns_timeout_when_interrupted_after_deadline() {
    let start = Instant::now();
    let mut clock_calls = 0;
    let mut poll_calls = 0;
    let result = crate::app::read_crossterm_event_with_clock(
        Some(Duration::from_millis(10)),
        |timeout| {
            poll_calls += 1;
            assert!(timeout.is_zero());
            Err(std::io::Error::from(std::io::ErrorKind::Interrupted))
        },
        || Ok(Event::Resize(80, 24)),
        || {
            let call = clock_calls;
            clock_calls += 1;
            if call == 0 { start } else { start + Duration::from_millis(11) }
        },
    );
    assert_eq!(result.unwrap(), None);
    assert_eq!(poll_calls, 1);
}

#[test]
fn renderer_panics_become_frontend_errors() {
    let error = catch_renderer_panic(|| -> () { panic!("invalid render cell") }).unwrap_err();
    assert_eq!(error.to_string(), "terminal renderer panicked: invalid render cell");
}

#[test]
fn terminal_paint_pacer_collapses_output_bursts_without_delaying_structural_draws() {
    let started = Instant::now();
    let mut pacer = TerminalPaintPacer::after_paint(started);

    assert_eq!(pacer.schedule(RenderAction::Paint, started), RenderAction::None);
    assert_eq!(pacer.wait_timeout(Duration::from_secs(1), started), TERMINAL_PAINT_CADENCE);
    assert_eq!(
        pacer.schedule(RenderAction::Paint, started + TERMINAL_PAINT_CADENCE / 2),
        RenderAction::None
    );
    assert_eq!(
        pacer.schedule(RenderAction::None, started + TERMINAL_PAINT_CADENCE),
        RenderAction::Paint
    );

    let structural = started + TERMINAL_PAINT_CADENCE + Duration::from_millis(1);
    assert_eq!(pacer.schedule(RenderAction::Paint, structural), RenderAction::None);
    assert_eq!(pacer.schedule(RenderAction::Draw, structural), RenderAction::Draw);

    let mut urgent = TerminalPaintPacer::after_paint(started);
    assert_eq!(urgent.schedule(RenderAction::Paint, started), RenderAction::None);
    assert_eq!(
        urgent.render_immediately(RenderAction::None, started),
        RenderAction::Paint,
        "deferred input must flush the pointer route before replay"
    );
}

#[test]
fn event_transition_dispatches_machine_request_before_next_event() {
    let mux = Mux::new("event-transition-machine-order", SurfaceOptions::default());
    let (mut app, _events) = test_app_with_events(Session::Local(mux));
    app.machine_ui = Some(provider_machine_ui());
    let (controller, _requests) = fake_controller(FakeMachineAction::Fail("expected failure"));
    install_machine_controller(&mut app, controller);
    let request = MachineRequest::ReconnectProvider;
    app.machine_ui.as_mut().unwrap().request = Some(request.clone());

    let action = app
        .handle_event_and_process_machine_requests(
            AppEvent::Mux(MuxEvent::Status("first".into())),
            RenderAction::None,
        )
        .unwrap();
    assert_eq!(action, RenderAction::Draw);
    assert!(app.machine_action_in_flight);
    assert_eq!(app.machine_action_request, Some(request.clone()));
    assert!(app.machine_ui.as_ref().unwrap().request.is_none());

    let action = app
        .handle_event_and_process_machine_requests(
            AppEvent::Mux(MuxEvent::Status("next".into())),
            action,
        )
        .unwrap();
    assert_eq!(action, RenderAction::Draw);
    assert_eq!(app.status_message.as_deref(), Some("next"));
    assert_eq!(app.machine_action_request, Some(request));
    app.shutdown_background_workers();
}

#[test]
fn event_transition_marks_pointer_route_after_structural_event() {
    let mux = Mux::new("event-transition-pointer-phase", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::Fresh);

    let action = app
        .handle_event_and_process_machine_requests(
            AppEvent::Mux(MuxEvent::Status("redraw".into())),
            RenderAction::None,
        )
        .unwrap();

    assert_eq!(action, RenderAction::Draw);
    assert_eq!(app.pointer_route_phase, PointerRoutePhase::DrawPending);
}

#[test]
fn frontend_journal_skips_unchanged_presentation_frames() {
    let mux = Mux::new("frontend-journal-frame-dedupe", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.outer_size = (80, 24);
    assert!(!app.frontend_presentation_unchanged());
    app.last_frontend_presentation = Some(app.frontend_presentation_snapshot());
    assert!(app.frontend_presentation_unchanged());

    app.outer_size.0 = 81;
    assert!(!app.frontend_presentation_unchanged());
    app.outer_size.0 = 80;
    app.focus = FocusTarget::WorkspaceRail;
    assert!(!app.frontend_presentation_unchanged());
}

#[test]
fn frontend_journal_queue_keeps_only_the_latest_event_of_each_type() {
    let queue = FrontendJournalQueue::default();
    fn event_id(event: &FrontendJournalEvent) -> &str {
        match event {
            FrontendJournalEvent::Focus { event_id, .. }
            | FrontendJournalEvent::Resize { event_id, .. }
            | FrontendJournalEvent::Viewport { event_id, .. } => event_id,
        }
    }
    let session =
        Session::Local(Mux::new("frontend-journal-bounded-coalescing", SurfaceOptions::default()));
    let projection =
        FrontendProjectionPublicId::parse("projection_00000000000000000000000000000001").unwrap();
    let focus = |event_id: &str| FrontendJournalEvent::Focus {
        event_id: event_id.into(),
        frontend_projection_id: projection.clone(),
        generation: "generation-1".into(),
        target: FrontendFocusTarget::Pane,
        workspace_id: None,
        screen_id: None,
        pane_id: None,
        tab_id: None,
        content_id: None,
    };

    queue.push(session.clone(), focus("focus-old"));
    queue.push(
        session.clone(),
        FrontendJournalEvent::Resize {
            event_id: "resize-latest".into(),
            frontend_projection_id: projection.clone(),
            generation: "generation-1".into(),
            cols: 80,
            rows: 24,
            cell_width: 8,
            cell_height: 16,
        },
    );
    queue.push(
        session.clone(),
        FrontendJournalEvent::Viewport {
            event_id: "viewport-latest".into(),
            frontend_projection_id: projection.clone(),
            generation: "generation-1".into(),
            screen_id: None,
            offset: 0,
            target: 0,
            settled: true,
        },
    );
    queue.push(session.clone(), focus("focus-latest"));

    assert_eq!(queue.pending_count(), 3);
    assert_eq!(event_id(&queue.take().unwrap().event), "resize-latest");
    assert_eq!(event_id(&queue.take().unwrap().event), "viewport-latest");
    assert_eq!(event_id(&queue.take().unwrap().event), "focus-latest");

    queue.push(session.clone(), focus("focus-retry"));
    queue.push(
        session,
        FrontendJournalEvent::Resize {
            event_id: "resize-ready".into(),
            frontend_projection_id: projection,
            generation: "generation-1".into(),
            cols: 81,
            rows: 24,
            cell_width: 8,
            cell_height: 16,
        },
    );
    let failed = queue.take().unwrap();
    assert_eq!(event_id(&failed.event), "focus-retry");
    queue.retry(failed);
    assert_eq!(
        event_id(&queue.take().unwrap().event),
        "resize-ready",
        "a delayed retry must not block another coalesced event type"
    );
}

#[test]
fn host_input_failure_is_forwarded_to_the_event_loop() {
    let (tx, rx) = crossbeam_channel::bounded(1);
    forward_host_input(
        || -> std::io::Result<Event> {
            Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "revoked tty"))
        },
        &tx,
    );
    match rx.recv().unwrap() {
        AppEvent::HostInputFailed(error) => assert_eq!(error, "revoked tty"),
        _ => panic!("expected host input failure"),
    }
}

#[test]
fn host_input_ingress_backpressures_instead_of_dropping_discrete_input() {
    let ingress = Arc::new(HostInputIngress::default());
    let key = Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE));
    for _ in 0..DEFERRED_INPUT_CAPACITY {
        ingress.send(key.clone()).unwrap();
    }
    assert_eq!(ingress.len(), DEFERRED_INPUT_CAPACITY);

    let blocked_ingress = ingress.clone();
    let (completed_tx, completed_rx) = std::sync::mpsc::sync_channel(1);
    let producer = std::thread::spawn(move || {
        blocked_ingress.send(key).unwrap();
        completed_tx.send(()).unwrap();
    });
    assert!(
        completed_rx.recv_timeout(Duration::from_millis(20)).is_err(),
        "the producer must wait while retained input owns the full budget"
    );

    assert!(ingress.pop_if(|_| true).is_some());
    completed_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    assert_eq!(ingress.len(), DEFERRED_INPUT_CAPACITY);
    ingress.close();
    producer.join().unwrap();
}

#[test]
fn host_input_runtime_shutdown_joins_reader_before_returning() {
    let runtime = HostInputRuntime::new();
    let ingress = runtime.ingress.clone();
    let (events_tx, events_rx) = crossbeam_channel::bounded(1);
    events_tx.send(AppEvent::HostInputReady).unwrap();
    let input = runtime.producer(events_tx);
    let (sent_tx, sent_rx) = std::sync::mpsc::sync_channel(1);
    let (finished_tx, finished_rx) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        let key = Event::Key(KeyEvent::new(KeyCode::Char('x'), KeyModifiers::NONE));
        assert!(input.send(key));
        sent_tx.send(()).unwrap();
        while !ingress.is_closed() {
            std::thread::yield_now();
        }
        finished_tx.send(()).unwrap();
    });

    runtime.attach_reader(reader);
    sent_rx.recv_timeout(Duration::from_secs(1)).unwrap();
    runtime.shutdown();

    assert!(
        finished_rx.try_recv().is_ok(),
        "runtime shutdown must join the input reader before returning"
    );
    drop(events_rx);
}

#[test]
fn host_input_runtime_shutdown_serializes_concurrent_callers() {
    let runtime = HostInputRuntime::new();
    let ingress = runtime.ingress.clone();
    let (closed_tx, closed_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        while !ingress.is_closed() {
            std::thread::yield_now();
        }
        closed_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    runtime.attach_reader(reader);

    let shutdown = runtime.shutdown_control();
    let first_shutdown = shutdown.clone();
    let (first_done_tx, first_done_rx) = std::sync::mpsc::sync_channel(1);
    let first = std::thread::spawn(move || {
        first_shutdown.shutdown();
        first_done_tx.send(()).unwrap();
    });
    closed_rx.recv().unwrap();

    let second_shutdown = shutdown;
    let (second_done_tx, second_done_rx) = std::sync::mpsc::sync_channel(1);
    let second = std::thread::spawn(move || {
        second_shutdown.shutdown();
        second_done_tx.send(()).unwrap();
    });
    assert!(
        second_done_rx.try_recv().is_err(),
        "concurrent shutdown must wait for the reader join"
    );

    release_tx.send(()).unwrap();
    first.join().unwrap();
    second.join().unwrap();
    assert!(first_done_rx.try_recv().is_ok());
    assert!(second_done_rx.try_recv().is_ok());
}

#[test]
fn host_input_ingress_keeps_latest_adjacent_resize() {
    let ingress = HostInputIngress::default();
    ingress.send(Event::Resize(80, 24)).unwrap();
    ingress.send(Event::Resize(120, 40)).unwrap();
    assert_eq!(ingress.len(), 1);
    assert!(matches!(
        ingress.pop_if(|_| true),
        Some(HostInputMessage::Event(Event::Resize(120, 40)))
    ));
}

#[test]
fn host_keyboard_protocol_reports_command_modifiers_and_is_restored() {
    let mut output = Vec::new();
    let accepted = KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
        | KeyboardEnhancementFlags::REPORT_ALTERNATE_KEYS
        | KeyboardEnhancementFlags::REPORT_ALL_KEYS_AS_ESCAPE_CODES
        | KeyboardEnhancementFlags::REPORT_ASSOCIATED_TEXT;

    let mut ownership = crate::app::HostKeyboardProtocolOwnership::default();
    negotiate_host_keyboard_protocol_with(&mut output, &mut ownership, |_| Ok(Some(accepted)))
        .unwrap();
    assert!(ownership.is_pushed());
    disable_host_keyboard_protocol(&mut output, &ownership).unwrap();

    assert_eq!(output, b"\x1b[>29u\x1b[<1u");
}

#[test]
fn host_keyboard_protocol_cleanup_is_single_use_across_clones() {
    let mut output = Vec::new();
    let ownership = enable_host_keyboard_protocol(&mut output).unwrap();
    let panic_ownership = ownership.clone();

    disable_host_keyboard_protocol(&mut output, &panic_ownership).unwrap();
    disable_host_keyboard_protocol(&mut output, &ownership).unwrap();

    assert_eq!(output, b"\x1b[>29u\x1b[<1u");
}

#[test]
fn unsupported_host_keyboard_protocol_is_a_nonfatal_fallback() {
    struct UnsupportedWriter {
        writes: usize,
    }

    impl std::io::Write for UnsupportedWriter {
        fn write(&mut self, _buffer: &[u8]) -> std::io::Result<usize> {
            self.writes += 1;
            Err(std::io::Error::from(std::io::ErrorKind::Unsupported))
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    let mut output = UnsupportedWriter { writes: 0 };
    let ownership = enable_host_keyboard_protocol(&mut output).unwrap();
    assert!(!ownership.is_pushed());
    disable_host_keyboard_protocol(&mut output, &ownership).unwrap();
    assert_eq!(output.writes, 1, "cleanup must not pop a stack entry cmux did not push");
}

#[test]
fn host_keyboard_protocol_requires_every_requested_flag() {
    let requested = KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
        | KeyboardEnhancementFlags::REPORT_ALTERNATE_KEYS
        | KeyboardEnhancementFlags::REPORT_ALL_KEYS_AS_ESCAPE_CODES
        | KeyboardEnhancementFlags::REPORT_ASSOCIATED_TEXT;
    let partial = requested - KeyboardEnhancementFlags::REPORT_ASSOCIATED_TEXT;

    assert!(!keyboard_protocol_accepts(requested, Some(partial)));
    assert!(!keyboard_protocol_accepts(requested, None));
    assert!(keyboard_protocol_accepts(requested, Some(requested)));
}

#[test]
fn partial_host_keyboard_protocol_is_popped_before_legacy_fallback() {
    let mut output = Vec::new();
    let accepted = KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES
        | KeyboardEnhancementFlags::REPORT_ALTERNATE_KEYS;

    let mut ownership = crate::app::HostKeyboardProtocolOwnership::default();
    negotiate_host_keyboard_protocol_with(&mut output, &mut ownership, |_| Ok(Some(accepted)))
        .unwrap();

    assert_eq!(ownership, crate::app::HostKeyboardProtocolOwnership::default());
    assert_eq!(output, b"\x1b[>29u\x1b[<1u");
}

#[test]
fn failed_host_keyboard_query_is_popped_before_legacy_fallback() {
    let mut output = Vec::new();
    let mut ownership = crate::app::HostKeyboardProtocolOwnership::default();

    negotiate_host_keyboard_protocol_with(&mut output, &mut ownership, |_| {
        Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "missing DA1"))
    })
    .unwrap();

    assert_eq!(ownership, crate::app::HostKeyboardProtocolOwnership::default());
    assert_eq!(output, b"\x1b[>29u\x1b[<1u");
}

#[test]
fn host_keyboard_protocol_query_uses_bounded_startup_deadline() {
    let mut output = Vec::new();
    let mut ownership = crate::app::HostKeyboardProtocolOwnership::default();
    let observed = std::cell::Cell::new(None);

    negotiate_host_keyboard_protocol_with(&mut output, &mut ownership, |timeout| {
        observed.set(Some(timeout));
        Ok(None)
    })
    .unwrap();

    assert_eq!(observed.get(), Some(crate::app::HOST_KEYBOARD_QUERY_TIMEOUT));
    assert!(crate::app::HOST_KEYBOARD_QUERY_TIMEOUT <= Duration::from_millis(200));
    assert_eq!(output, b"\x1b[>29u\x1b[<1u");
}

#[test]
fn failed_keyboard_pop_keeps_cleanup_ownership_for_terminal_restore() {
    struct RejectPop(Vec<u8>);

    impl std::io::Write for RejectPop {
        fn write(&mut self, buffer: &[u8]) -> std::io::Result<usize> {
            if buffer.contains(&b'<') {
                return Err(std::io::Error::from(std::io::ErrorKind::BrokenPipe));
            }
            self.0.extend_from_slice(buffer);
            Ok(buffer.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }

    let mut output = RejectPop(Vec::new());
    let mut ownership = crate::app::HostKeyboardProtocolOwnership::default();
    let error = negotiate_host_keyboard_protocol_with(&mut output, &mut ownership, |_| {
        Err(std::io::Error::new(std::io::ErrorKind::TimedOut, "missing DA1"))
    })
    .unwrap_err();

    assert_eq!(error.kind(), std::io::ErrorKind::BrokenPipe);
    assert!(ownership.is_pushed());
}

#[test]
fn unverified_host_keyboard_metadata_is_preserved() {
    let input = TerminalInput::from_event(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('л'), KeyModifiers::SUPER),
        shifted_key: None,
        base_layout_key: Some('k'),
        text: "generated".to_string(),
    }));
    let TerminalInput::Keyboard(input) = input else {
        panic!("enhanced key did not become keyboard input");
    };

    let (logical, physical) = input.shortcut_keys();
    assert_eq!(logical.code, KeyCode::Char('л'));
    assert_eq!(physical.unwrap().code, KeyCode::Char('k'));
    assert_eq!(input.associated_text_bytes(), "generated".len());
}

#[test]
fn enhanced_text_inserts_atomically_in_prompt_and_omnibar() {
    let mux = Mux::new("enhanced-overlay-text-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let text = "\u{2211}\u{6f22}";
    let enhanced = || {
        Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('w'), KeyModifiers::ALT),
            shifted_key: None,
            base_layout_key: Some('w'),
            text: text.to_string(),
        })
    };
    app.prompt = Some(Prompt::new("Rename", String::new(), PromptTarget::Workspace(1)));

    app.handle(AppEvent::Input(enhanced())).unwrap();

    assert_eq!(app.prompt.as_ref().unwrap().input.as_str(), text);
    app.prompt = None;
    app.omnibar = Some(OmnibarState {
        pane: 1,
        surface: 1,
        input: TextInput::new("old".to_string()),
        select_all: true,
    });

    app.handle(AppEvent::Input(enhanced())).unwrap();

    let omnibar = app.omnibar.as_ref().unwrap();
    assert_eq!(omnibar.input.as_str(), text);
    assert!(!omnibar.select_all);
}

#[test]
fn prompt_render_persists_text_input_viewport_before_left_movement() {
    let mux = Mux::new("text-input-viewport-lifecycle-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux.clone()));
    app.prompt = Some(Prompt::new(
        "Rename",
        "abcdefghijklmnopqrstuvwxyz0123456789".to_string(),
        PromptTarget::Workspace(1),
    ));
    let mut terminal = Terminal::new(TestBackend::new(24, 12)).unwrap();

    app.draw_terminal(&mut terminal, RenderAction::Draw).unwrap();

    let before = app.prompt.as_ref().unwrap().input.visible_text_and_cursor(18);
    assert!(before.1 > 0);
    app.handle_prompt_key(KeyEvent::new(KeyCode::Left, KeyModifiers::NONE)).unwrap();
    let after = app.prompt.as_ref().unwrap().input.visible_text_and_cursor(18);

    assert_eq!(after.0, before.0);
    assert_eq!(after.1, before.1 - 1);
    mux.shutdown();
}

#[test]
fn enhanced_control_text_uses_prompt_and_omnibar_shortcuts() {
    let mux = Mux::new("enhanced-overlay-shortcut-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let control_a = || {
        Event::EnhancedKey(EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('a'), KeyModifiers::CONTROL),
            shifted_key: None,
            base_layout_key: Some('a'),
            text: "a".to_string(),
        })
    };
    app.prompt = Some(Prompt::new("Rename", "word".into(), PromptTarget::Workspace(1)));

    app.handle(AppEvent::Input(control_a())).unwrap();

    let prompt = app.prompt.as_ref().unwrap();
    assert_eq!(prompt.input.as_str(), "word");
    assert_eq!(prompt.input.cursor, 0);
    app.prompt = None;
    app.omnibar = Some(OmnibarState {
        pane: 1,
        surface: 1,
        input: TextInput::new("https://example.com".to_string()),
        select_all: false,
    });

    app.handle(AppEvent::Input(control_a())).unwrap();

    let omnibar = app.omnibar.as_ref().unwrap();
    assert_eq!(omnibar.input.as_str(), "https://example.com");
    assert!(omnibar.select_all);
}

#[test]
fn shifted_layout_key_matches_reported_character_instead_of_us_pair() {
    let enhanced = EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('&'), KeyModifiers::ALT | KeyModifiers::SHIFT),
        shifted_key: Some('1'),
        base_layout_key: Some('1'),
        text: "1".to_string(),
    };
    let input = crate::keys::KeyboardInput::from(enhanced);
    let (key, fallback) = input.shortcut_keys();
    let alt_one = crate::config::Chord { code: KeyCode::Char('1'), mods: KeyModifiers::ALT };
    let alt_ampersand = crate::config::Chord { code: KeyCode::Char('&'), mods: KeyModifiers::ALT };

    assert!(crate::app::binding_matches(&alt_one, &key, fallback.as_ref()));
    assert!(!crate::app::binding_matches(&alt_ampersand, &key, fallback.as_ref()));
}

#[test]
fn enhanced_shifted_suffix_runs_uppercase_prefix_binding() {
    let mux = Mux::new("enhanced-prefix-shift-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_view = SidebarView::Workspaces;
    app.sync_layout((80, 25));
    app.handle_key(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL)).unwrap();

    app.handle_keyboard(crate::keys::KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('s'), KeyModifiers::SHIFT),
        shifted_key: Some('S'),
        base_layout_key: Some('s'),
        text: "S".to_string(),
    }))
    .unwrap();

    assert_eq!(app.focus, FocusTarget::WorkspaceRail);
    assert!(!app.prefix_armed);
}

#[test]
fn option_generated_text_does_not_match_alt_modeless_bindings() {
    let input = crate::keys::KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('j'),
        text: "\u{2206}".to_string(),
    });
    let (key, fallback) = input.shortcut_keys();

    assert_eq!(
        crate::app::modeless_action_for_binding(&Config::default().keys, &key, fallback.as_ref()),
        None
    );
}

#[test]
fn empty_text_alt_character_in_option_mode_does_not_match_modeless_bindings() {
    let mut input = crate::keys::KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('j'),
        text: String::new(),
    });
    input.resolve_macos_option_as_alt(false);
    let (key, fallback) = input.shortcut_keys();

    assert!(input.suppresses_alt_shortcut());
    assert_eq!(
        crate::app::modeless_action_for_binding(&Config::default().keys, &key, fallback.as_ref()),
        None
    );
}

#[test]
fn empty_text_alt_character_without_layout_metadata_respects_option_mode() {
    let mut input = crate::keys::KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: None,
        text: String::new(),
    });
    input.resolve_macos_option_as_alt(false);
    let (key, fallback) = input.shortcut_keys();

    assert!(input.suppresses_alt_shortcut());
    assert_eq!(
        crate::app::modeless_action_for_binding(&Config::default().keys, &key, fallback.as_ref()),
        None
    );
}

#[test]
fn app_resolves_empty_text_alt_from_the_configured_input_mode() {
    for (macos_option_as_alt, should_toggle) in [(true, true), (false, false)] {
        let mux = Mux::new(
            format!("explicit-alt-input-mode-{macos_option_as_alt}"),
            SurfaceOptions::default(),
        );
        let mut app = test_app(Session::Local(mux));
        app.config.keys.macos_option_as_alt = macos_option_as_alt;
        app.config.keys.apply_for_test(&HashMap::from([(
            "toggle-sidebar".to_string(),
            Value::String("alt+j".to_string()),
        )]));
        let sidebar_was_visible = app.sidebar_visible;

        app.handle_keyboard(
            EnhancedKeyEvent {
                key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::ALT),
                shifted_key: None,
                base_layout_key: Some('j'),
                text: String::new(),
            }
            .into(),
        )
        .unwrap();

        assert_eq!(
            app.sidebar_visible != sidebar_was_visible,
            should_toggle,
            "configured macos_option_as_alt={macos_option_as_alt}"
        );
        assert!(app.pty_input.shutdown(Duration::from_secs(1)));
    }
}

#[test]
fn alt_binding_with_matching_associated_text_remains_active() {
    let input = crate::keys::KeyboardInput::from(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('j'),
        text: "j".to_string(),
    });
    let (key, fallback) = input.shortcut_keys();

    assert_eq!(
        crate::app::modeless_action_for_binding(&Config::default().keys, &key, fallback.as_ref()),
        Some(Action::FocusDown)
    );
}

#[test]
fn option_generated_text_does_not_execute_a_prefixed_action() {
    let mux = Mux::new("option-prefix-action", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));

    app.handle_keyboard(KeyEvent::new(KeyCode::Char('b'), KeyModifiers::CONTROL).into()).unwrap();
    assert!(app.prefix_armed);
    app.handle_keyboard(
        EnhancedKeyEvent {
            key_event: KeyEvent::new(KeyCode::Char('d'), KeyModifiers::ALT),
            shifted_key: None,
            base_layout_key: Some('d'),
            text: "\u{2202}".to_string(),
        }
        .into(),
    )
    .unwrap();

    assert!(!app.prefix_armed);
    assert!(!app.quit);
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
}

#[test]
fn option_generated_text_cannot_bypass_a_pending_mutation_as_detach() {
    let mux = Mux::new("option-prefix-pending-detach", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.prefix_armed = true;
    app.session.pending_mutations.store(1, Ordering::Release);

    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('d'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('d'),
        text: "\u{2202}".to_string(),
    })))
    .unwrap();

    assert!(!app.quit);
    assert!(!app.prefix_armed);
    assert!(app.deferred_input.is_empty());
    assert_eq!(app.focus, FocusTarget::Pane);
    app.session.pending_mutations.store(0, Ordering::Release);
    assert!(app.pty_input.shutdown(Duration::from_secs(1)));
}

#[test]
fn files_filter_inserts_complete_associated_text() {
    let temp = test_temp_dir("files-filter-associated-text");
    let mux = Mux::new("files-filter-associated-text-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_files = FileBrowser::new(temp.clone());
    app.sidebar_view = SidebarView::Files;
    app.focus = FocusTarget::WorkspaceRail;
    app.sidebar_files.handle_key(&KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE));

    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('w'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('w'),
        text: "\u{2211}\u{6f22}".to_string(),
    })))
    .unwrap();

    assert_eq!(app.sidebar_files.query(), "\u{2211}\u{6f22}");
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn files_filter_does_not_insert_modified_associated_text() {
    let temp = test_temp_dir("files-filter-modified-associated-text");
    let mux = Mux::new("files-filter-modified-associated-text-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.sidebar_files = FileBrowser::new(temp.clone());
    app.sidebar_view = SidebarView::Files;
    app.focus = FocusTarget::WorkspaceRail;
    app.sidebar_files.handle_key(&KeyEvent::new(KeyCode::Char('/'), KeyModifiers::NONE));

    app.handle(AppEvent::Input(Event::EnhancedKey(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('x'), KeyModifiers::CONTROL),
        shifted_key: None,
        base_layout_key: Some('x'),
        text: "x".to_string(),
    })))
    .unwrap();

    assert_eq!(app.sidebar_files.query(), "");
    std::fs::remove_dir_all(temp).unwrap();
}

#[test]
fn browser_inserts_complete_associated_text_atomically() {
    let mux = Mux::new("browser-associated-text-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;
    let input = crate::keys::KeyboardInput::from_enhanced(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('w'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('w'),
        text: "\u{2211}\u{6f22}".to_string(),
    });

    app.forward_browser_key_to(7, SurfaceHandle::RemoteBrowserUnsupported, input);

    let event = blocked.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(matches!(
        event.kind,
        BrowserInputKind::InsertText(text) if text == "\u{2211}\u{6f22}"
    ));
}

#[test]
fn browser_routes_modified_associated_text_as_an_atomic_key_press() {
    let mux = Mux::new("browser-modified-associated-text-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;
    let input = crate::keys::KeyboardInput::from(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::ALT),
        shifted_key: None,
        base_layout_key: Some('j'),
        text: "j".to_string(),
    });

    app.forward_browser_key_to(7, SurfaceHandle::RemoteBrowserUnsupported, input);

    let event = blocked.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(matches!(
        event.kind,
        BrowserInputKind::KeyPress {
            key: crate::browser_input::BrowserKey::Character('j'),
            code: "KeyJ",
            windows_virtual_key_code: 74,
            modifiers: 1,
            text: None,
        }
    ));
    assert!(blocked.recv_timeout(Duration::from_millis(20)).is_none());
}

#[test]
fn browser_mapping_keeps_character_keys_and_codes_compact() {
    let (key, code, vk, text) =
        crate::app::browser_key_mapping(KeyCode::Char('j'), Some('j')).unwrap();

    assert_eq!(key, crate::browser_input::BrowserKey::Character('j'));
    assert_eq!(code, "KeyJ");
    assert_eq!(vk, 74);
    assert_eq!(text, None);
}

#[test]
fn browser_mapping_does_not_invent_physical_identity_without_host_metadata() {
    let (key, code, vk, text) = crate::app::browser_key_mapping(KeyCode::Char('a'), None).unwrap();

    assert_eq!(key, crate::browser_input::BrowserKey::Character('a'));
    assert_eq!(code, "");
    assert_eq!(vk, 0);
    assert_eq!(text, None);
}

#[test]
fn browser_preserves_meta_on_associated_key_events() {
    let mux = Mux::new("browser-meta-associated-text-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    let (dispatcher, blocked) = BrowserInputDispatcher::blocked(1);
    app.browser_input = dispatcher;
    let input = crate::keys::KeyboardInput::from(EnhancedKeyEvent {
        key_event: KeyEvent::new(KeyCode::Char('j'), KeyModifiers::META),
        shifted_key: None,
        base_layout_key: Some('j'),
        text: "j".to_string(),
    });

    app.forward_browser_key_to(7, SurfaceHandle::RemoteBrowserUnsupported, input);

    let event = blocked.recv_timeout(Duration::from_secs(1)).unwrap();
    assert!(matches!(
        event.kind,
        BrowserInputKind::KeyPress {
            key: crate::browser_input::BrowserKey::Character('j'),
            code: "KeyJ",
            windows_virtual_key_code: 74,
            modifiers: 4,
            text: None,
        }
    ));
}

#[test]
fn zero_width_startup_hides_sidebar_without_panicking() {
    let config = Config::default();
    let layout =
        sidebar_layout_for(&config, true, false, false, (0, 24), SidebarWidthOverrides::default());
    assert!(layout.workspace.is_none());
    assert_eq!(layout.content.width, 0);
}

#[test]
fn panic_restore_waits_for_a_concurrent_stdout_owner() {
    let lock = Arc::new(StdoutLock::new(()));
    let (held_tx, held_rx) = std::sync::mpsc::sync_channel(1);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(1);
    let owner_lock = lock.clone();
    let owner = std::thread::spawn(move || {
        let _guard = owner_lock.lock();
        held_tx.send(()).unwrap();
        release_rx.recv().unwrap();
    });
    held_rx.recv_timeout(Duration::from_secs(1)).unwrap();

    let (restored_tx, restored_rx) = std::sync::mpsc::sync_channel(1);
    let restore_lock = lock.clone();
    let restorer = std::thread::spawn(move || {
        with_panic_stdout_lock(&restore_lock, || restored_tx.send(()).unwrap());
    });
    let restored_while_owned = restored_rx.recv_timeout(Duration::from_millis(50)).is_ok();
    release_tx.send(()).unwrap();
    owner.join().unwrap();
    restorer.join().unwrap();

    assert!(!restored_while_owned, "panic cleanup bypassed another stdout owner");

    let _owner_guard = lock.lock();
    let reentrant_restore = AtomicBool::new(false);
    with_panic_stdout_lock(&lock, || {
        reentrant_restore.store(true, Ordering::SeqCst);
    });
    assert!(reentrant_restore.load(Ordering::SeqCst));
}

#[test]
fn pane_context_menu_groups_current_tab_creation_layout_and_ids() {
    let pane = 7;
    let menu = ContextMenu::at(10, 5, pane_context_menu_groups(pane, false, false));

    assert_eq!(
        menu.levels[0].items.as_ref(),
        vec![
            MenuItem::Action(MenuAction::RenameTab(pane)),
            MenuItem::Action(MenuAction::CloseTab(pane)),
            MenuItem::Separator,
            MenuItem::Action(MenuAction::NewPaneSmart(pane)),
            MenuItem::Action(MenuAction::NewTab(pane)),
            MenuItem::Action(MenuAction::NewBrowserTab(pane)),
            MenuItem::Separator,
            MenuItem::Action(MenuAction::SplitRight(pane)),
            MenuItem::Action(MenuAction::SplitDown(pane)),
            MenuItem::Action(MenuAction::ClosePane(pane)),
            MenuItem::Separator,
            MenuItem::Action(MenuAction::CopyTabId(pane)),
            MenuItem::Action(MenuAction::CopyPaneId(pane)),
        ]
        .as_slice()
    );
}

#[test]
fn context_menus_scope_pane_and_sidebar_actions_to_the_clicked_region() {
    let mux = Mux::new("shortcut-menu-test", SurfaceOptions::default());
    let mut app = test_app(Session::Local(mux));
    app.tree = notify_tree(41, false);
    app.sidebar_view = SidebarView::Workspaces;
    app.sidebar_width = 20;
    app.pane_areas.push(PaneArea {
        pane: 2,
        surface: 41,
        rect: Rect { x: 20, y: 0, width: 80, height: 24 },
        bar: None,
        omnibar: None,
        content: Rect { x: 20, y: 0, width: 80, height: 24 },
        track: None,
        viewport: None,
    });

    app.open_context_menu(30, 10);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    let shortcut = |target| {
        items.iter().find(|item| item.action() == Some(target)).and_then(MenuItem::shortcut)
    };
    assert_eq!(shortcut(MenuAction::NewPaneSmart(2)), Some("Alt-n"));
    assert_eq!(shortcut(MenuAction::CloseTab(2)), Some("Ctrl-b x"));
    assert_eq!(shortcut(MenuAction::ClosePane(2)), Some("Ctrl-b X"));
    assert_eq!(shortcut(MenuAction::TogglePaneZoom { pane: 2, zoomed: false }), Some("Ctrl-b z"));
    assert_eq!(shortcut(MenuAction::ToggleSidebar { visible: true }), Some("Ctrl-b s"));
    assert_eq!(shortcut(MenuAction::ToggleSidebarCompact { compact: false }), None);
    assert_eq!(shortcut(MenuAction::FocusSidebar), None);
    assert_eq!(shortcut(MenuAction::ShowShortcuts), Some("Ctrl-b ?"));

    let mut terminal = Terminal::new(TestBackend::new(100, 40)).unwrap();
    terminal.draw(|frame| crate::ui::draw(&mut app, frame)).unwrap();
    let rendered = buffer_text(terminal.backend().buffer());
    assert!(rendered.contains("Alt-n"));
    assert!(rendered.contains("Ctrl-b z"));

    app.open_context_menu(5, 10);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    let shortcut = |target| {
        items.iter().find(|item| item.action() == Some(target)).and_then(MenuItem::shortcut)
    };
    assert_eq!(shortcut(MenuAction::ToggleSidebar { visible: true }), Some("Ctrl-b s"));
    assert_eq!(shortcut(MenuAction::ToggleSidebarCompact { compact: false }), Some("Ctrl-b m"));
    assert_eq!(shortcut(MenuAction::FocusSidebar), Some("Ctrl-b S"));
    assert_eq!(shortcut(MenuAction::ShowShortcuts), Some("Ctrl-b ?"));
    assert!(!items.iter().any(|item| item.label() == Some("Show files in sidebar")));

    let workspace = app.tree.active_workspace().unwrap().id;
    app.hits.push((
        Rect { x: 2, y: 3, width: 10, height: 2 },
        crate::app::Hit::Workspace { index: 0, id: workspace },
    ));
    app.open_context_menu(3, 3);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    assert_eq!(
        items
            .iter()
            .find(|item| item.action() == Some(MenuAction::CloseWorkspace(workspace)))
            .and_then(MenuItem::shortcut),
        Some("Ctrl-b D")
    );

    let screen = app.tree.active_screen().unwrap().id;
    app.hits.push((
        Rect { x: 30, y: 30, width: 10, height: 1 },
        crate::app::Hit::ScreenEntry { index: 0, id: screen },
    ));
    app.open_context_menu(30, 30);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    assert!(items.iter().any(|item| item.action() == Some(MenuAction::RenameScreen(screen))));
    assert!(items.iter().any(|item| item.action() == Some(MenuAction::ShowShortcuts)));
    assert!(
        items.iter().any(|item| item.action() == Some(MenuAction::ToggleSidebar { visible: true }))
    );
    assert!(!items.iter().any(|item| {
        matches!(
            item.action(),
            Some(MenuAction::ToggleSidebarCompact { .. } | MenuAction::FocusSidebar)
        )
    }));
    app.activate_menu(MenuAction::ShowShortcuts).unwrap();
    assert!(app.shortcut_help.is_some());

    let mut inactive_workspace = app.tree.workspaces_mut()[0].clone();
    inactive_workspace.id = 14;
    app.tree.workspaces_mut().push(inactive_workspace);
    app.hits.clear();
    app.hits.push((
        Rect { x: 2, y: 6, width: 10, height: 1 },
        crate::app::Hit::Workspace { index: 1, id: 14 },
    ));
    app.open_context_menu(3, 6);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    assert_eq!(
        items
            .iter()
            .find(|item| item.action() == Some(MenuAction::CloseWorkspace(14)))
            .and_then(MenuItem::shortcut),
        None
    );

    let mut inactive_screen = app.tree.active_screen().unwrap().clone();
    inactive_screen.id = 13;
    app.tree.workspaces_mut()[0].screens.push(inactive_screen);
    app.hits.clear();
    app.hits.push((
        Rect { x: 30, y: 30, width: 10, height: 1 },
        crate::app::Hit::ScreenEntry { index: 1, id: 13 },
    ));
    app.open_context_menu(30, 30);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    assert_eq!(
        items
            .iter()
            .find(|item| item.action() == Some(MenuAction::CloseScreen(13)))
            .and_then(MenuItem::shortcut),
        None
    );

    let mut inactive_pane = app.tree.active_screen().unwrap().panes[0].clone();
    inactive_pane.id = 12;
    inactive_pane.tabs[0].surface = 51;
    app.tree.workspaces_mut()[0].screens[0].panes.push(inactive_pane);
    app.pane_areas.push(PaneArea {
        pane: 12,
        surface: 51,
        rect: Rect { x: 20, y: 25, width: 80, height: 10 },
        bar: None,
        omnibar: None,
        content: Rect { x: 20, y: 25, width: 80, height: 10 },
        track: None,
        viewport: None,
    });
    app.hits.clear();
    app.open_context_menu(30, 26);
    let items = &app.menu.as_ref().unwrap().levels[0].items;
    assert_eq!(
        items
            .iter()
            .find(|item| item.action() == Some(MenuAction::ClosePane(12)))
            .and_then(MenuItem::shortcut),
        None
    );
}
