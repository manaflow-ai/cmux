//! The cache's own rules, with no session and no worker thread.

use super::*;

fn branch(name: &str) -> Option<GitHead> {
    Some(GitHead { name: name.to_string(), detached: false })
}

fn entry(head: Option<GitHead>, refreshing: bool) -> Entry {
    Entry { checked: Instant::now(), head, refreshing }
}

/// Two replies can read a directory that has no cached value at the same time, and the branch
/// can change between their reads. The second store must move the tree revision: a client that
/// holds the tree with the first value would get `unchanged` for the second.
#[test]
fn a_second_read_of_an_uncached_directory_that_differs_moves_the_revision() {
    let mut cache = Inner::default();
    let now = Instant::now();
    let moves = [
        cache.store_read("/repository", now, branch("main")),
        cache.store_read("/repository", now, branch("main")),
        cache.store_read("/repository", now, branch("next")),
        cache.store_read("/repository", now, None),
        cache.store_read("/other", now, branch("next")),
    ];
    assert_eq!(
        moves,
        [false, false, true, true, false],
        "which stores move the revision: a first value, the same value, another branch, no \
         repository, a first value of another directory"
    );
    assert_eq!(cache.heads.len(), 2);
    assert_eq!(cache.heads.get("/repository").map(|entry| entry.head.clone()), Some(None));
}

/// A store over a directory that waits in the queue keeps it there one time.
#[test]
fn a_store_over_a_queued_directory_keeps_its_place_in_the_refresh() {
    let mut cache = Inner::default();
    cache.heads.insert("/repository".to_string(), entry(branch("main"), true));
    cache.queue.push("/repository".to_string());
    assert!(cache.store_read("/repository", Instant::now(), branch("next")));
    assert!(cache.heads.get("/repository").is_some_and(|entry| entry.refreshing));
    assert_eq!(cache.queue.len(), 1);
}

/// The full cache is emptied before a new directory goes in, and that moves the revision: the
/// cache forgot the values that a refresh could compare with.
#[test]
fn a_store_into_the_full_cache_empties_it_and_moves_the_revision() {
    let mut cache = Inner::default();
    for index in 0..GIT_HEAD_CACHE_LIMIT {
        assert!(!cache.store_read(&format!("/repository-{index}"), Instant::now(), None));
    }
    assert_eq!(cache.heads.len(), GIT_HEAD_CACHE_LIMIT);
    assert!(!cache.store_read("/repository-0", Instant::now(), None), "a cached directory");
    assert_eq!(cache.heads.len(), GIT_HEAD_CACHE_LIMIT);
    assert!(cache.store_read("/one-more", Instant::now(), None));
    assert_eq!(cache.heads.len(), 1);
}

/// A worker thread that panics ends the refresh: no directory stays `refreshing` and the next
/// reply can start a worker.
#[test]
fn a_worker_that_panics_leaves_no_directory_in_the_refresh() {
    let cache = Arc::new(GitHeadCache::default());
    {
        let mut inner = cache.inner.lock().recover_poison();
        inner.heads.insert("/read-now".to_string(), entry(branch("main"), true));
        inner.heads.insert("/queued".to_string(), entry(branch("main"), true));
        inner.heads.insert("/fresh".to_string(), entry(None, false));
        inner.queue.push("/queued".to_string());
        inner.worker_running = true;
    }
    git_head_probe::refresh_started();
    let worker = std::thread::spawn({
        let cache = Arc::clone(&cache);
        move || {
            let _end = RefreshEnd(cache);
            std::panic::panic_any("the worker of this test panics");
        }
    });
    assert!(worker.join().is_err(), "the thread did not panic");
    assert_eq!(git_head_probe::refreshes_running(), 0);
    let inner = cache.inner.lock().recover_poison();
    let refreshing = inner.heads.values().filter(|entry| entry.refreshing).count();
    assert_eq!(
        (inner.worker_running, inner.queue.len(), refreshing, inner.heads.len()),
        (false, 0, 0, 3),
        "after a worker panic: worker_running, queued directories, directories marked \
         `refreshing`, cached directories"
    );
}
