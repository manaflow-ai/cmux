//! The cache's own rules, with no session and no worker thread.

use super::*;

fn branch(name: &str) -> Option<GitHead> {
    Some(GitHead { name: name.to_string(), detached: false })
}

fn value(head: Option<GitHead>, at: &str, watched: bool) -> Cached {
    Cached { head, at: PathBuf::from(at), watched }
}

/// Stores `head` for `cwd`, read now from `at`.
fn store(cache: &mut Inner, cwd: &str, head: Option<GitHead>, at: &str, watched: bool) -> bool {
    let stamp = cache.heads.stamp();
    cache.store(cwd, stamp, Instant::now(), value(head, at, watched))
}

/// Two replies can read a directory that has no cached value at the same time, and the branch
/// can change between their reads. The second store must move the tree revision: a client that
/// holds the tree with the first value would get `unchanged` for the second.
#[test]
fn a_second_read_of_an_uncached_directory_that_differs_moves_the_revision() {
    let mut cache = Inner::default();
    let moves = [
        store(&mut cache, "/repository", branch("main"), "/repository/.git", false),
        store(&mut cache, "/repository", branch("main"), "/repository/.git", false),
        store(&mut cache, "/repository", branch("next"), "/repository/.git", false),
        store(&mut cache, "/repository", None, "/repository", false),
        store(&mut cache, "/other", branch("next"), "/other/.git", false),
    ];
    assert_eq!(
        moves,
        [false, false, true, true, false],
        "which stores move the revision: a first value, the same value, another branch, no \
         repository, a first value of another directory"
    );
    assert_eq!(cache.checked.len(), 2);
    assert_eq!(cache.lookup("/repository", Instant::now()).map(|(head, _)| head), Some(None));
}

/// The full cache is emptied before a new directory goes in, and that moves the revision: the
/// cache forgot the values that a refresh could compare with. Nothing names a dropped value.
#[test]
fn a_store_into_the_full_cache_empties_it_and_moves_the_revision() {
    let mut cache = Inner::default();
    for index in 0..GIT_HEAD_CACHE_LIMIT {
        let cwd = format!("/repository-{index}");
        assert!(!store(&mut cache, &cwd, None, &cwd, true));
    }
    assert_eq!(
        (cache.checked.len(), cache.heads.len()),
        (GIT_HEAD_CACHE_LIMIT, GIT_HEAD_CACHE_LIMIT)
    );
    assert!(!store(&mut cache, "/repository-0", None, "/repository-0", true), "a cached directory");
    assert!(store(&mut cache, "/one-more", None, "/one-more", true));
    assert_eq!(
        (cache.checked.len(), cache.heads.len(), cache.by_dir.len()),
        (1, 1, 1),
        "cached directories, values, watched directories"
    );
}

/// A watched value lives [`GIT_HEAD_SAFETY_TTL`] and one the watch does not hold
/// [`GIT_HEAD_TTL`]; an invalidation of its directory's tag makes a watched value stale at once,
/// and leaves the values of other directories fresh.
#[test]
fn a_watched_value_is_read_again_on_its_tag_or_past_the_safety_lifetime() {
    let mut cache = Inner::default();
    store(&mut cache, "/a/src", branch("main"), "/a/.git", true);
    store(&mut cache, "/a/doc", branch("main"), "/a/.git", true);
    store(&mut cache, "/b", branch("main"), "/b/.git", true);
    store(&mut cache, "/c", branch("main"), "/c/.git", false);
    let again = |cache: &Inner, cwd: &str, after: Duration| {
        cache.lookup(cwd, Instant::now() + after).is_some_and(|(_, again)| again)
    };
    let past_ttl = GIT_HEAD_TTL + Duration::from_secs(1);
    assert_eq!(
        [again(&cache, "/a/src", past_ttl), again(&cache, "/c", past_ttl)],
        [false, true],
        "3 seconds on: a watched value, a value the watch does not hold"
    );
    assert!(again(&cache, "/b", GIT_HEAD_SAFETY_TTL));

    cache.heads.invalidate(HeadTag::Dir(PathBuf::from("/a/.git")));
    assert_eq!(
        [
            again(&cache, "/a/src", Duration::ZERO),
            again(&cache, "/a/doc", Duration::ZERO),
            again(&cache, "/b", Duration::ZERO),
        ],
        [true, true, false],
        "after a write of /a/.git/HEAD"
    );
    assert_eq!(
        cache.by_dir.get(Path::new("/a/.git")).map(HashSet::len),
        Some(2),
        "the directories the watch of /a/.git sends to the refresh"
    );
}

