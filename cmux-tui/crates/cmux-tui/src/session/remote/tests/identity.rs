//! Identity and capability checks, frame logging, and JSON line framing.

use super::*;

#[test]
fn protocol_12_identity_without_browser_capability_keeps_pty_sessions_compatible() {
    validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 12})).unwrap();
}

#[test]
fn browser_attach_requires_the_guarded_pointer_capability() {
    let unsupported = super::super::test_session_with_provider_context(None, HashSet::new());
    assert!(!unsupported.supports_browser_attach());

    let supported = super::super::test_session_with_provider_context(
        None,
        HashSet::from([GUARDED_BROWSER_POINTER_CAPABILITY.to_string()]),
    );
    assert!(supported.supports_browser_attach());
}

#[test]
fn size_state_events_keep_the_newest_generation_per_terminal() {
    let session = super::super::test_session_with_provider_context(None, HashSet::new());
    let state = |generation: u64, cols: u16| {
        json!({
            "generation": generation, "cols": cols, "rows": 30, "reason": "smallest",
            "owners": ["c3"], "policy": {"mode": "smallest", "priority": [], "fixed": null},
            "participants": [],
        })
    };
    session.handle_line(json!({
        "event": "size-state", "surface": 9, "state": state(4, 118), "self_participant": "c3",
    }));
    let stored = session.size_state(9).expect("size state is stored");
    assert_eq!((stored.state.generation, stored.state.cols), (4, 118));
    assert_eq!(stored.self_participant.as_deref(), Some("c3"));

    session.handle_line(json!({"event": "size-state", "surface": 9, "state": state(3, 80)}));
    assert_eq!(session.size_state(9).unwrap().state.cols, 118);

    session.handle_line(json!({"event": "size-state", "surface": 9, "state": state(5, 90)}));
    assert_eq!(session.size_state(9).unwrap().state.cols, 90);
    assert!(session.size_state(10).is_none());
}

/// Answers `attach-surface` like a `shared-sizing-v1` daemon: with this
/// view's participant id and the current size state, and no event.
struct SizedAttachWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
}

impl RemoteMessageWriter for SizedAttachWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let Some(id) = request.get("id").and_then(Value::as_u64) else { return Ok(()) };
        let session = self
            .session
            .lock()
            .unwrap()
            .as_ref()
            .and_then(Weak::upgrade)
            .ok_or_else(|| io::Error::other("test remote session was dropped"))?;
        let response = session
            .pending
            .lock()
            .unwrap()
            .remove(&id)
            .ok_or_else(|| io::Error::other("remote request was not pending"))?;
        let data = match request.get("cmd").and_then(Value::as_str) {
            Some("attach-surface") => json!({
                "participant": "c3",
                "size_state": {
                    "generation": 2, "cols": 100, "rows": 40, "reason": "smallest",
                    "owners": ["c3"],
                    "policy": {"mode": "smallest", "priority": [], "fixed": null},
                    "participants": [{
                        "id": "c3", "device_kind": "tui", "device_name": "devbox",
                        "viewport": {"cols": 100, "rows": 40},
                        "counts": true, "priority_key": "anon:c3/tui",
                    }],
                },
            }),
            _ => Value::Null,
        };
        response
            .response
            .send(json!({"id": id, "ok": true, "data": data}))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn a_terminal_has_its_size_state_right_after_attach() {
    let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
    let session = test_session_with_writer(
        Box::new(SizedAttachWriter { session: session_slot.clone() }),
        None,
        HashSet::from([SHARED_SIZING_CAPABILITY.to_string()]),
    );
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));

    let attached =
        session.try_ensure_surface_with_kind(9, SurfaceKind::Pty, Some((100, 40))).unwrap();
    assert!(matches!(attached, RemoteSurfaceAttach::Attached(_)));

    let stored = session.size_state(9).expect("the attach answer carries the size state");
    assert_eq!((stored.state.generation, stored.state.cols, stored.state.rows), (2, 100, 40));
    assert_eq!(stored.self_participant.as_deref(), Some("c3"));
}

