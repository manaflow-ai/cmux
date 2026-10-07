mod common;

use cmux_chat_index::{AdapterKind, Resume, TitleSource};
use common::{by_id, ids, scan, set_mtime_ms, write};
use serde_json::json;

#[test]
fn local_thread_files_give_folderless_chats() {
    let dir = tempfile::tempdir().unwrap();
    let id = "T-5f0c0000-0000-4000-8000-000000000001";
    let path = dir.path().join(format!("{id}.json"));
    write(
        &path,
        &json!({"id":id,"created":1_790_848_800_000_i64,"messages":[
        {"role":"user","content":[{"type":"text","text":"amp task\nwith detail"}]},
        {"role":"assistant","content":[{"type":"text","text":"ok"}]},
        {"role":"user","content":[{"type":"text","text":"more"}]}]})
        .to_string(),
    );
    set_mtime_ms(&path, 1_790_852_400_000);
    write(&dir.path().join("settings.json"), "{}");

    let scan = scan(AdapterKind::Amp, dir.path());
    assert_eq!(ids(&scan), [id.to_owned()].into());
    let entry = &by_id(&scan)[id];
    assert_eq!(
        (entry.title.as_deref(), entry.title_source),
        (Some("amp task"), Some(TitleSource::Prompt))
    );
    assert_eq!(entry.cwd, None);
    assert_eq!((entry.created_ms, entry.updated_ms), (Some(1_790_848_800_000), 1_790_852_400_000));
    assert_eq!(entry.message_count, Some(3));
    let argv = ["amp", "threads", "continue", id].map(String::from).to_vec();
    assert_eq!(entry.resume, Resume::Argv { argv, cwd_needed: false });
}
