//! Byte attach mirror tests: output merging, mirrors joining mid-sequence,
//! resize replays, and theme-portable replay payloads.

use super::*;

#[test]
fn slow_attach_coalesces_adjacent_output_without_losing_bytes() {
    let mux = Mux::new_for_test("attach-output-coalescing", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let attach = surface.attach_stream().unwrap();
    let pty = surface.as_pty().unwrap();
    let expected =
        (0..ATTACH_STREAM_CAPACITY * 4).map(|index| (index % 251) as u8).collect::<Vec<_>>();

    for (index, byte) in expected.iter().copied().enumerate() {
        assert!(
            pty.broadcast_attach_output(&[byte]),
            "lossless attach disconnected at small output chunk {index}"
        );
    }

    assert!(!attach.lifecycle.overflowed());
    let mut received = Vec::new();
    while let Ok(frame) = attach.stream.try_recv() {
        match frame {
            AttachFrame::Output(bytes) => received.extend(bytes),
            other => panic!("unexpected frame in output-only stream: {other:?}"),
        }
    }
    assert_eq!(received, expected);
}

/// Streaming output that crosses every kind of parser state a byte mirror
/// can join in the middle of: CSI, OSC (BEL and ST), OSC 8, DCS, APC, and
/// multi-byte UTF-8.
const MIRROR_TRANSCRIPT: &[u8] = concat!(
    "before λ 🙂 ",
    "\u{1b}[1;31mstyled 赤\u{1b}[0m ",
    "\u{1b}]0;title λ\u{1b}\\",
    "\u{1b}]8;;https://example.com\u{7}link\u{1b}]8;;\u{7} ",
    "\u{1b}P$qm\u{1b}\\",
    "\u{1b}_ignored\u{1b}\\",
    "\u{1b}[3;7H\u{1b}[38;2;10;20;30mrgb\u{1b}[m",
    "\r\n\u{1b}[Kafter"
)
.as_bytes();

/// Models the native Cloud pane with its grid pinned to the daemon: a byte
/// mirror that rebuilds from every replay at the advertised grid, writes
/// its color sidecar after the replay the way the pane does, and then
/// follows the live byte stream.
struct PinnedByteMirror {
    term: Terminal,
    attach: AttachStream,
    replay_ended_mid_sequence: bool,
    /// Grid replacements (`Resized`) this mirror rebuilt from.
    replays: usize,
}

impl PinnedByteMirror {
    fn attach(surface: &Surface) -> Self {
        let attach = surface.attach_stream().unwrap();
        let mut replay_ended_mid_sequence = false;
        let term = Self::from_replay(
            attach.cols,
            attach.rows,
            &attach.replay,
            &attach.pending_sequence,
            &mut replay_ended_mid_sequence,
        );
        Self { term, attach, replay_ended_mid_sequence, replays: 0 }
    }

    fn from_replay(
        cols: u16,
        rows: u16,
        replay: &[u8],
        pending_sequence: &[u8],
        replay_ended_mid_sequence: &mut bool,
    ) -> Terminal {
        let mut term = Terminal::new(cols, rows, 1000, Callbacks::default()).unwrap();
        term.vt_write(replay);
        // The pane appends color sequences here, which is only safe at a
        // parser boundary.
        *replay_ended_mid_sequence |= !term.vt_stream_is_ground();
        term.vt_write(pending_sequence);
        term
    }

    fn drain(&mut self) {
        while let Ok(frame) = self.attach.stream.try_recv() {
            match frame {
                AttachFrame::Output(output)
                | AttachFrame::FlowOutput { output, .. }
                | AttachFrame::OutputWithColors { output, .. } => self.term.vt_write(&output),
                AttachFrame::Resized { cols, rows, replay, pending_sequence, .. }
                | AttachFrame::ResizedWithColors { cols, rows, replay, pending_sequence, .. } => {
                    self.replays += 1;
                    self.term = Self::from_replay(
                        cols,
                        rows,
                        &replay,
                        &pending_sequence,
                        &mut self.replay_ended_mid_sequence,
                    );
                }
                AttachFrame::ColorsChanged(_) => {}
            }
        }
    }

    /// Returns a description of every way this mirror differs from the
    /// authoritative terminal.
    fn divergence(&mut self, surface: &Surface) -> Option<String> {
        let disconnected = self.attach.lifecycle.is_canceled();
        self.drain();
        let pty = surface.as_pty().unwrap();
        let mut source = pty.term.lock().unwrap();
        let grid = (source.cols(), source.rows());
        let mirror_grid = (self.term.cols(), self.term.rows());
        let text = source.viewport_text().unwrap();
        let mirror_text = self.term.viewport_text().unwrap();
        let cursor = source.cursor_position();
        let mirror_cursor = self.term.cursor_position();
        let mid_sequence = self.replay_ended_mid_sequence;
        (disconnected
            || mid_sequence
            || grid != mirror_grid
            || text != mirror_text
            || cursor != mirror_cursor)
            .then(|| {
                format!(
                    "disconnected={disconnected} replay_ended_mid_sequence={mid_sequence} \
                     grid={grid:?}/{mirror_grid:?} cursor={cursor:?}/{mirror_cursor:?} \
                     text={text:?} mirror={mirror_text:?}"
                )
            })
    }
}

fn mirror_test_surface(mux: &Arc<Mux>) -> Arc<Surface> {
    let options = SurfaceOptions { cols: 80, rows: 10, ..SurfaceOptions::default() };
    Surface::spawn_for_test(1, options, Arc::downgrade(mux)).unwrap()
}

#[test]
fn byte_mirror_attached_inside_any_sequence_matches_the_terminal() {
    let mux = Mux::new_for_test("mirror-attach-mid-sequence", SurfaceOptions::default());
    let mut failures = Vec::new();
    for split in 0..=MIRROR_TRANSCRIPT.len() {
        let surface = mirror_test_surface(&mux);
        surface.apply_local_pty_output_for_test(&MIRROR_TRANSCRIPT[..split]).unwrap();
        let mut mirror = PinnedByteMirror::attach(&surface);
        surface.apply_local_pty_output_for_test(&MIRROR_TRANSCRIPT[split..]).unwrap();
        if let Some(divergence) = mirror.divergence(&surface) {
            failures.push(format!("attach at byte {split}: {divergence}"));
        }
    }
    assert!(failures.is_empty(), "byte mirror diverged:\n{}", failures.join("\n"));
}

#[test]
fn byte_mirror_survives_owner_resize_inside_any_sequence() {
    let mux = Mux::new_for_test("mirror-resize-mid-sequence", SurfaceOptions::default());
    let mut failures = Vec::new();
    for split in 0..=MIRROR_TRANSCRIPT.len() {
        let surface = mirror_test_surface(&mux);
        let mut mirror = PinnedByteMirror::attach(&surface);
        surface.apply_local_pty_output_for_test(&MIRROR_TRANSCRIPT[..split]).unwrap();
        surface.resize(100, 30).unwrap();
        surface.apply_local_pty_output_for_test(&MIRROR_TRANSCRIPT[split..]).unwrap();
        if let Some(divergence) = mirror.divergence(&surface) {
            failures.push(format!("resize at byte {split}: {divergence}"));
        }
    }
    assert!(failures.is_empty(), "byte mirror diverged:\n{}", failures.join("\n"));
}

/// A released client writes its color sequences right after a resize
/// replay, so a replay ending inside a sequence would put them inside it.
/// Those viewers keep the old behavior: they reconnect from a fresh
/// snapshot. Viewers that advertised pending-sequence support stay.
#[test]
fn resize_inside_a_sequence_disconnects_only_viewers_without_pending_support() {
    let mux = Mux::new_for_test("mirror-resize-legacy-viewer", SurfaceOptions::default());
    let surface = mirror_test_surface(&mux);
    let mut capable = PinnedByteMirror::attach(&surface);
    let legacy_lifecycle = AttachLifecycle::default();
    legacy_lifecycle.set_resumes_pending_sequence(false);
    let _legacy = surface.attach_stream_with_lifecycle(legacy_lifecycle.clone()).unwrap();

    surface.apply_local_pty_output_for_test(b"\x1b[1;3").unwrap();
    surface.resize(100, 30).unwrap();
    assert!(legacy_lifecycle.is_canceled(), "a legacy viewer kept a mid-sequence replay");
    surface.apply_local_pty_output_for_test(b"1mred").unwrap();
    assert_eq!(capable.divergence(&surface), None);
}

/// Several people view one terminal at different sizes. Viewers join at
/// arbitrary stream positions while geometry ownership moves between them,
/// and every viewer must still show exactly the authoritative screen.
#[test]
fn byte_mirrors_joining_during_owner_churn_converge_on_the_terminal() {
    let mux = Mux::new_for_test("mirror-owner-churn", SurfaceOptions::default());
    let transcript = [MIRROR_TRANSCRIPT, MIRROR_TRANSCRIPT].concat();
    let owner_grids = [(45, 20), (132, 40), (80, 24)];
    let mut failures = Vec::new();
    for split in 0..=MIRROR_TRANSCRIPT.len() {
        let surface = mirror_test_surface(&mux);
        let mut first = PinnedByteMirror::attach(&surface);
        surface.apply_local_pty_output_for_test(&transcript[..split]).unwrap();
        let mut second = PinnedByteMirror::attach(&surface);
        surface.resize(owner_grids[0].0, owner_grids[0].1).unwrap();
        let middle = split + MIRROR_TRANSCRIPT.len() / 2;
        surface.apply_local_pty_output_for_test(&transcript[split..middle]).unwrap();
        let mut third = PinnedByteMirror::attach(&surface);
        surface.resize(owner_grids[1].0, owner_grids[1].1).unwrap();
        surface.resize(owner_grids[2].0, owner_grids[2].1).unwrap();
        surface.apply_local_pty_output_for_test(&transcript[middle..]).unwrap();
        for (name, mirror) in
            [("first", &mut first), ("second", &mut second), ("third", &mut third)]
        {
            if let Some(divergence) = mirror.divergence(&surface) {
                failures.push(format!("{name} viewer, split {split}: {divergence}"));
            }
        }
    }
    assert!(failures.is_empty(), "byte mirrors diverged:\n{}", failures.join("\n"));
}

/// Steps of one resize burst (a divider drag or a window resize).
const RESIZE_BURST_STEPS: u16 = 24;

/// A divider drag or a window resize reaches the terminal as a burst of
/// geometry steps, with output between them. A byte mirror must be rebuilt
/// once for the burst, at its final grid, from one replay that also covers
/// the output of the burst: not one full replay per step, built under the
/// locks the reader and the frame path need (cmux-ad H10).
#[test]
fn resize_burst_builds_one_byte_mirror_replay_at_the_final_grid() {
    let mux = Mux::new_for_test("mirror-resize-burst", SurfaceOptions::default());
    let surface = mirror_test_surface(&mux);
    let pty = surface.as_pty().unwrap();
    let mut mirror = PinnedByteMirror::attach(&surface);
    surface.apply_local_pty_output_for_test(MIRROR_TRANSCRIPT).unwrap();
    pty.vt_replay_builds.store(0, Ordering::Release);

    for step in 0..RESIZE_BURST_STEPS {
        assert!(surface.resize(81 + step, 11 + step / 2).unwrap());
        surface.apply_local_pty_output_for_test(format!("step {step}\r\n").as_bytes()).unwrap();
    }

    assert_eq!(mirror.divergence(&surface), None);
    assert_eq!(
        (pty.vt_replay_builds.load(Ordering::Acquire), mirror.replays),
        (1, 1),
        "a burst of {RESIZE_BURST_STEPS} resize steps must build and send one byte-mirror \
         replay (builds, replays received)"
    );
}

/// A live resize (a divider drag or a window resize the app marks live)
/// builds no byte-mirror replay while it runs, even for a mirror that keeps
/// up and takes every frame between the steps; its end builds one, at the
/// final grid (Chrome coalesces resize to the frame and settles at the end;
/// lead decision 2026-10-28 on H10's drag case: 13 replays per drag, ~23 ms
/// per step).
#[test]
fn a_live_resize_builds_no_mirror_replay_until_it_ends() {
    let mux = Mux::new_for_test("mirror-live-resize", SurfaceOptions::default());
    let surface = mirror_test_surface(&mux);
    let pty = surface.as_pty().unwrap();
    let mut mirror = PinnedByteMirror::attach(&surface);
    surface.apply_local_pty_output_for_test(MIRROR_TRANSCRIPT).unwrap();
    mirror.drain();
    pty.vt_replay_builds.store(0, Ordering::Release);

    surface.set_live_resize(true);
    for step in 0..RESIZE_BURST_STEPS {
        assert!(surface.resize(81 + step, 11 + step / 2).unwrap());
        surface.apply_local_pty_output_for_test(format!("step {step}\r\n").as_bytes()).unwrap();
        // The mirror keeps up: it takes every frame between the steps.
        mirror.drain();
    }
    assert_eq!(
        (pty.vt_replay_builds.load(Ordering::Acquire), mirror.replays),
        (0, 0),
        "a live resize built mirror replays while it ran (builds, replays received)"
    );

    surface.set_live_resize(false);
    assert_eq!(mirror.divergence(&surface), None);
    assert_eq!(
        (pty.vt_replay_builds.load(Ordering::Acquire), mirror.replays),
        (1, 1),
        "the end of a live resize must build one replay, at the final grid"
    );
}

/// A live resize whose end never comes (the app crashed mid-drag, its
/// connection closed) settles on its own: the mirror is not left on the old
/// grid forever.
#[test]
fn a_live_resize_without_its_end_settles_after_its_deadline() {
    let mux = Mux::new_for_test("mirror-live-resize-deadline", SurfaceOptions::default());
    let surface = mirror_test_surface(&mux);
    let mut mirror = PinnedByteMirror::attach(&surface);
    surface.set_live_resize(true);
    assert!(surface.resize(90, 15).unwrap());
    let deadline = Instant::now() + LIVE_RESIZE_SETTLE + Duration::from_secs(5);
    loop {
        mirror.drain();
        if mirror.replays == 1 {
            break;
        }
        assert!(Instant::now() < deadline, "a live resize with no end never settled");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(mirror.divergence(&surface), None);
}

/// A terminal of 120x40 with 10k colored lines of scrollback, for the bench.
fn deep_history_surface(mux: &Arc<Mux>, id: SurfaceId) -> Arc<Surface> {
    let options = SurfaceOptions {
        cols: 120,
        rows: 40,
        scrollback: 64 * 1024 * 1024,
        ..SurfaceOptions::default()
    };
    let surface = Surface::spawn_for_test(id, options, Arc::downgrade(mux)).unwrap();
    let mut history = Vec::new();
    for line in 0..10_000 {
        let color = line % 8;
        history.extend_from_slice(
            format!(
                "\x1b[3{color}mline {line:05}\x1b[m the quick brown fox jumps over the dog\r\n"
            )
            .as_bytes(),
        );
    }
    surface.apply_local_pty_output_for_test(&history).unwrap();
    surface
}

fn percentiles(samples: &mut [Duration]) -> String {
    samples.sort();
    let at = |p: usize| samples[(samples.len() * p / 100).min(samples.len() - 1)];
    format!("p50 {:?} p95 {:?} max {:?}", at(50), at(95), at(100))
}

/// Bench (cmux-ad H10): resize bursts over a terminal with 10k lines of
/// scrollback and one byte mirror attached. Run with `cargo test -p
/// cmux-tui-core --lib -- --ignored --nocapture
/// resize_burst_terminal_lock_hold_bench`.
///
/// - burst: 24 steps back to back, then the mirror takes its frames (a view
///   that is busy, or whose connection is full, during the burst).
/// - drag: a 120 Hz drag (a step every 8 ms) while another thread takes the
///   mirror's frames as they come (a view that keeps up).
///
/// - build: one replay of that terminal, built under the terminal lock.
///
/// Each prints the replays built per burst and how long each resize step
/// takes (it holds the terminal lock throughout; in the drag it may first
/// wait for the lock while the view builds a replay).
#[test]
#[ignore = "bench: prints lock hold times, asserts nothing"]
fn resize_burst_terminal_lock_hold_bench() {
    const BURSTS: u16 = 5;
    const STEP_INTERVAL: Duration = Duration::from_millis(8);
    let mux = Mux::new_for_test("mirror-resize-burst-bench", SurfaceOptions::default());
    let grid = |burst: u16, step: u16| (100 + step + (burst % 2) * RESIZE_BURST_STEPS, 40);

    let surface = deep_history_surface(&mux, 1);
    let pty = surface.as_pty().unwrap();
    let mut mirror = PinnedByteMirror::attach(&surface);
    pty.vt_replay_builds.store(0, Ordering::Release);
    let (mut steps, mut takes) = (Vec::new(), Vec::new());
    for burst in 0..BURSTS {
        for step in 0..RESIZE_BURST_STEPS {
            let (cols, rows) = grid(burst, step);
            let started = Instant::now();
            surface.resize(cols, rows).unwrap();
            steps.push(started.elapsed());
        }
        let started = Instant::now();
        mirror.drain();
        takes.push(started.elapsed());
    }
    let builds = pty.vt_replay_builds.load(Ordering::Acquire);
    eprintln!(
        "resize burst bench [burst]: {BURSTS} bursts of {RESIZE_BURST_STEPS} steps: replay \
         builds {builds} ({:.1} per burst); resize step {}; mirror take after the burst {}; \
         mirror diverged: {}",
        builds as f64 / f64::from(BURSTS),
        percentiles(&mut steps),
        percentiles(&mut takes),
        mirror.divergence(&surface).is_some(),
    );
    let mut builds = (0..10)
        .map(|_| {
            let mut term = pty.term.lock().unwrap();
            let started = Instant::now();
            term.vt_replay_bounded_theme_portable_with_aliases(VT_REPLAY_MAX_BYTES).unwrap();
            started.elapsed()
        })
        .collect::<Vec<_>>();
    eprintln!("resize burst bench [build]: one replay build {}", percentiles(&mut builds));

    let surface = deep_history_surface(&mux, 2);
    let pty = surface.as_pty().unwrap();
    let attach = surface.attach_stream().unwrap();
    pty.vt_replay_builds.store(0, Ordering::Release);
    let done = Arc::new(AtomicBool::new(false));
    let view = {
        let done = done.clone();
        std::thread::spawn(move || {
            let mut last_grid = None;
            loop {
                let finished = done.load(Ordering::Acquire);
                match attach.stream.recv_timeout(Duration::from_millis(5)) {
                    Ok(frame) => {
                        if let Some(resize) = frame.resize() {
                            last_grid = Some((resize.cols, resize.rows));
                        }
                    }
                    Err(_) if finished => break,
                    Err(_) => {}
                }
            }
            (last_grid, attach.lifecycle.is_canceled())
        })
    };
    let (mut steps, mut final_grid) = (Vec::new(), (0, 0));
    for burst in 0..BURSTS {
        for step in 0..RESIZE_BURST_STEPS {
            final_grid = grid(burst, step);
            let started = Instant::now();
            surface.resize(final_grid.0, final_grid.1).unwrap();
            steps.push(started.elapsed());
            std::thread::sleep(STEP_INTERVAL.saturating_sub(started.elapsed()));
        }
        // The pause between two drags.
        std::thread::sleep(Duration::from_millis(100));
    }
    done.store(true, Ordering::Release);
    let (last_grid, disconnected) = view.join().unwrap();
    let builds = pty.vt_replay_builds.load(Ordering::Acquire);
    eprintln!(
        "resize burst bench [drag]: {BURSTS} bursts of {RESIZE_BURST_STEPS} steps every \
         {STEP_INTERVAL:?}: replay builds {builds} ({:.1} per burst); resize step {}; mirror's \
         last grid {last_grid:?} (final {final_grid:?}), disconnected {disconnected}",
        builds as f64 / f64::from(BURSTS),
        percentiles(&mut steps),
    );
}

fn bytes_contain(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

/// Byte mirrors (the native Cloud pane, `cmux-tui` remote views) render in
/// their own libghostty with their own theme. The attach replay must not
/// re-author this process's 256-entry palette or default fg/bg as OSC
/// state; only PTY-authored colors travel, in the sparse sidecar.
#[test]
fn byte_attach_replays_are_theme_portable_and_palette_rides_the_sidecar() {
    let mux = Mux::new("theme-portable-attach", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let pty = surface.as_pty().unwrap();
    pty.term.lock().unwrap().vt_write(b"\x1b]4;1;#112233\x07\x1b]10;#eeeeee\x07\x1b[31mred\x1b[m");
    let forbidden: [&[u8]; 4] = [b"\x1b]4;", b"\x1b]10;", b"\x1b]11;", b"\x1b]12;"];

    let attach = surface.attach_stream().unwrap();
    assert!(bytes_contain(&attach.replay, b"red"));
    for sequence in forbidden {
        assert!(
            !bytes_contain(&attach.replay, sequence),
            "attach replay pinned host colors with {sequence:?}"
        );
    }
    assert_eq!(attach.colors.palette[1], Some(Rgb { r: 0x11, g: 0x22, b: 0x33 }));
    assert_eq!(attach.colors.fg, Some(Rgb { r: 0xee, g: 0xee, b: 0xee }));
    assert!(
        attach
            .colors
            .palette
            .iter()
            .enumerate()
            .all(|(index, entry)| index == 1 || entry.is_none()),
        "unauthored palette entries must stay unset so the renderer keeps its theme"
    );

    surface.resize(100, 30).unwrap();
    let AttachFrame::ResizedWithColors { replay, colors, .. } =
        attach.stream.recv_timeout(Duration::from_secs(1)).unwrap()
    else {
        panic!("expected a resize replay with colors");
    };
    assert!(bytes_contain(&replay, b"red"));
    for sequence in forbidden {
        assert!(
            !bytes_contain(&replay, sequence),
            "resize replay pinned host colors with {sequence:?}"
        );
    }
    assert_eq!(colors.palette[1], Some(Rgb { r: 0x11, g: 0x22, b: 0x33 }));
}

#[test]
fn resized_replay_payload_is_shared_across_attach_taps() {
    let mux = Mux::new("shared-resize-replay", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let first = surface.attach_stream().unwrap();
    let second = surface.attach_stream().unwrap();
    let pty = surface.as_pty().unwrap();

    pty.broadcast_attach_frame(AttachFrame::ResizedWithColors {
        cols: 80,
        rows: 24,
        replay: vec![7; 1024].into(),
        kitty_image_aliases: Vec::new(),
        kitty_state: KittyReplayState::disabled(),
        colors: Box::new(TerminalColors::default()),
        pending_sequence: Arc::from([]),
    });

    let first_replay = match first.stream.recv_timeout(Duration::from_secs(1)).unwrap() {
        AttachFrame::ResizedWithColors { replay, .. } => replay,
        frame => panic!("unexpected first attach frame: {frame:?}"),
    };
    let second_replay = match second.stream.recv_timeout(Duration::from_secs(1)).unwrap() {
        AttachFrame::ResizedWithColors { replay, .. } => replay,
        frame => panic!("unexpected second attach frame: {frame:?}"),
    };
    assert_eq!(
        first_replay.as_ptr(),
        second_replay.as_ptr(),
        "resize replay bytes were deep-cloned for each attach subscriber"
    );
}

#[test]
fn unresumable_legacy_resize_disconnects_the_byte_attachment() {
    let mux = Mux::new("legacy-resize-disconnect", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(73, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let attachment = surface.attach_stream().unwrap();
    let pty = surface.as_pty().unwrap();
    // Only a control string past the replay's pending-sequence budget
    // cannot be carried into a replacement replay.
    pty.term.lock().unwrap().vt_write(b"\x1b]52;c;");
    pty.term.lock().unwrap().vt_write(&vec![b'A'; 2 * 1024 * 1024]);
    assert!(!pty.term.lock().unwrap().vt_replay_resumes_stream());

    assert!(surface.resize(100, 30).unwrap());
    assert!(matches!(
        attachment.stream.recv_timeout(Duration::from_secs(1)),
        Err(RecvTimeoutError::Disconnected)
    ));
    assert!(attachment.lifecycle.is_canceled());
}
