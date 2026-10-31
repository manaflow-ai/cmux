//! The registry open stays proportional to live state, not to history.
//!
//! Lawrence 2026-10-29: after a NIGHTLY update the daemon took 10.5 s to its
//! first answer on a 41.6 GB registry, so `sidebar.get` timed out and pins and
//! CLI-made workspaces drew late. Three open-time steps cost seconds there
//! because each one grew with stored history instead of live state. These
//! tests count SQLite VM steps (deterministic, unlike wall time) or the rows
//! an open rewrites.

use serde_json::json;

use super::*;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-open-cost-{label}-{}", new_uuid_v4()))
}

/// SQLite VM steps `run` takes on `connection`, counted in batches of 16.
fn vm_steps(connection: &Connection, run: impl FnOnce()) -> u64 {
    let steps = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let counter = steps.clone();
    connection
        .progress_handler(
            16,
            Some(move || {
                counter.fetch_add(16, std::sync::atomic::Ordering::Relaxed);
                false
            }),
        )
        .unwrap();
    run();
    connection.progress_handler(0, None::<fn() -> bool>).unwrap();
    steps.load(std::sync::atomic::Ordering::Relaxed)
}

fn live_workspaces(registry: &mut WorkspaceRegistry, count: u64) {
    let workspaces = (1..=count)
        .map(|id| RegistryWorkspace {
            id,
            public_id: WorkspacePublicId::parse(format!("ws_{id:032x}")).unwrap(),
            key: format!("workspace-{id}"),
            name: "Workspace".into(),
            name_source: Default::default(),
            name_revision: 0,
            group_key: "default".into(),
        })
        .collect::<Vec<_>>();
    let revision = registry.snapshot().unwrap().revision;
    registry
        .commit(
            &WorkspaceMutation::daemon("create-many", "test").unwrap(),
            &json!({"op":"create-many"}),
            None,
            Some(revision),
            "workspace-added",
            "workspace-1",
            &workspaces,
            &json!({}),
        )
        .unwrap();
}

/// Finished creation receipts, as a long-lived machine piles up (3,723 on
/// the 41.6 GB nightly registry).
fn finished_creation_receipts(registry: &WorkspaceRegistry, count: usize) {
    let db = registry.connection.get();
    for index in 0..count {
        let intent = json!({
            "fields": {"cwd": "/tmp"},
            "operation": "workspace.create",
            "workspace_reservation": {"workspace_key": format!("closed-{index}")},
        });
        db.execute(
            "INSERT INTO resource_creation_receipts(
               correlation_key, operation, fingerprint, idempotency_key, intent_json,
               execution_kind, attempt, state, execution_generation, created_path_json,
               generation, committed_revision
             ) VALUES(?1, 'workspace.create', '{}', ?2, ?3,
                      'effect', 1, 'created', NULL, '{}', 'generation', 1)",
            params![format!("creation-{index}"), format!("effect-{index}"), intent.to_string()],
        )
        .unwrap();
    }
}

fn invariant_steps(registry: &WorkspaceRegistry) -> u64 {
    let db = registry.connection.get();
    vm_steps(&db, || {
        let transaction = db.unchecked_transaction().unwrap();
        validate_resource_invariants(&transaction).unwrap();
        transaction.commit().unwrap();
    })
}

/// The live-identity invariant reads the creation receipts once, not once
/// per live workspace: 876 workspaces x 3,723 receipts took 2 s warm.
#[test]
fn live_identity_invariant_reads_finished_receipts_once() {
    const WORKSPACES: u64 = 100;
    const RECEIPTS: usize = 2_000;
    let mut registry = WorkspaceRegistry::in_memory("open-cost-invariants").unwrap();
    live_workspaces(&mut registry, WORKSPACES);
    let without = invariant_steps(&registry);
    finished_creation_receipts(&registry, RECEIPTS);
    let with = invariant_steps(&registry);
    let per_receipt = (with.saturating_sub(without)) / RECEIPTS as u64;
    assert!(
        per_receipt < 64,
        "the open's invariants take {per_receipt} VM steps per stored receipt \
         ({without} -> {with}); per-workspace rescans make it about {WORKSPACES}x one read"
    );
}

