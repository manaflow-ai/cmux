//! A holder panic reaches the panic log the daemon names (p10-stability-150):
//! the release profile unwinds, so no system crash report has it, and it can
//! end every terminal the holder keeps. The cmux-next app sends new lines to
//! Sentry (`RustPanicSource.holder`).

#![cfg(all(unix, debug_assertions))]

use std::path::Path;
use std::time::{Duration, Instant};

use cmux_holder::client::launch_with;
use cmux_holder::panic_log::{PANIC_LOG_ENV, PANIC_LOG_VERSION_ENV, TEST_PANIC_ENV};

mod support;

#[test]
fn a_holder_thread_panic_is_one_line_in_the_log_the_daemon_names() {
    let dir = support::unique_dir("hpl");
    let log = dir.join("holder-panics.jsonl");
    let mut child = launch_with(
        Path::new(env!("CARGO_BIN_EXE_cmux-holder")),
        &dir.join("h.sock"),
        &[0x22; 32],
        |command| {
            command
                .env(PANIC_LOG_ENV, &log)
                .env(PANIC_LOG_VERSION_ENV, "9.8.7")
                .env(TEST_PANIC_ENV, "thread");
        },
    )
    .expect("the holder starts");
    let deadline = Instant::now() + Duration::from_secs(20);
    let line = loop {
        if let Some(line) = std::fs::read_to_string(&log)
            .ok()
            .and_then(|text| text.lines().next().map(String::from))
        {
            break line;
        }
        assert!(Instant::now() < deadline, "nothing in {}", log.display());
        std::thread::sleep(Duration::from_millis(20));
    };
    // The panic ended only its own thread.
    std::thread::sleep(Duration::from_millis(200));
    let alive = child.try_wait().unwrap().is_none();
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(&log).unwrap().permissions().mode() & 0o777
    };
    let _ = child.kill();
    let _ = child.wait();
    let _ = std::fs::remove_dir_all(&dir);

    let record: serde_json::Value = serde_json::from_str(&line).expect("one JSON object per line");
    assert_eq!(record["process"], "cmux-holder", "{record}");
    assert_eq!(record["message"], "cmux-holder test panic", "{record}");
    assert_eq!(record["thread"], "holder-panic-test", "{record}");
    assert_eq!(record["test"], true, "{record}");
    assert_eq!(record["version"], "9.8.7", "{record}");
    assert_eq!(record["os"], std::env::consts::OS, "{record}");
    assert_eq!(record["arch"], std::env::consts::ARCH, "{record}");
    assert_eq!(record["pid"].as_u64(), Some(u64::from(child.id())), "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains("panic_log.rs:"), "{record}");
    assert!(record["backtrace"].is_string(), "{record}");
    assert!(alive, "the holder keeps serving");
    assert_eq!(mode, 0o600, "the panic log is owner-only");
}
