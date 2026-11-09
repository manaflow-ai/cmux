//! Journal checkpoints are kept bounded.
//!
//! Leo 2026-11-09: "wonder if there's other random stuff like that we do. we
//! should fix those too." Every 4096 journal records the maintenance worker
//! wrote a checkpoint holding the whole reduced state (about 1.5 MB on Leo's
//! registry, 519 a day), and a trigger refused every delete, so the table
//! only grew: 1.78 GB. Pruning now keeps the newest
//! `JOURNAL_CHECKPOINTS_KEPT` checkpoints and every one no sealed segment
//! covers yet.

use super::*;
use crate::workspace_registry::{JOURNAL_CHECKPOINTS_KEPT, new_uuid_v4};
use std::path::PathBuf;

const ROUNDS: usize = 40;

fn temp_root(label: &str) -> PathBuf {
    std::env::temp_dir().join(format!("cmux-checkpoint-retention-{label}-{}", new_uuid_v4()))
}

/// The checkpoint table's rows and the bytes its rows hold.
fn checkpoint_rows(mux: &Mux) -> (usize, usize) {
    let registry = mux.workspace_registry.lock().unwrap();
    let (rows, bytes) = registry
        .connection
        .get()
        .query_row(
            "SELECT COUNT(*), COALESCE(SUM(length(state_json) + length(content_refs_json)), 0)
             FROM journal_checkpoints",
            [],
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )
        .unwrap();
    (usize::try_from(rows).unwrap(), usize::try_from(bytes).unwrap())
}

/// A test mux whose maintenance worker is stopped, so only the test seals
/// and prunes.
fn open_mux(session: &str, root: &Path) -> Arc<Mux> {
    let mux = open_persistent_test_mux(session, root);
    mux.stop_journal_maintenance();
    mux
}

fn prune(mux: &Mux) -> anyhow::Result<usize> {
    mux.workspace_registry.lock().unwrap().prune_journal_checkpoints()
}

/// One maintenance round: new journal records, a checkpoint at the head, and
/// a seal through it.
fn checkpoint_and_seal(mux: &Mux, round: usize) -> u64 {
    mux.create_empty_workspace(Some(format!("round-{round}")), None, None).unwrap();
    let checkpoint =
        mux.create_journal_checkpoint("client_test", &format!("checkpoint_{round}")).unwrap();
    let through = checkpoint.checkpoint.source_sequence;
    mux.seal_journal_segments(through, "client_test", &format!("segment_{round}")).unwrap();
    through
}

#[test]
fn pruning_keeps_the_newest_checkpoints_and_bounds_the_table() {
    let unpruned_root = temp_root("unpruned");
    let unpruned = open_mux("checkpoint-unpruned", &unpruned_root);
    let pruned_root = temp_root("pruned");
    let pruned = open_mux("checkpoint-pruned", &pruned_root);
    let mut latest = 0;
    for round in 0..ROUNDS {
        checkpoint_and_seal(&unpruned, round);
        latest = checkpoint_and_seal(&pruned, round);
        prune(&pruned).unwrap();
    }

    let (before_rows, before_bytes) = checkpoint_rows(&unpruned);
    let (after_rows, after_bytes) = checkpoint_rows(&pruned);
    eprintln!(
        "checkpoint retention, {ROUNDS} checkpoints: before {before_rows} rows {before_bytes} B, \
         after {after_rows} rows {after_bytes} B"
    );
    assert_eq!(before_rows, ROUNDS, "without pruning every checkpoint stays");
    assert_eq!(after_rows, JOURNAL_CHECKPOINTS_KEPT);
    assert!(after_bytes < before_bytes / 2, "{after_bytes} B of {before_bytes} B stayed");

    // Restore still reads the newest one, and the next seal still finds a
    // checkpoint at or below its target.
    let newest = pruned.workspace_registry.lock().unwrap().journal_checkpoint("latest").unwrap();
    assert_eq!(newest.map(|checkpoint| checkpoint.source_sequence), Some(latest));
    let next = checkpoint_and_seal(&pruned, ROUNDS);
    assert!(next > latest);

    for (mux, root) in [(unpruned, unpruned_root), (pruned, pruned_root)] {
        mux.shutdown();
        drop(mux);
        std::fs::remove_dir_all(root).unwrap();
    }
}

#[test]
fn pruning_keeps_every_checkpoint_the_next_seal_needs() {
    let root = temp_root("unsealed");
    let mux = open_mux("checkpoint-unsealed", &root);
    checkpoint_and_seal(&mux, 0);
    // More checkpoints than are kept, none of them sealed yet.
    let unsealed = JOURNAL_CHECKPOINTS_KEPT + 4;
    for round in 1..=unsealed {
        mux.create_empty_workspace(Some(format!("unsealed-{round}")), None, None).unwrap();
        mux.create_journal_checkpoint("client_test", &format!("checkpoint_{round}")).unwrap();
    }

    assert_eq!(prune(&mux).unwrap(), 1, "only the sealed checkpoint goes");
    assert_eq!(checkpoint_rows(&mux).0, unsealed);
    let refused = mux.workspace_registry.lock().unwrap().connection.get().execute(
        "DELETE FROM journal_checkpoints
         WHERE source_sequence = (SELECT MIN(source_sequence) FROM journal_checkpoints)",
        [],
    );
    assert!(refused.is_err(), "the trigger refuses an unsealed checkpoint");

    let through = mux.workspace_registry.lock().unwrap().session_journal_head().unwrap();
    mux.seal_journal_segments(through, "client_test", "segment_unsealed").unwrap();
    assert_eq!(prune(&mux).unwrap(), unsealed - JOURNAL_CHECKPOINTS_KEPT);
    assert_eq!(checkpoint_rows(&mux).0, JOURNAL_CHECKPOINTS_KEPT);
    let refused = mux.workspace_registry.lock().unwrap().connection.get().execute(
        "DELETE FROM journal_checkpoints
         WHERE source_sequence = (SELECT MIN(source_sequence) FROM journal_checkpoints)",
        [],
    );
    assert!(refused.is_err(), "the trigger refuses one of the newest checkpoints");

    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn opening_the_registry_replaces_an_older_binarys_delete_trigger() {
    let root = temp_root("old-trigger");
    let mux = open_mux("checkpoint-old-trigger", &root);
    for round in 0..=JOURNAL_CHECKPOINTS_KEPT {
        checkpoint_and_seal(&mux, round);
    }
    // An older binary put back the trigger that refuses every delete.
    mux.workspace_registry
        .lock()
        .unwrap()
        .connection
        .get()
        .execute_batch(
            "CREATE TRIGGER journal_checkpoints_reject_delete
               BEFORE DELETE ON journal_checkpoints
             BEGIN
               SELECT RAISE(ABORT, 'journal checkpoints are immutable');
             END;",
        )
        .unwrap();
    assert!(prune(&mux).is_err(), "the old trigger defers pruning");
    mux.shutdown();
    drop(mux);

    let mux = open_mux("checkpoint-old-trigger", &root);
    // The shutdown may have added a checkpoint of its own.
    assert!(prune(&mux).unwrap() >= 1);
    assert_eq!(checkpoint_rows(&mux).0, JOURNAL_CHECKPOINTS_KEPT);
    mux.shutdown();
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
