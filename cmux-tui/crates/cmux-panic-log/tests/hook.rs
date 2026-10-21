//! A panic on any thread lands in the log as one JSON line, with the
//! caller's fields, and the previous hook still runs.

use std::sync::atomic::{AtomicBool, Ordering};

static PREVIOUS_RAN: AtomicBool = AtomicBool::new(false);

#[test]
fn a_thread_panic_is_appended_with_fields_and_the_previous_hook_runs() {
    let dir = std::env::temp_dir().join(format!("cmux-panic-log-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("panics.jsonl");
    let _ = std::fs::remove_file(&path);
    std::panic::set_hook(Box::new(|_| PREVIOUS_RAN.store(true, Ordering::SeqCst)));
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "acpmux".into());
    cmux_panic_log::install(path.clone(), fields, |thread| thread == "test-trigger");

    let joined = std::thread::Builder::new()
        .name("worker".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("comparison is not a total order"))
        .unwrap()
        .join();
    assert!(joined.is_err());
    let _ = std::thread::Builder::new()
        .name("test-trigger".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("debug trigger"))
        .unwrap()
        .join();

    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> =
        text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert_eq!(lines[0]["process"], "acpmux");
    assert_eq!(lines[0]["message"], "comparison is not a total order");
    assert_eq!(lines[0]["thread"], "worker");
    assert_eq!(lines[0]["test"], false);
    assert!(lines[0]["location"].as_str().unwrap().contains("hook.rs:"));
    assert!(lines[0]["backtrace"].is_string());
    assert_eq!(lines[1]["test"], true);
    assert!(PREVIOUS_RAN.load(Ordering::SeqCst));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_long_backtrace_is_cut_on_a_char_boundary() {
    let long = "é".repeat(cmux_panic_log::MAX_BACKTRACE_BYTES);
    let line = cmux_panic_log::record(&cmux_panic_log::Fields::new(), "m", "l", "t", false, long);
    let kept = line["backtrace"].as_str().unwrap();
    assert!(kept.len() <= cmux_panic_log::MAX_BACKTRACE_BYTES);
}

#[cfg(windows)]
#[test]
fn append_never_follows_a_prepositioned_file_link() {
    use std::os::windows::fs::symlink_file;

    let dir = std::env::temp_dir().join(format!("cmux-panic-log-link-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let target = dir.join("target.jsonl");
    let linked = dir.join("panics.jsonl");
    std::fs::write(&target, "unchanged\n").unwrap();
    symlink_file(&target, &linked).unwrap();
    cmux_panic_log::append(&linked, &serde_json::json!({"message": "must not land"}));
    assert_eq!(std::fs::read_to_string(&target).unwrap(), "unchanged\n");
    let _ = std::fs::remove_dir_all(&dir);
}
