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
    hub_and_durability(home, journal, cmux_journal::Config::default().kept_sync_quiet).0
}

/// [`hub`] whose journal syncs kept records after `kept_sync_quiet` of idle time, and the store's
/// durability as the outbound gate reads it.
fn hub_and_durability(
    home: &Path,
    journal: &SimStorage,
    kept_sync_quiet: Duration,
) -> (Arc<crate::hub::Hub>, crate::store::Durability) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    let journal_config = cmux_journal::Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        kept_sync_quiet,
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
    let durability = store.durability().unwrap_or_else(|| panic!("a journal store has one"));
    (crate::hub::Hub::new(config, store), durability)
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

/// An unread mark appends its metadata record and its `status` line (acknowledged changes): the
/// reply waits until they are durable, one sync after they were appended at the earliest.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn an_acked_change_is_answered_once_its_record_is_durable() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(60);
    let hub = hub(home.path(), &journal);
    let (input, mut outgoing) = connect(&hub).await;
    journal.set_sync_delay(SYNC);
    let started = Instant::now();
    let unread = json!({"sessionId": CHAT});
    send(&input, Message::request(2, method::MUX_MARK_UNREAD, unread)).await;
    let reply = until(&mut outgoing, |line| line["id"] == 2).await;
    let took = started.elapsed();
    journal.set_sync_delay(Duration::ZERO);
    assert!(reply.get("error").is_none(), "markUnread: {reply}");
    assert!(
        took >= SYNC.saturating_sub(Duration::from_millis(50)),
        "the unread mark was answered after {took:?}, before its record could be durable"
    );
}

/// A draft and a name are kept changes (`store/durability.rs`): each answer waits for its records
/// to be written, not synced, so typing and renaming never wait for the disk; and a kill -9 of
/// the daemon right after the answers keeps both.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_draft_and_a_name_are_answered_before_their_sync_and_survive_a_kill() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(63);
    // No idle-time sync of the draft's record between the two requests: on a loaded machine the
    // pause between them can pass the 10 ms quiet time, and the rename's write would then wait
    // behind that (simulated 400 ms) sync. Review of #37174, finding 1.
    let (hub, _) = hub_and_durability(home.path(), &journal, Duration::from_secs(60));
    let (input, mut outgoing) = connect(&hub).await;
    // The full sync that follows the chats' saves within the journal's 1 s interval is over: no
    // sync of the setup is under way when the slow syncs start.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    journal.set_sync_delay(SYNC);
    let started = Instant::now();
    let draft = json!({"sessionId": CHAT, "text": "still typing"});
    send(&input, Message::request(2, method::MUX_DRAFT_SET, draft)).await;
    let drafted = until(&mut outgoing, |line| line["id"] == 2).await;
    let draft_took = started.elapsed();
    let started = Instant::now();
    let rename = json!({"sessionId": CHAT, "newName": "kept-name"});
    send(&input, Message::request(3, method::MUX_RENAME, rename)).await;
    let renamed = until(&mut outgoing, |line| line["id"] == 3).await;
    let rename_took = started.elapsed();
    // A kill -9 right after the answers: what the processes wrote stays, nothing more is synced.
    let killed = journal.snapshot(cmux_journal::Crash::Process);
    killed.set_sync_delay(Duration::ZERO);
    journal.set_sync_delay(Duration::ZERO);
    assert!(drafted.get("error").is_none(), "draft_set: {drafted}");
    assert!(renamed.get("error").is_none(), "rename: {renamed}");
    assert!(draft_took < SYNC / 2, "draft_set was answered after {draft_took:?}: it waited a sync");
    assert!(rename_took < SYNC / 2, "rename was answered after {rename_took:?}: it waited a sync");
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    let journal_config = cmux_journal::Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    let store = crate::store::open_with_journal(
        &config.store,
        home.path(),
        Arc::new(killed),
        journal_config,
    )
    .unwrap_or_else(|e| panic!("open the store after the kill: {e:#}"));
    let meta = store
        .load(CHAT)
        .unwrap_or_else(|e| panic!("load: {e:#}"))
        .unwrap_or_else(|| panic!("the chat is gone after the kill"));
    assert_eq!(meta.composer_draft.as_deref(), Some("still typing"), "the draft after the kill");
    assert_eq!(meta.name, "kept-name", "the name after the kill");
}

