//! The std-only writer: a panic on any thread lands in the log as one JSON
//! line, with the caller's fields, and the previous hook still runs.

#![cfg(feature = "minimal")]

use std::sync::atomic::{AtomicBool, Ordering};

use cmux_panic_log::minimal;

static PREVIOUS_RAN: AtomicBool = AtomicBool::new(false);

#[test]
fn a_thread_panic_is_one_parsable_line_with_fields() {
    let dir = std::env::temp_dir().join(format!("cmux-panic-log-minimal-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("holder-panics.jsonl");
    std::panic::set_hook(Box::new(|_| PREVIOUS_RAN.store(true, Ordering::SeqCst)));
    let mut fields = minimal::Fields::new();
    fields.insert("process", "cmux-holder");
    fields.insert("holder_pid", std::process::id());
    minimal::install(path.clone(), fields, |thread| thread == "test-trigger");

    let joined = std::thread::Builder::new()
        .name("worker".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("bad \"frame\"\n\tat {}", "\u{1}"))
        .unwrap()
        .join();
    assert!(joined.is_err());

    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> =
        text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 1, "{text}");
    assert_eq!(lines[0]["process"], "cmux-holder");
    assert_eq!(lines[0]["holder_pid"], std::process::id());
    assert_eq!(lines[0]["message"], "bad \"frame\"\n\tat \u{1}");
    assert_eq!(lines[0]["thread"], "worker");
    assert_eq!(lines[0]["test"], false);
    assert!(lines[0]["location"].as_str().unwrap().contains("minimal.rs:"));
    assert!(lines[0]["backtrace"].is_string());
    assert!(PREVIOUS_RAN.load(Ordering::SeqCst));
    let _ = std::fs::remove_dir_all(&dir);
}
