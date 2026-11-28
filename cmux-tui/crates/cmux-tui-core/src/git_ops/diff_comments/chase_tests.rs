use std::cell::RefCell;

use serde_json::{Map, Value, json};

use super::super::{File, Store, save};
use super::*;
use crate::mux::agent_message_pump::Handover;

const BOUND: u64 = 1_000;

fn fields(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

fn saved(file: &mut File, key: &str, message: &str) -> String {
    let (saved, _) = save(file, "/r", key, fields(json!({"message": message}))).unwrap();
    saved["comment"]["id"].as_str().unwrap().to_owned()
}

fn comment<'a>(file: &'a File, id: &str) -> &'a Map<String, Value> {
    file.comments.iter().find(|c| c["id"] == id).unwrap()
}

fn agent_reply(file: &mut File, id: &str) {
    let slot = file.comments.iter_mut().find(|c| c["id"] == id).unwrap();
    let mut replies = slot.get("replies").and_then(Value::as_array).cloned().unwrap_or_default();
    replies.push(json!({"id": "dr_x", "author": "agent", "text": "done"}));
    slot.insert("replies".into(), Value::Array(replies));
}

#[test]
fn an_unanswered_thread_is_chased_to_the_session_that_took_it() {
    let mut file = File::default();
    let a = saved(&mut file, "k1", "fix the race");
    let b = saved(&mut file, "k2", "rename it");
    mark_awaiting(&mut file, &[a.clone(), b.clone()], "acp-1", 0);
    assert!(plan(&file, "/r", BOUND - 1, BOUND).is_empty(), "not due before the bound");
    agent_reply(&mut file, &b);
    let chases = plan(&file, "/r", BOUND, BOUND);
    assert_eq!(chases.len(), 1);
    assert_eq!(chases[0].session, "acp-1");
    assert_eq!(chases[0].ids, vec![a.clone()], "an answered thread is not chased");
    assert!(chases[0].text.contains(&a) && chases[0].text.contains("fix the race"));
    assert!(chases[0].text.contains("cmux git comments reply"));
    assert_eq!(plan(&file, "/r", BOUND, BOUND)[0].prompt_id, chases[0].prompt_id, "stable id");
}

#[test]
fn chases_double_their_wait_then_stall_and_a_new_send_starts_over() {
    let mut file = File::default();
    let a = saved(&mut file, "k1", "fix");
    mark_awaiting(&mut file, &[a.clone()], "acp-1", 0);
    let mut now = 0;
    let mut ids = Vec::new();
    for chase in 0..MAX_CHASES {
        now = due_ms(comment(&file, &a), BOUND).unwrap();
        assert_eq!(now, BOUND * ((1 << (chase + 1)) - 1), "bound, then 2x, then 4x");
        let planned = plan(&file, "/r", now, BOUND);
        ids.push(planned[0].prompt_id.clone());
        mark_chased(&mut file, &[a.clone()], now);
    }
    ids.dedup();
    assert_eq!(ids.len() as u64, MAX_CHASES, "each chase is its own prompt");
    assert_eq!(comment(&file, &a)["stalled"], true);
    assert!(plan(&file, "/r", now * 100, BOUND).is_empty(), "a stalled thread is not chased");
    mark_awaiting(&mut file, &[a.clone()], "acp-2", now);
    assert!(comment(&file, &a).get("stalled").is_none());
    assert_eq!(plan(&file, "/r", now + BOUND, BOUND)[0].session, "acp-2");
}

#[test]
fn a_resolved_thread_is_never_chased_and_a_page_save_keeps_the_marks() {
    let mut file = File::default();
    let a = saved(&mut file, "k1", "fix");
    mark_awaiting(&mut file, &[a.clone()], "acp-1", 0);
    // A page save of the same comment keeps the daemon's chase fields.
    let (_, _) = save(&mut file, "/r", "k2", fields(json!({"id": a, "message": "fix"}))).unwrap();
    assert_eq!(comment(&file, &a)["sentTo"], "acp-1");
    file.comments[0].insert("resolved".into(), Value::Bool(true));
    assert!(plan(&file, "/r", BOUND * 10, BOUND).is_empty());
}

#[test]
fn a_pass_hands_over_due_chases_and_reads_the_thread_when_it_fires() {
    let dir = std::env::temp_dir().join(format!("diff-comment-chase-{}", std::process::id()));
    let store = Store::at(dir.clone());
    let mut file = File { root: "/r".into(), ..File::default() };
    let a = saved(&mut file, "k1", "fix");
    let b = saved(&mut file, "k2", "also");
    mark_awaiting(&mut file, &[a.clone(), b.clone()], "acp-1", 0);
    store.write("/r", &file).unwrap();
    let sent = RefCell::new(Vec::new());
    let hand = |session: &str, prompt: &str, text: String, meta: Value| {
        assert_eq!(meta["steer"], false, "queued behind a turn, never steered");
        sent.borrow_mut().push((session.to_owned(), prompt.to_owned(), text));
        Handover::Delivered
    };
    assert_eq!(pass(&store, "/r", BOUND / 2, BOUND, hand), Some(BOUND), "not yet due");
    assert!(sent.borrow().is_empty());
    // The agent answers b before the timer fires: only a goes.
    let mut stored = store.read("/r").unwrap();
    agent_reply(&mut stored, &b);
    store.write("/r", &stored).unwrap();
    let next = pass(&store, "/r", BOUND, BOUND, hand);
    assert_eq!(sent.borrow().len(), 1);
    assert!(sent.borrow()[0].2.contains(&a) && !sent.borrow()[0].2.contains(&b));
    assert_eq!(next, Some(BOUND + 2 * BOUND), "the next chase waits twice as long");
    assert_eq!(comment(&store.read("/r").unwrap(), &a)["chases"], 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn the_bound_has_a_floor() {
    assert!(bound_ms() >= 250);
}
