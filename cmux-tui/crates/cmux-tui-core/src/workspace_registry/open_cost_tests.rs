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
