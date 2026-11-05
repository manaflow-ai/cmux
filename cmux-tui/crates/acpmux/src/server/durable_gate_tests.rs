//! Replies and events wait for durability (R-DURABILITY S2c, DESIGN.md 3.3d): with the event
//! journal on, an acknowledged change is answered only once its record is durable, and agent
//! output to a connection that heard no acknowledged change is not held behind one.
//!
//! The journal runs on the simulated file system (`cmux_journal::SimStorage`) with every sync
//! taking [`SYNC`], so "durable" takes a time a test can see.

use crate::config::{Config, StoreMode};
use crate::rpc::{Message, method};
use crate::server::{Origin, serve_connection_with};
use cmux_journal::SimStorage;
use serde_json::{Value, json};
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;

const CHAT: &str = "chat-a";
const OTHER: &str = "chat-b";
/// How long every journal sync takes once a test sets it.
const SYNC: Duration = Duration::from_millis(400);

/// A hub on a journal store with two chats.
fn hub(home: &Path, journal: &SimStorage) -> Arc<crate::hub::Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    config.store.journal = true;
    let journal_config = cmux_journal::Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    let store = crate::store::open_with_journal(
        &config.store,
        home,
        Arc::new(journal.clone()),
        journal_config,
    )
    .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    for id in [CHAT, OTHER] {
        let meta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id,
            "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1
        }))
        .unwrap_or_else(|e| panic!("meta: {e}"));
        store.save(&meta).unwrap_or_else(|e| panic!("{e:#}"));
    }
    crate::hub::Hub::new(config, store)
}

/// A local connection, initialized, and its outgoing lines.
async fn connect(hub: &Arc<crate::hub::Hub>) -> (mpsc::Sender<String>, mpsc::Receiver<String>) {
    let (input, incoming) = mpsc::channel(64);
    let (output, mut outgoing) = mpsc::channel(256);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {},
        "clientInfo": {"name": "test", "version": "0"}});
    send(&input, Message::request(1, method::INITIALIZE, hello)).await;
    let reply = until(&mut outgoing, |line| line["id"] == 1).await;
    assert!(reply.get("error").is_none(), "initialize: {reply}");
    (input, outgoing)
}

async fn send(input: &mpsc::Sender<String>, message: Message) {
    input.send(message.to_line()).await.unwrap_or_else(|e| panic!("send: {e}"));
}

/// The next line `outgoing` sends that `stop` takes, within 10 s.
async fn until(outgoing: &mut mpsc::Receiver<String>, stop: impl Fn(&Value) -> bool) -> Value {
    tokio::time::timeout(Duration::from_secs(10), async {
        loop {
            let line = outgoing.recv().await.unwrap_or_else(|| panic!("the connection ended"));
            let line: Value =
                serde_json::from_str(&line).unwrap_or_else(|e| panic!("not JSON ({e}): {line}"));
            if stop(&line) {
                return line;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("no such line within 10 s"))
}

/// A rename appends its `renamed` record (an acknowledged change): the reply waits until that
/// record is durable, one sync after it was appended at the earliest.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_acked_change_is_answered_once_its_record_is_durable() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(60);
    let hub = hub(home.path(), &journal);
    let (input, mut outgoing) = connect(&hub).await;
    journal.set_sync_delay(SYNC);
    let started = Instant::now();
    let rename = json!({"sessionId": CHAT, "newName": "renamed"});
    send(&input, Message::request(2, method::MUX_RENAME, rename)).await;
    let reply = until(&mut outgoing, |line| line["id"] == 2).await;
    let took = started.elapsed();
    journal.set_sync_delay(Duration::ZERO);
    assert!(reply.get("error").is_none(), "rename: {reply}");
    assert!(
        took >= SYNC.saturating_sub(Duration::from_millis(50)),
        "the rename was answered after {took:?}, before its record could be durable"
    );
}

/// Agent output (a `Stream` record) to a connection attached to its chat goes at once, while
/// another chat's acknowledged change, which this connection does not hear, waits for its sync.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn agent_output_is_not_held_behind_another_chats_acked_change() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(61);
    let hub = hub(home.path(), &journal);
    let (viewer, mut viewer_out) = connect(&hub).await;
    let attach = json!({"sessionId": CHAT, "visible": false, "waitLogs": false});
    send(&viewer, Message::request(2, method::MUX_ATTACH, attach)).await;
    let reply = until(&mut viewer_out, |line| line["id"] == 2).await;
    assert!(reply.get("error").is_none(), "attach: {reply}");
    let (other, mut other_out) = connect(&hub).await;
    journal.set_sync_delay(SYNC);
    let rename = json!({"sessionId": OTHER, "newName": "renamed"});
    send(&other, Message::request(2, method::MUX_RENAME, rename)).await;
    // The rename's record is appended; its reply waits for its sync.
    tokio::time::sleep(Duration::from_millis(100)).await;
    let session = hub.resolve(CHAT).unwrap_or_else(|e| panic!("{e:?}"));
    let started = Instant::now();
    let _ = hub.append(
        &session,
        "in",
        method::SESSION_UPDATE,
        json!({"jsonrpc": "2.0", "method": method::SESSION_UPDATE, "params": {
            "sessionId": CHAT,
            "update": {"sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": "hi"}}
        }}),
    );
    let update = until(&mut viewer_out, |line| line["method"] == method::SESSION_UPDATE).await;
    let took = started.elapsed();
    let renamed = until(&mut other_out, |line| line["id"] == 2).await;
    journal.set_sync_delay(Duration::ZERO);
    assert!(renamed.get("error").is_none(), "rename: {renamed}");
    assert_eq!(update["params"]["update"]["content"]["text"], "hi", "{update}");
    assert!(took < SYNC / 2, "agent output waited {took:?} behind another chat's change");
}

