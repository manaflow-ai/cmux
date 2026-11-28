use super::*;

#[test]
fn resume_runs_the_harness_own_command() {
    assert_eq!(resume_argv("claude", "abc"), ["claude", "--resume", "abc"]);
    assert_eq!(resume_argv("codex", "abc"), ["codex", "resume", "abc"]);
}

#[test]
fn a_rollout_with_item_kinds_is_read_by_its_items() {
    let dir = std::env::temp_dir().join(format!("acpmux-release-{}", uuid::Uuid::now_v7()));
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join("rollout.jsonl");
    let item = json!({"type": "response_item", "payload": {"type": "message", "role": "user",
        "content": [{"type": "input_text", "text": "hi"}],
        "internal_chat_message_metadata_passthrough": {"content_item_kinds": ["user.text"]}}});
    std::fs::write(&file, format!("{item}\n")).unwrap();
    let (len, items) = transcript_end(&file, true);
    assert_eq!(len, std::fs::metadata(&file).unwrap().len());
    assert!(items);
    assert!(!transcript_end(&file, false).1);
    assert_eq!(transcript_end(&dir.join("gone.jsonl"), true), (0, false));
    let _ = std::fs::remove_dir_all(&dir);
}
