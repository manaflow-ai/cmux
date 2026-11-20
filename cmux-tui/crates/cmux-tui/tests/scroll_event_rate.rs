//! A flooding terminal must not flood every subscriber with scroll events
//! (perf100 tui lane). Output moves a terminal's scroll offset on almost
//! every chunk, and the daemon sent one `scroll-changed` event per chunk to
//! every event subscription (93k events/s, 6.6 MB/s of JSON, while one
//! terminal ran `yes`); the app parses each one. Output's scroll changes are
//! now published once per render frame (8 ms cadence), and the newest
//! position is always the one that arrives.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;

/// `scroll-changed` events per second of flood one subscriber may get: the
/// frame cadence is 125 frames/s; the margin covers scheduling.
const MAX_SCROLL_EVENTS_PER_SECOND: f64 = 250.0;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn start() -> Daemon {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = PathBuf::from("/tmp").join(format!("cmux-scroll-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("mux.sock");
    let settings = dir.join("cmux-next.json");
    fs::write(&settings, "{}\n").unwrap();
    let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["--headless", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_NEXT_CONFIG_FILE", &settings)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
    while transport::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
        std::thread::sleep(Duration::from_millis(25));
    }
    Daemon { child, socket, dir }
}

fn request(daemon: &Daemon, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(&daemon.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let response: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(response["ok"], true, "{value} failed: {response}");
    response["data"].clone()
}

#[test]
fn cmux_next_flooding_terminal_sends_scroll_events_per_frame_not_per_chunk() {
    let daemon = start();
    let stream = transport::connect(&daemon.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    writeln!(writer, "{}", serde_json::json!({"id": 1, "cmd": "subscribe"})).unwrap();
    let mut events = BufReader::new(stream);
    let mut line = String::new();
    events.read_line(&mut line).unwrap();
    assert!(line.contains("\"ok\":true"), "subscribe failed: {line}");

    // 20 MB of `y` lines: about 10 M lines of scrollback movement.
    let created = request(
        &daemon,
        serde_json::json!({
            "id": 2,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "yes | head -c 20000000"],
            "new_workspace": true,
            "name": "flood",
        }),
    );
    let surface = created["surface"].as_u64().or_else(|| created["surface_id"].as_u64());
    let started = Instant::now();
    let deadline = started + test_timeout(Duration::from_secs(120));
    let mut scroll_events = 0u64;
    let mut last_scroll: Option<serde_json::Value> = None;
    let exited_at = loop {
        assert!(Instant::now() < deadline, "the flood did not end; {scroll_events} scroll events");
        line.clear();
        assert!(events.read_line(&mut line).unwrap() > 0, "subscription closed");
        let event: serde_json::Value = serde_json::from_str(&line).unwrap();
        if surface.is_some_and(|surface| event["surface"].as_u64() != Some(surface)) {
            continue;
        }
        match event["event"].as_str() {
            Some("scroll-changed") => {
                scroll_events += 1;
                last_scroll = Some(event);
            }
            Some("surface-exited") => break started.elapsed(),
            _ => {}
        }
    };
    let flood = exited_at.as_secs_f64().max(0.1);
    let rate = scroll_events as f64 / flood;
    let _ = writeln!(
        std::io::stderr(),
        "scroll-changed: {scroll_events} events in {flood:.2} s of flood ({rate:.0}/s)"
    );
    let last = last_scroll.expect("output that scrolled published no scroll position");
    assert_eq!(last["at_bottom"], true, "the newest position is at the bottom: {last}");
    // 20 MB of 2-byte lines scrolled about 10 M rows, clamped by the
    // scrollback limit; the newest offset is far from the top.
    assert!(last["offset"].as_u64().unwrap_or(0) > 1000, "stale last position: {last}");
    assert!(
        rate <= MAX_SCROLL_EVENTS_PER_SECOND,
        "{rate:.0} scroll-changed events/s while flooding (budget {MAX_SCROLL_EVENTS_PER_SECOND})"
    );
}
