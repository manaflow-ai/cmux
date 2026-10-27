//! The hang log: the file sink appends one owner-only line per record with
//! the process's fields, and a record before install goes nowhere.

use cmux_panic_log::hang;

#[test]
fn the_file_sink_appends_one_line_per_record_with_the_fields() {
    let dir = std::env::temp_dir().join(format!("cmux-hang-log-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("hangs.jsonl");
    let _ = std::fs::remove_file(&path);
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("session".into(), "s".into());
    fields.insert("scope".into(), "overridden".into());
    let sink = hang::file_sink(path.clone(), fields);
    sink(serde_json::json!({"event": "hang", "scope": "journal-writer", "method": "commit-batch"}));
    // Not an object: not a record.
    sink(serde_json::json!("ignored"));
    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> =
        text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 1, "{text}");
    assert_eq!(lines[0]["session"], "s");
    assert_eq!(lines[0]["scope"], "journal-writer", "the record's keys win");
    assert_eq!(lines[0]["method"], "commit-batch");
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_record_goes_to_the_installed_sink_only_after_install() {
    let (records, received) = std::sync::mpsc::channel();
    let records = std::sync::Mutex::new(records);
    hang::write(serde_json::json!({"before": true}));
    assert!(!hang::installed());
    let sink: hang::HangSink = Box::new(move |record| {
        let _ = records.lock().unwrap().send(record);
    });
    assert!(hang::install(sink).is_ok());
    assert!(hang::installed());
    assert!(hang::install(Box::new(|_| {})).is_err(), "one hang log per process");
    hang::write(serde_json::json!({"after": true}));
    assert_eq!(received.try_recv().unwrap(), serde_json::json!({"after": true}));
    assert!(received.try_recv().is_err(), "the record before install went nowhere");
}
