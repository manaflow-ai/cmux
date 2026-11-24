use super::*;
use crate::hub::inbox::Item;
use crate::prompt_class::PromptClass;

/// The body names the task and carries only its last lines; a cut first line goes.
#[test]
fn a_notice_body_carries_the_last_lines() {
    let dir = cmux_unix_socket::short_test_dir("bg-notice");
    let mut spool = bg_run::Spool::create(dir.path(), "t", 1 << 20).unwrap();
    let out: String = (0..30).map(|i| format!("line-{i}\n")).collect();
    spool.write(out.as_bytes()).unwrap();
    let record = Record { id: "t".into(), command: "make  test\n".into(), ..Record::default() };
    let (body, wrote) = notice_body(dir.path(), &record);
    assert!(wrote);
    assert!(body.starts_with("Task t: make test\nLast 20 lines"), "{body}");
    assert!(body.contains("line-10\n") && body.contains("line-29\n"), "{body}");
    assert!(!body.contains("line-9\n"), "{body}");
    let quiet = Record { id: "none".into(), command: "true".into(), ..Record::default() };
    let (body, wrote) = notice_body(dir.path(), &quiet);
    assert!(!wrote);
    assert!(body.ends_with("It wrote no output."));
}

/// A task end whose subagent ended draws nothing when it went well with no output, one quiet
/// line otherwise; the chat's own task end keeps its row.
#[test]
fn an_orphan_task_end_is_quiet() {
    let ok = json!({"severity": "info"});
    let failed = json!({"severity": "warn"});
    assert_eq!(orphan_display(true, false, &ok), Some("none"));
    assert_eq!(orphan_display(true, true, &ok), Some("line"));
    assert_eq!(orphan_display(true, false, &failed), Some("line"));
    assert_eq!(orphan_display(false, false, &ok), None);
}

/// Number of this process's threads named `acpmux-bg-watch`.
#[cfg(target_os = "linux")]
fn watch_threads() -> usize {
    std::fs::read_dir("/proc/self/task")
        .unwrap()
        .flatten()
        .filter(|t| {
            std::fs::read_to_string(t.path().join("comm"))
                .is_ok_and(|c| c.trim() == "acpmux-bg-watch")
        })
        .count()
}

/// A lock file held as a runner holds it, by its own open file.
fn held_lock(dir: &Path, name: &str) -> (std::path::PathBuf, cmux_file_lock::FileLock) {
    let path = dir.join(format!("{name}.lock"));
    let file = crate::home_fs::create_file(&path).unwrap();
    let held = cmux_file_lock::FileLock::try_take(file, cmux_file_lock::Kind::Exclusive).unwrap();
    (path, held)
}

/// 200 watched tasks take one thread, not 200; a lock let go fires its end once, within a
/// tick or two; a purged chat's watches go without firing while their locks are still held.
#[test]
fn bg_watch_one_thread_fires_once_and_unwatches() {
    let dir = cmux_unix_socket::short_test_dir("bg-watch");
    let owner = 0xb9_0001;
    let fired = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let (tx, rx) = std::sync::mpsc::channel();
    let mut held = Vec::new();
    for i in 0..200 {
        let (path, file) = held_lock(dir.path(), &format!("t{i}"));
        let session = if i == 0 { "live" } else { "purged" };
        let (fired, tx) = (fired.clone(), tx.clone());
        watcher().watch(
            path,
            owner,
            session.into(),
            || true,
            move || {
                fired.fetch_add(1, Ordering::SeqCst);
                let _ = tx.send(i);
            },
        );
        held.push(file);
    }
    #[cfg(target_os = "linux")]
    assert_eq!(watch_threads(), 1, "200 watched tasks take one thread");
    // The purged chat's 199 watches go; their locks stay held.
    watcher().unwatch(owner, "purged");
    let left =
        watcher().state.lock().unwrap().watches.values().filter(|w| w.owner == owner).count();
    assert_eq!(left, 1);
    assert_eq!(fired.load(Ordering::SeqCst), 0, "nothing fired while every lock is held");
    // Every lock let go: only the one still watched fires, once, within the tick.
    let started = std::time::Instant::now();
    drop(held);
    assert_eq!(rx.recv_timeout(TICK * 3).unwrap(), 0);
    assert!(started.elapsed() < TICK * 3);
    std::thread::sleep(TICK * 2);
    assert_eq!(fired.load(Ordering::SeqCst), 1, "one end, once");
    #[cfg(target_os = "linux")]
    assert_eq!(watch_threads(), 1);
}

