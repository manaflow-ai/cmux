//! The place-mode migration loses nothing (memory: cutovers-ship-with-migrations). Approved MVP
//! (Leo, 2026-11-24: "i think so. i think this is good as a start."): when place modes ship,
//! every existing chat is pinned to its current machine, once, so nothing moves unasked.
//!
//! One store of older chats (open, closed, titled, tagged, with logs, one already picked and one
//! picked in the first `place_set`'s own file) is copied twice. Copy A is opened and closed by a
//! daemon's hub with no migration; copy B the same, with the migration. Every chat in B must be
//! A's chat, field for field, but for its new pin, and its log must be A's log, record for
//! record. A second start finds the marker and changes nothing; a chat made after the cutoff
//! is Auto.

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::place_mode::PlaceMode;
use acpmux::place_pin;
use acpmux::store::{EventRecord, META_SCHEMA, SessionMeta};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

const CHATS: [&str; 5] = [
    "01a20c70-0000-7000-8000-000000000001",
    "01a20c70-0000-7000-8000-000000000002",
    "01a20c70-0000-7000-8000-000000000003",
    "01a20c70-0000-7000-8000-000000000004",
    "01a20c70-0000-7000-8000-000000000005",
];

fn config() -> Config {
    let mut cfg: Config = serde_json::from_value(json!({})).unwrap();
    cfg.store.mode = StoreMode::Local;
    cfg
}

fn meta(id: &str, extra: Value) -> SessionMeta {
    let mut v = json!({
        "schema": META_SCHEMA, "id": id, "name": id, "harness": "claude", "cwd": "/tmp",
        "status": "idle", "createdAt": 1_790_000_000_000u64, "updatedAt": 1_790_000_000_000u64,
        "lastSeq": 0, "eventCount": 0,
    });
    for (k, x) in extra.as_object().unwrap() {
        v[k] = x.clone();
    }
    serde_json::from_value(v).unwrap()
}

fn record(seq: u64, text: &str) -> EventRecord {
    EventRecord {
        seq,
        at: 1_790_000_000_000 + seq,
        dir: "in".into(),
        kind: "agent_message_chunk".into(),
        msg: json!({"update": {"content": {"text": text}}}),
        host_seq: None,
    }
}

/// The older chats, and the first `place_set`'s pin file with one pick.
fn seed(root: &Path) {
    let store = acpmux::store::open(&config().store, root).unwrap();
    let extras = [
        json!({"title": "Fix the login flow", "tags": {"lane": {"value": "auth"}}}),
        json!({"status": "closed", "title": "Closed one"}),
        json!({"placeMode": {"mode": "cloud"}, "title": "Picked Cloud already"}),
        json!({"title": "Picked in place-modes.json"}),
        json!({"pullRequests": ["manaflow-ai/cmux#1"], "gitBranch": "lane/x"}),
    ];
    for (id, extra) in CHATS.iter().zip(extras) {
        let events = 40;
        for seq in 1..=events {
            store.append(id, &record(seq, &format!("{id} line {seq}"))).unwrap();
        }
        let mut m = meta(id, extra);
        m.last_seq = events;
        m.event_count = events;
        store.save(&m).unwrap();
    }
    store.flush().unwrap();
    std::fs::write(
        root.join(place_pin::LEGACY_PINS),
        json!({CHATS[3]: {"mode": "machine", "machine": "studio"}}).to_string(),
    )
    .unwrap();
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let dest = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &dest);
        } else {
            std::fs::copy(entry.path(), dest).unwrap();
        }
    }
}

/// Each chat's metadata (as JSON) and its whole log, as the store holds them now.
fn read_back(root: &Path) -> BTreeMap<String, (Value, Vec<Value>)> {
    let store = acpmux::store::open(&config().store, root).unwrap();
    let mut out = BTreeMap::new();
    for m in store.list().unwrap() {
        let log = store.events(&m.id, 0, usize::MAX).unwrap();
        let log = log.iter().map(|r| serde_json::to_value(r).unwrap()).collect();
        out.insert(m.id.clone(), (serde_json::to_value(&m).unwrap(), log));
    }
    out
}