#[test]
fn per_surface_client_sizing_requires_protocol_10() {
    const { assert!(SUPPORTED_PROTOCOL_VERSION >= 10) };
}

#[test]
fn protocol_11_identity_is_rejected_before_workspace_loading() {
    let error = validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 11})).unwrap_err();
    assert_eq!(
        error.to_string(),
        "unsupported cmux-tui protocol 11; this client requires protocol 12; restart the cmux-tui server"
    );
}

#[test]
fn protocol_12_identity_with_guarded_pointer_capability_is_accepted() {
    validate_remote_identity(&json!({
        "app": "cmux-tui",
        "protocol": 12,
        "capabilities": ["browser-pointer-frame-guard-v1"],
    }))
    .unwrap();
}

#[test]
fn clear_history_requires_its_additive_capability() {
    let without = identity_capabilities(&json!({
        "capabilities": ["attach-initial-size", "workspace-registry-v1"]
    }));
    let error =
        require_capability(&without, CLEAR_HISTORY_CAPABILITY, "clear-history").unwrap_err();
    assert_eq!(
        error.to_string(),
        "remote server does not support clear-history; restart the cmux-tui server"
    );

    let with = identity_capabilities(&json!({
        "capabilities": ["clear-history-v1"]
    }));
    require_capability(&with, CLEAR_HISTORY_CAPABILITY, "clear-history").unwrap();
    let error =
        require_capability(&with, CLEAR_HISTORY_KEY_CAPABILITY, "clear-history").unwrap_err();
    assert_eq!(error.to_string(), CLEAR_HISTORY_UNSUPPORTED_ERROR);

    let with_key_fallback = identity_capabilities(&json!({
        "capabilities": ["clear-history-v1", "clear-history-key-v1"]
    }));
    require_capability(&with_key_fallback, CLEAR_HISTORY_KEY_CAPABILITY, "clear-history").unwrap();
}

#[test]
fn protocol_12_identity_is_accepted() {
    validate_remote_identity(&json!({"app": "cmux-tui", "protocol": 12})).unwrap();
}

#[test]
fn malformed_identity_capabilities_are_rejected() {
    for capabilities in [json!(null), json!("clear-history-v1"), json!(["ok", 1])] {
        assert!(
            validate_remote_identity(&json!({
                "app": "cmux-tui", "protocol": 12, "capabilities": capabilities,
            }))
            .is_err()
        );
    }
}

#[test]
fn disabled_frame_logging_does_not_format_hot_path_messages() {
    struct FormattingProbe(Arc<AtomicBool>);

    impl std::fmt::Display for FormattingProbe {
        fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            self.0.store(true, Ordering::Relaxed);
            formatter.write_str("formatted")
        }
    }

    let formatted = Arc::new(AtomicBool::new(false));
    let session = super::super::test_session_with_provider_context(None, HashSet::new());

    session.log_frame(7, format_args!("{}", FormattingProbe(formatted.clone())));

    assert!(!formatted.load(Ordering::Relaxed));
    assert!(session.frame_logs.lock().unwrap().entries.is_empty());
}

#[test]
fn frame_logging_evicts_oldest_entries_to_stay_within_both_limits() {
    let mut logs = RemoteFrameLogs::default();
    for line in ["first", "second", "third"] {
        logs.push_with_limits(7, line.into(), 2, 100);
    }
    assert_eq!(
        logs.entries.iter().map(|entry| entry.line.as_str()).collect::<Vec<_>>(),
        ["second", "third"]
    );

    let mut byte_bounded = RemoteFrameLogs::default();
    byte_bounded.push_with_limits(7, "1234".into(), 10, 8);
    byte_bounded.push_with_limits(7, "5678".into(), 10, 8);
    assert_eq!(byte_bounded.bytes, 5);
    assert_eq!(byte_bounded.entries.front().unwrap().line, "5678");
}

