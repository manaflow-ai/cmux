//! Lock-order tests. The documented order is mux state -> PTY geometry ->
//! terminal -> render/taps; no surface path may hold the terminal lock while
//! it calls back into the mux.

use super::*;

/// Reproduces the frame/reader/resize/render cycle from the surface split
/// report with a forced interleaving: the frame path reaches its mux output
/// event while a mux thread holds the state lock, then a resize, a per-view
/// render and that mux thread's `size()` read run against it. All four must
/// finish; with the terminal lock held across the output event they deadlock.
#[test]
fn frame_output_event_resize_render_and_mux_size_read_never_form_a_lock_cycle() {
    const WAIT: Duration = Duration::from_secs(10);
    let mux = Mux::new_for_test("surface-lock-order", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    let (cols, rows) = surface.size();

    let (at_output_event_tx, at_output_event_rx) = std::sync::mpsc::channel();
    let at_output_event_tx = Mutex::new(Some(at_output_event_tx));
    *pty.geometry_test_hook.lock().unwrap() = Some(Arc::new(move |step| {
        if step == PtyGeometryTestStep::OutputEventStarted
            && let Some(tx) = at_output_event_tx.lock().unwrap().take()
        {
            tx.send(()).unwrap();
        }
    }));

    let (done_tx, done_rx) = std::sync::mpsc::channel::<&'static str>();

    // Mux thread: holds the state lock, then reads the surface geometry, as
    // the mux projections do (state -> geometry).
    let (state_held_tx, state_held_rx) = std::sync::mpsc::channel();
    let (read_size_tx, read_size_rx) = std::sync::mpsc::channel::<()>();
    let mux_reader = std::thread::spawn({
        let mux = mux.clone();
        let surface = surface.clone();
        let done = done_tx.clone();
        move || {
            let state = mux.state.lock().unwrap();
            state_held_tx.send(()).unwrap();
            read_size_rx.recv().unwrap();
            let _ = surface.size();
            drop(state);
            done.send("mux reader").unwrap();
        }
    });
    state_held_rx.recv_timeout(WAIT).unwrap();

    // Frame path: a producer-driven frame publishes SurfaceOutput, which
    // needs the mux state lock held above.
    pty.dirty.store(false, Ordering::Release);
    let frame = std::thread::spawn({
        let surface = surface.clone();
        let done = done_tx.clone();
        move || {
            surface.as_pty().unwrap().publish_final_frame();
            done.send("frame").unwrap();
        }
    });
    at_output_event_rx.recv_timeout(WAIT).expect("frame path reached its output event");

    // Resize path: geometry, then terminal.
    let resize = std::thread::spawn({
        let surface = surface.clone();
        let done = done_tx.clone();
        move || {
            surface.resize(cols + 7, rows + 3).unwrap();
            done.send("resize").unwrap();
        }
    });
    // Let the resize take the geometry lock (or finish) before the mux
    // thread reads the size, so the cycle is forced when it exists.
    let deadline = Instant::now() + WAIT;
    let mut finished = Vec::new();
    loop {
        if let Ok(name) = done_rx.try_recv() {
            finished.push(name);
            if name == "resize" {
                break;
            }
        }
        if matches!(pty.geometry.try_lock(), Err(TryLockError::WouldBlock)) {
            break;
        }
        assert!(Instant::now() < deadline, "resize neither took geometry nor finished");
        std::thread::yield_now();
    }

    // Render path: a per-view frame takes the terminal lock.
    let render = std::thread::spawn({
        let surface = surface.clone();
        let done = done_tx.clone();
        move || {
            let mut state = RenderState::new().unwrap();
            let _ = surface.render_view_frame(&mut state);
            done.send("render").unwrap();
        }
    });
    read_size_tx.send(()).unwrap();
    drop(done_tx);

    let deadline = Instant::now() + WAIT;
    while finished.len() < 4 {
        match done_rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(name) => finished.push(name),
            Err(_) => panic!(
                "surface lock cycle: only {finished:?} finished. The frame path holds the \
                 terminal lock while it waits for mux state, the resize holds geometry while \
                 it waits for the terminal, and the mux reader holds state while it waits for \
                 geometry"
            ),
        }
    }
    for thread in [mux_reader, frame, resize, render] {
        thread.join().unwrap();
    }
    assert_eq!(surface.size(), (cols + 7, rows + 3));
    // The surface holds only a weak mux; keep it alive until every path ran.
    drop(mux);
}
