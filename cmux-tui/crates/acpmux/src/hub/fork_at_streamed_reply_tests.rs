use super::*;
use serde_json::json;

/// A Claude store holding `records` as session `parent`'s transcript; returns its root.
fn store(parent: &str, records: &[Value]) -> std::path::PathBuf {
    let root = std::env::temp_dir().join(format!("acpmux-fork-now-{}", uuid::Uuid::now_v7()));
    let project = root.join("projects").join("p");
    std::fs::create_dir_all(&project).unwrap();
    let text: String = records.iter().map(|r| format!("{r}\n")).collect();
    std::fs::write(project.join(format!("{parent}.jsonl")), text).unwrap();
    root
}

fn copy(root: &Path, id: &str) -> Vec<Value> {
    let file = root.join("projects").join("p").join(format!("{id}.jsonl"));
    std::fs::read_to_string(file)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect()
}

fn prompt() -> Value {
    json!({"type": "user", "sessionId": "parent-1", "uuid": "u1", "timestamp": "2026-11-22T08:35:20.062Z",
           "cwd": "/w", "message": {"role": "user", "content": [{"type": "text", "text": "count to 400"}]}})
}

/// The reply the chat was streaming, of which Claude Code stored only its thinking, ends
/// the copy as the agent's own text, chained after the transcript's last line (cmux#50021).
#[test]
fn a_reply_still_streaming_ends_the_copy_as_its_text() {
    let thinking = json!({"type": "assistant", "sessionId": "parent-1", "uuid": "a1", "parentUuid": "u1",
        "timestamp": "2026-11-22T08:35:22.000Z", "cwd": "/w",
        "message": {"id": "msg_live", "role": "assistant", "model": "claude-haiku-5-5",
                    "content": [{"type": "thinking", "thinking": "counting"}]}});
    // A line with no uuid (Claude's bookkeeping) does not break the chain.
    let bookkeeping = json!({"type": "queue-operation", "sessionId": "parent-1"});
    let root = store("parent-1", &[prompt(), thinking, bookkeeping]);
    let streamed = vec![
        ("msg_live".to_owned(), "one, two, three".to_owned()),
        ("msg_empty".to_owned(), " ".to_owned()),
    ];
    let id = claude_transcript_now(&root, "parent-1", &streamed).unwrap();
    // The copy is the owner's only, whatever the umask (review F2 on #41462).
    #[cfg(unix)]
    {
        let file = root.join("projects").join("p").join(format!("{id}.jsonl"));
        let mode = std::os::unix::fs::PermissionsExt::mode(
            &std::fs::metadata(&file).unwrap().permissions(),
        );
        assert_eq!(mode & 0o777, 0o600, "mode {mode:o}");
    }
    let lines = copy(&root, &id);
    assert_eq!(lines.len(), 4, "{lines:#?}");
    let last = &lines[3];
    assert_eq!(last["type"], "assistant");
    assert_eq!(last["sessionId"], json!(id));
    assert_eq!(last["parentUuid"], "a1");
    assert!(last["uuid"].is_string());
    assert_eq!(last["message"]["id"], "msg_live");
    assert_eq!(last["message"]["model"], "claude-haiku-5-5");
    assert_eq!(last["message"]["content"], json!([{"type": "text", "text": "one, two, three"}]));
    assert_eq!(last["cwd"], "/w");
    let _ = std::fs::remove_dir_all(&root);
}

/// A message whose text the transcript holds already is not written again.
#[test]
fn a_stored_reply_is_not_repeated() {
    let answer = json!({"type": "assistant", "sessionId": "parent-2", "uuid": "a1", "parentUuid": "u1",
        "message": {"id": "msg_done", "role": "assistant", "content": [{"type": "text", "text": "one, two"}]}});
    let root = store("parent-2", &[prompt(), answer]);
    let streamed = vec![("msg_done".to_owned(), "one, two".to_owned())];
    let id = claude_transcript_now(&root, "parent-2", &streamed).unwrap();
    assert_eq!(copy(&root, &id).len(), 2);
    let _ = std::fs::remove_dir_all(&root);
}