/// Opens `root` as a daemon's hub does, runs `migrate` with it, and closes it.
async fn start(root: &Path, migrate: bool) -> Option<place_pin::Report> {
    let store = acpmux::store::open(&config().store, root).unwrap();
    let mailbox = acpmux::mailbox::Mailbox::open(root.join("mailbox")).unwrap();
    let hub = Hub::new_deferred(config(), store, mailbox);
    hub.load_logs_async().await;
    let report = if migrate {
        place_pin::start(root, acpmux::store::now_ms())
            .map(|cutoff| hub.migrate_place_modes(root, cutoff))
    } else {
        None
    };
    hub.shutdown_all().await;
    report
}

/// The fields a daemon's own start and stop may set on any chat, A's and B's alike.
fn without_volatile(mut v: Value) -> Value {
    if let Some(o) = v.as_object_mut() {
        o.remove("placeMode");
        o.remove("updatedAt");
    }
    v
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_migration_pins_every_older_chat_here_and_loses_nothing() {
    let base = PathBuf::from("/tmp").join(format!("acpmux-place-mig-{}", uuid::Uuid::now_v7()));
    let (seeded, a, b) = (base.join("seed"), base.join("a"), base.join("b"));
    seed(&seeded);
    copy_dir(&seeded, &a);
    copy_dir(&seeded, &b);

    start(&a, false).await;
    let report = start(&b, true).await.expect("the first start migrates");
    let here = report.here.clone();
    assert_eq!(
        (report.pinned, report.from_legacy, report.kept, report.failed),
        (3, 1, 1, 0),
        "{report:?}"
    );

    let (before, after) = (read_back(&a), read_back(&b));
    assert_eq!(before.len(), CHATS.len(), "copy A lost a chat");
    assert_eq!(
        before.keys().collect::<Vec<_>>(),
        after.keys().collect::<Vec<_>>(),
        "the migration lost or added a chat"
    );
    for (id, (meta_a, log_a)) in &before {
        let (meta_b, log_b) = &after[id];
        assert_eq!(log_a.len(), 40, "{id}: copy A's log is not whole");
        assert_eq!(log_a, log_b, "{id}: the migration changed the chat's log");
        assert_eq!(
            without_volatile(meta_a.clone()),
            without_volatile(meta_b.clone()),
            "{id}: the migration changed more than the pin"
        );
        let pin: PlaceMode = serde_json::from_value(meta_b["placeMode"].clone())
            .unwrap_or_else(|e| panic!("{id} has no pin after the migration: {e}: {meta_b}"));
        let want = match id.as_str() {
            id if id == CHATS[2] => PlaceMode::Cloud,
            id if id == CHATS[3] => PlaceMode::Machine { id: "studio".into() },
            _ => PlaceMode::Machine { id: here.clone() },
        };
        assert_eq!(pin, want, "{id}");
    }
    assert!(place_pin::read_marker(&b).is_some(), "no marker");
    assert!(!b.join(place_pin::LEGACY_PINS).exists(), "the older pin file was not retired");
    assert!(b.join("place-modes.json.migrated").exists(), "the older pin file was deleted");

    // A second start finds the marker: nothing runs, nothing changes.
    assert_eq!(start(&b, true).await, None, "the migration ran twice");
    assert_eq!(read_back(&b), after, "a second start changed a chat");

    // A chat made after the cutoff has no pin and is Auto; an older one without a pin (one the
    // migration has not reached) reads as pinned here.
    let cutoff = place_pin::cutoff();
    assert!(cutoff > 0);
    assert_eq!(place_pin::effective(None, &here, cutoff, cutoff), PlaceMode::Auto);
    assert_eq!(
        place_pin::effective(None, &here, cutoff - 1, cutoff),
        PlaceMode::Machine { id: here.clone() }
    );
    let _ = std::fs::remove_dir_all(&base);
}