/// The open touches the newest journal content blob only; it does not read
/// and sort every stored blob (a 46 MB scan through overflow pages, 0.67 s
/// cold on the nightly registry).
#[test]
fn integrity_check_touches_one_content_blob() {
    const BLOBS: usize = 2_000;
    let registry = WorkspaceRegistry::in_memory("open-cost-blobs").unwrap();
    let db = registry.connection.get();
    let empty = vm_steps(&db, || check_registry_integrity(&db).unwrap());
    for index in 0..BLOBS {
        let mut digest = [0_u8; 32];
        digest[..8].copy_from_slice(&(index as u64).to_be_bytes());
        db.execute(
            "INSERT INTO journal_content_blobs(
               content_id, sha256, codec, content, uncompressed_bytes, created_at_ms
             ) VALUES(?1, ?2, 'identity', ?3, 64, ?4)",
            params![format!("blob-{index}"), digest.to_vec(), vec![7_u8; 64], index as i64],
        )
        .unwrap();
    }
    let full = vm_steps(&db, || check_registry_integrity(&db).unwrap());
    assert!(
        full.saturating_sub(empty) < 256,
        "the open's integrity check grows with stored blobs: {empty} -> {full} VM steps \
         for {BLOBS} blobs"
    );
}

/// A registry whose receipts were scrubbed opens without rewriting them:
/// SQLite counts a same-value UPDATE as a change, so every launch rewrote
/// all finished receipts and ran a full `wal_checkpoint(TRUNCATE)` (3.7 s on
/// the nightly registry's WAL).
#[test]
fn a_scrubbed_registry_reopens_without_rewriting_receipts() {
    let root = temp_root("scrub-once");
    let registry = WorkspaceRegistry::open(&root, "open-cost").unwrap();
    {
        let db = registry.connection.get();
        let intent = json!({
            "fields": {"cwd": "/tmp", "env": {"CMUX_API_TOKEN": "open-cost-secret"}},
            "operation": "tab.create_terminal",
        });
        db.execute(
            "INSERT INTO resource_effect_receipts(
               idempotency_key, operation, fingerprint, intent_json, state,
               outcome_json, committed_revision
             ) VALUES('effect-done', 'tab.create_terminal', ?1, ?1, 'committed',
                      '{\"kind\":\"success\",\"value\":{}}', 1)",
            params![canonical_json(&intent).unwrap()],
        )
        .unwrap();
        db.execute(
            "INSERT INTO resource_creation_receipts(
               correlation_key, operation, fingerprint, idempotency_key, intent_json,
               execution_kind, attempt, state, execution_generation, created_path_json,
               generation, committed_revision
             ) VALUES('creation-done', 'tab.create_terminal', ?1, 'effect-done', ?1,
                      'effect', 1, 'created', NULL, '{}', 'generation', 1)",
            params![canonical_json(&intent).unwrap()],
        )
        .unwrap();
    }
    drop(registry);
    // The first reopen scrubs the values; the second finds nothing to do.
    drop(WorkspaceRegistry::open(&root, "open-cost").unwrap());
    let reopened = WorkspaceRegistry::open(&root, "open-cost").unwrap();
    let db = reopened.connection.get();
    let transaction = db.unchecked_transaction().unwrap();
    let rewrote =
        receipt_env::scrub_stored_receipts(&transaction, &reopened.resource_effect_pepper).unwrap();
    transaction.commit().unwrap();
    assert!(!rewrote, "a scrubbed registry's open rewrites its receipts again");
    drop(db);
    drop(reopened);
    let _ = fs::remove_dir_all(root);
}

/// Finished effect and creation receipts, as a long-lived machine keeps
/// (16,093 and 3,723 on the 41.6 GB nightly registry), already scrubbed.
fn finished_receipts(registry: &WorkspaceRegistry, count: usize) {
    let db = registry.connection.get();
    let tx = db.unchecked_transaction().unwrap();
    for index in 0..count {
        let intent = json!({"fields": {"cwd": "/tmp", "env": {"TERM": null}},
                            "operation": "tab.create_terminal"});
        tx.execute(
            "INSERT INTO resource_effect_receipts(
               idempotency_key, operation, fingerprint, intent_json, state,
               outcome_json, committed_revision
             ) VALUES(?1, 'tab.create_terminal', '{}', ?2, 'committed',
                      '{\"kind\":\"success\",\"value\":{}}', 1)",
            params![format!("effect-{index}"), intent.to_string()],
        )
        .unwrap();
        tx.execute(
            "INSERT INTO resource_creation_receipts(
               correlation_key, operation, fingerprint, idempotency_key, intent_json,
               execution_kind, attempt, state, execution_generation, created_path_json,
               generation, committed_revision
             ) VALUES(?1, 'tab.create_terminal', '{}', ?2, ?3,
                      'effect', 1, 'created', NULL, '{}', 'generation', 1)",
            params![format!("creation-{index}"), format!("effect-{index}"), intent.to_string()],
        )
        .unwrap();
    }
    tx.commit().unwrap();
}

