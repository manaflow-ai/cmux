//! The chat store on disk (`store/journal_store.rs`) with thousands of chats: an append costs
//! the same disk with 2,000 chats as with 20, and appending across every chat holds no file
//! descriptor or memory per chat.

use super::*;
use crate::config::{StoreConfig, StoreMode};
use crate::store::{EventRecord, META_SCHEMA, SessionMeta, Store};
use serde_json::json;

fn local(home: &Path) -> Box<dyn Store> {
    let config = StoreConfig { mode: StoreMode::Local, ..StoreConfig::default() };
    crate::store::open(&config, home).unwrap_or_else(|e| panic!("open the store: {e:#}"))
}

fn chat(store: &dyn Store, id: &str) {
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "family": "claude",
        "cwd": "/w", "status": "idle", "createdAt": 1, "updatedAt": 1,
    }))
    .unwrap();
    store.save(&meta).unwrap_or_else(|e| panic!("save {id}: {e:#}"));
}

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"content": {"type": "text", "text": "A usual chunk of an agent's reply."}}),
        host_seq: None,
    }
}

/// Disk bytes each of 400 appends to one chat adds, with `chats` other chats in the store.
fn disk_per_append(chats: usize) -> f64 {
    let home = tempfile::tempdir().unwrap();
    let store = local(home.path());
    for i in 0..chats {
        let id = format!("c-{i:05}");
        chat(store.as_ref(), &id);
        store.append(&id, &record(1)).unwrap();
    }
    chat(store.as_ref(), "hot");
    for seq in 1..=20 {
        store.append("hot", &record(seq)).unwrap();
    }
    store.flush().unwrap();
    let before = disk_bytes(home.path());
    let ops = 400;
    for seq in 21..21 + ops {
        store.append("hot", &record(seq)).unwrap();
    }
    store.flush().unwrap();
    (disk_bytes(home.path()).saturating_sub(before)) as f64 / ops as f64
}

#[test]
fn an_append_costs_the_same_disk_with_thousands_of_chats() {
    let (small, god) = (disk_per_append(20), disk_per_append(2_000));
    assert_flat_with_size("store disk bytes per append (20 vs 2000 chats)", small, god, 32.0);
}

/// In a process of its own: descriptors and memory are counted for the whole process.
#[test]
fn appends_across_thousands_of_chats_hold_no_files_or_memory_per_chat() {
    isolated("stress::store::appends_across_chats_alone");
}

#[test]
fn appends_across_chats_alone() {
    if !in_child() {
        return;
    }
    let home = tempfile::tempdir().unwrap();
    let store = local(home.path());
    let (mut fds, mut rss) = (Vec::new(), Vec::new());
    let (rounds, per_round) = (10, 250);
    for round in 0..rounds {
        for i in 0..per_round {
            let id = format!("c-{round:02}-{i:04}");
            chat(store.as_ref(), &id);
            for seq in 1..=4 {
                store.append(&id, &record(seq)).unwrap();
            }
        }
        store.flush().unwrap();
        // Warm-up: the first rounds fill the allocator's pools and the store's bounded caches.
        if round >= 2 {
            fds.push(open_fds().unwrap() as f64);
            rss.push(rss_bytes().unwrap() as f64);
        }
    }
    assert_no_growth("store fds per 250 new chats", &fds, 0.5);
    // Each chat's metadata is held in memory for the list the sidebar reads: about 1.9 KB a
    // chat measured; the band is 3 KB a chat, so allocator noise on a loaded runner passes and a
    // per-chat buffer (a log's 64 KB, a cache entry per record) does not.
    assert_no_growth("store RSS per 250 new chats", &rss, 250.0 * 3.0 * 1024.0);
    // The same chats again, no new one: appends spread over all of them hold nothing more.
    let ids: Vec<String> =
        (0..rounds).flat_map(|r| (0..per_round).map(move |i| format!("c-{r:02}-{i:04}"))).collect();
    let mut held = Vec::new();
    for (round, seq) in (5..15).enumerate() {
        for id in ids.iter().step_by(3) {
            store.append(id, &record(seq)).unwrap();
        }
        store.flush().unwrap();
        if round >= 2 {
            held.push(rss_bytes().unwrap() as f64);
        }
    }
    assert_no_growth("store RSS per round of appends over 2500 chats", &held, 64.0 * 1024.0);
    assert_no_growth(
        "store fds after appends over 2500 chats",
        &[fds[0], open_fds().unwrap() as f64],
        0.5,
    );
}
