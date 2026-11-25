//! The seal hands the home over (`Store::seal`): the next daemon opens the store while the old
//! daemon's process still exits, and its hub (which owns the store) lives on until then. So the
//! sealed store lets go of the event journal at its seal and changes no file of the home after.

use super::*;
use serde_json::json;

const CHAT: &str = "chat-a";

fn config() -> StoreConfig {
    StoreConfig::default()
}

fn open_store(home: &Path) -> Result<Box<dyn Store>> {
    crate::store::open(&config(), home)
}

fn record(seq: u64) -> EventRecord {
    EventRecord {
        seq,
        at: 1_000 + seq,
        dir: "mux".into(),
        kind: "queued".into(),
        msg: json!({ "n": seq }),
        host_seq: None,
    }
}

fn meta(name: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": META_SCHEMA,
        "id": CHAT,
        "name": name,
        "harness": "claude",
        "family": "claude",
        "cwd": "/tmp",
        "status": "idle",
        "createdAt": 1,
        "updatedAt": 1,
        "lastSeq": 0,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"))
}

fn seqs(store: &dyn Store) -> Vec<u64> {
    let events = store.events(CHAT, 0, 100).unwrap_or_else(|e| panic!("events: {e:#}"));
    events.iter().map(|event| event.seq).collect()
}

#[test]
fn a_sealed_store_hands_its_home_to_the_next_open_at_once() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let first = open_store(home.path()).unwrap_or_else(|e| panic!("open: {e:#}"));
    first.save(&meta("kept")).unwrap_or_else(|e| panic!("save: {e:#}"));
    first.append(CHAT, &record(1)).unwrap_or_else(|e| panic!("append: {e:#}"));
    let stop = first.stop_reason().unwrap_or_else(|| panic!("the journal store asks to stop"));
    first.seal();
    // The writer the seal ends is no failure: a shutdown never asks for a restart (exit 74).
    assert_eq!(*stop.borrow(), None, "the seal asked the daemon to stop");
    // Not dropped: a daemon's hub outlives its seal (its tasks hold it) until the process exits.
    let started = Instant::now();
    let second = open_store(home.path())
        .unwrap_or_else(|e| panic!("the sealed store kept the event journal: {e:#}"));
    let waited = started.elapsed();
    assert!(waited < LOCK_WAIT, "the open waited {waited:?} for the sealed store");
    let loaded = second.load(CHAT).unwrap_or_else(|e| panic!("load: {e:#}"));
    assert_eq!(loaded.map(|meta| meta.name), Some("kept".to_owned()));
    assert_eq!(seqs(second.as_ref()), vec![1]);
    // The new owner's checkpoint stays: the sealed store's flush and drop write nothing.
    second.append(CHAT, &record(2)).unwrap_or_else(|e| panic!("append: {e:#}"));
    second.flush().unwrap_or_else(|e| panic!("flush: {e:#}"));
    let checkpoint = home.path().join(CHECKPOINT_NAME);
    let owned = std::fs::read(&checkpoint).unwrap_or_else(|e| panic!("read the checkpoint: {e}"));
    first.flush().unwrap_or_else(|e| panic!("a flush after the seal: {e:#}"));
    drop(first);
    let now = std::fs::read(&checkpoint).unwrap_or_else(|e| panic!("read the checkpoint: {e}"));
    assert_eq!(now, owned, "the sealed store wrote the checkpoint after its seal");
    second.seal();
    drop(second);
    let third = open_store(home.path()).unwrap_or_else(|e| panic!("open again: {e:#}"));
    assert_eq!(seqs(third.as_ref()), vec![1, 2]);
}