/// F2: a journal that makes nothing durable (a hung or failing disk; the writer retries without
/// end) must not hold every reply without a limit: past the stall limit, the store asks the
/// daemon to stop for a restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_journal_that_syncs_nothing_asks_the_daemon_to_stop() {
    use std::sync::atomic::Ordering;
    super::TEST_STALL_MS.store(300, Ordering::SeqCst);
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(62);
    let hub = hub(home.path(), &journal);
    let (input, mut outgoing) = connect(&hub).await;
    let mut stop = hub.store.stop_reason().unwrap_or_else(|| panic!("no stop reason"));
    // Each sync takes 3 s: past the 300 ms stall limit, and short enough that the journal ends
    // (a sync under way keeps its delay, and the store's drop waits for it).
    journal.set_sync_delay(Duration::from_secs(3));
    let rename = json!({"sessionId": CHAT, "newName": "renamed"});
    send(&input, Message::request(2, method::MUX_RENAME, rename)).await;
    let asked = tokio::time::timeout(Duration::from_millis(2500), stop.wait_for(Option::is_some))
        .await
        .is_ok();
    journal.set_sync_delay(Duration::ZERO);
    let _ = until(&mut outgoing, |line| line["id"] == 2).await;
    assert!(asked, "a reply waited past the stall limit and the store did not ask to stop");
}

/// F1, the streaming read: `session/load`'s replay sends each record as it reads it
/// (`Hub::scan_events`). It must stop at the records whose journal record was appended when it
/// started: a line the log holds while its record is not appended is not sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_replay_never_sends_a_line_before_its_record() {
    use crate::store::PAUSE_AFTER_LOG_WRITE;
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(63);
    let hub = hub(home.path(), &journal);
    let session = hub.resolve(CHAT).unwrap_or_else(|e| panic!("{e:?}"));
    let first = hub.append(&session, "mux", "note", json!({"n": 1}));
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel::<()>();
    *PAUSE_AFTER_LOG_WRITE.lock().unwrap_or_else(|e| e.into_inner()) =
        Some((arrived_tx, release_rx));
    let appender = {
        let (hub, session) = (hub.clone(), session.clone());
        std::thread::spawn(move || hub.append(&session, "mux", "note", json!({"n": 2})).seq)
    };
    arrived
        .recv_timeout(Duration::from_secs(10))
        .unwrap_or_else(|e| panic!("the append never paused: {e}"));
    let releaser = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(200));
        let _ = release.send(());
    });
    let mut seen = Vec::new();
    hub.scan_events(CHAT, 0, &mut |record| {
        seen.push(record.seq);
        true
    })
    .unwrap_or_else(|e| panic!("{e:#}"));
    releaser.join().unwrap_or_else(|_| panic!("releaser panicked"));
    let second = appender.join().unwrap_or_else(|_| panic!("append panicked"));
    assert!(seen.contains(&first.seq), "the replay missed line {}: {seen:?}", first.seq);
    assert!(!seen.contains(&second), "the replay sent line {second} before its record: {seen:?}");
}

/// Review of #35400 N1: after a hard stop the log can be ahead of the chat's saved `lastSeq`
/// (metadata is saved less often than lines). `session/load`'s replay stops at `lastSeq`, so it
/// must count the log's tail first (`Hub::catch_up`): else the first replay of a chat whose log
/// is not loaded yet leaves out its newest lines, and they are never sent live either. With the
/// switch off too.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_replay_after_a_hard_stop_sends_the_tail_past_the_saved_last_seq() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    let store = crate::store::open(&config.store, home.path())
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": CHAT, "name": CHAT,
        "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
        "lastSeq": 1,
    }))
    .unwrap_or_else(|e| panic!("meta: {e}"));
    store.save(&meta).unwrap_or_else(|e| panic!("{e:#}"));
    // The hard stop: three lines in the log, `lastSeq` saved at 1.
    for seq in 1..=3 {
        let record = crate::store::EventRecord {
            seq,
            at: 1_000 + seq,
            dir: "mux".into(),
            kind: "note".into(),
            msg: json!({ "n": seq }),
            host_seq: None,
        };
        store.append(CHAT, &record).unwrap_or_else(|e| panic!("{e:#}"));
    }
    store.flush().unwrap_or_else(|e| panic!("{e:#}"));
    drop(store);
    // A new daemon on the same home, as the daemon builds its hub: the chat's metadata loads, its
    // log is read later (`load_logs`, after the ready line). `Hub::new` would read it at once.
    let store = crate::store::open(&config.store, home.path())
        .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    let hub = crate::hub::Hub::new_deferred(config, store, crate::mailbox::Mailbox::memory());
    let mut seen = Vec::new();
    hub.scan_events(CHAT, 0, &mut |record| {
        seen.push(record.seq);
        true
    })
    .unwrap_or_else(|e| panic!("{e:#}"));
    assert_eq!(seen, vec![1, 2, 3], "the replay left out the log's tail past the saved lastSeq");
}
