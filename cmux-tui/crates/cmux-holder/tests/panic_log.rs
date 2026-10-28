//! The holder's panic log: with the hook `main`
//! installs, a panic appends one line to `holder-panics.jsonl` beside the
//! socket, through cmux-panic-log's std-only writer, and the previous hook
//! still runs. Its own test binary, so the process's panic hook touches no
//! other test.

#![cfg(unix)]

use std::sync::atomic::{AtomicBool, Ordering};

mod support;

static PREVIOUS_RAN: AtomicBool = AtomicBool::new(false);

#[test]
fn a_holder_panic_writes_one_line_to_holder_panics_jsonl() {
    let dir = support::unique_dir("cmhp");
    let socket = dir.join("h.sock");
    assert_eq!(cmux_holder::panic_log::log_path(&socket), Some(dir.join("holder-panics.jsonl")));
    std::panic::set_hook(Box::new(|_| PREVIOUS_RAN.store(true, Ordering::SeqCst)));
    let args = ["--socket".to_string(), socket.display().to_string()];
    cmux_holder::panic_log::install(&args);

    let joined = std::thread::Builder::new()
        .name("holder-loop".into())
        .spawn(|| panic!("cmux-holder \"test\" panic"))
        .unwrap()
        .join();
    assert!(joined.is_err(), "the thread panicked");
    assert!(PREVIOUS_RAN.load(Ordering::SeqCst), "the previous hook ran after the line");

    let log = dir.join("holder-panics.jsonl");
    let text = std::fs::read_to_string(&log).unwrap();
    assert_eq!(text.lines().count(), 1, "one panic, one line: {text}");
    let record: serde_json::Value = serde_json::from_str(text.trim_end()).unwrap();
    assert_eq!(record["process"], "cmux-holder", "{record}");
    assert_eq!(record["message"], "cmux-holder \"test\" panic", "{record}");
    assert_eq!(record["thread"], "holder-loop", "{record}");
    assert_eq!(record["test"], false, "{record}");
    assert_eq!(record["holder_pid"].as_u64(), Some(u64::from(std::process::id())), "{record}");
    assert_eq!(record["holder_socket"], "h.sock", "{record}");
    assert_eq!(record["holder_wire"], cmux_holder::version_line(), "{record}");
    assert_eq!(record["os"], std::env::consts::OS, "{record}");
    assert!(record["location"].as_str().unwrap_or_default().contains("panic_log.rs:"), "{record}");
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(&log).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn no_socket_argument_no_log() {
    assert_eq!(cmux_holder::panic_log::log_path(std::path::Path::new("h.sock")), None);
}
