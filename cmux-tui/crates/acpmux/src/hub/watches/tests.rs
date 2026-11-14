use super::*;
use crate::{
    config::{Config, StoreMode},
    store,
};
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::time::{Duration, sleep};

/// A panic in the watch loop ended it for the daemon's whole life: no watch resolved and no
/// owed wake was sent again, with one line in `panics.jsonl` as the only sign. The loop
/// starts again (`crate::supervise`).
#[tokio::test]
async fn the_watch_loop_runs_again_after_a_panic() {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let hub =
        Hub::new(config.clone(), store::open(&config.store, Path::new("/nonexistent")).unwrap());
    Watches::start(&hub);
    let passes = |hub: &Hub| hub.watches.passes.load(Ordering::SeqCst);
    let reaches = |hub: Arc<Hub>, n: usize| async move {
        tokio::time::timeout(Duration::from_secs(10), async {
            while passes(&hub) < n {
                hub.watches.wake.notify_one();
                sleep(Duration::from_millis(10)).await;
            }
        })
        .await
    };
    reaches(hub.clone(), 1).await.expect("the loop runs");
    hub.watches.panic_next.store(true, Ordering::SeqCst);
    let before = passes(&hub);
    reaches(hub.clone(), before + 3).await.expect("the loop came around again after its panic");
    assert!(!hub.watches.panic_next.load(Ordering::SeqCst), "the loop never panicked");
}

/// Codex review of #40885, F1: a watch saved before `match` was capped came back with its
/// multi-megabyte pattern, and every stub of its peer's replies kept that much of each end. At
/// load the match is cut to `MAX_MATCH_BYTES`; the load never fails over it.
#[test]
fn a_persisted_oversized_match_loads_capped_and_its_stubs_stay_bounded() {
    let dir = cmux_unix_socket::short_test_dir("watch-match-cap");
    let path = dir.path().join("watches.json");
    let watch = |id: &str, m: String| Watch {
        id: id.into(),
        to: "sink".into(),
        sessions: vec!["peer/s".into()],
        until: vec!["ready".into()],
        match_text: Some(m),
        once: true,
        caller: None,
        active: true,
        cursors: BTreeMap::new(),
        offline: BTreeSet::new(),
    };
    let mut saved = Saved::default();
    saved.watches.insert("big".into(), watch("big", "\u{e9}".repeat(2 << 20)));
    saved.watches.insert("small".into(), watch("small", "ready".into()));
    std::fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();

    let watches = Watches::default();
    watches.open(&path);
    let loaded = watches.inner.lock().unwrap().saved.watches.clone();
    assert_eq!(loaded.len(), 2, "the load dropped a watch");
    assert_eq!(loaded["small"].match_text.as_deref(), Some("ready"));
    let big = loaded["big"].match_text.clone().expect("the match was dropped, not capped");
    assert!(big.len() <= crate::hub::MAX_MATCH_BYTES, "match kept {} bytes", big.len());
    assert!(path.exists(), "the state file was moved aside as bad");

    // A long reply chunk stubbed with the loaded pattern stays within a page.
    let text = "\u{e9}".repeat(3 << 20);
    let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s",
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}});
    let stub = super::super::paging::stub_msg(&msg, text.len(), Some(&big));
    let size = serde_json::to_vec(&stub).unwrap().len();
    assert!(size <= super::super::paging::DEFAULT_PAGE_BYTES / 16, "stub is {size} bytes");
}

