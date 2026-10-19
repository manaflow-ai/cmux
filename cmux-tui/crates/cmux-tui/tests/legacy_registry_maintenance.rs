//! A registry written by a build without journal maintenance (no incremental
//! auto-vacuum, no migration marker) must not be rewritten by a full VACUUM
//! while its live data is large: VACUUM holds the registry for the whole
//! rewrite, so on a 10.7 GB registry every client of the owner read "not
//! connected" for minutes after an update (cx-4bd8m). Small legacy
//! registries are still converted.
//!
//! Drives the real owner binary: a fresh registry is turned into the legacy
//! shape, the owner is started on it with a short maintenance interval and a
//! small live-data bound (debug-build overrides), and the registry file is
//! read after maintenance ticks.
//!
//! `server compact-registry` (cx-ossub) gives a large legacy registry's free
//! pages back offline: refused while the owner runs, and with the owner
//! stopped it rewrites the file smaller with the same rows and incremental
//! auto-vacuum, which the next owner opens.

#![cfg(all(unix, debug_assertions))]

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rusqlite::Connection;

const REGISTRY: &str = "workspace-registry.sqlite3";
const MIGRATED_KEY: &str = "journal_auto_vacuum_migrated";
/// The live-data bound for the legacy conversion these owners run with.
const TEST_BOUND_BYTES: usize = 8 * 1024 * 1024;

struct StateDir(PathBuf);

