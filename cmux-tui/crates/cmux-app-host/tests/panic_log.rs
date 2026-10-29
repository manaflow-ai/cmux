//! The app host's panic log (`--panic-log`). A panic
//! after the sandbox holds still reaches the log, through the handle
//! `panic_log::install` opened before it.
#![cfg(unix)]

use std::path::Path;
use std::process::Command;

/// Set in the child copy of this test binary, with the log's path.
const CHILD_ENV: &str = "CMUX_APP_HOST_PANIC_LOG_CHILD";
const TEST: &str = "panic_log_gets_one_line_for_a_panic_inside_the_sandbox";

#[test]
fn panic_log_gets_one_line_for_a_panic_inside_the_sandbox() {
    if let Some(log) = std::env::var_os(CHILD_ENV) {
        // The child: install as `main` does, sandbox the thread, then panic.
        cmux_app_host::panic_log::install(Path::new(&log)).expect("open the panic log");
        cmux_app_host::sandbox::apply().expect("apply the sandbox");
        assert!(std::fs::read("/etc/hosts").is_err(), "the sandbox holds");
        panic!("cmux-app-host sandboxed panic");
    }
    let dir = std::env::temp_dir().join(format!("cmux-ahp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("scratch");
    let log = dir.join("app-host-panics.jsonl");
    let child = Command::new(std::env::current_exe().expect("this test binary"))
        .args(["--exact", TEST, "--test-threads", "1"])
        .env(CHILD_ENV, &log)
        .output()
        .expect("run the child");
    assert!(!child.status.success(), "the child's test panics");
    let text = std::fs::read_to_string(&log).expect("the panic log exists");
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(&log).expect("log").permissions().mode() & 0o777
    };
    let _ = std::fs::remove_dir_all(&dir);
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1, "{text}");
    let record: serde_json::Value = serde_json::from_str(lines[0]).expect("json line");
    assert_eq!(record["process"], "cmux-app-host", "{record}");
    assert_eq!(record["message"], "cmux-app-host sandboxed panic", "{record}");
    assert_eq!(record["test"], false, "{record}");
    assert!(record["pid"].as_u64().is_some(), "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains("panic_log.rs:"), "{record}");
    assert_eq!(mode, 0o600);
}
