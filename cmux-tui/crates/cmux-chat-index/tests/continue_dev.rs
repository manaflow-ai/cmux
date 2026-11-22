mod common;

use cmux_chat_index::{AdapterKind, PathRole, Resume, TitleSource, classify_path};
use common::{by_id, ids, scan, set_mtime_ms, write};
use serde_json::json;

const A: &str = "c0000000-0000-4000-8000-000000000001";
const B: &str = "c0000000-0000-4000-8000-000000000002";
const C: &str = "c0000000-0000-4000-8000-000000000003";

fn session(id: &str, title: &str, dir: &str) -> String {
    json!({"sessionId":id,"title":title,"workspaceDirectory":dir,"history":[
        {"message":{"role":"user","content":"wire up auth\nplease"},"contextItems":[]},
        {"message":{"role":"assistant","content":"done"},"contextItems":[]},
        {"message":{"role":"user","content":[{"type":"text","text":"more"}]},"contextItems":[]},
        {"message":{"role":"assistant","content":"ok"},"contextItems":[]}]})
    .to_string()
}

#[test]
fn the_index_and_unindexed_session_files_are_read() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path();
    write(
        &root.join("sessions.json"),
        &json!([
            {"sessionId":A,"title":"Auth wiring","dateCreated":"1790848800000","workspaceDirectory":"/work/cn","messageCount":2},
            {"sessionId":B,"title":"New Session","dateCreated":"1790848900000","workspaceDirectory":"file:///Users/me/my%20app","messageCount":2},
            {"session_id":"legacy","title":"Legacy shape"}
        ])
        .to_string(),
    );
    write(&root.join(format!("{A}.json")), &session(A, "Auth wiring", "/work/cn"));
    set_mtime_ms(&root.join(format!("{A}.json")), 1_790_852_400_000);
    write(&root.join(format!("{B}.json")), &session(B, "New Session", "file:///Users/me/my%20app"));
    // Not in the index (written after the index, or the index was lost).
    write(&root.join(format!("{C}.json")), &session(C, "", "/work/other"));
    set_mtime_ms(&root.join(format!("{C}.json")), 1_790_860_000_000);

    let scan = scan(AdapterKind::Continue, root);
    assert!(scan.database);
    assert_eq!(ids(&scan), [A, B, C].map(String::from).into());
    let chats = by_id(&scan);
    let a = &chats[A];
    assert_eq!((a.title.as_deref(), a.title_source), (Some("Auth wiring"), Some(TitleSource::Ai)));
    assert_eq!(a.cwd.as_deref(), Some("/work/cn"));
    assert_eq!((a.created_ms, a.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(a.message_count, Some(2));
    assert_eq!(a.resume, Resume::ReadOnly);
    let b = &chats[B];
    assert_eq!(
        (b.title.as_deref(), b.title_source),
        (Some("wire up auth"), Some(TitleSource::Prompt)),
        "the placeholder title gives way to the first prompt"
    );
    assert_eq!(b.cwd.as_deref(), Some("/Users/me/my app"));
    let c = &chats[C];
    assert_eq!((c.title.as_deref(), c.message_count), (Some("wire up auth"), Some(2)));
    assert_eq!((c.created_ms, c.updated_ms), (None, 1_790_860_000_000));
    assert_eq!(c.cwd.as_deref(), Some("/work/other"));
}

#[test]
fn a_missing_index_still_lists_session_files() {
    let dir = tempfile::tempdir().unwrap();
    write(&dir.path().join(format!("{A}.json")), &session(A, "Only file", "/w"));
    let entry = by_id(&scan(AdapterKind::Continue, dir.path())).remove(A).unwrap();
    assert_eq!(entry.title.as_deref(), Some("Only file"));
}

#[test]
fn paths_are_classified() {
    let root = std::path::Path::new("/s");
    let role = |rel: &str| classify_path(AdapterKind::Continue, root, &root.join(rel));
    assert_eq!(role("sessions.json"), PathRole::Store);
    assert_eq!(role("x.json"), PathRole::Store);
    assert_eq!(role("sub/x.json"), PathRole::Ignore);
}
