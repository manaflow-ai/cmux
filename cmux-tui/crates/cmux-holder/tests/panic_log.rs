//! A holder panic reaches the panic log the daemon names (p10-stability-150):
//! the release profile unwinds, so no system crash report has it, and it can
//! end every terminal the holder keeps. The cmux-next app sends new lines to
//! Sentry (`RustPanicSource.holder`). One test in this binary: it installs
//! the process's panic hook.

#![cfg(unix)]

use std::path::Path;

use cmux_holder::client::launch_with;
use cmux_holder::panic_log::{PANIC_LOG_ENV, PANIC_LOG_VERSION_ENV, TEST_PANIC_THREAD};

mod support;

#[test]
fn a_holder_thread_panic_is_one_line_in_the_log_the_daemon_names() {
    let dir = support::unique_dir("hpl");
    let log = dir.join("holder-panics.jsonl");

    // A holder given the log starts and serves as before.
    let mut child = launch_with(
        Path::new(env!("CARGO_BIN_EXE_cmux-holder")),
        &dir.join("h.sock"),
        &[0x22; 32],
        |command| {
            command.env(PANIC_LOG_ENV, &log).env(PANIC_LOG_VERSION_ENV, "9.8.7");
        },
    )
    .expect("a holder with a panic log starts");
    let _ = child.kill();
    let _ = child.wait();

    cmux_holder::panic_log::install(log.clone(), Some("9.8.7"));
    let joined = std::thread::Builder::new()
        .name(TEST_PANIC_THREAD.into())
        .spawn(|| panic!("cmux-holder test panic"))
        .unwrap()
        .join();
    assert!(joined.is_err(), "the thread panicked");
    let text = std::fs::read_to_string(&log).expect("the panic log exists");
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(&log).unwrap().permissions().mode() & 0o777
    };
    let _ = std::fs::remove_dir_all(&dir);

    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 1, "{text}");
    let record: serde_json::Value = serde_json::from_str(lines[0]).expect("one JSON object");
    assert_eq!(record["process"], "cmux-holder", "{record}");
    assert_eq!(record["message"], "cmux-holder test panic", "{record}");
    assert_eq!(record["thread"], TEST_PANIC_THREAD, "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert_eq!(record["version"], "9.8.7", "{record}");
    assert_eq!(record["os"], std::env::consts::OS, "{record}");
    assert_eq!(record["arch"], std::env::consts::ARCH, "{record}");
    assert_eq!(record["pid"].as_u64(), Some(u64::from(std::process::id())), "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains("panic_log.rs:"), "{record}");
    assert!(record["backtrace"].is_string(), "{record}");
    assert_eq!(mode, 0o600, "the panic log is owner-only");
}