/// Kept changes are synced in the journal's idle time soon after they are written, so the next
/// acknowledged change (a prompt) syncs only its own records. Before, they waited for that change
/// or the stream sync delay (1 s): after the perf bench's 200 drafts and names, the first prompt's
/// sync carried 316 records, 1.17 MB, and took 7.3 ms against 2.2-2.5 ms for its own 319 bytes
/// (job 01189fd6, aws-m4pro-8: `light.op.prompt_accepted` p95 2.0 -> 3.2 ms, max 3.6 -> 7.4 ms).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn kept_changes_are_synced_in_idle_time_before_the_next_acked_change() {
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(64);
    let quiet = cmux_journal::Config::default().kept_sync_quiet;
    let (hub, durability) = hub_and_durability(home.path(), &journal, quiet);
    let (input, mut outgoing) = connect(&hub).await;
    // The setup's syncs (and the full sync that follows them within 1 s) are over.
    tokio::time::sleep(Duration::from_millis(1500)).await;
    for id in 0..20u64 {
        let draft = json!({"sessionId": CHAT, "text": format!("typing {id}")});
        send(&input, Message::request(10 + id, method::MUX_DRAFT_SET, draft)).await;
        let drafted = until(&mut outgoing, |line| line["id"] == 10 + id).await;
        assert!(drafted.get("error").is_none(), "draft_set: {drafted}");
    }
    let rename = json!({"sessionId": CHAT, "newName": "idle-synced"});
    send(&input, Message::request(40, method::MUX_RENAME, rename)).await;
    let renamed = until(&mut outgoing, |line| line["id"] == 40).await;
    assert!(renamed.get("error").is_none(), "rename: {renamed}");
    let kept = durability.kept.load(std::sync::atomic::Ordering::SeqCst);
    assert!(kept > 0, "the drafts and the name appended no kept record");
    // No acknowledged change comes. Within 300 ms of idle time (well inside the 1 s stream sync
    // delay) the kept records are synced on their own.
    let mut durable = durability.durable.clone();
    let synced =
        tokio::time::timeout(Duration::from_millis(300), durable.wait_for(|lsn| *lsn >= kept))
            .await
            .is_ok();
    let at = *durable.borrow();
    assert!(
        synced,
        "kept records up to LSN {kept} were not synced in 300 ms of idle time (durable: {at}): \
         the next acked change would sync them in its own turn"
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
    let unread = json!({"sessionId": OTHER});
    send(&other, Message::request(2, method::MUX_MARK_UNREAD, unread)).await;
    // The unread mark's record is appended; its reply waits for its sync.
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
    let marked = until(&mut other_out, |line| line["id"] == 2).await;
    journal.set_sync_delay(Duration::ZERO);
    assert!(marked.get("error").is_none(), "markUnread: {marked}");
    assert_eq!(update["params"]["update"]["content"]["text"], "hi", "{update}");
    assert!(took < SYNC / 2, "agent output waited {took:?} behind another chat's change");
}

/// huge-blue, 2026-11-08: a saturated disk (35-50% iowait, a 10.4 s fdatasync) made a reply wait
/// past the stall limit, and the daemon stopped for a restart 8 times in 3 hours; every session
/// start meanwhile failed with "acpmux is shutting down". A journal that is only slow (each sync
/// takes ten stall limits, and none fails) must not ask the daemon to stop: the reply waits and
/// then goes out.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_slow_journal_delays_the_reply_and_never_asks_the_daemon_to_stop() {
    use std::sync::atomic::Ordering;
    super::TEST_STALL_MS.store(100, Ordering::SeqCst);
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(62);
    let hub = hub(home.path(), &journal);
    let (input, mut outgoing) = connect(&hub).await;
    let stop = hub.store.stop_reason().unwrap_or_else(|| panic!("no stop reason"));
    journal.set_sync_delay(Duration::from_millis(1000));
    let started = Instant::now();
    let unread = json!({"sessionId": CHAT});
    send(&input, Message::request(2, method::MUX_MARK_UNREAD, unread)).await;
    let reply = until(&mut outgoing, |line| line["id"] == 2).await;
    let took = started.elapsed();
    journal.set_sync_delay(Duration::ZERO);
    assert!(reply.get("error").is_none(), "markUnread: {reply}");
    assert!(took >= Duration::from_millis(900), "the reply did not wait for its sync: {took:?}");
    assert!(stop.borrow().is_none(), "a slow disk asked the daemon to stop: {:?}", *stop.borrow());
}

