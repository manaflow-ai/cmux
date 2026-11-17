//! The Mac keeps the scrollback; a phone holds the screen and a window of it
//! (`attach-replay-history-window-v1`, `surface/history_window.rs`), on the
//! wire: a window far up a long history, and a viewer's window across a
//! resize. Plus the 100k-line bench (CMUX_VIEWPORT_WINDOW_BENCH).

use super::*;

/// An attached bytes viewer: its client, writer and queue.
struct Viewer {
    client: u64,
    writer: crate::server::MessageWriter,
    outbound: std::sync::Arc<BoundedOutbound>,
}

impl Viewer {
    /// A viewer that declares `attach-replay-history-window-v1`, as the phone does.
    fn attach(mux: &std::sync::Arc<Mux>, surface: &crate::Surface, extra: Value) -> (Self, Value) {
        Self::attach_declaring(mux, surface, extra, &["attach-replay-history-window-v1"])
    }

    fn attach_declaring(
        mux: &std::sync::Arc<Mux>,
        surface: &crate::Surface,
        extra: Value,
        capabilities: &[&str],
    ) -> (Self, Value) {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let info = json!({"cmd": "set-client-info", "capabilities": capabilities});
        handle_command(mux, client, command(info), &writer).unwrap();
        let mut request = json!({"cmd": "attach-surface", "surface": surface.id});
        for (key, value) in extra.as_object().expect("fields") {
            request[key] = value.clone();
        }
        handle_command(mux, client, command(request), &writer).unwrap();
        let first = next_event(&outbound, Duration::from_secs(10)).expect("vt-state");
        assert_eq!(first["event"], "vt-state", "{first}");
        (Self { client, writer, outbound }, first)
    }

    /// The viewer resizes the terminal; its `resized` event.
    fn resize(
        &self,
        mux: &std::sync::Arc<Mux>,
        surface: &crate::Surface,
        cols: u16,
        rows: u16,
    ) -> Value {
        let request =
            json!({"cmd": "resize-surface", "surface": surface.id, "cols": cols, "rows": rows});
        handle_command(mux, self.client, command(request), &self.writer).unwrap();
        loop {
            let event = next_event(&self.outbound, Duration::from_secs(10)).expect("resized");
            if event["event"] == "resized" {
                return event;
            }
        }
    }

    fn detach(self, mux: &std::sync::Arc<Mux>) {
        disconnect_client(mux, self.client, false);
    }
}

fn replay(event: &Value) -> Vec<u8> {
    base64::engine::general_purpose::STANDARD
        .decode(event["replay"].as_str().expect("replay"))
        .expect("base64")
}

/// The plain rows a replay rebuilds on an 80x24 mirror (history first).
fn mirror_rows(bytes: &[u8]) -> Vec<String> {
    let mut term =
        ghostty_vt::Terminal::new(80, 24, 64 * 1024 * 1024, ghostty_vt::Callbacks::default())
            .unwrap();
    term.vt_write(bytes);
    term.plain_text().unwrap().lines().map(str::to_owned).collect()
}