impl Drop for StateDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn state_dir(label: &str) -> StateDir {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir =
        PathBuf::from("/tmp").join(format!("cmux-lrm-{label}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(dir.join("state").join("sessions")).unwrap();
    StateDir(dir)
}

fn command(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command
        .env("CMUX_TUI_STATE_DIR", dir.join("state").join("sessions"))
        .env("CMUX_TUI_CONFIG", dir.join("config.json"))
        .env("CMUX_TUI_LOG_FILE", dir.join("client.log"))
        .env("CMUX_TUI_TEST_JOURNAL_MAINTENANCE_INTERVAL_MS", "200")
        .env("CMUX_TUI_TEST_LEGACY_AUTO_VACUUM_MAX_LIVE_BYTES", TEST_BOUND_BYTES.to_string());
    command
}

struct Owner {
    child: Child,
    dir: PathBuf,
    session: String,
}

impl Owner {
    fn start(dir: &Path, session: &str) -> Self {
        let socket = dir.join("mux.sock");
        let _ = fs::remove_file(&socket);
        let child = command(dir)
            .args(["--headless", "--session", session, "--socket"])
            .arg(&socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let owner = Self { child, dir: dir.to_path_buf(), session: session.to_string() };
        let deadline = Instant::now() + Duration::from_secs(60);
        while !owner.answers() {
            assert!(Instant::now() < deadline, "the owner of {session} never answered");
            std::thread::sleep(Duration::from_millis(50));
        }
        owner
    }

    /// `server status` got a running owner back.
    fn answers(&self) -> bool {
        command(&self.dir)
            .args(["--json", "server", "status", "--session", &self.session, "--socket"])
            .arg(self.dir.join("mux.sock"))
            .output()
            .is_ok_and(|output| {
                output.status.success()
                    && String::from_utf8_lossy(&output.stdout).contains("\"running\"")
            })
    }

    fn stop(mut self) {
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            let _ = command(&self.dir)
                .args(["server", "stop", "--session", &self.session, "--socket"])
                .arg(self.dir.join("mux.sock"))
                .output();
            let retry = Instant::now() + Duration::from_secs(1);
            while Instant::now() < retry {
                if self.child.try_wait().unwrap().is_some() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if Instant::now() >= deadline {
                let _ = self.child.kill();
                let _ = self.child.wait();
                panic!("the owner of {} did not stop", self.session);
            }
        }
    }
}

fn registry_path(dir: &Path) -> PathBuf {
    fs::read_dir(dir.join("state").join("sessions"))
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .find(|path| path.join(REGISTRY).is_file())
        .expect("a first start creates the registry")
        .join(REGISTRY)
}

/// Turns the registry into what a build without journal maintenance left:
/// auto-vacuum off, no migration marker, plus `filler` bytes of live data.
fn make_legacy(registry: &Path, filler: usize) {
    let db = Connection::open(registry).unwrap();
    db.execute("DELETE FROM meta WHERE key = ?1", [MIGRATED_KEY]).unwrap();
    db.execute_batch("PRAGMA auto_vacuum=NONE; VACUUM;").unwrap();
    db.execute_batch("CREATE TABLE legacy_filler(chunk BLOB NOT NULL);").unwrap();
    let chunk = vec![0x5a_u8; 1024 * 1024];
    let tx = db.unchecked_transaction().unwrap();
    for _ in 0..filler / chunk.len() {
        tx.execute("INSERT INTO legacy_filler(chunk) VALUES(?1)", [&chunk]).unwrap();
    }
    tx.commit().unwrap();
    db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    assert_eq!(auto_vacuum(&db), 0, "the fixture must be a legacy registry");
}

fn auto_vacuum(db: &Connection) -> i64 {
    db.query_row("PRAGMA auto_vacuum", [], |row| row.get(0)).unwrap()
}

fn migrated(db: &Connection) -> bool {
    db.query_row("SELECT COUNT(*) FROM meta WHERE key = ?1", [MIGRATED_KEY], |row| {
        row.get::<_, i64>(0)
    })
    .unwrap()
        > 0
}

/// Reads the registry's conversion state while the owner runs (WAL readers
/// do not block it).
fn conversion(registry: &Path) -> (i64, bool) {
    let db =
        Connection::open_with_flags(registry, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    (auto_vacuum(&db), migrated(&db))
}

fn first_start(dir: &Path, session: &str) -> PathBuf {
    Owner::start(dir, session).stop();
    registry_path(dir)
}

#[test]
fn a_large_legacy_registry_is_not_vacuumed_while_its_owner_serves() {
    let dir = state_dir("large");
    let session = "lrm-large";
    let registry = first_start(&dir.0, session);
    make_legacy(&registry, 2 * TEST_BOUND_BYTES);

    let owner = Owner::start(&dir.0, session);
    // Many 200 ms maintenance ticks; the owner keeps answering throughout.
    let until = Instant::now() + Duration::from_secs(4);
    while Instant::now() < until {
        assert!(owner.answers(), "the owner stopped answering during maintenance");
        std::thread::sleep(Duration::from_millis(100));
    }
    let state = conversion(&registry);
    owner.stop();
    assert_eq!(
        state,
        (0, false),
        "a legacy registry above the live-data bound must not get a full VACUUM"
    );
}

#[test]
fn a_small_legacy_registry_is_converted() {
    let dir = state_dir("small");
    let session = "lrm-small";
    let registry = first_start(&dir.0, session);
    make_legacy(&registry, TEST_BOUND_BYTES / 8);

    let owner = Owner::start(&dir.0, session);
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut state = conversion(&registry);
    while state != (2, true) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
        state = conversion(&registry);
    }
    owner.stop();
    assert_eq!(state, (2, true), "a small legacy registry converts to incremental auto-vacuum");
}

/// Row count of every table, in name order: the content a compaction must keep.
fn table_rows(registry: &Path) -> Vec<(String, i64)> {
    let db =
        Connection::open_with_flags(registry, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap();
    let tables: Vec<String> = db
        .prepare("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
        .unwrap()
        .query_map([], |row| row.get(0))
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap();
    tables
        .into_iter()
        .map(|table| {
            let count = db
                .query_row(&format!("SELECT COUNT(*) FROM \"{table}\""), [], |row| row.get(0))
                .unwrap();
            (table, count)
        })
        .collect()
}

fn compact(dir: &Path, session: &str) -> (bool, String) {
    let output = command(dir)
        .args(["--json", "server", "compact-registry", "--session", session])
        .output()
        .unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    (output.status.success(), text)
}

#[test]
fn compact_registry_is_refused_while_the_owner_runs_and_shrinks_it_offline() {
    let dir = state_dir("compact");
    let session = "lrm-compact";
    let registry = first_start(&dir.0, session);
    // Live data stays above the in-place bound (the owner must not convert
    // it itself), and as much again is freed: a legacy file keeps those pages.
    let kept_chunks = 2 * TEST_BOUND_BYTES / (1024 * 1024);
    make_legacy(&registry, 4 * TEST_BOUND_BYTES);
    {
        let db = Connection::open(&registry).unwrap();
        db.execute("DELETE FROM legacy_filler WHERE rowid > ?1", [kept_chunks as i64]).unwrap();
        db.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);").unwrap();
    }

    let owner = Owner::start(&dir.0, session);
    let (ok, text) = compact(&dir.0, session);
    assert!(!ok, "compaction must be refused while the owner runs: {text}");
    assert!(text.contains("server.compact_owner_running"), "refusal code: {text}");
    assert!(owner.answers(), "the owner keeps serving after a refused compaction");
    owner.stop();
    assert_eq!(conversion(&registry), (0, false), "the owner left the legacy registry as it was");
    let stopped_rows = table_rows(&registry);
    let before_len = fs::metadata(&registry).unwrap().len();

    let output = command(&dir.0).args(["--json", "server", "compact-registry"]).output().unwrap();
    assert!(!output.status.success(), "compaction without --session is refused");

    let (ok, text) = compact(&dir.0, session);
    assert!(ok, "compaction with the owner stopped: {text}");
    assert!(text.contains("\"compacted\""), "status: {text}");
    let after_len = fs::metadata(&registry).unwrap().len();
    assert!(
        after_len + TEST_BOUND_BYTES as u64 <= before_len,
        "the file gives its free pages back: {before_len} -> {after_len} bytes"
    );
    assert_eq!(table_rows(&registry), stopped_rows, "every table keeps its rows");
    assert_eq!(
        stopped_rows.iter().find(|(table, _)| table == "legacy_filler"),
        Some(&("legacy_filler".to_string(), kept_chunks as i64)),
        "the fixture kept its filler rows"
    );
    {
        let db = Connection::open_with_flags(&registry, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
            .unwrap();
        assert_eq!(auto_vacuum(&db), 2, "the compacted registry is incremental auto-vacuum");
    }

    // The next owner opens the compacted registry and marks it migrated.
    let owner = Owner::start(&dir.0, session);
    let deadline = Instant::now() + Duration::from_secs(20);
    let mut state = conversion(&registry);
    while state != (2, true) && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(100));
        state = conversion(&registry);
    }
    assert!(owner.answers(), "the owner serves the compacted registry");
    owner.stop();
    assert_eq!(state, (2, true), "the owner marks the compacted registry migrated");
}
