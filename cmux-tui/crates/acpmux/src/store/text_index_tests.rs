//! A segment's text copy (`store/text_index.rs`): the messages a search reads, kept current by
//! reading only the bytes appended past it.

use super::*;
use crate::session_search::{Entry, Role};
use serde_json::json;
use std::io::Write;

fn chunk(seq: u64, message: &str, text: &str) -> EventRecord {
    let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "c",
        "update": {"sessionUpdate": "agent_message_chunk", "messageId": message,
            "content": {"type": "text", "text": text}}}});
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg,
        host_seq: None,
    }
}

fn prompt(seq: u64, text: &str) -> EventRecord {
    let msg = json!({"text": text});
    EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg,
        host_seq: None,
    }
}

fn noise(seq: u64) -> EventRecord {
    let msg = json!({"params": {"update": {"sessionUpdate": "tool_call_update", "pad": "x".repeat(8000)}}});
    EventRecord {
        seq,
        at: seq,
        dir: "in".into(),
        kind: "tool_call_update".into(),
        msg,
        host_seq: None,
    }
}

/// A memory store holds a chat's records only once its meta is saved.
fn memory() -> MemoryStore {
    let store = MemoryStore::default();
    let meta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": "c", "name": "c", "harness": "claude",
        "family": "claude", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap();
    store
}

fn root() -> PathBuf {
    std::env::temp_dir().join(format!("acpmux-text-index-{}", uuid::Uuid::now_v7()))
}

fn entries(store: &dyn Store) -> Vec<Entry> {
    let mut out = Vec::new();
    store.text_entries("c", &mut |e| out.push(e)).unwrap();
    out
}

fn entry(seq: u64, role: Role, text: &str) -> Entry {
    Entry { seq, at: seq, role, text: text.into() }
}

/// The first search writes the copy; the second reads it, not the segment: a segment whose bytes
/// are gone (the same file and length, other bytes) still gives its messages.
#[test]
fn a_second_search_reads_the_copy_not_the_segment() {
    let root = root();
    let store = LocalStore::new(root.clone(), 1 << 30).unwrap();
    let log = [
        prompt(1, "find the sentence"),
        chunk(2, "m1", "the queue "),
        noise(3),
        chunk(4, "m1", "waits for "),
        chunk(5, "m1", "the owner"),
        prompt(6, "next"),
        chunk(7, "m2", "done"),
    ];
    for r in &log {
        store.append("c", r).unwrap();
    }
    store.flush().unwrap();
    let want = vec![
        entry(1, Role::User, "find the sentence"),
        entry(2, Role::Assistant, "the queue waits for the owner"),
        entry(6, Role::User, "next"),
        entry(7, Role::Assistant, "done"),
    ];
    assert_eq!(entries(&store), want);
    let copy = root.join("c").join(DIR).join("000001.ndjson");
    assert!(copy.exists(), "the first search saves the copy");
    for (_, path) in store.segments("c").unwrap() {
        let len = std::fs::metadata(&path).unwrap().len();
        let blank = " ".repeat(usize::try_from(len).unwrap());
        std::fs::OpenOptions::new()
            .write(true)
            .open(&path)
            .unwrap()
            .write_all(blank.as_bytes())
            .unwrap();
    }
    assert_eq!(entries(&store), want, "the copy holds every message");
    let _ = std::fs::remove_dir_all(&root);
}

/// A reply still being written when the copy was saved takes the chunks appended after it, and a
/// prompt after it is a message of its own.
#[test]
fn a_reply_open_at_the_copys_end_takes_the_chunks_appended_later() {
    let root = root();
    let store = LocalStore::new(root.clone(), 1 << 30).unwrap();
    store.append("c", &chunk(1, "m1", "cmux-platform#469 ")).unwrap();
    store.flush().unwrap();
    assert_eq!(entries(&store), vec![entry(1, Role::Assistant, "cmux-platform#469 ")]);
    store.append("c", &chunk(2, "m1", "and cmux-platform#470.")).unwrap();
    store.append("c", &prompt(3, "thanks")).unwrap();
    store.flush().unwrap();
    assert_eq!(
        entries(&store),
        vec![
            entry(1, Role::Assistant, "cmux-platform#469 and cmux-platform#470."),
            entry(3, Role::User, "thanks"),
        ]
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// A copy of another file (the segment replaced, as retention does) is read past and made again.
#[test]
fn a_copy_of_a_replaced_segment_is_made_again() {
    let root = root();
    let store = LocalStore::new(root.clone(), 1 << 30).unwrap();
    store.append("c", &prompt(1, "old words")).unwrap();
    store.flush().unwrap();
    assert_eq!(entries(&store), vec![entry(1, Role::User, "old words")]);
    let (_, path) = store.segments("c").unwrap().pop().unwrap();
    let mut line = serde_json::to_vec(&prompt(1, "new words, longer than the old")).unwrap();
    line.push(b'\n');
    let next = path.with_extension("tmp");
    std::fs::write(&next, &line).unwrap();
    std::fs::rename(&next, &path).unwrap();
    assert_eq!(entries(&store), vec![entry(1, Role::User, "new words, longer than the old")]);
    let _ = std::fs::remove_dir_all(&root);
}

/// Across many small segments the file store gives what the plain scan gives (`Store`'s default,
/// the memory store's), each message once and in order.
#[test]
fn every_segment_gives_its_messages_once_in_order() {
    let root = root();
    let store = LocalStore::new(root.clone(), 4096).unwrap();
    let memory = memory();
    let mut seq = 0_u64;
    for turn in 0..40_u64 {
        let mut next = || {
            seq += 1;
            seq
        };
        let records = [
            prompt(next(), &format!("prompt {turn}")),
            noise(next()),
            chunk(next(), &format!("m{turn}"), &format!("reply {turn}")),
        ];
        for r in &records {
            store.append("c", r).unwrap();
            memory.append("c", r).unwrap();
        }
    }
    store.flush().unwrap();
    assert!(store.segments("c").unwrap().len() > 3);
    let first = entries(&store);
    assert_eq!(first.len(), 80);
    assert_eq!(first, entries(&memory));
    assert_eq!(entries(&store), first, "read again from the copies");
    let _ = std::fs::remove_dir_all(&root);
}
