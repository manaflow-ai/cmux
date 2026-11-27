//! The put-off peer-cache saves share one writer thread (`peer_cache.rs` `CacheWriter`).

use super::*;
use std::sync::atomic::Ordering;

fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

/// Under peer churn a thread per save left ~110 parked on one gate; many saves at once now
/// start one writer, which runs them all in the order they were queued.
#[tokio::test]
async fn many_saves_at_once_share_one_writer_thread_in_order() {
    let hub = hub();
    let done = Arc::new(StdMutex::new(Vec::new()));
    std::thread::scope(|s| {
        for t in 0..8 {
            let (hub, done) = (Arc::clone(&hub), Arc::clone(&done));
            s.spawn(move || {
                for i in 0..25 {
                    let done = Arc::clone(&done);
                    let queued = hub
                        .cache_writer
                        .push(&hub, Box::new(move |_: &Hub| done.lock().unwrap().push((t, i))));
                    assert!(queued);
                }
            });
        }
    });
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    while done.lock().unwrap().len() < 200 {
        assert!(std::time::Instant::now() < deadline, "writer stalled");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    assert_eq!(hub.cache_writer.threads_started.load(Ordering::Relaxed), 1);
    let done = done.lock().unwrap();
    for t in 0..8 {
        let seen: Vec<_> = done.iter().filter(|(x, _)| *x == t).map(|(_, i)| *i).collect();
        assert_eq!(seen, (0..25).collect::<Vec<_>>(), "one caller's saves land in order");
    }
}
