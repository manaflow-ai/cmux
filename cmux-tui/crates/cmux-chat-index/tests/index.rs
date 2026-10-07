mod common;

use std::fs;
use std::path::Path;

use cmux_chat_index::{AdapterKind, ChatChange, ChatIndex, ChatRoot, RootSource};
use common::{append_jsonl, set_mtime_ms, write_jsonl};
use serde_json::{Value, json};

const X: &str = "aaaaaaaa-0000-4000-8000-000000000001";
const Y: &str = "aaaaaaaa-0000-4000-8000-000000000002";

fn root(path: &Path, accounts: &[&str]) -> ChatRoot {
    fs::create_dir_all(path).unwrap();
    ChatRoot {
        harness: AdapterKind::ClaudeCode,
        path: path.to_path_buf(),
        real_path: fs::canonicalize(path).unwrap(),
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: accounts.iter().map(|account| (*account).to_owned()).collect(),
    }
}

fn prompt(text: &str) -> Value {
    json!({"type":"user","cwd":"/work","message":{"role":"user","content":text}})
}

fn session(root: &Path, id: &str, text: &str, mtime: u64) -> std::path::PathBuf {
    let path = root.join("-work").join(format!("{id}.jsonl"));
    write_jsonl(&path, &[prompt(text)]);
    set_mtime_ms(&path, mtime);
    path
}

#[test]
fn the_same_session_in_two_roots_is_one_chat_and_the_newest_copy_wins() {
    let dir = tempfile::tempdir().unwrap();
    let (a, b) = (dir.path().join("a/projects"), dir.path().join("b/projects"));
    let roots = vec![root(&a, &[]), root(&b, &["work"])];
    session(&a, X, "old copy", 1_000);
    session(&b, X, "new copy", 2_000);
    session(&b, Y, "only in b", 1_500);
    let mut index = ChatIndex::new(roots.clone());
    let changes = index.rescan_all();
    assert_eq!(changes.len(), 2);
    let chats = index.chats();
    assert_eq!(chats.iter().map(|chat| chat.entry.session_id.as_str()).collect::<Vec<_>>(), [X, Y]);
    assert_eq!(chats[0].entry.title.as_deref(), Some("new copy"));
    assert_eq!(chats[0].roots, vec![roots[0].id(), roots[1].id()]);
    assert_eq!(chats[0].accounts, vec!["work".to_owned()]);
}

#[test]
fn file_events_upsert_and_remove_chats() {
    let dir = tempfile::tempdir().unwrap();
    let projects = dir.path().join("projects");
    let mut index = ChatIndex::new(vec![root(&projects, &[])]);
    let path = session(&projects, X, "hello", 1_000);
    index.rescan_all();
    append_jsonl(&path, &[prompt("again")]);
    let changes = index.path_changed(&path);
    let [ChatChange::Upsert { chat }] = changes.as_slice() else {
        panic!("expected one upsert: {changes:?}")
    };
    assert_eq!(chat.entry.message_count, Some(2));
    // A subagent write is not chat data.
    let subagent = projects.join("-work").join(X).join("subagents/agent-1.jsonl");
    write_jsonl(&subagent, &[prompt("sub")]);
    assert!(index.path_changed(&subagent).is_empty());
    fs::remove_file(&path).unwrap();
    let changes = index.path_changed(&path);
    assert!(matches!(changes.as_slice(), [ChatChange::Removed { key }] if key.session_id == X));
    assert!(index.chats().is_empty());
}

#[test]
fn the_cache_file_restores_chats_and_read_offsets() {
    let dir = tempfile::tempdir().unwrap();
    let projects = dir.path().join("projects");
    let roots = vec![root(&projects, &[])];
    let path = session(&projects, X, "hello", 1_000);
    let cache = dir.path().join("acpmux/chat-index/v1.json");
    let mut index = ChatIndex::new(roots.clone());
    index.rescan_all();
    index.save(&cache).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&cache).unwrap().permissions().mode() & 0o777, 0o600);
    }

    let mut restored = ChatIndex::load(&cache, roots);
    assert_eq!(restored.chats(), index.chats());
    append_jsonl(&path, &[prompt("two"), prompt("three")]);
    restored.path_changed(&path);
    assert_eq!(restored.chats()[0].entry.message_count, Some(3));
}
