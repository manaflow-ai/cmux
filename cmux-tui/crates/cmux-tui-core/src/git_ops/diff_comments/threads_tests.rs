//! Sent reviews kept as threads, answered with their turn's reply.

use std::cell::Cell;
use std::path::PathBuf;

use serde_json::{Value, json};

use super::threads::{Thread, answered_with, record};
use super::{File, MAX_THREADS, Store};
use crate::server::TurnReply;

const ROOT: &str = "browser:https://example.com/a";

struct Dir(PathBuf);

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn store(name: &str) -> (Store, Dir) {
    let directory =
        std::env::temp_dir().join(format!("dct-{name}-{}-{}", std::process::id(), super::now_ms()));
    (Store::at(directory.clone()), Dir(directory))
}

fn file_with(ids: &[&str]) -> File {
    File {
        root: ROOT.into(),
        comments: ids
            .iter()
            .map(|id| json!({"id": id, "message": format!("on {id}")}).as_object().unwrap().clone())
            .collect(),
        ..File::default()
    }
}

#[test]
fn a_send_keeps_only_the_sent_comments_under_its_prompt_id() {
    let mut file = file_with(&["a", "b", "c"]);
    record(&mut file, "p1", "acp-1", &["a".into(), "c".into()]);
    assert_eq!(file.threads.len(), 1);
    let thread = &file.threads[0];
    assert_eq!((thread.id.as_str(), thread.acp_session.as_str()), ("p1", "acp-1"));
    let ids: Vec<_> = thread.comments.iter().map(|c| c["id"].as_str().unwrap()).collect();
    assert_eq!(ids, ["a", "c"]);
    assert!(thread.reply.is_none() && thread.sent_ms > 0);
}

#[test]
fn a_resend_of_the_same_prompt_replaces_its_thread_and_the_oldest_go_past_the_cap() {
    let mut file = file_with(&["a"]);
    record(&mut file, "p1", "acp-1", &["a".into()]);
    record(&mut file, "p1", "acp-1", &["a".into()]);
    assert_eq!(file.threads.len(), 1);
    for n in 0..MAX_THREADS + 5 {
        record(&mut file, &format!("q{n}"), "acp-1", &["a".into()]);
    }
    assert_eq!(file.threads.len(), MAX_THREADS);
    assert_eq!(file.threads[0].id, "q5");
}

#[test]
fn an_ended_turn_is_read_once_and_kept() {
    let (store, _dir) = store("kept");
    let mut file = file_with(&["a"]);
    record(&mut file, "p1", "acp-1", &["a".into()]);
    record(&mut file, "p2", "acp-1", &["a".into()]);
    store.write(ROOT, &file).unwrap();

    let reads = Cell::new(0);
    let read = |thread: &Thread| {
        reads.set(reads.get() + 1);
        if thread.id == "p1" {
            TurnReply::Ended { status: "completed".into(), text: "Done.".into() }
        } else {
            TurnReply::Pending
        }
    };
    let first = answered_with(&store, ROOT, store.read(ROOT).unwrap().threads, "op", read).unwrap();
    assert_eq!(first[0]["reply"], json!({"status": "completed", "text": "Done."}));
    assert_eq!(first[1]["reply"], json!({"status": "pending"}));
    assert_eq!(reads.get(), 2);

    // The kept reply answers from the file; only the open thread asks again.
    let second =
        answered_with(&store, ROOT, store.read(ROOT).unwrap().threads, "op", read).unwrap();
    assert_eq!(second[0]["reply"]["text"], "Done.");
    assert_eq!(reads.get(), 3);
    let kept = store.read(ROOT).unwrap();
    assert!(kept.threads[1].reply.is_none(), "a pending reply is never kept");
}

#[test]
fn an_unreadable_acpmux_answers_unknown_and_keeps_nothing() {
    let (store, _dir) = store("unknown");
    let mut file = file_with(&["a"]);
    record(&mut file, "p1", "acp-1", &["a".into()]);
    store.write(ROOT, &file).unwrap();
    let threads = store.read(ROOT).unwrap().threads;
    let answered = answered_with(&store, ROOT, threads, "op", |_| TurnReply::Unreadable).unwrap();
    assert_eq!(answered[0]["reply"], json!({"status": "unknown"}));
    assert_eq!(answered[0]["comments"][0]["id"], Value::from("a"));
    assert!(store.read(ROOT).unwrap().threads[0].reply.is_none());
}

#[test]
fn a_file_from_before_threads_reads_with_none() {
    let file: File = serde_json::from_value(json!({"root": ROOT, "comments": []})).unwrap();
    assert!(file.threads.is_empty());
    let written = serde_json::to_value(&file).unwrap();
    assert!(written.get("threads").is_none());
}
