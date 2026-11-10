//! Registry premigration (`server premigrate-registry`): the next build folds
//! the agent roster beside the running owner, read-only, into a side file
//! that the next owner adopts at open.

use super::*;
use crate::journal_reducers::{AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION};
use crate::mux::agent_roster_restore::{RosterFoldLimits, restore_agent_roster_with};
use crate::workspace_registry::premigrate::{
    PremigrateControl, PremigrateOutcome, RosterPremigration, premigrate_registry, registry_file,
    roster_side_file,
};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::Duration;

struct Store {
    root: PathBuf,
    session: &'static str,
    db_path: PathBuf,
    /// The roster a cold fold of the whole journal ends with.
    cold: Value,
    head: u64,
}

impl Drop for Store {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn never() -> bool {
    false
}
const NEVER: &dyn Fn() -> bool = &never;

/// `<registry>` plus `suffix`, as the registry names its sidecars.
fn sidecar(db_path: &Path, suffix: &str) -> PathBuf {
    let mut name = db_path.as_os_str().to_os_string();
    name.push(suffix);
    PathBuf::from(name)
}

/// Agents in sealed segments and in the active journal, then a roster
/// snapshot of an older reducer version, as a nightly that bumps the version
/// finds it.
fn stale_roster_store(session: &'static str) -> Store {
    let root = std::env::temp_dir()
        .join(format!("cmux-premigrate-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    for step in 0..4 {
        let surface = mux.new_workspace(None, None).unwrap();
        let terminal_id = surface.terminal_public_id().cloned().expect("workspace terminal");
        append_journal_hook(&mux, &terminal_id, "SessionStart", Some(&format!("agent-{step}")));
        if step < 3 {
            let checkpoint = mux
                .create_journal_checkpoint("client_test", &format!("premigrate_{step}_checkpoint"))
                .unwrap();
            mux.seal_journal_segments(
                checkpoint.checkpoint.source_sequence,
                "client_test",
                &format!("premigrate_{step}_seal"),
            )
            .unwrap();
        }
    }
    mux.shutdown();
    drop(mux);
    let db_path = registry_file(&root, session);
    assert!(db_path.is_file(), "{}", db_path.display());
    // No saved roster at all: the restore below folds from the first record
    // (a version mismatch would serve the old snapshot and rebuild later).
    write_meta(&db_path, &[(roster_key().as_str(), None), (rebuild_key().as_str(), None)]);
    let registry = WorkspaceRegistry::open(&root, session).unwrap();
    let head = registry.session_journal_head().unwrap();
    let limits = RosterFoldLimits { page: 512, save_every_pages: 64, stop_after_pages: None };
    let cold = restore_agent_roster_with(&registry, limits).unwrap();
    assert!(cold.diagnostic.is_none(), "{:?}", cold.diagnostic);
    assert_eq!(cold.host.cursor, head);
    let cold = cold.host.roster.snapshot();
    assert!(cold.to_string().contains("agent-0"), "the cold fold has the agents: {cold}");
    // Back to the older version: the cold fold above saved the current one.
    registry.put_journal_reducer_state(AGENT_ROSTER_REDUCER_ID, 8, 3, "{}").unwrap();
    drop(registry);
    Store { root, session, db_path, cold, head }
}

fn roster_key() -> String {
    format!("journal_reducer.{AGENT_ROSTER_REDUCER_ID}")
}

fn rebuild_key() -> String {
    format!("journal_reducer_rebuild.{AGENT_ROSTER_REDUCER_ID}")
}

/// Sets (`Some`) or deletes (`None`) `meta` rows with no registry open.
fn write_meta(db_path: &Path, rows: &[(&str, Option<String>)]) {
    let db = rusqlite::Connection::open(db_path).unwrap();
    for (key, value) in rows {
        match value {
            Some(value) => db
                .execute(
                    "INSERT INTO meta(key, value) VALUES(?1, ?2)
                     ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                    rusqlite::params![key, value],
                )
                .unwrap(),
            None => db.execute("DELETE FROM meta WHERE key = ?1", rusqlite::params![key]).unwrap(),
        };
    }
}

fn premigrate(store: &Store, control: &PremigrateControl<'_>) -> RosterPremigration {
    match premigrate_registry(&store.root, store.session, control).unwrap() {
        PremigrateOutcome::Done(report) => report,
        other => panic!("expected a premigration, got {other:?}"),
    }
}

fn side_file(store: &Store) -> Value {
    serde_json::from_slice(&std::fs::read(roster_side_file(&store.db_path)).unwrap()).unwrap()
}

fn side_snapshot(store: &Store) -> Value {
    serde_json::from_str(side_file(store)["snapshot"].as_str().unwrap()).unwrap()
}

fn rewrite_side_file(store: &Store, edit: impl FnOnce(&mut Value)) {
    let mut value = side_file(store);
    edit(&mut value);
    std::fs::write(roster_side_file(&store.db_path), value.to_string()).unwrap();
}

fn stored_roster(store: &Store) -> (u32, u64, String) {
    // Read without an open, which would adopt the side file.
    let connection = rusqlite::Connection::open_with_flags(
        &store.db_path,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
    )
    .unwrap();
    let raw: String = connection
        .query_row(
            "SELECT value FROM meta WHERE key = ?1",
            [format!("journal_reducer.{AGENT_ROSTER_REDUCER_ID}")],
            |row| row.get(0),
        )
        .unwrap();
    let value: Value = serde_json::from_str(&raw).unwrap();
    (
        value["version"].as_u64().unwrap() as u32,
        value["cursor"].as_str().unwrap().parse().unwrap(),
        value["snapshot"].as_str().unwrap().to_owned(),
    )
}

#[test]
fn the_side_snapshot_equals_a_cold_fold() {
    let store = stale_roster_store("premigrate-cold");
    let report = premigrate(&store, &PremigrateControl::new(None, NEVER));
    assert!(report.complete && !report.up_to_date, "{report:?}");
    assert_eq!((report.from_cursor, report.cursor, report.head), (0, store.head, store.head));
    assert!(report.records_folded > 0);
    let side = side_file(&store);
    assert_eq!(side["format"], 1);
    assert_eq!(side["reducer_id"], AGENT_ROSTER_REDUCER_ID);
    assert_eq!(side["version"], AGENT_ROSTER_REDUCER_VERSION);
    assert_eq!(side["cursor"], store.head.to_string());
    assert_eq!(side_snapshot(&store), store.cold);
    // The registry itself still has the older roster.
    assert_eq!(stored_roster(&store).0, 8);
}

#[test]
fn a_partial_premigration_resumes_from_its_side_file() {
    let store = stale_roster_store("premigrate-resume");
    let first = premigrate(&store, &PremigrateControl::new(None, NEVER).pages(1, Some(2)));
    assert!(!first.complete, "{first:?}");
    assert!(first.cursor > 0 && first.cursor < store.head, "{first:?}");
    assert_eq!(side_file(&store)["cursor"], first.cursor.to_string());

    let second = premigrate(&store, &PremigrateControl::new(None, NEVER).pages(1, None));
    assert_eq!(second.from_cursor, first.cursor);
    assert!(second.complete, "{second:?}");
    assert_eq!(side_snapshot(&store), store.cold);

    // A stop request saves where the fold was and exits cleanly.
    std::fs::remove_file(roster_side_file(&store.db_path)).unwrap();
    let stopped = premigrate(&store, &PremigrateControl::new(None, &|| true));
    assert_eq!(
        (stopped.cursor, stopped.complete, stopped.stop_reason),
        (0, false, Some("stopped"))
    );
}

#[test]
fn an_up_to_date_roster_or_a_missing_registry_has_nothing_to_premigrate() {
    let store = stale_roster_store("premigrate-up-to-date");
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    registry
        .put_journal_reducer_state(AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, 1, "{}")
        .unwrap();
    drop(registry);
    let report = premigrate(&store, &PremigrateControl::new(None, NEVER));
    assert!(report.up_to_date && report.complete && report.records_folded == 0, "{report:?}");
    assert!(!roster_side_file(&store.db_path).exists());
    assert!(matches!(
        premigrate_registry(
            &store.root,
            "premigrate-no-such-session",
            &PremigrateControl::new(None, NEVER)
        )
        .unwrap(),
        PremigrateOutcome::NoRegistry(_)
    ));
}

#[test]
fn a_second_premigration_of_the_same_registry_says_it_already_runs() {
    let store = stale_roster_store("premigrate-lock");
    let lock = std::fs::File::create(sidecar(&store.db_path, ".premigrate.lock")).unwrap();
    fs4::FileExt::lock(&lock).unwrap();
    assert!(matches!(
        premigrate_registry(&store.root, store.session, &PremigrateControl::new(None, NEVER))
            .unwrap(),
        PremigrateOutcome::AlreadyRunning(_)
    ));
    fs4::FileExt::unlock(&lock).unwrap();
}

/// The owner keeps serving: a write transaction it holds open does not stop
/// the premigration, and the premigration changes neither the database
/// file nor its WAL.
#[test]
fn a_premigration_never_writes_the_live_registry_and_runs_beside_a_writer() {
    let store = stale_roster_store("premigrate-read-only");
    let wal = sidecar(&store.db_path, "-wal");
    let writer = rusqlite::Connection::open(&store.db_path).unwrap();
    writer.execute_batch("PRAGMA journal_mode=WAL;").unwrap();
    writer
        .execute_batch(
            "BEGIN IMMEDIATE; INSERT INTO meta(key, value) VALUES('premigrate_test', '1');",
        )
        .unwrap();
    let before = (std::fs::read(&store.db_path).unwrap(), std::fs::read(&wal).unwrap_or_default());
    let report = premigrate(&store, &PremigrateControl::new(None, NEVER));
    assert!(report.complete, "{report:?}");
    let after = (std::fs::read(&store.db_path).unwrap(), std::fs::read(&wal).unwrap_or_default());
    assert!(before == after, "the premigration wrote the registry or its WAL");
    writer.execute_batch("COMMIT;").unwrap();
    assert_eq!(side_snapshot(&store), store.cold);
}

#[test]
fn the_next_open_adopts_a_matching_side_snapshot() {
    let store = stale_roster_store("premigrate-adopt");
    let report = premigrate(&store, &PremigrateControl::new(None, NEVER));
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    drop(registry);
    let (version, cursor, snapshot) = stored_roster(&store);
    assert_eq!((version, cursor), (AGENT_ROSTER_REDUCER_VERSION, report.cursor));
    assert_eq!(serde_json::from_str::<Value>(&snapshot).unwrap(), store.cold);
    assert!(!roster_side_file(&store.db_path).exists(), "an adopted side file is removed");
}

#[test]
fn the_next_open_drops_a_side_snapshot_it_cannot_use() {
    type Edit<'a> = &'a dyn Fn(&mut Value);
    let cases: [(&str, Edit<'_>); 4] = [
        ("other registry", &|side| side["registry_id"] = "another-registry".into()),
        ("older version", &|side| side["version"] = (AGENT_ROSTER_REDUCER_VERSION - 1).into()),
        ("past the head", &|side| side["cursor"] = u64::MAX.to_string().into()),
        ("bad snapshot", &|side| side["snapshot"] = "not a roster".into()),
    ];
    for (case, edit) in cases {
        let store = stale_roster_store("premigrate-reject");
        premigrate(&store, &PremigrateControl::new(None, NEVER));
        rewrite_side_file(&store, edit);
        drop(WorkspaceRegistry::open(&store.root, store.session).unwrap());
        assert_eq!(stored_roster(&store).0, 8, "{case}: the side snapshot was adopted");
        assert!(!roster_side_file(&store.db_path).exists(), "{case}: the side file stayed");
    }
    // A registry already at the current version keeps its own roster and
    // drops a leftover side file.
    let store = stale_roster_store("premigrate-leftover");
    premigrate(&store, &PremigrateControl::new(None, NEVER));
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    std::fs::write(roster_side_file(&store.db_path), side_file_text_for_test()).unwrap();
    registry
        .put_journal_reducer_state(AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, 1, "{}")
        .unwrap();
    drop(registry);
    drop(WorkspaceRegistry::open(&store.root, store.session).unwrap());
    assert_eq!(stored_roster(&store).1, 1);
    assert!(!roster_side_file(&store.db_path).exists());
}

fn side_file_text_for_test() -> String {
    serde_json::json!({"format": 1, "reducer_id": AGENT_ROSTER_REDUCER_ID}).to_string()
}

/// A partial premigration (adopted at open when it is past the saved roster's
/// cursor, else a seed for the rebuild), the start's bounded fold and its
/// background replay and rebuild end with the same roster as a cold fold of
/// the whole journal.
#[test]
fn a_partial_premigration_and_the_background_replay_converge_on_a_cold_fold() {
    use crate::mux::agent_roster_restore::STARTUP_BUDGET_FOR_TEST;
    let store = stale_roster_store("premigrate-converge");
    let partial = premigrate(&store, &PremigrateControl::new(None, NEVER).pages(1, Some(2)));
    assert!(!partial.complete && partial.cursor > 0, "{partial:?}");
    STARTUP_BUDGET_FOR_TEST.with(|budget| budget.set(Some(Duration::ZERO)));
    let reopened = open_persistent_test_mux(store.session, &store.root);
    STARTUP_BUDGET_FOR_TEST.with(|budget| budget.set(None));
    for _ in 0..100 {
        if !reopened.agent_roster_replaying() {
            break;
        }
        assert!(reopened.settle_agent_roster_for_test());
    }
    assert!(!reopened.agent_roster_replaying(), "the background replay did not finish");
    let deadline = Instant::now() + Duration::from_secs(10);
    while reopened.agent_roster_rebuilding() {
        assert!(Instant::now() < deadline, "the rebuild did not end");
        std::thread::sleep(Duration::from_millis(10));
    }
    // The reopened owner also folds what it journals itself after the
    // start's head, so compare each agent's state, as a view reads them.
    let roster = settled(&reopened).agent_roster.lock().unwrap().roster.snapshot();
    assert_eq!(agent_states(&roster), agent_states(&store.cold));
    assert_eq!(agent_states(&store.cold).len(), 4, "{}", store.cold);
    reopened.shutdown();
    drop(reopened);
}

/// A premigration cut short (here at about 30% of the journal) is not served:
/// the start serves what it would without one, the old build's roster
/// migrated (the full current roster, at the saved cursor), marked stale, with
/// no replay that would refuse `expect_agent` sends. The partial fold only
/// seeds the background rebuild, which folds from its cursor, not from the
/// first record, and ends with the cold fold's roster, the mark cleared.
#[test]
fn a_partial_premigration_seeds_the_rebuild_and_the_start_serves_the_saved_roster() {
    use crate::mux::agent_roster_fold::rebuild_faults;
    let store = stale_roster_store("premigrate-partial-seed");
    // The old build's own roster, saved through the head, as a running owner
    // keeps it: an older reducer version, so the start migrates it.
    let saved = serde_json::json!({
        "version": AGENT_ROSTER_REDUCER_VERSION - 1,
        "cursor": store.head.to_string(),
        "snapshot": store.cold.to_string(),
    });
    write_meta(&store.db_path, &[(roster_key().as_str(), Some(saved.to_string()))]);
    // Resumed one page at a time until it covers about 30% of the journal.
    let mut partial = premigrate(&store, &PremigrateControl::new(None, NEVER).pages(1, Some(1)));
    while partial.cursor * 10 < store.head * 3 {
        partial = premigrate(&store, &PremigrateControl::new(None, NEVER).pages(1, Some(1)));
    }
    assert!(!partial.complete && partial.cursor < store.head, "{partial:?}");

    rebuild_faults::hold(store.session, true);
    let mux = open_persistent_test_mux(store.session, &store.root);
    assert!(roster_side_file(&store.db_path).exists(), "a partial side file is not adopted");
    assert!(mux.agent_roster_rebuilding());
    assert_eq!(
        mux.agent_roster_rebuild_cursor_for_test(),
        Some(partial.cursor),
        "the rebuild starts at the premigrated cursor, not the first record"
    );
    assert!(!mux.agent_roster_replaying(), "no replay holds back expect_agent sends");
    let served = settled(&mux).agent_roster.lock().unwrap().roster.snapshot();
    assert_eq!(agent_states(&served), agent_states(&store.cold), "the full current roster");
    {
        let registry = mux.workspace_registry.lock().unwrap();
        assert!(
            registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap().is_some(),
            "the roster stays marked stale until the rebuild ends"
        );
    }

    rebuild_faults::hold(store.session, false);
    mux.continue_agent_roster_rebuild_later();
    let deadline = Instant::now() + Duration::from_secs(10);
    while mux.agent_roster_rebuilding() {
        assert!(Instant::now() < deadline, "the rebuild did not end");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert!(!mux.agent_roster_replaying());
    let rebuilt = settled(&mux).agent_roster.lock().unwrap().roster.snapshot();
    assert_eq!(agent_states(&rebuilt), agent_states(&store.cold));
    assert_eq!(agent_states(&store.cold).len(), 4, "{}", store.cold);
    {
        let registry = mux.workspace_registry.lock().unwrap();
        assert_eq!(
            registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap(),
            None
        );
    }
    mux.shutdown();
    drop(mux);
    // The next open finds the roster current and drops the used side file.
    drop(WorkspaceRegistry::open(&store.root, store.session).unwrap());
    assert!(!roster_side_file(&store.db_path).exists());
}

fn agent_states(snapshot: &Value) -> std::collections::BTreeMap<String, Value> {
    snapshot["entries"]
        .as_object()
        .expect("roster entries")
        .iter()
        .map(|(terminal, entry)| (terminal.clone(), entry["state"].clone()))
        .collect()
}

/// A legacy kind backfill an older build stopped partway (marker `0`) can
/// leave a sealed segment mapped without its agent kinds. The premigration
/// does not trust such a map: it reads the sealed range with the full
/// decoder, so the side snapshot equals a cold fold and its cursor never
/// passes an agent event the map hides.
#[test]
fn a_partial_kind_map_does_not_hide_an_agent_event_from_the_premigration() {
    let store = stale_roster_store("premigrate-partial-kind-map");
    let db = rusqlite::Connection::open(&store.db_path).unwrap();
    let hidden: i64 = db
        .query_row(
            "SELECT COUNT(*) FROM journal_segment_kinds
             WHERE kind LIKE 'agent.%' OR kind LIKE 'plugin.%'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(hidden > 0, "the sealed segments map agent kinds");
    db.execute_batch(
        "DELETE FROM journal_segment_kinds WHERE kind LIKE 'agent.%' OR kind LIKE 'plugin.%';
         INSERT OR IGNORE INTO journal_segment_kinds(segment_id, kind)
           SELECT segment_id, 'personal.session.put' FROM journal_segments;
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill', '0')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;
         INSERT INTO meta(key, value) VALUES('journal_segment_kinds_backfill_through', '0')
           ON CONFLICT(key) DO UPDATE SET value = excluded.value;",
    )
    .unwrap();
    drop(db);
    let report = premigrate(&store, &PremigrateControl::new(None, NEVER));
    assert!(report.complete, "{report:?}");
    assert_eq!(report.cursor, store.head);
    assert_eq!(side_snapshot(&store), store.cold);
    assert_eq!(agent_states(&side_snapshot(&store)).len(), 4, "{}", store.cold);
}

/// A start of this build that served a migrated roster saved it at the
/// current version with a stale mark. That roster is not a fold: the
/// premigration still folds, and the next open adopts the side snapshot as
/// the rebuild and clears the mark.
#[test]
fn a_roster_marked_stale_is_premigrated_and_the_adoption_clears_the_mark() {
    let store = stale_roster_store("premigrate-stale-mark");
    let migrated = serde_json::json!({
        "version": AGENT_ROSTER_REDUCER_VERSION,
        "cursor": "3",
        "snapshot": "{}",
    });
    write_meta(
        &store.db_path,
        &[
            (roster_key().as_str(), Some(migrated.to_string())),
            (rebuild_key().as_str(), Some(serde_json::json!({"from_version": 8}).to_string())),
        ],
    );
    let report = premigrate(&store, &PremigrateControl::new(None, NEVER));
    assert!(!report.up_to_date && report.complete, "{report:?}");
    let registry = WorkspaceRegistry::open(&store.root, store.session).unwrap();
    assert_eq!(registry.journal_reducer_rebuild_pending(AGENT_ROSTER_REDUCER_ID).unwrap(), None);
    drop(registry);
    let (version, cursor, snapshot) = stored_roster(&store);
    assert_eq!((version, cursor), (AGENT_ROSTER_REDUCER_VERSION, store.head));
    assert_eq!(serde_json::from_str::<Value>(&snapshot).unwrap(), store.cold);
    assert!(!roster_side_file(&store.db_path).exists());
}

/// Journal retention deleted the first records of the journal, and the saved
/// roster is then the one copy of an agent whose records were all there. A
/// build with a newer roster reducer premigrates this registry: its fold of
/// what is left of the journal does not have that agent, and the next open
/// adopts the fold in place of the saved roster. The premigration must go on
/// from the saved roster, as the background rebuild does.
#[test]
fn a_premigration_after_retention_keeps_an_agent_whose_records_are_deleted() {
    const OLD_AGENT: &str = "agent-below-the-floor";
    let session = "premigrate-retained";
    let root = std::env::temp_dir()
        .join(format!("cmux-premigrate-retained-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux(session, &root);
    let old_surface = mux.new_workspace(None, None).unwrap();
    let old_terminal = old_surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &old_terminal, "SessionStart", Some(OLD_AGENT));
    let old_agent_head = mux.session_journal_head().unwrap();

    // A second agent works until retention deletes the first agent's records.
    let live_surface = mux.new_workspace(None, None).unwrap();
    let live_terminal = live_surface.terminal_public_id().cloned().expect("workspace terminal");
    append_journal_hook(&mux, &live_terminal, "SessionStart", Some("agent-live"));
    for cycle in 0..24 {
        for _ in 0..32 {
            append_journal_hook(&mux, &live_terminal, "UserPromptSubmit", Some("agent-live"));
            append_journal_hook(&mux, &live_terminal, "Stop", Some("agent-live"));
        }
        mux.create_journal_checkpoint("client_test", &format!("retained_{cycle}_checkpoint"))
            .unwrap();
        mux.run_journal_maintenance_for_test();
        mux.run_journal_maintenance_for_test();
    }
    let pruned_through = mux.journal_pruned_through().unwrap();
    assert!(
        pruned_through >= old_agent_head,
        "setup: retention deleted through {pruned_through}, the first agent's records end at \
         {old_agent_head}"
    );
    let served = settled(&mux).agent_roster.lock().unwrap().roster.snapshot();
    assert!(served.to_string().contains(OLD_AGENT), "setup: the running daemon has the agent");
    mux.shutdown();
    drop(mux);

    let db_path = registry_file(&root, session);
    let store = Store { root, session, db_path, cold: served, head: 0 };
    let (version, cursor, snapshot) = stored_roster(&store);
    assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION);
    assert!(snapshot.contains(OLD_AGENT), "setup: the saved roster has the agent");
    // The next build's reducer is newer than the one that saved this roster.
    let saved = serde_json::json!({
        "version": AGENT_ROSTER_REDUCER_VERSION - 1,
        "cursor": cursor.to_string(),
        "snapshot": snapshot,
    });
    write_meta(&store.db_path, &[(roster_key().as_str(), Some(saved.to_string()))]);

    let report = premigrate(&store, &PremigrateControl::new(None, NEVER));
    assert!(report.complete, "{report:?}");
    assert!(
        side_snapshot(&store).to_string().contains(OLD_AGENT),
        "the premigrated roster lost the agent whose records retention deleted \
         (deleted through {pruned_through})"
    );
    // The next open adopts the side file in place of the saved roster.
    drop(WorkspaceRegistry::open(&store.root, store.session).unwrap());
    let (version, _, adopted) = stored_roster(&store);
    assert_eq!(version, AGENT_ROSTER_REDUCER_VERSION);
    assert!(adopted.contains(OLD_AGENT), "the adopted roster lost the agent");
}