/// Codex review of #40885 at c18b2425, F1: capping a saved match left each cursor's tail and
/// `matched` from the old pattern. After a restart mid-turn the next chunk searched the old
/// 4 MiB tail with the cut pattern and woke on text the watch had already passed, and the old
/// tail stayed in memory. A capped watch's cursors start the turn's match over.
#[test]
fn a_capped_match_resets_its_cursors_so_the_old_tail_never_wakes() {
    let dir = cmux_unix_socket::short_test_dir("watch-match-cursors");
    let path = dir.path().join("watches.json");
    let old = "q".repeat(4 << 20);
    let cursor = watch_events::Cursor {
        seq: 7,
        // One short of the old pattern: it never matched, but holds the cut one many times.
        tail: "q".repeat((4 << 20) - 1),
        ..Default::default()
    };
    let mut saved = Saved::default();
    saved.watches.insert(
        "w".into(),
        Watch {
            id: "w".into(),
            to: "sink".into(),
            sessions: vec!["peer/s".into()],
            until: vec!["ready".into()],
            match_text: Some(old),
            once: true,
            caller: None,
            active: true,
            cursors: BTreeMap::from([("peer/s".to_string(), cursor)]),
            offline: BTreeSet::new(),
        },
    );
    std::fs::write(&path, serde_json::to_vec(&saved).unwrap()).unwrap();

    let watches = Watches::default();
    watches.open(&path);
    let w = watches.inner.lock().unwrap().saved.watches["w"].clone();
    let pattern = w.match_text.clone().unwrap();
    let mut c = w.cursors["peer/s"].clone();
    assert!(c.tail.len() <= crate::hub::MAX_MATCH_BYTES, "tail kept {} bytes", c.tail.len());
    assert!(!c.matched);
    assert_eq!(c.seq, 7, "the cursor's place in the log is kept");
    c.text("z", Some(&pattern));
    assert!(!c.matched, "the next chunk matched the old tail: a false wake");
}

#[tokio::test]
async fn reconcile_uses_a_real_eight_worker_pool_and_dirty_requeues_once() {
    let _hook = HOOK_TEST.lock().await;
    let dir = cmux_unix_socket::short_test_dir("watch-pool");
    #[cfg(unix)]
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    let hub = Hub::new(config.clone(), store::open(&config.store, dir.path()).unwrap());
    let keys: Vec<_> = (0..100).map(|n| format!("peer/session-{n}")).collect();
    let cursors = keys.iter().map(|k| (k.clone(), watch_events::Cursor::default())).collect();
    hub.watches
        .add(Watch {
            id: "w".into(),
            to: "sink".into(),
            sessions: keys.clone(),
            until: vec!["ready".into()],
            match_text: None,
            once: true,
            caller: None,
            active: true,
            cursors,
            offline: BTreeSet::new(),
        })
        .unwrap();
    let before = tokio::runtime::Handle::current().metrics().num_alive_tasks();
    reconcile(&hub).await.unwrap();
    reconcile(&hub).await.unwrap();
    assert_eq!(tokio::runtime::Handle::current().metrics().num_alive_tasks(), before);
    assert_eq!(hub.watches.jobs.lock().unwrap().ready.len(), 100);
    let active = Arc::new(AtomicUsize::new(0));
    let maximum = Arc::new(AtomicUsize::new(0));
    let reads = Arc::new(Mutex::new(Vec::new()));
    let started = Arc::new(Notify::new());
    let hook: ReadHook = {
        let (active, maximum, reads, started) =
            (active.clone(), maximum.clone(), reads.clone(), started.clone());
        Arc::new(move |key| {
            let (active, maximum, reads, started) =
                (active.clone(), maximum.clone(), reads.clone(), started.clone());
            Box::pin(async move {
                let first = {
                    let mut r = reads.lock().unwrap();
                    r.push(key.clone());
                    key.ends_with("session-0") && r.iter().filter(|k| *k == &key).count() == 1
                };
                if first {
                    started.notify_one();
                }
                let n = active.fetch_add(1, Ordering::SeqCst) + 1;
                maximum.fetch_max(n, Ordering::SeqCst);
                sleep(Duration::from_millis(5)).await;
                active.fetch_sub(1, Ordering::SeqCst);
                Ok(false)
            })
        })
    };
    *READ_HOOK.get_or_init(Mutex::default).lock().unwrap() = Some(hook);
    let workers: Vec<_> =
        (0..REMOTE_WORKERS).map(|_| tokio::spawn(remote_worker(hub.clone()))).collect();
    tokio::time::timeout(Duration::from_secs(5), started.notified()).await.unwrap();
    hub.watches.jobs.lock().unwrap().enqueue("peer/session-0".into());
    for _ in 0..5000 {
        if hub.watches.jobs.lock().unwrap().pending.is_empty() && active.load(Ordering::SeqCst) == 0
        {
            break;
        }
        sleep(Duration::from_millis(1)).await;
    }
    for worker in workers {
        worker.abort();
    }
    let mut expected = keys;
    expected.push("peer/session-0".into());
    let mut actual = reads.lock().unwrap().clone();
    actual.sort();
    expected.sort();
    assert_eq!(actual, expected);
    assert!(maximum.load(Ordering::SeqCst) <= REMOTE_WORKERS);
    *READ_HOOK.get_or_init(Mutex::default).lock().unwrap() = None;
    hub.shutdown_all().await;
}

