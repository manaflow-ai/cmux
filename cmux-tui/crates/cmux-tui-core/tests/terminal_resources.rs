//! `terminal-resources` for a PTY the daemon owns itself (no terminal host).
#![cfg(unix)]

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
fn cmux_next_terminal_resources_in_daemon_pty_has_no_host() {
    let options = SurfaceOptions {
        command: Some(vec!["/bin/sh".into(), "-c".into(), "sleep 60 & wait".into()]),
        ..Default::default()
    };
    let mux = Mux::new(unique_session("test-terminal-resources"), options);
    let surface = mux.new_workspace(None, None).unwrap();
    let sock_path = cmux_tui_core::server::serve(mux.clone(), None).unwrap();
    let stream = transport::connect(&sock_path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let mut next_id = 0u64;
    let mut request = |value: serde_json::Value| {
        next_id += 1;
        let mut value = value;
        value["id"] = next_id.into();
        writeln!(writer, "{value}").unwrap();
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let response: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(response["ok"], true, "{value} failed: {response}");
        response["data"].clone()
    };

    let deadline = Instant::now() + Duration::from_secs(10);
    let terminal = loop {
        let data = request(serde_json::json!({"cmd": "terminal-resources"}));
        assert_eq!(data["missing"], serde_json::json!([]), "{data}");
        let terminal = data["terminals"]
            .as_array()
            .into_iter()
            .flatten()
            .find(|terminal| terminal["surface"] == surface.id)
            .cloned()
            .unwrap_or_else(|| panic!("surface {} is not reported: {data}", surface.id));
        let processes = terminal["processes"].as_array().map(Vec::len).unwrap_or(0);
        if processes >= 2 {
            break terminal;
        }
        assert!(Instant::now() < deadline, "the sleep never appeared: {data}");
        std::thread::sleep(Duration::from_millis(50));
    };
    // The daemon is the shell's parent, so there is no terminal host.
    assert!(terminal["host"].is_null(), "{terminal}");
    assert!(terminal["terminal_id"].is_null(), "{terminal}");
    assert_eq!(terminal["processes"][0]["pid"], terminal["pid"], "{terminal}");
    assert_eq!(terminal["processes"][0]["ppid"], std::process::id(), "{terminal}");

    mux.close_surface(surface.id).unwrap();
    cmux_tui_core::server::cleanup(&sock_path);
}