/// A task whose lock file is gone ends at once, on the caller's thread.
#[test]
fn bg_watch_of_a_missing_lock_ends_at_once() {
    let dir = cmux_unix_socket::short_test_dir("bg-watch-missing");
    let fired = Arc::new(std::sync::atomic::AtomicBool::new(false));
    let f = fired.clone();
    watcher().watch(
        dir.path().join("gone.lock"),
        0xb9_0002,
        "s".into(),
        || true,
        move || {
            f.store(true, Ordering::SeqCst);
        },
    );
    assert!(fired.load(Ordering::SeqCst));
}

/// A hub with idle chat `name` (it ran turns before; no agent), on the coordinator list
/// when `listed`.
async fn hub_with_chat(name: &str, listed: bool) -> (Arc<Hub>, Arc<Session>) {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    if listed {
        cfg.page_rule =
            Some(crate::config::PageRuleConfig { sessions: vec![format!("host/{name}")] });
    }
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let meta = json!({"schema": crate::store::META_SCHEMA, "id": name, "name": name,
        "harness": "claude", "cwd": "/tmp", "status": "idle", "turnCount": 3,
        "createdAt": 1, "updatedAt": 2});
    store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    let hub = Hub::new(cfg, store);
    hub.begin_startup(false);
    let session = hub.resolve(name).unwrap();
    (hub, session)
}

/// An ended task of chat `session`, that exited with `code`.
fn ended(id: &str, session: &Session, code: i32) -> Record {
    Record {
        id: id.into(),
        session_id: session.id.clone(),
        command: "make test".into(),
        ended_at: Some(2),
        exit_code: Some(code),
        notify: true,
        ..Record::default()
    }
}

/// In a chat on the coordinator list, an end with exit 0 starts no turn: it waits in the
/// inbox, counts as sent, goes with the next notice, and a second send adds no second one.
#[tokio::test]
async fn a_listed_chats_exit_zero_end_waits_in_the_inbox() {
    let (hub, session) = hub_with_chat("coord-bg-ok", true).await;
    let dir = cmux_unix_socket::short_test_dir("bg-fold-ok");
    let record = ended("ok1", &session, 0);
    hub.bg_end_to_chat(&session, dir.path(), &record, None).await;
    hub.bg_end_to_chat(&session, dir.path(), &record, None).await;
    assert!(bg_run::notified_path(dir.path(), "ok1").exists(), "sent: no restart owes it");
    {
        let inbox = session.inbox();
        assert_eq!(inbox.items.len(), 1, "once, however often it is sent");
        let item = &inbox.items[0];
        assert_eq!(item.prompt_id, "bg-done-ok1");
        assert!(!item.noticed, "no notice told the agent of it");
        assert!(item.text.contains("make test") && item.text.contains("exit 0"), "{}", item.text);
        assert!(inbox.in_flight.is_none() && inbox.refused_at == 0, "no turn was tried");
        assert!(inbox.timer.is_some(), "its flush is timed");
    }
    // It rides with the next turn the chat takes: a lane's block wakes it, the end is in
    // that notice.
    let block = Item::carried("b1", "lane-a", "blocked on #12");
    let mut block = block;
    block.noticed = false;
    block.class = PromptClass::Block;
    session.inbox().items.push(block);
    let inbox = session.inbox();
    let new: Vec<&Item> = inbox.items.iter().filter(|i| !i.noticed).collect();
    assert!(super::super::inbox::render(&new).0.contains("exit 0"));
}

/// A failed end (nonzero exit, a signal) wakes the chat as before, listed or not: it is
/// never left in the inbox.
#[tokio::test]
async fn a_listed_chats_failed_end_still_wakes() {
    let (hub, session) = hub_with_chat("coord-bg-failed", true).await;
    let dir = cmux_unix_socket::short_test_dir("bg-fold-failed");
    let mut killed = ended("k1", &session, 0);
    killed.exit_code = None;
    killed.signal = Some(9);
    for record in [ended("f1", &session, 2), killed] {
        hub.bg_end_to_chat(&session, dir.path(), &record, None).await;
    }
    assert!(session.inbox().items.is_empty(), "a failure is no inbox item: it is a prompt");
    for id in ["f1", "k1"] {
        // Held, it would be marked sent at once; a prompt is marked only when a turn takes
        // it, and this chat has no agent to take it.
        assert!(!bg_run::notified_path(dir.path(), id).exists(), "{id} took the prompt path");
    }
}

/// A chat not on the list gets its exit-0 end as before: a prompt, not an inbox item.
#[tokio::test]
async fn an_unlisted_chats_exit_zero_end_is_unchanged() {
    let (hub, session) = hub_with_chat("plain-bg-ok", false).await;
    let dir = cmux_unix_socket::short_test_dir("bg-fold-unlisted");
    hub.bg_end_to_chat(&session, dir.path(), &ended("u1", &session, 0), None).await;
    assert!(session.inbox().items.is_empty());
    assert!(!bg_run::notified_path(dir.path(), "u1").exists(), "it took the prompt path, not held");
}