/// F2: a journal whose writer fails (a failing disk: every sync returns an error and the writer
/// retries without end) must not hold every reply without a limit: past the stall limit, the
/// store asks the daemon to stop for a restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failing_journal_asks_the_daemon_to_stop() {
    use std::sync::atomic::Ordering;
    super::TEST_STALL_MS.store(300, Ordering::SeqCst);
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(62);
    let hub = hub(home.path(), &journal);
    let (input, mut outgoing) = connect(&hub).await;
    let mut stop = hub.store.stop_reason().unwrap_or_else(|| panic!("no stop reason"));
    journal.fail_all_syncs(Some(std::io::ErrorKind::Other));
    let unread = json!({"sessionId": CHAT});
    send(&input, Message::request(2, method::MUX_MARK_UNREAD, unread)).await;
    let asked = tokio::time::timeout(Duration::from_millis(2500), stop.wait_for(Option::is_some))
        .await
        .is_ok();
    journal.fail_all_syncs(None);
    let _ = until(&mut outgoing, |line| line["id"] == 2).await;
    assert!(
        asked,
        "a reply waited past the stall limit on a failing journal and the store did not ask to stop"
    );
    let why = stop.borrow().clone().unwrap_or_default();
    assert!(why.contains("failing"), "{why}");
}

