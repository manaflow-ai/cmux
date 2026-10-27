use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, sync_channel};
use std::time::Duration;

use cmux_memory::{PressureLevel, Retention};

use super::{TrimRun, TrimTarget};
use crate::memory::{DaemonMemory, MemorySetup};

/// The Files lane's best-effort worker of the mux's `Work` (`mux-files-be`).
const FILES_WORKER: &str = "mux-files-be";

struct Fixture {
    root: PathBuf,
    memory: Arc<DaemonMemory>,
    mux: Arc<crate::Mux>,
    runs: Receiver<TrimRun>,
}

impl Fixture {
    fn new(name: &str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-sqlite-trim-{name}-{}", crate::workspace_registry::new_uuid_v4()));
        let memory = Arc::new(DaemonMemory::without_system_source());
        let setup = MemorySetup { memory: memory.clone(), scrollback_pressure: false };
        let mux = crate::Mux::open_persistent_with_memory_for_test(
            name,
            crate::SurfaceOptions::default(),
            &root,
            setup,
        )
        .unwrap();
        let (observer, runs) = sync_channel(64);
        mux.sqlite_trim.observer.set(observer).unwrap();
        Self { root, memory, mux, runs }
    }

    /// The release of every target, in any order.
    fn wait_for_every_release(&self) -> Vec<TrimRun> {
        let mut runs: Vec<TrimRun> = (0..TrimTarget::ALL.len())
            .map(|_| self.runs.recv_timeout(Duration::from_secs(10)).expect("a release ran"))
            .collect();
        runs.sort_by_key(|run| run.target as usize);
        runs
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.mux.shutdown();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// 10,000 rows of 100 bytes in the registry database.
fn insert_registry_rows(mux: &crate::Mux) {
    mux.registry_connection
        .get()
        .execute_batch(
            "CREATE TABLE trim_rows(id INTEGER PRIMARY KEY, text TEXT NOT NULL);
             WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 10000)
             INSERT INTO trim_rows(text) SELECT printf('%0100d', i) FROM n;",
        )
        .unwrap();
}

/// Scans the 10,000 rows until the registry connection's page cache holds
/// them (about 1.1 MB, under its 2 MB cap); returns the bytes it holds.
/// SQLite here shares one page cache LRU between every connection of the
/// process (`SQLITE_ENABLE_MEMORY_MANAGEMENT`), and a connection that closes
/// in a parallel test evicts LRU pages of the others, so a scan is repeated
/// when such an eviction emptied the cache before it was read.
fn fill_registry_cache(mux: &crate::Mux) -> u64 {
    let mut filled = 0;
    for _ in 0..5 {
        let total: i64 = mux
            .registry_connection
            .get()
            .query_row("SELECT SUM(LENGTH(text)) FROM trim_rows", [], |row| row.get(0))
            .unwrap();
        assert_eq!(total, 1_000_000, "the rows read (again after a release)");
        filled = mux.registry_connection.cache_used_bytes().unwrap();
        if filled > 500_000 {
            return filled;
        }
    }
    panic!("five scans of 10,000 rows left {filled} bytes in the page cache");
}

#[test]
fn sqlite_trim_registers_one_lossless_consumer_per_connection() {
    let fixture = Fixture::new("consumers");
    fixture.mux.register_sqlite_trim();
    fixture.mux.register_sqlite_trim();
    let mut names: Vec<_> = fixture
        .memory
        .registry()
        .report()
        .into_iter()
        .filter(|line| line.name.starts_with("sqlite."))
        .inspect(|line| assert_eq!(line.retention, Retention::Lossless, "{}", line.name))
        .map(|line| line.name)
        .collect();
    names.sort_unstable();
    let mut expected: Vec<_> =
        TrimTarget::ALL.iter().map(|target| target.consumer_name()).collect();
    expected.sort_unstable();
    assert_eq!(names, expected, "registered once");
}

/// The acceptance case: after a 10k-row query, a warning vote frees the
/// registry connection's page cache to near 0, on the Files lane worker,
/// never on the voting thread.
#[test]
fn sqlite_trim_warning_frees_the_registry_cache_on_the_files_worker() {
    let fixture = Fixture::new("registry");
    fixture.mux.register_sqlite_trim();
    insert_registry_rows(&fixture.mux);
    let filled = fill_registry_cache(&fixture.mux);

    let voter = fixture.memory.registry().voter();
    voter.set_level(PressureLevel::Warning);
    let runs = fixture.wait_for_every_release();
    let voting_thread = std::thread::current().name().map(str::to_owned);
    for run in &runs {
        assert_eq!(run.thread.as_deref(), Some(FILES_WORKER), "{:?}", run.target);
        assert_ne!(run.thread, voting_thread);
    }
    let trimmed = fixture.mux.registry_connection.cache_used_bytes().unwrap();
    assert!(trimmed < 64 * 1024, "release left {trimmed} of {filled} bytes");

    // The rows read again, and critical frees what they filled again.
    fill_registry_cache(&fixture.mux);
    voter.set_level(PressureLevel::Critical);
    fixture.wait_for_every_release();
    let trimmed = fixture.mux.registry_connection.cache_used_bytes().unwrap();
    assert!(trimmed < 64 * 1024, "critical left {trimmed} bytes");

    // Back to normal asks for nothing.
    voter.set_level(PressureLevel::Normal);
    assert!(fixture.runs.recv_timeout(Duration::from_millis(200)).is_err());
}

/// A consumer that registers under pressure frees at once (the registry
/// delivers the current level), and stores that were never opened stay
/// closed: no conversation or Chief store and no history directory appear.
#[test]
fn sqlite_trim_registered_under_pressure_releases_and_opens_nothing() {
    let fixture = Fixture::new("unopened");
    let voter = fixture.memory.registry().voter();
    voter.set_level(PressureLevel::Critical);
    fixture.mux.register_sqlite_trim();
    let runs = fixture.wait_for_every_release();
    assert!(runs.iter().all(|run| run.thread.as_deref() == Some(FILES_WORKER)));
    assert!(fixture.mux.conversations.lock_store().unwrap().is_none());
    assert!(fixture.mux.chiefs.lock_store().unwrap().is_none());
    let history = fixture.mux.session_state_directory().unwrap().parent().unwrap().join("history");
    assert!(!history.exists(), "a release opened the page history");
}

/// The conversation and Chief stores free their own connections' caches.
#[test]
fn sqlite_trim_frees_the_conversation_and_chief_store_caches() {
    let fixture = Fixture::new("stores");
    fixture.mux.register_sqlite_trim();
    fixture.mux.with_conversations(|store| store.list()).unwrap();
    let directory = fixture.mux.session_state_directory();
    *fixture.mux.chiefs.lock_store().unwrap() =
        Some(crate::chief_registry::ChiefStore::open(directory.as_deref()).unwrap());
    let conversations = fixture.mux.conversations.cache_used_bytes().unwrap();
    let chiefs = fixture.mux.chiefs.cache_used_bytes().unwrap();
    assert!(conversations > 0 && chiefs > 0, "opening read the schemas");

    let voter = fixture.memory.registry().voter();
    voter.set_level(PressureLevel::Warning);
    fixture.wait_for_every_release();
    let after = (
        fixture.mux.conversations.cache_used_bytes().unwrap(),
        fixture.mux.chiefs.cache_used_bytes().unwrap(),
    );
    // An empty store's cache is SQLite's own floor of about 5 KB.
    assert!(
        after.0 <= conversations && after.0 < 16 * 1024,
        "{after:?} of ({conversations}, {chiefs})"
    );
    assert!(after.1 < chiefs && after.1 < 16 * 1024, "{after:?} of ({conversations}, {chiefs})");
}

/// A burst of level changes before the worker runs queues one release per
/// connection.
#[test]
fn sqlite_trim_a_burst_of_levels_queues_one_release_per_connection() {
    let fixture = Fixture::new("burst");
    fixture.mux.register_sqlite_trim();
    // Hold the registry connection so the registry release waits behind it.
    let held = fixture.mux.registry_connection.get();
    let voter = fixture.memory.registry().voter();
    for _ in 0..5 {
        voter.set_level(PressureLevel::Warning);
        voter.set_level(PressureLevel::Critical);
    }
    drop(held);
    let mut registry_runs = 0;
    while let Ok(run) = fixture.runs.recv_timeout(Duration::from_millis(500)) {
        registry_runs += usize::from(run.target == TrimTarget::Registry);
    }
    assert!(
        (1..=2).contains(&registry_runs),
        "{registry_runs} registry releases: one queued, at most one more after it started"
    );
}
