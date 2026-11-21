//! The phone's daemon lane under a typical workload, per stream (ask-acfe81d613: what the
//! phone's link carries, before and after the lean stream, its adapters and hidden tabs).
//!
//! cmux-mobile-host splices the phone's `daemon` channel to this daemon's socket line for line
//! (cmux-next-ios `services.rs`, no re-encoding), so the lines a viewer gets here are what
//! crosses the phone's link, before the link's own framing. The bench runs one daemon with four
//! terminal tabs: Claude Code replaying a recorded session at its recorded pace
//! (`cmux-agent-cli-render` fixture), and three idle shells (`/bin/sh`, a prompt drawn). A
//! second workload makes one shell busy: a build log of 20 coloured lines a second and, for 2 s
//! in every 10, a full-screen program. Three phones watch the same run at once:
//!
//! - `pty`: today's phone (no hybrid capability), every tab attached;
//! - `lean`: `agent-cli-hybrid-v1`, `-v2`, `terminal-shell-lines-v1` and
//!   `attach-output-coalesce-v1`, every tab attached;
//! - `lean, visible tab only`: the same, attached to the tab on screen only (hidden tabs get
//!   nothing, #43260).
//!
//! Run on the fleet (ignored in the normal run):
//! `cargo test -p cmux-tui-core --lib phone_link_bench -- --ignored --nocapture`;
//! `CMUX_PHONE_LINK_BENCH_SECONDS` sets each workload's length (default 60).

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use super::super::{BoundedOutbound, disconnect_client};
use super::{Viewer, declaring};
use crate::{Mux, Surface, SurfaceOptions};

const CLAUDE_PTY: &str =
    include_str!("../../../cmux-agent-cli-render/tests/fixtures/claude-code-2.1.310/pty.jsonl");

/// What one phone received: bytes and events per event name, after the attach.
#[derive(Default)]
struct Tally {
    bytes: BTreeMap<String, usize>,
    events: BTreeMap<String, usize>,
}

struct Phone {
    name: &'static str,
    viewers: Vec<Viewer>,
    tally: Arc<Mutex<Tally>>,
    attach_bytes: usize,
}

/// Pops `outbound` into `tally` until `stop`.
fn reader(outbound: Arc<BoundedOutbound>, tally: Arc<Mutex<Tally>>, stop: Arc<AtomicBool>) {
    std::thread::spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            let mut got = false;
            while let Some(message) = outbound.try_pop() {
                got = true;
                let name = serde_json::from_str::<Value>(&message)
                    .ok()
                    .and_then(|value| value["event"].as_str().map(str::to_owned))
                    .unwrap_or_else(|| "reply".to_owned());
                let mut tally = tally.lock().unwrap();
                *tally.bytes.entry(name.clone()).or_default() += message.len() + 1;
                *tally.events.entry(name).or_default() += 1;
            }
            if !got {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
    });
}

/// Drains what the attach sent first; its bytes.
fn drain(outbound: &BoundedOutbound) -> usize {
    std::thread::sleep(Duration::from_millis(300));
    let mut bytes = 0;
    while let Some(message) = outbound.try_pop() {
        bytes += message.len() + 1;
    }
    bytes
}

fn phone(
    mux: &Arc<Mux>,
    name: &'static str,
    capabilities: &[&str],
    tabs: &[&Arc<Surface>],
) -> Phone {
    let mut viewers = Vec::new();
    let mut attach_bytes = 0;
    for tab in tabs {
        // One connection per terminal, as the phone's `DaemonTerminalSession`.
        let viewer = declaring(mux, capabilities);
        viewer.attach(mux, tab, json!({"cols": 100, "rows": 32}));
        attach_bytes += drain(&viewer.outbound);
        viewers.push(viewer);
    }
    Phone { name, viewers, tally: Arc::default(), attach_bytes }
}

