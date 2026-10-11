//! Surface resize and cell pixel geometry transactions.

use super::*;

struct CellPixelFanoutWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
    fail_next: bool,
    deferred_failure: bool,
}

impl RemoteMessageWriter for CellPixelFanoutWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
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
            Some("set-cell-pixels") if std::mem::take(&mut self.fail_next) => {
                json!({
                    "resizes": [],
                    "failures": [{
                        "surface": 7,
                        "error": "injected fan-out failure",
                        "deferred": self.deferred_failure,
                    }],
                })
            }
            Some("set-cell-pixels") => json!({"resizes": [], "failures": []}),
            Some("attach-surface") => Value::Null,
            command => {
                return Err(io::Error::other(format!("unexpected test command: {command:?}")));
            }
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

struct AmbiguousCellPixelWriter {
    session: Arc<Mutex<Option<Weak<RemoteSession>>>>,
}

impl RemoteMessageWriter for AmbiguousCellPixelWriter {
    fn send(&mut self, message: &str) -> io::Result<()> {
        let request: Value = serde_json::from_str(message).map_err(io::Error::other)?;
        if request.get("cmd").and_then(Value::as_str) == Some("set-cell-pixels") {
            return Ok(());
        }
        if request.get("cmd").and_then(Value::as_str) != Some("get-cell-pixels") {
            return Err(io::Error::other("unexpected ambiguous cell-pixel test command"));
        }
        let id = request
            .get("id")
            .and_then(Value::as_u64)
            .ok_or_else(|| io::Error::other("remote request omitted its id"))?;
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
        response
            .response
            .send(json!({
                "id": id,
                "ok": true,
                "data": {
                    "width_px": 10,
                    "height_px": 20,
                    "surfaces": [{
                        "surface": 7,
                        "width_px": 11,
                        "height_px": 22,
                    }],
                },
            }))
            .map_err(|_| io::Error::other("remote response receiver was dropped"))
    }

    fn close(&mut self) -> io::Result<()> {
        Ok(())
    }
}

#[test]
fn stream_resize_without_pixel_dimensions_preserves_last_cell_measurement() {
    let surface = test_remote_pty_surface(1, 80, 24, (8, 16));
    surface.set_cell_pixel_size(11, 19).unwrap();

    surface.apply_stream_resize(90, 31, None, &[]).unwrap();

    assert_eq!(*surface.cell_pixels.lock().unwrap(), (11, 19));
    let term = surface.term.lock().unwrap();
    assert_eq!((term.cols(), term.rows()), (90, 31));
}

#[test]
fn rejected_cell_pixel_request_rolls_back_session_and_mirror_geometry() {
    let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
    let session = test_session(Box::new(RejectingWriter { session: session_slot.clone() }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
    session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

    let error = session.set_cell_pixel_size(9, 18).err().expect("injected rejection must fail");

    assert!(matches!(
        error.downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::Rejected {
            error,
            delivery: None,
            ..
        }) if error == "injected rejection"
    ));
    assert_eq!(*session.cell_pixels.lock().unwrap(), (8, 16));
    assert_eq!(*surface.cell_pixels.lock().unwrap(), (8, 16));
}

#[test]
fn timed_out_cell_pixel_request_preserves_session_and_mirror_geometry() {
    let session = test_session(Box::new(SilentWriter));
    let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
    session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

    let error = session.set_cell_pixel_size(9, 18).err().expect("silent remote must time out");

    assert!(matches!(
        error.downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::Timeout)
    ));
    assert_eq!(*session.cell_pixels.lock().unwrap(), (9, 18));
    assert_eq!(*surface.cell_pixels.lock().unwrap(), (9, 18));
    assert!(session.pending.lock().unwrap().is_empty());
}

#[test]
fn ambiguous_cell_pixel_timeout_does_not_overwrite_the_requested_geometry() {
    let session = test_session(Box::new(SilentWriter));
    let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
    session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

    let error = session.set_cell_pixel_size(9, 18).err().expect("silent remote must time out");

    assert!(matches!(
        error.downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::Timeout)
    ));
    assert_eq!(
        *session.cell_pixels.lock().unwrap(),
        (9, 18),
        "an ambiguous timeout restored a stale global geometry mirror"
    );
    assert_eq!(
        *surface.cell_pixels.lock().unwrap(),
        (9, 18),
        "an ambiguous timeout overwrote geometry that the server may have committed"
    );
}

