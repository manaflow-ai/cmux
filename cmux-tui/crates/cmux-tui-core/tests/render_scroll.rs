//! Render attach viewport metadata through a real daemon socket: a
//! `scroll-surface` sent on a command connection must reach the render attach
//! as a `scroll-changed` (offset and at-bottom) ordered before the
//! `render-delta` that shows the moved rows (spec/render.md, spec/events.md
//! "scroll-changed"), and a render attach made while the viewport is scrolled
//! back must learn that position before any later event.

use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};
mod support;
use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, SurfaceOptions};
use serde_json::{Value, json};
use support::{DaemonMuxOps, wait_for};

const LINES: u32 = 300;
const ROWS: u16 = 4;

fn shell_opts(script: &str) -> SurfaceOptions {
    SurfaceOptions {
        command: Some(vec!["/bin/sh".to_string(), "-c".to_string(), script.to_string()]),
        ..Default::default()
    }
}

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

/// Newline-delimited JSON over a socket with a short read timeout. A partial
/// line read before a timeout stays buffered for the next call.
struct Lines {
    reader: BufReader<Box<dyn transport::Stream>>,
    writer: Box<dyn transport::Stream>,
    partial: String,
}

impl Lines {
    fn connect(path: &std::path::Path) -> Self {
        let stream = transport::connect(path).unwrap();
        stream.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        let writer = stream.try_clone_box().unwrap();
        Self { reader: BufReader::new(stream), writer, partial: String::new() }
    }

    /// The next message, or `None` when none arrived within the read timeout.
    fn next(&mut self) -> Option<Value> {
        match self.reader.read_line(&mut self.partial) {
            Ok(0) => panic!("socket closed"),
            Ok(_) => {
                let line = std::mem::take(&mut self.partial);
                Some(serde_json::from_str(&line).unwrap_or_else(|error| {
                    panic!("bad JSON line ({error}): {line}");
                }))
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                ) =>
            {
                None
            }
            Err(error) => panic!("socket read failed: {error}"),
        }
    }

    fn send(&mut self, request: Value) {
        writeln!(self.writer, "{request}").unwrap();
    }

    /// Send a request and return its response; other messages are returned
    /// in arrival order through `seen`.
    fn request(&mut self, request: Value, seen: &mut Vec<Value>) -> Value {
        let id = request["id"].clone();
        self.send(request);
        let deadline = Instant::now() + Duration::from_secs(10);
        while Instant::now() < deadline {
            if let Some(value) = self.next() {
                if value.get("id") == Some(&id) {
                    assert_eq!(value["ok"], true, "request failed: {value}");
                    return value;
                }
                seen.push(value);
            }
        }
        panic!("no response to request {id}");
    }