fn wait_for_shell(surface: &Surface) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !surface
        .process_id()
        .and_then(crate::platform::process_executable)
        .is_some_and(|program| program.ends_with("sh"))
    {
        assert!(Instant::now() < deadline, "the shell did not start");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// The Claude Code session's writes, as (offset from its first, bytes).
fn claude_writes() -> Vec<(Duration, Vec<u8>)> {
    let lines: Vec<Value> =
        CLAUDE_PTY.lines().filter_map(|line| serde_json::from_str(line).ok()).collect();
    let first = lines.first().and_then(|line| line["t_ms"].as_u64()).unwrap_or(0);
    lines
        .iter()
        .filter_map(|line| {
            let at = line["t_ms"].as_u64()?.saturating_sub(first);
            let bytes =
                base64::engine::general_purpose::STANDARD.decode(line["b64"].as_str()?).ok()?;
            Some((Duration::from_millis(at), bytes))
        })
        .collect()
}

/// A build log line and, 2 s in every 10, a full-screen program, written into `shell`.
fn busy_shell(shell: &Surface, at: Duration, n: u64) {
    let in_cycle = at.as_millis() % 10_000;
    if (8_000..10_000).contains(&in_cycle) {
        if in_cycle < 50 {
            shell.inject_output_for_test(b"\x1b[?1049h\x1b[H\x1b[2J");
        }
        let row = n % 30 + 1;
        shell.inject_output_for_test(format!("\x1b[{row};1H  PID {n} cpu 3.{n}%  ").as_bytes());
        return;
    }
    if (0..50).contains(&in_cycle) && n > 0 {
        shell.inject_output_for_test(b"\x1b[?1049l");
    }
    shell.inject_output_for_test(
        format!("\x1b[1;32m   Compiling\x1b[0m crate-{n} v0.1.{n} (/src/crate-{n})\r\n").as_bytes(),
    );
}

fn run(workload: &str, seconds: u64, busy: bool) -> Vec<(String, Value)> {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "sleep 3600; :".into()]),
        ..SurfaceOptions::default()
    };
    let mux = Mux::new(format!("phone-link-bench-{workload}"), options);
    let claude = mux.new_workspace(None, None).unwrap();
    mux.note_running_agent_for_test(claude.terminal_public_id().expect("a terminal"), "claude");
    let shells: Vec<Arc<Surface>> =
        (0..3).map(|_| mux.new_workspace(None, None).unwrap()).collect();
    for shell in &shells {
        wait_for_shell(shell);
        shell.inject_output_for_test(b"\x1b[1;34m~/src\x1b[0m $ ");
    }
    let all: Vec<&Arc<Surface>> = std::iter::once(&claude).chain(shells.iter()).collect();
    let lean = [
        "agent-cli-hybrid-v1",
        "agent-cli-hybrid-v2",
        "terminal-shell-lines-v1",
        "attach-output-coalesce-v1",
    ];
    // The busy workload looks at the busy shell; the typical one at Claude Code.
    let visible = if busy { &shells[0] } else { &claude };
    let phones = vec![
        phone(&mux, "pty, every tab", &[], &all),
        phone(&mux, "lean, every tab", &lean, &all),
        phone(&mux, "lean, visible tab only", &lean, &[visible]),
    ];
    let stop = Arc::new(AtomicBool::new(false));
    for phone in &phones {
        for viewer in &phone.viewers {
            reader(viewer.outbound.clone(), phone.tally.clone(), stop.clone());
        }
    }
    let writes = claude_writes();
    let session = writes.last().map(|(at, _)| *at + Duration::from_secs(2)).unwrap_or_default();
    let start = Instant::now();
    let length = Duration::from_secs(seconds);
    let mut next = 0;
    let mut loops = 0u32;
    let mut busy_n = 0u64;
    let mut busy_next = Duration::ZERO;
    while start.elapsed() < length {
        let at = start.elapsed();
        let in_session = at.saturating_sub(session * loops);
        if in_session >= session {
            loops += 1;
            next = 0;
            continue;
        }
        while let Some((when, bytes)) = writes.get(next)
            && *when <= in_session
        {
            claude.inject_output_for_test(bytes);
            next += 1;
        }
        if busy && at >= busy_next {
            busy_shell(&shells[0], at, busy_n);
            busy_n += 1;
            busy_next += Duration::from_millis(50);
        }
        std::thread::sleep(Duration::from_millis(5));
    }
    std::thread::sleep(Duration::from_millis(400));
    stop.store(true, Ordering::Relaxed);
    let elapsed = start.elapsed().as_secs_f64() - 0.4;
    let mut rows = Vec::new();
    for phone in phones {
        let tally = phone.tally.lock().unwrap();
        let total: usize = tally.bytes.values().sum();
        let streams: Value = tally
            .bytes
            .iter()
            .map(|(name, bytes)| {
                let events = tally.events.get(name).copied().unwrap_or(0);
                (
                    name.clone(),
                    json!({"bytes_per_s": *bytes as f64 / elapsed,
                           "events_per_s": events as f64 / elapsed}),
                )
            })
            .collect::<serde_json::Map<_, _>>()
            .into();
        let events: usize = tally.events.values().sum();
        rows.push((
            phone.name.to_owned(),
            json!({
                "workload": workload,
                "seconds": elapsed,
                "bytes_per_s": total as f64 / elapsed,
                "events_per_s": events as f64 / elapsed,
                "hour_mb": total as f64 / elapsed * 3600.0 / 1e6,
                "attach_bytes": phone.attach_bytes,
                "streams": streams,
            }),
        ));
        drop(tally);
        for viewer in &phone.viewers {
            disconnect_client(&mux, viewer.client, false);
        }
    }
    rows
}

#[test]
#[ignore = "a bench: run it on the fleet with --ignored --nocapture"]
fn phone_link_bench() {
    let seconds = std::env::var("CMUX_PHONE_LINK_BENCH_SECONDS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(60);
    let mut out = Vec::new();
    println!("| Workload | Phone | B/s | events/s | MB per hour | attach B | streams (B/s) |");
    println!("| --- | --- | ---: | ---: | ---: | ---: | --- |");
    for (workload, busy) in [("typical", false), ("busy-shell", true)] {
        for (phone, row) in run(workload, seconds, busy) {
            let streams = row["streams"]
                .as_object()
                .map(|streams| {
                    streams
                        .iter()
                        .map(|(name, s)| {
                            format!("{name} {:.0}", s["bytes_per_s"].as_f64().unwrap_or(0.0))
                        })
                        .collect::<Vec<_>>()
                        .join(", ")
                })
                .unwrap_or_default();
            println!(
                "| {workload} | {phone} | {:.0} | {:.1} | {:.2} | {} | {streams} |",
                row["bytes_per_s"].as_f64().unwrap_or(0.0),
                row["events_per_s"].as_f64().unwrap_or(0.0),
                row["hour_mb"].as_f64().unwrap_or(0.0),
                row["attach_bytes"],
            );
            out.push(json!({"phone": phone, "row": row}));
        }
    }
    println!("PHONE_LINK_BENCH_JSON {}", Value::Array(out));
}
