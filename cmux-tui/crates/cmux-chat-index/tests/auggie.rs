mod common;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, write};
use serde_json::{Value, json};

const A: &str = "a0000000-0000-4000-8000-000000000001";
const B: &str = "a0000000-0000-4000-8000-000000000002";
const CHILD: &str = "a0000000-0000-4000-8000-000000000003";

fn exchange(message: &str) -> Value {
    json!({"exchange":{"request_message":message,"request_id":"r","response_text":"ok",
        "request_nodes":[
            {"id":1,"type":0,"text_node":{"content":message}},
            {"id":2,"type":4,"ide_state_node":{"workspace_folders":[{"repository_root":"/work/aug","folder_root":"/work/aug/sub"}]}}]},
        "completed":true,"sequenceId":1})
}

fn session(id: &str, extra: Value) -> String {
    let mut base = json!({"sessionId":id,"created":"2026-10-01T10:00:00.000Z","modified":"2026-10-01T11:00:00.000Z",
        "chatHistory":[exchange("refactor the cache"), exchange("now test it")],"agentState":{"modelId":"m"}});
    if let (Some(base), Some(extra)) = (base.as_object_mut(), extra.as_object()) {
        base.extend(extra.clone());
    }
    base.to_string()
}

#[test]
fn session_files_give_titles_folders_and_counts() {
    let dir = tempfile::tempdir().unwrap();
    write(
        &dir.path().join(format!("{A}.json")),
        &session(A, json!({"title":"Cache work","customTitle":"My cache"})),
    );
    write(&dir.path().join(format!("{B}.json")), &session(B, json!({})));
    write(&dir.path().join(format!("{A}-backup1.json")), &session(A, json!({"customTitle":"old"})));
    write(
        &dir.path().join(format!("{CHILD}.json")),
        &session(CHILD, json!({"parentConversationId":A})),
    );

    let scan = scan(AdapterKind::Auggie, dir.path());
    assert_eq!(ids(&scan), [A.to_owned(), B.to_owned()].into());
    let chats = by_id(&scan);
    let a = &chats[A];
    assert_eq!((a.title.as_deref(), a.title_source), (Some("My cache"), Some(TitleSource::Custom)));
    assert_eq!(a.cwd.as_deref(), Some("/work/aug"));
    assert_eq!((a.created_ms, a.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(a.message_count, Some(2));
    assert_eq!(a.resume, Resume::ReadOnly);
    let b = &chats[B];
    assert_eq!(
        (b.title.as_deref(), b.title_source),
        (Some("refactor the cache"), Some(TitleSource::Prompt))
    );
}

#[test]
fn an_ai_title_is_used_without_a_custom_one() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join(format!("{A}.json")), &session(A, json!({"title":"Generated"})));
    let entry = by_id(&scan(AdapterKind::Auggie, dir.path())).remove(A).unwrap();
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("Generated"), Some(TitleSource::Ai))
    );
}

#[test]
fn paths_are_classified() {
    let root = std::path::Path::new("/a");
    let role = |rel: &str| classify_path(AdapterKind::Auggie, root, &root.join(rel));
    assert_eq!(role("x.json"), PathRole::Session);
    assert_eq!(role("x-backup2.json"), PathRole::Ignore);
    assert_eq!(role("sub/x.json"), PathRole::Ignore);
}