    /// Collect messages until `done` holds for the collected list or the
    /// deadline passes.
    fn collect_until(
        &mut self,
        seen: &mut Vec<Value>,
        timeout: Duration,
        done: impl Fn(&[Value]) -> bool,
    ) -> bool {
        let deadline = Instant::now() + timeout;
        loop {
            if done(seen) {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            if let Some(value) = self.next() {
                seen.push(value);
            }
        }
    }

    /// Collect messages until none arrives for `quiet`.
    fn drain(&mut self, seen: &mut Vec<Value>, quiet: Duration) {
        let mut last = Instant::now();
        while last.elapsed() < quiet {
            if let Some(value) = self.next() {
                seen.push(value);
                last = Instant::now();
            }
        }
    }
}

fn rows_text(value: &Value) -> Vec<String> {
    value["rows"]
        .as_array()
        .into_iter()
        .flatten()
        .map(|row| {
            row["runs"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|run| run["text"].as_str())
                .collect::<String>()
                .trim_end()
                .to_string()
        })
        .collect()
}

fn is_scroll(value: &Value) -> bool {
    value["event"] == "scroll-changed"
}

fn is_delta_showing(value: &Value, line: &str) -> bool {
    value["event"] == "render-delta" && rows_text(value).iter().any(|row| row == line)
}

fn describe(events: &[Value]) -> String {
    events
        .iter()
        .map(|event| match event["event"].as_str() {
            Some("render-delta") => {
                format!("render-delta full={} rows={:?}", event["full"], rows_text(event))
            }
            Some("render-state") => format!("render-state rows={:?}", rows_text(event)),
            _ => event.to_string(),
        })
        .collect::<Vec<_>>()
        .join("\n  ")
}

/// Open a render attach on `lines` and return the initial `render-state`;
/// later messages (and the response) are left in `seen`.
fn render_attach(lines: &mut Lines, surface: u64, seen: &mut Vec<Value>) -> Value {
    lines.send(json!({"id": 1, "cmd": "attach-surface", "surface": surface, "mode": "render"}));
    let initial = wait_for(|| lines.next(), Duration::from_secs(5)).expect("render-state event");
    assert_eq!(initial["event"], "render-state", "first render attach event: {initial}");
    assert!(
        lines.collect_until(seen, Duration::from_secs(5), |seen| seen
            .iter()
            .any(|value| value["id"] == 1 && value["ok"] == true)),
        "render attach response: {}",
        describe(seen)
    );
    initial
}

/// A `cat` terminal of `ROWS` rows with `LINES` numbered lines of output and
/// a render attach that has seen the last one.
struct Fixture {
    mux: std::sync::Arc<Mux>,
    surface: std::sync::Arc<cmux_tui_core::Surface>,
    sock_path: std::path::PathBuf,
    render: Lines,
    command: Lines,
    /// The viewport offset at the live bottom after the output.
    bottom: u64,
}

impl Fixture {
    fn new(prefix: &str) -> Self {
        let mux = Mux::new(unique_session(prefix), shell_opts("stty -echo; printf ready; cat"));
        let surface = mux.new_workspace(None, Some((20, ROWS))).unwrap();
        wait_for(
            || {
                surface
                    .with_terminal(|term| {
                        term.viewport_text().ok().filter(|text| text.contains("ready"))
                    })
                    .flatten()
            },
            Duration::from_secs(10),
        )
        .expect("cat ready");
        let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
        let mut render = Lines::connect(&sock_path);
        let mut seen = Vec::new();
        render_attach(&mut render, surface.id, &mut seen);

        let output: String = (1..=LINES).map(|line| format!("{line}\n")).collect();
        surface.write_bytes(format!("\n{output}").as_bytes()).unwrap();
        let last = LINES.to_string();
        assert!(
            render.collect_until(&mut seen, Duration::from_secs(10), |seen| seen
                .iter()
                .any(|value| is_delta_showing(value, &last))),
            "the render attach never showed line {last}: {}",
            describe(&seen)
        );
        render.drain(&mut seen, Duration::from_millis(300));
        let scrollbar = surface
            .with_terminal(|term| term.scrollbar())
            .flatten()
            .expect("the output left scrollback");
        assert!(!scrollbar.scrolled_back(), "output leaves the viewport at the live bottom");
        let bottom = scrollbar.offset;
        assert!(bottom >= u64::from(LINES) - u64::from(ROWS), "scrollback offset {bottom}");
        let command = Lines::connect(&sock_path);
        Self { mux, surface, sock_path, render, command, bottom }
    }

    fn scroll(&mut self, id: u64, delta: i64) {
        let mut seen = Vec::new();
        self.command.request(
            json!({"id": id, "cmd": "scroll-surface", "surface": self.surface.id, "delta": delta}),
            &mut seen,
        );
    }