/// F1, the streaming read: `session/load`'s replay sends each record as it reads it
/// (`Hub::scan_events`). It must stop at the records whose journal record was appended when it
/// started: a line the log holds while its record is not appended is not sent.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_replay_never_sends_a_line_before_its_record() {
    use crate::store::pause_next_log_write_on_this_thread;
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let journal = SimStorage::new(63);
    // No idle-time sync of the draft's record between the two requests: on a loaded machine the
    // pause between them can pass the 10 ms quiet time, and the rename's write would then wait
    // behind that (simulated 400 ms) sync. Review of #37174, finding 1.
    let (hub, _) = hub_and_durability(home.path(), &journal, Duration::from_secs(60));
    let session = hub.resolve(CHAT).unwrap_or_else(|e| panic!("{e:?}"));
    let first = hub.append(&session, "mux", "note", json!({"n": 1}));
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel::<()>();
    let appender = {
        let (hub, session) = (hub.clone(), session.clone());
        std::thread::spawn(move || {
            pause_next_log_write_on_this_thread(arrived_tx, release_rx);
            hub.append(&session, "mux", "note", json!({"n": 2})).seq
        })
    };
    arrived
        .recv_timeout(Duration::from_secs(10))
        .unwrap_or_else(|e| panic!("the append never paused: {e}"));
    // The replay reads `lastSeq` and says so before it scans the log: only then the append goes
    // on. (The first append caught the chat up, so the replay takes no append lock first.)
    let (scans_tx, scans) = std::sync::mpsc::channel();
    crate::hub::NOTE_BEFORE_REPLAY_SCAN.with(|note| *note.borrow_mut() = Some(scans_tx));
    let releaser = std::thread::spawn(move || {
        scans
            .recv_timeout(Duration::from_secs(10))
            .unwrap_or_else(|e| panic!("the replay never began its scan: {e}"));
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
/// is not loaded yet leaves out its newest lines, and they are never sent live either.
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

/// The reviewer's scenario (review of #36022, finding 1), with handshakes and no timer: a replay
/// that comes while another catch-up of the same chat is under way (a first replay, the
/// background log pass or the chat's first append) must still send the tail past the saved
/// `lastSeq`. `catch_up_locked` marked the chat caught up before it counted the tail, so a replay
/// that read the mark skipped the catch-up and stopped at the saved `lastSeq`. The first catch-up
/// is held while it counts: its read of the tail waits at the journal's read fence, because
/// another chat's append holds the appends' lock (`pause_next_log_write_on_this_thread`, set on
/// the appending thread). The first replay says when its catch-up is under way
/// (`NOTE_IN_CATCH_UP`). The second says when it waits for the chat's append lock
/// (`NOTE_BEFORE_CATCH_UP_LOCK`, the fixed code) or reads the log having skipped its catch-up
/// (`NOTE_BEFORE_REPLAY_SCAN`, the code before), and only then is the append let go.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_replay_during_another_catch_up_sends_the_tail_past_the_saved_last_seq() {
    use crate::hub::{NOTE_BEFORE_CATCH_UP_LOCK, NOTE_BEFORE_REPLAY_SCAN, NOTE_IN_CATCH_UP};
    use crate::store::pause_next_log_write_on_this_thread;
    const WAIT: Duration = Duration::from_secs(10);
    let home = tempfile::tempdir().unwrap_or_else(|e| panic!("tempdir: {e}"));
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    // The hard stop: three lines in the chat's log, `lastSeq` saved at 1.
    {
        let store = crate::store::open(&config.store, home.path())
            .unwrap_or_else(|e| panic!("open the store: {e:#}"));
        for (id, last) in [(CHAT, 1), (OTHER, 0)] {
            let meta: crate::store::SessionMeta = serde_json::from_value(json!({
                "schema": crate::store::META_SCHEMA, "id": id, "name": id,
                "harness": "fake", "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 1,
                "lastSeq": last,
            }))
            .unwrap_or_else(|e| panic!("meta: {e}"));
            store.save(&meta).unwrap_or_else(|e| panic!("{e:#}"));
        }
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
    }
    // A new daemon with the journal on, its logs read later (`Hub::new_deferred`).
    let journal = SimStorage::new(64);
    let journal_config = cmux_journal::Config {
        retry_min: Duration::from_millis(1),
        retry_max: Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    let store = crate::store::open_with_journal(
        &config.store,
        home.path(),
        Arc::new(journal.clone()),
        journal_config,
    )
    .unwrap_or_else(|e| panic!("open the store: {e:#}"));
    let hub = crate::hub::Hub::new_deferred(config, store, crate::mailbox::Mailbox::memory());
    // The chat's log is not loaded yet: else neither replay would catch up.
    let chat = hub.resolve(CHAT).unwrap_or_else(|e| panic!("{e:?}"));
    assert!(!hub.session_log_loaded(&chat), "the chat's log was loaded before the replays");
    // The other chat's append stops after its log write, the appends' lock held.
    let other = hub.resolve(OTHER).unwrap_or_else(|e| panic!("{e:?}"));
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel::<()>();
    let appender = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            pause_next_log_write_on_this_thread(arrived_tx, release_rx);
            hub.append(&other, "mux", "note", json!({"n": 1})).seq
        })
    };
    arrived.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the append never paused: {e}"));
    // The first replay: its catch-up is under way, and its read of the tail waits at the fence.
    let (under_way_tx, under_way) = std::sync::mpsc::channel();
    let first = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            NOTE_IN_CATCH_UP.with(|note| *note.borrow_mut() = Some(under_way_tx));
            let mut seen = Vec::new();
            hub.scan_events(CHAT, 0, &mut |record| {
                seen.push(record.seq);
                true
            })
            .unwrap_or_else(|e| panic!("{e:#}"));
            seen
        })
    };
    under_way.recv_timeout(WAIT).unwrap_or_else(|e| panic!("the first catch-up never began: {e}"));
    // The second replay meanwhile: it says where it stopped.
    let (events_tx, events) = std::sync::mpsc::channel();
    let second = {
        let hub = hub.clone();
        std::thread::spawn(move || {
            NOTE_BEFORE_CATCH_UP_LOCK.with(|note| *note.borrow_mut() = Some(events_tx.clone()));
            NOTE_BEFORE_REPLAY_SCAN.with(|note| *note.borrow_mut() = Some(events_tx));
            let mut seen = Vec::new();
            hub.scan_events(CHAT, 0, &mut |record| {
                seen.push(record.seq);
                true
            })
            .unwrap_or_else(|e| panic!("{e:#}"));
            seen
        })
    };
    let stopped =
        events.recv_timeout(WAIT).unwrap_or_else(|e| panic!("no word from the second replay: {e}"));
    let _ = release.send(());
    let _ = appender.join().unwrap_or_else(|_| panic!("append panicked"));
    let first = first.join().unwrap_or_else(|_| panic!("the first replay panicked"));
    let second = second.join().unwrap_or_else(|_| panic!("the second replay panicked"));
    assert_eq!(first, vec![1, 2, 3], "the first replay left out the tail");
    assert_eq!(
        second,
        vec![1, 2, 3],
        "a replay during another catch-up left out the tail (it {stopped} while the first catch-up counted)"
    );
}
