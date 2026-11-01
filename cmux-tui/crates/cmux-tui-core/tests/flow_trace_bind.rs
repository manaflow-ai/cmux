//! The daemon's own bind starts key-press flow marks (`CMUX_TRACE_FLOWS`), in its own process (this test
//! binary). The headless daemon binds with `bind_session_socket(..).serve_restoring()` and never calls
//! `server::serve`, so a mark started only in `serve` left the daemon with no flow file: trace.py then
//! joined 0 of 29 key presses (fleet step 478be279, cmuxs-Mac-mini, macOS 27.0.1).

#![cfg(unix)]

#[test]
fn the_daemon_bind_path_starts_flow_marks() {
    let dir = std::env::temp_dir().join(format!("cmux-flow-bind-test-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    // SAFETY: set before any thread of this test binary reads the environment (`init` reads it once).
    unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &dir) };
    // An explicit socket's folder must be a real directory, never a symlink
    // (`server/listen.rs`), and macOS's /tmp is a symlink to /private/tmp: the resolved /tmp,
    // still short enough for a socket path.
    let socket = std::fs::canonicalize("/tmp")
        .unwrap()
        .join(format!("cmux-flow-bind-{}.sock", std::process::id()));
    let _ = std::fs::remove_file(&socket);
    let server = cmux_tui_core::server::bind_session_socket("flow-bind-test", Some(socket.clone()))
        .unwrap()
        .serve_restoring()
        .unwrap();
    assert!(cmux_flow_trace::enabled(), "binding the daemon's socket did not start flow marks");
    cmux_flow_trace::hop("daemon.send.write", 7, "00ff");
    assert!(cmux_flow_trace::flush());
    let text =
        std::fs::read_to_string(dir.join(format!("flows-{}.jsonl", std::process::id()))).unwrap();
    assert!(text.contains("\"hop\":\"daemon.send.write\",\"flow\":7"), "{text}");
    drop(server);
    let _ = std::fs::remove_file(&socket);
    let _ = std::fs::remove_dir_all(&dir);
}