    fn read_screen(&mut self, id: u64) -> String {
        let mut seen = Vec::new();
        let response = self.command.request(
            json!({"id": id, "cmd": "read-screen", "surface": self.surface.id}),
            &mut seen,
        );
        response["data"]["text"].as_str().unwrap_or_default().to_string()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.mux.close_surface(self.surface.id);
        cmux_tui_core::server::cleanup(&self.sock_path);
    }
}

/// Wait on `lines` for a `scroll-changed` matching `offset`/`at_bottom` and a
/// later `render-delta` that shows `row`; return everything seen.
fn expect_scroll_then_rows(
    lines: &mut Lines,
    surface: u64,
    offset: u64,
    at_bottom: bool,
    row: &str,
    what: &str,
) -> Vec<Value> {
    let mut seen = Vec::new();
    let matches = |value: &Value| {
        is_scroll(value)
            && value["surface"] == surface
            && value["offset"] == offset
            && value["at_bottom"] == at_bottom
    };
    let found = lines.collect_until(&mut seen, Duration::from_secs(5), |seen| {
        seen.iter()
            .position(matches)
            .is_some_and(|at| seen[at + 1..].iter().any(|value| is_delta_showing(value, row)))
    });
    assert!(
        found,
        "{what}: the render attach did not get scroll-changed {{offset:{offset}, \
         at_bottom:{at_bottom}}} followed by a render-delta showing row {row:?}; got:\n  {}",
        describe(&seen)
    );
    let first_scroll = seen.iter().position(is_scroll).unwrap();
    let first_rows = seen.iter().position(|value| is_delta_showing(value, row)).unwrap();
    assert!(
        first_scroll < first_rows,
        "{what}: scroll-changed must come before the render-delta that moved the rows:\n  {}",
        describe(&seen)
    );
    seen
}

#[test]
fn command_scroll_surface_reaches_the_render_attach_as_scroll_changed_and_rows() {
    let mut fixture = Fixture::new("test-render-scroll-command");
    let surface = fixture.surface.id;
    let bottom = fixture.bottom;
    // The live bottom shows lines 298..=300 and the cursor row; six rows up
    // the viewport shows lines 292..=295.
    fixture.scroll(10, -6);
    expect_scroll_then_rows(
        &mut fixture.render,
        surface,
        bottom - 6,
        false,
        "292",
        "scroll-surface delta -6",
    );

    fixture.scroll(12, 6);
    expect_scroll_then_rows(
        &mut fixture.render,
        surface,
        bottom,
        true,
        "300",
        "scroll-surface back to the bottom",
    );
}

#[test]
fn render_attach_made_while_scrolled_back_learns_the_viewport_position() {
    let mut fixture = Fixture::new("test-render-scroll-attach");
    let surface = fixture.surface.id;
    let bottom = fixture.bottom;
    fixture.scroll(10, -6);
    expect_scroll_then_rows(
        &mut fixture.render,
        surface,
        bottom - 6,
        false,
        "292",
        "scroll-surface delta -6",
    );

    let mut late = Lines::connect(&fixture.sock_path);
    let mut seen = Vec::new();
    let initial = render_attach(&mut late, surface, &mut seen);
    assert_eq!(
        rows_text(&initial).first().map(String::as_str),
        Some("292"),
        "a late render attach starts from the scrolled viewport"
    );
    late.drain(&mut seen, Duration::from_millis(300));
    let events: Vec<&Value> = seen.iter().filter(|value| value.get("event").is_some()).collect();
    assert!(
        events.first().is_some_and(|value| is_scroll(value)
            && value["offset"] == bottom - 6
            && value["at_bottom"] == false),
        "a render attach made while scrolled back must get scroll-changed \
         {{offset:{}, at_bottom:false}} before any other event; got:\n  {}",
        bottom - 6,
        describe(&seen)
    );

    // New output while scrolled back keeps the viewport where it is.
    fixture.surface.write_bytes(b"301\n302\n").unwrap();
    let mut after = Vec::new();
    fixture.render.drain(&mut after, Duration::from_millis(500));
    assert!(
        !after.iter().any(|value| is_scroll(value) && value["at_bottom"] == true)
            && !after.iter().any(|value| is_delta_showing(value, "302")),
        "output while scrolled back must not snap the render attach to the bottom:\n  {}",
        describe(&after)
    );
    fixture.scroll(11, 1000);
    expect_scroll_then_rows(
        &mut fixture.render,
        surface,
        bottom + 2,
        true,
        "302",
        "scroll-surface past the bottom",
    );
}

/// The position a render client holds after applying `events` in order,
/// starting from `start`.
fn client_position(start: (u64, bool), events: &[Value]) -> (u64, bool) {
    events.iter().filter(|value| is_scroll(value)).fold(start, |_, value| {
        (value["offset"].as_u64().unwrap(), value["at_bottom"].as_bool().unwrap())
    })
}

fn daemon_position(surface: &cmux_tui_core::Surface) -> (u64, bool) {
    let scrollbar =
        surface.with_terminal(|term| term.scrollbar()).flatten().expect("terminal has scrollback");
    (scrollbar.offset, !scrollbar.scrolled_back())
}

/// A resize moves the viewport (at the live bottom the offset follows the row
/// count; reflow moves a scrolled-back position). The render attach must get
/// the new position before the full render-delta of the resized grid, so the
/// client's offset never lags the daemon's.
#[test]
fn resize_announces_the_viewport_move_to_the_render_attach() {
    let mut fixture = Fixture::new("test-render-scroll-resize");
    let surface = fixture.surface.id;
    let start = (fixture.bottom, true);

    // At the live bottom: two fewer rows push two rows into history.
    assert!(fixture.surface.resize(20, ROWS - 2).unwrap(), "the resize applies");
    let mut seen = Vec::new();
    fixture.render.drain(&mut seen, Duration::from_millis(500));
    let moved = daemon_position(&fixture.surface);
    assert_ne!(moved, start, "fixture: the resize moves the live bottom's offset");
    assert_eq!(
        client_position(start, &seen),
        moved,
        "after a resize at the live bottom the render attach must hold the daemon's position; \
         got:\n  {}",
        describe(&seen)
    );
    let first_scroll = seen.iter().position(is_scroll).unwrap();
    let first_full = seen
        .iter()
        .position(|value| value["event"] == "render-delta" && value["full"] == true)
        .expect("a resize sends a full render-delta");
    assert!(
        first_scroll < first_full,
        "scroll-changed must come before the resized rows:\n  {}",
        describe(&seen)
    );
    assert!(seen.iter().all(|value| !is_scroll(value) || value["surface"] == surface));

    // Scrolled back, then a resize: whatever the reflow does to the
    // position, the render attach ends at the daemon's.
    fixture.scroll(10, -6);
    let mut seen = Vec::new();
    fixture.render.drain(&mut seen, Duration::from_millis(500));
    let scrolled = client_position(moved, &seen);
    assert_eq!(scrolled, daemon_position(&fixture.surface));
    assert!(!scrolled.1, "fixture: scrolled back");
    assert!(fixture.surface.resize(12, ROWS + 2).unwrap(), "the resize applies");
    let mut seen = Vec::new();
    fixture.render.drain(&mut seen, Duration::from_millis(500));
    assert_eq!(
        client_position(scrolled, &seen),
        daemon_position(&fixture.surface),
        "after a resize while scrolled back the render attach must hold the daemon's \
         position; got:\n  {}",
        describe(&seen)
    );
}

/// A protocol scroll moves only what render attaches show. Automation reads
/// keep reading the live screen: `read-screen` shows the newest rows and
/// `wait-for` matches new output while a person is scrolled back.
#[test]
fn automation_reads_follow_the_live_screen_while_scrolled_back() {
    let mut fixture = Fixture::new("test-render-scroll-automation");
    let surface = fixture.surface.id;
    let bottom = fixture.bottom;
    fixture.scroll(10, -6);
    expect_scroll_then_rows(
        &mut fixture.render,
        surface,
        bottom - 6,
        false,
        "292",
        "scroll-surface delta -6",
    );

    let screen = fixture.read_screen(11);
    assert!(
        screen.contains("300") && !screen.contains("292"),
        "read-screen must show the live screen, not the scrolled render viewport: {screen:?}"
    );

    fixture.surface.write_bytes(b"fresh-output\n").unwrap();
    let mut seen = Vec::new();
    let response = fixture.command.request(
        json!({"id": 12, "cmd": "wait-for", "surface": surface,
               "pattern": "fresh-output", "timeout_ms": 5000}),
        &mut seen,
    );
    assert_eq!(response["data"]["matched"], true, "wait-for: {response}");
    assert!(
        !daemon_position(&fixture.surface).1,
        "the output did not snap the scrolled-back render viewport"
    );
}
