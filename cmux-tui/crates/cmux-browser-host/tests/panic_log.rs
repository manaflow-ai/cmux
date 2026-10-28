//! The browser host's panic log. A worker-thread
//! panic appends one JSON line (owner-only) and ends only its thread.
#![cfg(unix)]

#[test]
fn panic_log_gets_one_line_per_panic() {
    let dir = std::env::temp_dir().join(format!("cmux-bhp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let log = dir.join("browser-host-panics.jsonl");
    cmux_browser_host::panic_log::install(log.clone());
    let worker = std::thread::Builder::new()
        .name("browser-host-worker".into())
        .spawn(|| panic!("cmux-browser-host worker panic"))
        .unwrap();
    assert!(worker.join().is_err(), "the worker panicked");
    let text = std::fs::read_to_string(&log).expect("the panic log exists");
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(&log).unwrap().permissions().mode() & 0o777
    };
    let _ = std::fs::remove_dir_all(&dir);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1, "{text}");
    let record: serde_json::Value = serde_json::from_str(lines[0]).unwrap();
    assert_eq!(record["process"], "cmux-browser-host", "{record}");
    assert_eq!(record["message"], "cmux-browser-host worker panic", "{record}");
    assert_eq!(record["thread"], "browser-host-worker", "{record}");
    assert_eq!(record["test"], false, "{record}");
    assert_eq!(record["pid"].as_u64(), Some(u64::from(std::process::id())), "{record}");
    assert_eq!(mode, 0o600);
}