#[test]
fn ambiguous_cell_pixel_timeout_reconciles_from_an_ordered_server_query() {
    let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
    let session =
        test_session(Box::new(AmbiguousCellPixelWriter { session: session_slot.clone() }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
    session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

    let error = session.set_cell_pixel_size(9, 18).err().expect("first reply must be lost");

    assert!(matches!(
        error.downcast_ref::<RemoteRequestError>(),
        Some(RemoteRequestError::Timeout)
    ));
    assert_eq!(*session.cell_pixels.lock().unwrap(), (10, 20));
    assert_eq!(*surface.cell_pixels.lock().unwrap(), (11, 22));
    assert!(session.pending.lock().unwrap().is_empty());
}

#[test]
fn partial_cell_pixel_fanout_retries_before_publishing_the_remote_default() {
    let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
    let session = test_session(Box::new(CellPixelFanoutWriter {
        session: session_slot.clone(),
        fail_next: true,
        deferred_failure: false,
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
    session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

    let first = session.set_cell_pixel_size(9, 18).unwrap();
    assert_eq!(first.failures, vec![(7, "injected fan-out failure".to_string())]);
    assert_eq!(*session.cell_pixels.lock().unwrap(), (8, 16));
    assert_eq!(*surface.cell_pixels.lock().unwrap(), (8, 16));

    let retried = session.set_cell_pixel_size(9, 18).unwrap();
    assert!(retried.failures.is_empty());
    assert_eq!(*session.cell_pixels.lock().unwrap(), (9, 18));
    assert_eq!(*surface.cell_pixels.lock().unwrap(), (9, 18));
}

#[test]
fn deferred_cell_pixel_failure_preserves_target_for_late_resize() {
    let session_slot: Arc<Mutex<Option<Weak<RemoteSession>>>> = Arc::new(Mutex::new(None));
    let session = test_session(Box::new(CellPixelFanoutWriter {
        session: session_slot.clone(),
        fail_next: true,
        deferred_failure: true,
    }));
    *session_slot.lock().unwrap() = Some(Arc::downgrade(&session));
    let surface = test_remote_pty_surface(7, 80, 24, (8, 16));
    session.surfaces.lock().unwrap().insert(surface.id, surface.clone());

    let update = session.set_cell_pixel_size(9, 18).unwrap();
    assert_eq!(update.failures, vec![(7, "injected fan-out failure".to_string())]);
    surface.apply_stream_resize(90, 31, None, &[]).unwrap();
    let created = attached_surface(
        session.try_ensure_surface_with_kind(8, SurfaceKind::Pty, Some((80, 24))).unwrap(),
    );

    assert_eq!(
        surface.cell_pixel_size(),
        (9, 18),
        "a late authoritative resize used the geometry from before the deferred request"
    );
    assert_eq!(
        created.cell_pixel_size(),
        (9, 18),
        "a newly discovered surface used the geometry from before the deferred request"
    );
}

#[test]
fn resize_replay_replaces_mirror_with_server_truth_without_duplication() {
    let mut server = Terminal::new(12, 4, 100, Callbacks::default()).unwrap();
    for i in 0..12 {
        server.vt_write(format!("srv{i:02}\r\n").as_bytes());
    }
    server.resize(8, 4, 8, 16).unwrap();
    let server_text = server.plain_text().unwrap();
    let server_oldest = server.selection_text_absolute((0, 0), (4, 0)).unwrap();
    assert_eq!(server_oldest, "srv00");
    let replay = server.vt_replay_bytes().unwrap();

    let surface = RemoteSurface {
        id: 1,
        kind: SurfaceKind::Pty,
        term: Mutex::new(Terminal::new(20, 6, 100, Callbacks::default()).unwrap()),
        mouse_encoders: Mutex::new(MouseEncoders::new().unwrap()),
        cursor_provenance: Mutex::new(CursorStyleProvenance::default()),
        dirty: AtomicBool::new(false),
        geometry_lifecycle: Mutex::new(()),
        cell_pixels: Mutex::new((8, 16)),
        geometry_test_hook: Mutex::new(None),
        content_generation: AtomicU64::new(1),
        reported_size: Mutex::new(None),
        browser: Mutex::new(RemoteBrowserState::default()),
    };
    {
        let mut mirror = surface.term.lock().unwrap();
        mirror.vt_write(b"mirror-only\r\nstate\r\n");
    }

    surface.apply_stream_resize(8, 4, Some(&replay), &[]).unwrap();
    let scrollback_rows = {
        let mut mirror = surface.term.lock().unwrap();
        assert_eq!(mirror.plain_text().unwrap(), server_text);
        assert_eq!(mirror.selection_text_absolute((0, 0), (4, 0)).unwrap(), server_oldest);
        mirror.scrollback_rows()
    };

    surface.apply_stream_resize(8, 4, Some(&replay), &[]).unwrap();
    let mut mirror = surface.term.lock().unwrap();
    assert_eq!(mirror.plain_text().unwrap(), server_text);
    assert_eq!(mirror.scrollback_rows(), scrollback_rows);
}