#[test]
fn partial_message_progress_targets_only_its_request_or_attach() {
    assert_eq!(
        remote_progress_target(br#"{"id":41,"ok":true,"data":"partial"#),
        Some(RemoteProgressTarget::Request(41))
    );
    assert_eq!(
        remote_progress_target(br#"{"event":"vt-state","surface":7,"cols":80,"data":"partial"#),
        Some(RemoteProgressTarget::AttachSurface(7))
    );
    assert_eq!(
        remote_progress_target(br#"{"event":"browser-state","surface":8,"frame":{"data":"partial"#),
        Some(RemoteProgressTarget::AttachSurface(8))
    );
    assert_eq!(
        remote_progress_target(br#"{"event":"output","surface":7,"id":41,"data":"partial"#),
        None
    );
    assert_eq!(remote_progress_target(br#"{"id":41"#), None);
}

#[test]
fn json_line_reader_rejects_oversized_frames_before_buffering_them() {
    let mut reader = BufReader::with_capacity(4, io::Cursor::new(b"123456789\n".to_vec()));
    let mut largest_progress = 0;
    let error = read_json_line_with_progress_bounded(
        &mut reader,
        &mut |partial| largest_progress = largest_progress.max(partial.len()),
        8,
    )
    .unwrap_err();

    assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    assert_eq!(error.to_string(), "remote session message exceeds the 8-byte limit");
    assert!(largest_progress <= 8);
}

#[test]
fn json_line_reader_accepts_a_frame_at_the_exact_limit() {
    let mut reader = BufReader::with_capacity(3, io::Cursor::new(b"12345678\n".to_vec()));

    let line = read_json_line_with_progress_bounded(&mut reader, &mut |_| {}, 8).unwrap().unwrap();

    assert_eq!(line, "12345678");
}

#[test]
fn json_line_reader_preserves_an_empty_delimited_frame() {
    let mut reader = BufReader::new(io::Cursor::new(b"\n".to_vec()));

    let line = read_json_line_with_progress_bounded(&mut reader, &mut |_| {}, 8).unwrap().unwrap();

    assert!(line.is_empty());
}

#[test]
fn browser_frame_parses_image_dimensions_with_legacy_fallback() {
    let frame = parse_browser_frame(&json!({
        "seq": 1,
        "width": 800,
        "height": 600,
        "image_width": 400,
        "image_height": 300,
        "data": "frame",
    }))
    .unwrap()
    .frame;
    assert_eq!((frame.css_width, frame.css_height), (800, 600));
    assert_eq!((frame.image_width, frame.image_height), (400, 300));

    let legacy = parse_browser_frame(&json!({
        "seq": 2,
        "width": 320,
        "height": 200,
        "data": "legacy",
    }))
    .unwrap()
    .frame;
    assert_eq!((legacy.image_width, legacy.image_height), (320, 200));
}

#[test]
fn raw_output_decscusr_authors_cursor_and_daemon_replay_resets_provenance() {
    let (session, surface) = test_unleased_view_surface(7);
    assert!(!surface.cursor_style_authored(), "defaults are never authored");

    // Raw inner-PTY output authors the cursor style.
    let encoded = base64::engine::general_purpose::STANDARD.encode(b"\x1b[5 q");
    session.handle_line(json!({"event": "output", "surface": 7, "data": encoded}));
    assert!(surface.cursor_style_authored());

    // The application resetting to the default clears authorship.
    let encoded = base64::engine::general_purpose::STANDARD.encode(b"\x1b[0 q");
    session.handle_line(json!({"event": "output", "surface": 7, "data": encoded}));
    assert!(!surface.cursor_style_authored());

    // A daemon-built vt-state replay carries resolved state with the
    // session defaults baked in, so it must never count as authored,
    // even when the replay bytes contain DECSCUSR.
    surface.scan_cursor_provenance(b"\x1b[6 q");
    assert!(surface.cursor_style_authored());
    surface
        .apply_stream_resize_with_colors(80, 24, Some(b"\x1b[5 q"), &[], None, None, &[])
        .unwrap();
    assert!(!surface.cursor_style_authored());
}
