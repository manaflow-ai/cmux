//! `memory-report` over the daemon's Unix socket with three live shells: each
//! terminal is reported once, and the one that printed most holds the most
//! scrollback.
#![cfg(unix)]

use cmux_tui_core::Actor;
use std::io::{BufRead, BufReader, Write};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cmux_tui_core::platform::transport;
use cmux_tui_core::{Mux, SurfaceOptions};

fn unique_session(prefix: &str) -> String {
    static NEXT: AtomicU64 = AtomicU64::new(1);
    format!("{prefix}-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed))
}

#[test]
fn memory_report_over_the_socket_reports_three_terminals() {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "sleep 60 & wait".into()]),
        ..Default::default()
    };
    let mux = Mux::new(unique_session("test-memory-report"), options);
    let quiet = mux.new_workspace_as(&Actor::Daemon, None, None).unwrap();
    let busy = mux.new_workspace_as(&Actor::Daemon, None, None).unwrap();
    let third = mux.new_workspace_as(&Actor::Daemon, None, None).unwrap();
    // The busy terminal's history comes straight into its parser.
    let lines: String = (0..20_000).map(|line| format!("busy history line {line}\r\n")).collect();
    busy.with_terminal(|term| term.vt_write(lines.as_bytes())).unwrap();
    let surfaces = [quiet.id, busy.id, third.id];
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = transport::connect(&sock_path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let mut request = |value: serde_json::Value| {
        writeln!(writer, "{value}").unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let response: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["ok"], true, "{value} failed: {response}");
        response["data"].clone()
    };

    let deadline = Instant::now() + Duration::from_secs(10);
    let data = loop {
        let data = request(serde_json::json!({"id": 1, "cmd": "memory-report"}));
        let reported = data["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|terminal| surfaces.iter().any(|surface| terminal["surface"] == *surface))
            .count();
        if reported == 3 {
            break data;
        }
        assert!(Instant::now() < deadline, "three terminals never appeared: {data}");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert_eq!(data["pid"], std::process::id(), "{data}");
    assert_eq!(data["totals"]["terminals"], 3, "{data}");
    let live = |surface: u64| -> u64 {
        let terminal = data["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["surface"] == surface)
            .unwrap();
        assert_eq!(terminal["home"], "daemon", "{terminal}");
        terminal["scrollback"]["live_bytes"].as_u64().unwrap()
    };
    assert!(live(busy.id) > live(quiet.id), "{data}");
    assert!(data["process"]["private_footprint_bytes"].as_u64().unwrap() > 0, "{data}");
    assert!(data["consumers"].is_array(), "{data}");

    for surface in surfaces {
        mux.close_surface_as(&Actor::Daemon, surface).unwrap();
    }
    cmux_tui_core::server::cleanup(&sock_path);
}
