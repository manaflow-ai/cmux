use super::serve;
use serde_json::Value;

fn replies(input: &str) -> Vec<Value> {
    let mut output = Vec::new();
    serve(input.as_bytes(), &mut output).expect("serve");
    String::from_utf8(output)
        .expect("utf-8")
        .lines()
        .map(|line| serde_json::from_str(line).expect("json"))
        .collect()
}

#[test]
fn lists_a_folder_with_kinds_sizes_and_hidden_flags() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(dir.path().join("a.txt"), b"hello").expect("write");
    std::fs::write(dir.path().join(".secret"), b"").expect("write");
    std::fs::create_dir(dir.path().join("sub")).expect("mkdir");
    std::os::unix::fs::symlink("a.txt", dir.path().join("link")).expect("symlink");
    let request =
        format!("{{\"id\":7,\"op\":\"list\",\"path\":{}}}\n", serde_json::json!(dir.path()));
    let reply = &replies(&request)[0];
    assert_eq!(reply["id"], 7);
    let mut entries = reply["entries"].as_array().expect("entries").clone();
    entries.sort_by_key(|entry| entry["n"].as_str().unwrap_or_default().to_owned());
    let summary: Vec<(String, String, u64, bool)> = entries
        .iter()
        .map(|entry| {
            (
                entry["n"].as_str().unwrap_or_default().to_owned(),
                entry["k"].as_str().unwrap_or_default().to_owned(),
                entry["s"].as_u64().unwrap_or(99),
                entry["h"].as_bool().unwrap_or_default(),
            )
        })
        .collect();
    assert_eq!(
        summary,
        vec![
            (".secret".into(), "file".into(), 0, true),
            ("a.txt".into(), "file".into(), 5, false),
            ("link".into(), "link".into(), 0, false),
            ("sub".into(), "dir".into(), 0, false),
        ]
    );
    assert!(entries[1]["m"].as_f64().unwrap_or_default() > 1_000_000_000.0);
}

#[test]
fn answers_errno_for_a_missing_folder_and_null_for_a_gone_item() {
    let lines = "{\"id\":1,\"op\":\"list\",\"path\":\"/nonexistent-cmux-files-lister\"}\n\
                     {\"id\":2,\"op\":\"entry\",\"path\":\"/nonexistent-cmux-files-lister\"}\n";
    let replies = replies(lines);
    assert_eq!(replies[0]["errno"], libc::ENOENT);
    assert_eq!(replies[1], serde_json::json!({"id": 2, "entry": null}));
}

#[test]
fn answers_one_item_and_refuses_bad_lines_in_order() {
    let dir = tempfile::tempdir().expect("tempdir");
    std::fs::write(dir.path().join("b.bin"), b"123").expect("write");
    let path = dir.path().join("b.bin");
    let lines = format!(
        "not json\n{{\"id\":3,\"op\":\"entry\",\"path\":{}}}\n{{\"id\":4,\"op\":\"list\",\"path\":\"relative\"}}\n{{\"id\":5,\"op\":\"rm\",\"path\":\"/\"}}\n",
        serde_json::json!(path)
    );
    let replies = replies(&lines);
    assert_eq!(replies.len(), 4);
    assert!(replies[0]["error"].is_string());
    assert_eq!(replies[1]["entry"]["n"], "b.bin");
    assert_eq!(replies[1]["entry"]["s"], 3);
    assert_eq!(replies[2]["id"], 4);
    assert!(replies[2]["error"].is_string());
    assert_eq!(replies[3]["id"], 5);
    assert!(replies[3]["error"].as_str().unwrap_or_default().contains("unknown op"));
}

#[test]
fn refuses_an_oversized_line_and_keeps_serving() {
    let lines = format!(
        "{}\n{{\"id\":9,\"op\":\"entry\",\"path\":\"/\"}}\n",
        "x".repeat(super::MAX_LINE + 10)
    );
    let replies = replies(&lines);
    assert_eq!(replies.len(), 2);
    assert_eq!(replies[0]["error"], "request line too long");
    assert_eq!(replies[1]["id"], 9);
    assert_eq!(replies[1]["entry"]["k"], "dir");
}
