//! The cached snapshot never blocks a caller on tailscaled.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_tailnet_local::{
    Error, Fetcher, PeerPath, SnapshotConfig, Source, TailnetLocal, parse_status,
};

fn fixture() -> Vec<u8> {
    std::fs::read(format!("{}/tests/fixtures/status_mixed.json", env!("CARGO_MANIFEST_DIR")))
        .unwrap()
}

fn config(min: Duration) -> SnapshotConfig {
    SnapshotConfig { min_interval: min, retry_after_error: min, ..SnapshotConfig::default() }
}

#[test]
fn snapshot_returns_at_once_while_a_slow_fetch_runs() {
    let calls = Arc::new(AtomicUsize::new(0));
    let c = calls.clone();
    let fetch: Fetcher = Arc::new(move |_| {
        c.fetch_add(1, Ordering::SeqCst);
        std::thread::sleep(Duration::from_millis(300));
        parse_status(&fixture(), Source::Supplied)
    });
    let local = TailnetLocal::with_fetcher(config(Duration::from_secs(60)), fetch);
    let start = Instant::now();
    assert!(local.snapshot().is_none());
    assert_eq!(local.path_hint("100.64.0.2".parse().unwrap()), None);
    assert!(start.elapsed() < Duration::from_millis(100), "snapshot blocked {:?}", start.elapsed());
    let view = local.refresh_blocking(Duration::from_secs(5)).unwrap();
    assert!(view.running());
    assert!(matches!(
        local.path_hint("100.64.0.2".parse().unwrap()),
        Some(PeerPath::Direct { .. })
    ));
    // Fresh: further snapshots do not refetch.
    let before = calls.load(Ordering::SeqCst);
    for _ in 0..100 {
        local.snapshot();
    }
    std::thread::sleep(Duration::from_millis(50));
    assert_eq!(calls.load(Ordering::SeqCst), before);
}

#[test]
fn stale_view_triggers_one_background_refresh_and_previous_is_passed() {
    let saw_previous = Arc::new(Mutex::new(Vec::new()));
    let s = saw_previous.clone();
    let fetch: Fetcher = Arc::new(move |prev| {
        s.lock().unwrap().push(prev.is_some());
        parse_status(&fixture(), Source::Supplied)
    });
    let local = TailnetLocal::with_fetcher(config(Duration::from_millis(50)), fetch);
    local.refresh_blocking(Duration::from_secs(5)).unwrap();
    std::thread::sleep(Duration::from_millis(80));
    assert!(local.snapshot().is_some(), "stale view is still served");
    local.refresh_blocking(Duration::from_secs(5)).unwrap();
    let seen = saw_previous.lock().unwrap().clone();
    assert_eq!(seen.first(), Some(&false));
    assert!(seen[1..].iter().all(|p| *p), "{seen:?}");
}

#[test]
fn errors_keep_the_last_good_view_until_max_age() {
    let fail = Arc::new(AtomicUsize::new(0));
    let f = fail.clone();
    let fetch: Fetcher = Arc::new(move |_| {
        if f.load(Ordering::SeqCst) == 1 {
            Err(Error::Timeout)
        } else {
            parse_status(&fixture(), Source::Supplied)
        }
    });
    let mut cfg = config(Duration::from_millis(10));
    cfg.max_age = Duration::from_millis(300);
    let local = TailnetLocal::with_fetcher(cfg, fetch);
    local.refresh_blocking(Duration::from_secs(5)).unwrap();
    fail.store(1, Ordering::SeqCst);
    assert_eq!(local.refresh_blocking(Duration::from_secs(5)).unwrap_err(), Error::Timeout);
    assert_eq!(local.last_error(), Some(Error::Timeout));
    assert!(local.snapshot().is_some());
    std::thread::sleep(Duration::from_millis(350));
    assert!(local.snapshot().is_none(), "too old to serve");
}
