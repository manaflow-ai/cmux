//! The daemon's part of a phone's wheel round trip (Leo, 2026-11-21: "this claude code cli is often slow to scroll up
//! and down from ios"). The phone's `TerminalTUIScrollController` sends each frame's SGR wheel reports as one
//! `send {surface, bytes, key}` on its attach connection, and the program's redraw comes back as `output` events on
//! the same connection. This times that path through a real socket, the connection's three threads, the PTY and back,
//! against a program that answers each read at once (no render time of its own), so what it measures is what the
//! daemon adds. The cadence is the phone's momentum fling: 8 ms between reports at first, growing to 70 ms over about
//! 40 reports, 3 flings each way, at the phone's 46x42 grid.
//!
//! `--ignored` only (a bench, not a gate): `cargo test -p cmux-tui-core wheel_round_trip -- --ignored --nocapture`.
//! It prints one line per variant: the phone's own attach (no output capability, today's default), and an attach that
//! declared `attach-output-coalesce-v1` (the frame-interval coalescer the phone does not declare), for comparison.

use super::*;
use base64::Engine;
use std::io::BufRead;
use std::sync::mpsc;
use std::time::Instant;

/// A program with no render time: raw mode, then every read answered at once with about the redraw Claude Code sends
/// per wheel report at 46x42 (1.6 KB, cmux#48951), one per report in the read. `cat` when there is no python3.
const RESPONDER: &str = "stty raw -echo 2>/dev/null; \
if command -v python3 >/dev/null 2>&1; then exec python3 -c '\
import os\n\
os.write(1, b\"\\x1b[?1049h\\x1b[?1000h\\x1b[?1006hWHEELREADY\")\n\
while True:\n\
    d = os.read(0, 65536)\n\
    if not d: break\n\
    n = max(1, d.count(b\"\\x1b[<\"))\n\
    os.write(1, (b\"\\x1b[H\" + b\"x\" * 1600) * n)\n\
'; else printf 'WHEELREADY'; exec cat; fi";

fn percentile(sorted: &[f64], p: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    let index = ((sorted.len() - 1) as f64 * p) as usize;
    sorted[index.min(sorted.len() - 1)]
}

fn stats(values: &mut [f64]) -> String {
    values.sort_by(f64::total_cmp);
    format!(
        "n={} p50={:.2} p95={:.2} max={:.2}",
        values.len(),
        percentile(values, 0.5),
        percentile(values, 0.95),
        values.last().copied().unwrap_or(f64::NAN)
    )
}