#[test]
fn replay_history_window_capability_is_advertised() {
    let mux = Mux::new_for_test("replay-history-window-identify", SurfaceOptions::default());
    let (writer, _outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let identity =
        handle_command(&mux, client, command(json!({"cmd": "identify"})), &writer).unwrap();
    let capabilities = identity["capabilities"].as_array().expect("capabilities");
    assert!(
        capabilities.iter().any(|value| value == "attach-replay-history-window-v1"),
        "{identity}"
    );
    disconnect_client(&mux, client, false);
    mux.shutdown();
}

/// Scrolling all the way back: a window at the top of a long history holds
/// line 1 and the screen, and none of the rows between, so its replay is as
/// small as its window, not the whole history.
#[test]
fn a_window_at_the_top_of_a_long_history_holds_line_one_and_the_screen() {
    let (mux, surface) =
        quiet_surface_with_scrollback_limit("replay-history-window", 20_000, 50_000_000);
    let (viewer, tail) = Viewer::attach(&mux, &surface, json!({"replay_history_rows": 0}));
    viewer.detach(&mux);
    let (viewer, top) = Viewer::attach(
        &mux,
        &surface,
        json!({"replay_history_rows": 2_000, "replay_history_start": 0}),
    );
    viewer.detach(&mux);
    assert_eq!(top["history_rows_omitted"], 0, "{}", top["history_rows_omitted"]);
    let skipped = top["history_rows_skipped"].as_u64().expect("skipped rows");
    let history = tail["history_rows_omitted"].as_u64().expect("history rows");
    assert_eq!(skipped, history - 2_000, "every row between the window and the screen");
    let bytes = data(&top);
    assert!(bytes.len() < 400_000, "a 2,000-row window replay of {} bytes", bytes.len());
    let rows = mirror_rows(&bytes);
    assert!(rows[0].starts_with("000000 compiling"), "{:?}", &rows[..3]);
    // The window is the history's first 2,000 rows; a few long lines wrap
    // to two rows, so it ends a few lines before 002000.
    assert!(rows.iter().any(|row| row.starts_with("001990 compiling")), "the window's rows");
    assert!(!rows.iter().any(|row| row.starts_with("002000 compiling")), "past the window");
    assert!(
        rows.iter().any(|row| row.starts_with("019999 compiling")),
        "the screen's newest line follows the window"
    );
    assert!(!rows.iter().any(|row| row.starts_with("010000 compiling")), "the gap is left out");
    mux.shutdown();
}

/// A viewer that asked for the screen alone keeps that across a resize: its
/// `resized` replay is its window and names the rows left out. Before, every
/// resize sent it the whole history.
#[test]
fn a_windowed_viewer_gets_its_window_on_a_resize() {
    let (mux, surface) =
        quiet_surface_with_scrollback_limit("replay-history-window-resize", 20_000, 50_000_000);
    let (whole, _) = Viewer::attach(&mux, &surface, json!({}));
    // A phone from before the window reads no `history_rows_omitted` on
    // `resized`: it keeps getting the whole history there.
    let (older, _) =
        Viewer::attach_declaring(&mux, &surface, json!({"replay_history_rows": 0}), &[]);
    let (windowed, first) = Viewer::attach(&mux, &surface, json!({"replay_history_rows": 0}));
    let resized = windowed.resize(&mux, &surface, 60, 20);
    let next_resized = |viewer: &Viewer| loop {
        let event = next_event(&viewer.outbound, Duration::from_secs(10)).expect("resized");
        if event["event"] == "resized" {
            break event;
        }
    };
    let whole_resized = next_resized(&whole);
    let older_resized = next_resized(&older);
    assert_eq!(replay(&older_resized).len(), replay(&whole_resized).len());
    assert!(older_resized.get("history_rows_omitted").is_none(), "{older_resized}");
    older.detach(&mux);
    let windowed_bytes = replay(&resized);
    let whole_bytes = replay(&whole_resized);
    assert!(
        windowed_bytes.len() * 50 < whole_bytes.len(),
        "the windowed viewer's resize replay is {} bytes, the whole one {}",
        windowed_bytes.len(),
        whole_bytes.len()
    );
    let omitted = resized["history_rows_omitted"].as_u64().expect("omitted rows");
    assert!(omitted >= first["history_rows_omitted"].as_u64().unwrap() / 2, "{omitted}");
    assert!(whole_resized.get("history_rows_omitted").is_none(), "{whole_resized}");
    windowed.detach(&mux);
    whole.detach(&mux);
    mux.shutdown();
}

/// Bench (off unless CMUX_VIEWPORT_WINDOW_BENCH=1): an 80x24 terminal with
/// 100,000 lines of history, one phone viewer. Wire bytes (the event line)
/// and time to the line for: the attach (screen first), a resize, and
/// scrolling back 10,000 rows and to line 1 the way the phone fetched older
/// rows before (a new attach with 2,000 more rows each time) and with a
/// window (`replay_history_start`, 4,000 rows, 1,500 older each step, as the phone moves it).
/// Prints VIEWPORT-WINDOW-BENCH lines (also to
/// $FAST_CHECKS_OUT/viewport-window-bench.txt).
#[test]
fn viewport_window_bench() {
    if std::env::var("CMUX_VIEWPORT_WINDOW_BENCH").ok().as_deref() != Some("1") {
        return;
    }
    const LINES: usize = 100_000;
    const CHUNK: u64 = 2_000;
    const WINDOW: u64 = 4_000;
    const STEP: u64 = 1_500;
    let (mux, surface) =
        quiet_surface_with_scrollback_limit("viewport-window-bench", LINES, 400_000_000);
    let mut out = Vec::new();
    let profile = if cfg!(debug_assertions) { "dev-profile" } else { "release" };
    // One attach: (line bytes, ms, event).
    let attach = |extra: Value| {
        let started = Instant::now();
        let (viewer, event) = Viewer::attach(&mux, &surface, extra);
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        let bytes = serde_json::to_string(&event).unwrap().len();
        viewer.detach(&mux);
        (bytes, ms, event)
    };
    let (bytes, ms, first) = attach(json!({"replay_history_rows": 0}));
    let history = first["history_rows_omitted"].as_u64().unwrap_or(0);
    out.push(format!("VIEWPORT-WINDOW-BENCH {profile} attach: {bytes} wire bytes, {ms:.1} ms, history {history} rows"));

    // A resize of a phone that attached with the screen alone.
    let (viewer, _) = Viewer::attach(&mux, &surface, json!({"replay_history_rows": 0}));
    let started = Instant::now();
    let resized = viewer.resize(&mux, &surface, 60, 20);
    let ms = started.elapsed().as_secs_f64() * 1000.0;
    let bytes = serde_json::to_string(&resized).unwrap().len();
    out.push(format!(
        "VIEWPORT-WINDOW-BENCH {profile} resize: {bytes} wire bytes, {ms:.1} ms, history_rows_omitted {}",
        resized["history_rows_omitted"]
    ));
    let _ = viewer.resize(&mux, &surface, 80, 24);
    viewer.detach(&mux);

    // Before: each fetch is an attach with 2,000 more rows (the phone's
    // `loadOlderHistory` at feat-cmux-next). To 10,000 rows back, then to line 1.
    let (mut total, mut fetches, mut last_ms, mut omitted) = (0usize, 0usize, 0.0, history);
    let mut allowance = 0u64;
    let mut at_10k = None;
    while omitted > 0 && fetches < 60 {
        allowance += CHUNK;
        let request =
            if omitted <= CHUNK { json!({}) } else { json!({"replay_history_rows": allowance}) };
        let (bytes, ms, event) = attach(request);
        total += bytes;
        fetches += 1;
        last_ms = ms;
        omitted = event["history_rows_omitted"].as_u64().unwrap_or(0);
        if at_10k.is_none() && allowance >= 10_000 {
            at_10k = Some((total, fetches, ms));
        }
        if fetches == 1 || omitted == 0 || fetches % 10 == 0 {
            out.push(format!("VIEWPORT-WINDOW-BENCH {profile} chunked fetch {fetches}: {bytes} wire bytes, {ms:.1} ms, {omitted} rows left"));
        }
    }
    let (b10, f10, ms10) = at_10k.unwrap_or_default();
    out.push(format!(
        "VIEWPORT-WINDOW-BENCH {profile} before: 10k rows back {b10} wire bytes in {f10} fetches (last {ms10:.1} ms); \
         line 1 {total} wire bytes in {fetches} fetches (last {last_ms:.1} ms), rows held at the top {history}"
    ));

    // After: a window of 4,000 rows moves up 1,500 rows per fetch.
    let (mut total, mut fetches, mut last_ms) = (0usize, 0usize, 0.0);
    let mut start = history.saturating_sub(STEP);
    let mut at_10k = None;
    let mut reached_line_one = false;
    let mut supported = true;
    loop {
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let request = json!({"cmd": "attach-surface", "surface": surface.id,
            "replay_history_rows": WINDOW, "replay_history_start": start});
        let started = Instant::now();
        if handle_command(&mux, client, command(request), &writer).is_err() {
            supported = false;
            disconnect_client(&mux, client, false);
            break;
        }
        let event = next_event(&outbound, Duration::from_secs(10)).expect("vt-state");
        let ms = started.elapsed().as_secs_f64() * 1000.0;
        disconnect_client(&mux, client, false);
        let bytes = serde_json::to_string(&event).unwrap().len();
        total += bytes;
        fetches += 1;
        last_ms = ms;
        if at_10k.is_none() && history - start >= 10_000 {
            at_10k = Some((total, fetches, ms));
        }
        if start == 0 {
            reached_line_one = mirror_rows(&data(&event))
                .first()
                .is_some_and(|row| row.starts_with("000000 compiling"));
            out.push(format!("VIEWPORT-WINDOW-BENCH {profile} window fetch {fetches}: {bytes} wire bytes, {ms:.1} ms, skipped {}", event["history_rows_skipped"]));
            break;
        }
        start = start.saturating_sub(STEP);
    }
    let (b10, f10, ms10) = at_10k.unwrap_or_default();
    out.push(format!(
        "VIEWPORT-WINDOW-BENCH {profile} after: supported {supported}; 10k rows back {b10} wire bytes in {f10} fetches \
         (last {ms10:.1} ms); line 1 {total} wire bytes in {fetches} fetches (last {last_ms:.1} ms), \
         rows held at the top {WINDOW}, line 1 reached {reached_line_one}"
    ));
    mux.shutdown();
    for line in &out {
        eprintln!("{line}");
    }
    if let Ok(dir) = std::env::var("FAST_CHECKS_OUT") {
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            std::path::Path::new(&dir).join("viewport-window-bench.txt"),
            out.join("\n") + "\n",
        )
        .unwrap();
    }
}