/// `READ_HOOK` is one per process: the tests that set it run one at a time.
static HOOK_TEST: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// A failing source waits out its backoff in the queue, not in a worker: when eight sources
/// failed at once, each of the eight workers slept out its source's wait, and a healthy
/// source (another peer's) was not read until one woke, up to minutes later.
#[tokio::test]
async fn failing_sources_never_hold_a_worker_from_a_healthy_one() {
    let _hook = HOOK_TEST.lock().await;
    let dir = cmux_unix_socket::short_test_dir("watch-retry");
    #[cfg(unix)]
    std::fs::set_permissions(dir.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
    let mut config = Config::default();
    config.store.mode = StoreMode::Local;
    let hub = Hub::new(config.clone(), store::open(&config.store, dir.path()).unwrap());
    let bad: Vec<_> = (0..REMOTE_WORKERS).map(|n| format!("down/session-{n}")).collect();
    let good = "up/session".to_owned();
    let keys: Vec<_> = bad.iter().cloned().chain([good.clone()]).collect();
    let cursors = keys.iter().map(|k| (k.clone(), watch_events::Cursor::default())).collect();
    hub.watches
        .add(Watch {
            id: "w".into(),
            to: "sink".into(),
            sessions: keys,
            until: vec!["ready".into()],
            match_text: None,
            once: true,
            caller: None,
            active: true,
            cursors,
            offline: BTreeSet::new(),
        })
        .unwrap();
    let reads = Arc::new(Mutex::new(Vec::<(String, tokio::time::Instant)>::new()));
    let failed = Arc::new(Notify::new());
    let hook: ReadHook = {
        let (reads, failed) = (reads.clone(), failed.clone());
        Arc::new(move |key: String| {
            let (reads, failed) = (reads.clone(), failed.clone());
            Box::pin(async move {
                let mut r = reads.lock().unwrap();
                r.push((key.clone(), tokio::time::Instant::now()));
                if !key.starts_with("down/") {
                    return Ok(false);
                }
                if r.iter().filter(|(k, _)| k.starts_with("down/")).count() == REMOTE_WORKERS {
                    failed.notify_one();
                }
                Err(RpcError::internal("peer watch page timed out"))
            })
        })
    };
    *READ_HOOK.get_or_init(Mutex::default).lock().unwrap() = Some(hook);
    let workers: Vec<_> =
        (0..REMOTE_WORKERS).map(|_| tokio::spawn(remote_worker(hub.clone()))).collect();
    {
        let mut jobs = hub.watches.jobs.lock().unwrap();
        for key in &bad {
            jobs.enqueue(key.clone());
        }
    }
    hub.watches.available.notify_one();
    tokio::time::timeout(Duration::from_secs(5), failed.notified()).await.unwrap();
    // Every worker has just seen its source fail. The healthy source comes in now.
    let asked = tokio::time::Instant::now();
    hub.watches.jobs.lock().unwrap().enqueue(good.clone());
    hub.watches.available.notify_one();
    let mut served = None;
    for _ in 0..2000 {
        served = reads.lock().unwrap().iter().find(|(k, _)| *k == good).map(|(_, at)| *at);
        if served.is_some() {
            break;
        }
        sleep(Duration::from_millis(1)).await;
    }
    let served = served.expect("the healthy source was never read");
    assert!(
        served - asked < Duration::from_millis(100),
        "the healthy source waited {:?} behind failing ones",
        served - asked
    );
    // The failing ones are asked again on their own deadlines, backing off: in 1 s at most
    // 250 ms, 500 ms after the first try, each.
    sleep(Duration::from_secs(1)).await;
    for key in &bad {
        let n = reads.lock().unwrap().iter().filter(|(k, _)| k == key).count();
        assert!((2..=3).contains(&n), "{key} was read {n} times in about 1 s");
    }
    for worker in workers {
        worker.abort();
    }
    *READ_HOOK.get_or_init(Mutex::default).lock().unwrap() = None;
    hub.shutdown_all().await;
}