/// The open's receipt recovery: interrupted effects, the env scrub and the
/// input-receipt backfill, as the open runs them.
fn receipt_recovery_steps(registry: &WorkspaceRegistry) -> u64 {
    let db = registry.connection.get();
    vm_steps(&db, || {
        let tx = db.unchecked_transaction().unwrap();
        recover_resource_effects(&tx).unwrap();
        receipt_env::scrub_stored_receipts(&tx, &registry.resource_effect_pepper).unwrap();
        initialize_resource_input_receipt_retention(&tx).unwrap();
        tx.commit().unwrap();
    })
}

/// Each open re-read every stored receipt three times (interrupted effects,
/// env scrub, input backfill): about 0.45 s per pass cold on the nightly
/// registry. After the first open they read only what changed since.
#[test]
fn receipt_recovery_at_open_does_not_reread_finished_receipts() {
    const RECEIPTS: usize = 2_000;
    let empty = WorkspaceRegistry::in_memory("open-cost-recovery-empty").unwrap();
    let _ = receipt_recovery_steps(&empty);
    let baseline = receipt_recovery_steps(&empty);
    let full = WorkspaceRegistry::in_memory("open-cost-recovery-full").unwrap();
    finished_receipts(&full, RECEIPTS);
    // The first open after the rows appear reads them once.
    let _ = receipt_recovery_steps(&full);
    let again = receipt_recovery_steps(&full);
    assert!(
        again.saturating_sub(baseline) < 512,
        "a later open's receipt recovery rereads finished receipts: {baseline} VM steps with \
         none, {again} with {RECEIPTS}"
    );
}

/// The open checks the tables it serves from in full and touches only the
/// tail of the tables that grow with use: a corrupt old page there must not
/// keep the daemon from answering (the full check of those tables was 1.6 s
/// of the 1.9 s cold check on the nightly registry). The maintenance worker
/// checks them in full after the daemon serves.
#[test]
fn a_corrupt_old_history_page_does_not_stop_the_open() {
    const ROWS: i64 = 3_000;
    let root = temp_root("history-corrupt");
    let registry = WorkspaceRegistry::open(&root, "open-cost").unwrap();
    let database = registry.session_journal_database_path().unwrap();
    {
        let db = registry.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        for revision in 1..=ROWS {
            tx.execute(
                "INSERT INTO terminal_events(
                   revision, kind, terminal_id, workspace_key, origin, mutation_id, result_json
                 ) VALUES(?1, 'exit', 'terminal', 'workspace', 'test', ?2, ?3)",
                params![
                    revision,
                    format!("mutation-{revision}"),
                    format!("{{\"marker\":\"history-row-{revision:06}\"}}")
                ],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    drop(registry);
    let page_size = {
        let connection = Connection::open(&database).unwrap();
        connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(())).unwrap();
        connection.query_row("PRAGMA page_size", [], |row| row.get::<_, i64>(0)).unwrap()
    };
    // Damage the leaf page that holds an early row; the newest rows live on
    // later pages.
    let mut bytes = fs::read(&database).unwrap();
    let marker = b"history-row-000100";
    let offset = bytes.windows(marker.len()).position(|window| window == marker).unwrap();
    let page_size = usize::try_from(page_size).unwrap();
    let page_start = offset - offset % page_size;
    bytes[page_start] = 0xff;
    fs::write(&database, bytes).unwrap();

    let reopened = WorkspaceRegistry::open(&root, "open-cost");
    assert!(
        reopened.is_ok(),
        "a corrupt old terminal event page stops the open: {:#}",
        reopened.err().unwrap()
    );
    let reopened = reopened.unwrap();

    // The maintenance worker's full check finds it, and the next open then
    // checks every table in full and stops, with the data in place.
    let damaged = history_check::scan_background_checked_tables(&database).unwrap();
    let (table, report) = damaged
        .iter()
        .find(|(table, _)| *table == "terminal_events")
        .expect("the background check finds the damaged terminal event page");
    reopened.require_full_open_check(table, report).unwrap();
    drop(reopened);
    let Err(error) = WorkspaceRegistry::open(&root, "open-cost") else {
        panic!("the full check of a damaged registry stops the open");
    };
    assert!(format!("{error:#}").contains("integrity check failed"), "{error:#}");
    assert!(database.exists(), "the registry stays in place");
    let _ = fs::remove_dir_all(root);
}

/// The local feed's start trims its folded set against the notification
/// receipts only: it read every stored receipt's outcome (a scan of all of
/// resource_effect_receipts, 0.40 s cold of the 0.38 s restore step on a
/// 41.6 GB registry, Lawrence 2026-10-30).
#[test]
fn feed_folded_trim_reads_only_notification_receipts() {
    const RECEIPTS: usize = 2_000;
    let registry = WorkspaceRegistry::in_memory("open-cost-feed-trim").unwrap();
    // A folded notification whose receipt is still stored: the trim keeps
    // it, and checking that is what reads the receipts.
    let notification = "notif_0000000000000000000000000000feed";
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO resource_effect_receipts(
               idempotency_key, operation, fingerprint, intent_json, state,
               outcome_json, committed_revision
             ) VALUES('notify-1', 'notification.create', '{}', '{}', 'committed', ?1, 1)",
            [json!({"kind": "success", "value": {"id": notification}}).to_string()],
        )
        .unwrap();
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO feed_local_folded(notification_id, item_id, created_at_ms)
             VALUES(?1, 'fi_00000000000000000000', 1)",
            [notification],
        )
        .unwrap();
    let trim_steps = |registry: &WorkspaceRegistry| {
        let db = registry.connection.get();
        vm_steps(&db, || {
            let tx = db.unchecked_transaction().unwrap();
            feed_local_store::trim_feed_local_folded(&tx).unwrap();
            tx.commit().unwrap();
        })
    };
    let empty = trim_steps(&registry);
    finished_receipts(&registry, RECEIPTS);
    let full = trim_steps(&registry);
    let kept: i64 = registry
        .connection
        .get()
        .query_row("SELECT COUNT(*) FROM feed_local_folded", [], |row| row.get(0))
        .unwrap();
    assert_eq!(kept, 1, "the trim keeps a folded notification whose receipt is stored");
    assert!(
        full.saturating_sub(empty) < 512,
        "the feed trim reads receipts that are not notifications: {empty} -> {full} VM steps \
         with {RECEIPTS} terminal receipts"
    );
}