fn run_variant(label: &str, capabilities: &[&str]) -> String {
    let mux = Mux::new(
        &format!("wheel-rtt-{label}"),
        SurfaceOptions {
            command: Some(vec!["/bin/sh".into(), "-c".into(), RESPONDER.into()]),
            ..SurfaceOptions::default()
        },
    );
    let surface = mux.new_workspace(None, Some((46, 42))).unwrap();
    let socket = TestSocket::new(&format!("wheel-{label}"));
    let listener = transport::listen(&socket.path).unwrap();
    let client = transport::connect(&socket.path).unwrap();
    let server = listener.accept().unwrap();
    let handler = std::thread::spawn({
        let mux = mux.clone();
        move || handle_connection(mux, server)
    });
    let mut writer = client.try_clone_box().unwrap();
    // Every output event's arrival time and decoded bytes, read on its own thread as the phone's socket does.
    let (events_tx, events) = mpsc::channel::<(Instant, Vec<u8>)>();
    let reader = std::thread::spawn(move || {
        let mut reader = BufReader::new(client);
        let mut line = String::new();
        loop {
            line.clear();
            if reader.read_line(&mut line).unwrap_or(0) == 0 {
                return;
            }
            let at = Instant::now();
            let Ok(value) = serde_json::from_str::<Value>(&line) else { continue };
            if value["event"] == "output"
                && let Some(data) = value["data"].as_str()
                && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(data)
                && !bytes.is_empty()
                && events_tx.send((at, bytes)).is_err()
            {
                return;
            }
        }
    });
    let mut next_id = 1u64;
    let mut request = |writer: &mut Box<dyn transport::Stream>, mut value: Value| {
        value["id"] = json!(next_id);
        next_id += 1;
        writeln!(writer, "{value}").unwrap();
        writer.flush().unwrap();
    };
    if !capabilities.is_empty() {
        request(
            &mut writer,
            json!({"cmd": "set-client-info", "name": "wheel bench", "capabilities": capabilities}),
        );
    }
    request(
        &mut writer,
        json!({"cmd": "attach-surface", "surface": surface.id, "cols": 46, "rows": 42}),
    );
    // The program is up once its marker came (in the replay or a later output).
    let ready_deadline = Instant::now() + Duration::from_secs(20);
    let mut seen = Vec::new();
    while !seen.windows(10).any(|window| window == b"WHEELREADY") {
        let remaining = ready_deadline.saturating_duration_since(Instant::now());
        assert!(
            !remaining.is_zero(),
            "the responder never started: {:?}",
            String::from_utf8_lossy(&seen)
        );
        match events.recv_timeout(remaining.min(Duration::from_millis(100))) {
            Ok((_, bytes)) => seen.extend_from_slice(&bytes),
            Err(_) => {
                // The marker may have come in the attach's replay (vt-state), before the stream: go on.
                if surface
                    .try_with_terminal(|t| t.active_text())
                    .ok()
                    .and_then(Result::ok)
                    .is_some_and(|text| text.contains("WHEELREADY") || text.contains("xxxx"))
                {
                    break;
                }
            }
        }
    }
    std::thread::sleep(Duration::from_millis(200));
    while events.try_recv().is_ok() {}
    // python3 asked for the mouse; `cat` did not (its answers are the reports echoed back).
    let python = surface.try_with_terminal(|t| t.mode(1000, false)).unwrap_or(false);

    let mut first_of_fling = Vec::new();
    let mut every = Vec::new();
    let mut bytes_back = 0usize;
    let mut reports = 0usize;
    for fling in 0..6 {
        let button = if fling % 2 == 0 { 64 } else { 65 };
        let mut gap = 8.0f64;
        for index in 0..40 {
            let report = format!("\x1b[<{button};23;21M");
            let key = format!("wheel-{label}-{fling}-{index}");
            let sent = Instant::now();
            request(
                &mut writer,
                json!({"cmd": "send", "surface": surface.id,
                       "bytes": base64::engine::general_purpose::STANDARD.encode(report.as_bytes()), "key": key}),
            );
            reports += 1;
            // The first output after this report: its answer (the responder answers every read).
            match events.recv_timeout(Duration::from_secs(2)) {
                Ok((at, bytes)) => {
                    let ms = at.saturating_duration_since(sent).as_secs_f64() * 1000.0;
                    every.push(ms);
                    if index == 0 {
                        first_of_fling.push(ms);
                    }
                    bytes_back += bytes.len();
                }
                Err(_) => panic!("no output within 2 s of wheel report {reports}"),
            }
            // The rest of this report's answer, then the fling's next gap.
            let next = sent + Duration::from_secs_f64(gap / 1000.0);
            while let Ok((_, bytes)) =
                events.recv_timeout(next.saturating_duration_since(Instant::now()))
            {
                bytes_back += bytes.len();
            }
            gap = (gap * 1.06).min(70.0);
        }
        std::thread::sleep(Duration::from_millis(300));
        while let Ok((_, bytes)) = events.try_recv() {
            bytes_back += bytes.len();
        }
    }
    drop(writer);
    mux.shutdown();
    let _ = handler.join();
    let _ = reader.join();
    format!(
        "wheel_round_trip {label} responder={} reports={reports} bytes/report={} first_of_fling[{}] every_report[{}]",
        if python { "python3" } else { "cat" },
        bytes_back / reports.max(1),
        stats(&mut first_of_fling),
        stats(&mut every),
    )
}

#[cfg(unix)]
#[test]
#[ignore = "bench: cargo test -p cmux-tui-core wheel_round_trip -- --ignored --nocapture"]
fn wheel_round_trip() {
    for (label, capabilities) in [
        ("phone-default", &[][..]),
        ("output-coalesce-v1", &[ATTACH_OUTPUT_COALESCE_CAPABILITY][..]),
    ] {
        for run in 0..3 {
            println!("{} run={run}", run_variant(label, capabilities));
        }
    }
}