/// A value read while its directory changed (the event landed between the stamp and the store)
/// is stored stale, so the worker reads it again.
#[test]
fn a_value_read_across_an_event_is_stored_stale() {
    let mut cache = Inner::default();
    store(&mut cache, "/a", branch("main"), "/a/.git", true);
    let stamp = cache.heads.stamp();
    cache.heads.invalidate(HeadTag::Dir(PathBuf::from("/a/.git")));
    cache.store("/a", stamp, Instant::now(), value(branch("main"), "/a/.git", true));
    assert!(matches!(cache.heads.get("/a"), Lookup::Stale(_)));
}

/// A request with `known` walks the cached directories only once one is due: before that it
/// costs one comparison, whatever is cached.
#[test]
fn the_sweep_of_a_known_request_walks_nothing_until_a_value_is_due() {
    let mut cache = Inner::default();
    for index in 0..64 {
        let cwd = format!("/r-{index}");
        store(&mut cache, &cwd, branch("main"), &format!("{cwd}/.git"), true);
    }
    let now = Instant::now();
    cache.queue_due(now + GIT_HEAD_TTL + Duration::from_secs(1));
    assert!(cache.queue.is_empty(), "no watched value is due 3 seconds on");
    cache.queue_due(now + GIT_HEAD_SAFETY_TTL + Duration::from_secs(1));
    assert_eq!(cache.queue.len(), 64, "each is due past the safety lifetime");
    cache.queue_due(now + GIT_HEAD_SAFETY_TTL + Duration::from_secs(1));
    assert_eq!(cache.queue.len(), 64, "a directory is in the refresh one time");
}

/// The events of a burst: a HEAD write names its git dir, a `.git` write the directory it would
/// make a repository, a read nothing, and an error or a rescan every value.
#[test]
fn the_watch_takes_head_and_dot_git_writes_and_rescans() {
    use notify::event::{AccessKind, CreateKind, Event, EventKind, Flag, ModifyKind};
    let mut fired = Fired::default();
    fired.add(Ok(Event::new(EventKind::Access(AccessKind::Any)).add_path("/a/.git/HEAD".into())));
    fired.add(Ok(Event::new(EventKind::Modify(ModifyKind::Any)).add_path("/a/.git/index".into())));
    assert!(fired.dirs.is_empty() && !fired.all, "a read and a write of another file");
    fired.add(Ok(Event::new(EventKind::Modify(ModifyKind::Any)).add_path("/a/.git/HEAD".into())));
    fired.add(Ok(Event::new(EventKind::Create(CreateKind::Folder)).add_path("/b/.git".into())));
    assert_eq!(fired.dirs, HashSet::from([PathBuf::from("/a/.git"), PathBuf::from("/b")]));
    assert!(!fired.all);
    fired.add(Ok(Event::new(EventKind::Other).set_flag(Flag::Rescan)));
    assert!(fired.all, "a rescan");
    let mut fired = Fired::default();
    fired.add(Err(notify::Error::generic("inotify read failed")));
    assert!(fired.all, "a watcher error");
}

/// A worker thread that panics ends the refresh: no directory stays `refreshing` and the next
/// reply can start a worker.
#[test]
fn a_worker_that_panics_leaves_no_directory_in_the_refresh() {
    let cache = Arc::new(GitHeadCache::default());
    {
        let mut inner = cache.inner.lock().recover_poison();
        store(&mut inner, "/read-now", branch("main"), "/read-now/.git", true);
        store(&mut inner, "/queued", branch("main"), "/queued/.git", true);
        store(&mut inner, "/fresh", None, "/fresh", true);
        inner.refreshing.insert("/read-now".to_string());
        inner.enqueue("/queued");
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
    assert_eq!(
        (inner.worker_running, inner.queue.len(), inner.refreshing.len(), inner.checked.len()),
        (false, 0, 0, 3),
        "after a worker panic: worker_running, queued directories, directories marked \
         `refreshing`, cached directories"
    );
}