/// The closed-item history (reopen closed tab, screen, workspace) only grows
/// until its bound and is read only to reopen: the open touches its tail and
/// the maintenance worker checks it in full (2,630 groups, 4.5 MB: 90 ms of
/// the 260 ms cold integrity check on a 41.6 GB registry, Lawrence
/// 2026-10-30). A damaged old page stops the next open after the background
/// check finds it, as for the other history tables.
#[test]
fn a_corrupt_old_closed_history_page_does_not_stop_the_open() {
    const GROUPS: i64 = 3_000;
    let root = temp_root("closed-history-corrupt");
    let registry = WorkspaceRegistry::open(&root, "open-cost").unwrap();
    let database = registry.session_journal_database_path().unwrap();
    {
        let db = registry.connection.get();
        let tx = db.unchecked_transaction().unwrap();
        for index in 1..=GROUPS {
            tx.execute(
                "INSERT INTO closed_groups(closed_id, kind, window_id, closed_at_ms, record_json)
                 VALUES(?1, 'tab', NULL, ?2, ?3)",
                params![
                    format!("closed-{index:06}"),
                    index,
                    format!("{{\"marker\":\"closed-row-{index:06}\"}}")
                ],
            )
            .unwrap();
        }
        tx.commit().unwrap();
    }
    drop(registry);
    let page_size = {
        let connection = Connection::open(&database).unwrap();
        connection.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(())).unwrap();
        connection.query_row("PRAGMA page_size", [], |row| row.get::<_, i64>(0)).unwrap()
    };
    let mut bytes = fs::read(&database).unwrap();
    let marker = b"closed-row-000100";
    let offset = bytes.windows(marker.len()).position(|window| window == marker).unwrap();
    let page_size = usize::try_from(page_size).unwrap();
    let page_start = offset - offset % page_size;
    bytes[page_start] = 0xff;
    fs::write(&database, bytes).unwrap();

    let reopened = WorkspaceRegistry::open(&root, "open-cost");
    assert!(
        reopened.is_ok(),
        "a corrupt old closed history page stops the open: {:#}",
        reopened.err().unwrap()
    );
    let reopened = reopened.unwrap();
    let damaged = history_check::scan_background_checked_tables(&database).unwrap();
    let (table, report) = damaged
        .iter()
        .find(|(table, _)| *table == "closed_groups")
        .expect("the background check finds the damaged closed history page");
    reopened.require_full_open_check(table, report).unwrap();
    drop(reopened);
    let Err(error) = WorkspaceRegistry::open(&root, "open-cost") else {
        panic!("the full check of a damaged registry stops the open");
    };
    assert!(format!("{error:#}").contains("integrity check failed"), "{error:#}");
    let _ = fs::remove_dir_all(root);
}
