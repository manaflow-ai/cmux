//! The retention floor, term by term.
//!
//! Each test builds a registry whose journal is [`SEGMENTS`] sealed segments
//! of a known age, with every reader at the head: the newest 16 checkpoints
//! are on the newest 16 records (a client that asks for checkpoints fast),
//! the agent roster and the agent history fold have their cursor at the
//! head, and no hook is installed. Then it moves one reader back, or makes
//! segments young, and reads the floor through `journal_retention_floor`:
//! the one function the maintenance worker, the cleanup worker and the swap
//! at open call. No test times anything.

use rusqlite::params;
use sha2::{Digest, Sha256};

use super::*;
use crate::history_ops::{AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION};
use crate::journal_reducers::AGENT_ROSTER_REDUCER_VERSION;

const SEGMENTS: u64 = 32;
const SEGMENT_RECORDS: u64 = 256;
const HEAD: u64 = SEGMENTS * SEGMENT_RECORDS;
const MINUTE_MS: u64 = 60 * 1_000;
/// Far older than any window.
const OLD: u64 = 30 * 24 * 60;
/// The end of the newest segment at or below a reader at sequence 3,000.
const FLOOR_AT_3000: u64 = 11 * SEGMENT_RECORDS;

fn digest(label: &str, sequence: u64) -> Vec<u8> {
    Sha256::digest(format!("{label}-{sequence}").as_bytes()).to_vec()
}

/// The registry of the module doc. `sealed_minutes_ago` gives the age of the
/// segment that ends at its argument.
fn registry(sealed_minutes_ago: impl Fn(u64) -> u64) -> WorkspaceRegistry {
    let registry = WorkspaceRegistry::in_memory("journal-retention-floor").unwrap();
    let now = crate::workspace_registry::unix_epoch_ms().unwrap();
    {
        let db = registry.connection.get();
        // No live record: the journal is the sealed segments alone.
        db.execute_batch(
            "DROP TRIGGER session_journal_reject_delete;
             DELETE FROM session_journal;
             CREATE TRIGGER session_journal_reject_delete
               BEFORE DELETE ON session_journal
             BEGIN SELECT RAISE(ABORT, 'session journal is append-only'); END;",
        )
        .unwrap();
        for segment in 0..SEGMENTS {
            let start = segment * SEGMENT_RECORDS + 1;
            let end = start + SEGMENT_RECORDS - 1;
            let sealed_at = now.saturating_sub(sealed_minutes_ago(end) * MINUTE_MS);
            // The floor reads a segment's range and age, never its content.
            db.execute(
                "INSERT INTO journal_segments(
                   segment_id, start_sequence, end_sequence, record_count, codec, content,
                   uncompressed_bytes, sha256, sealed_at_ms
                 ) VALUES(?1, ?2, ?3, ?4, 'gzip-json-v1', x'00', 1, ?5, ?6)",
                params![
                    format!("segment_{start}_{end}"),
                    i64::try_from(start).unwrap(),
                    i64::try_from(end).unwrap(),
                    i64::try_from(SEGMENT_RECORDS).unwrap(),
                    digest("segment", end),
                    i64::try_from(sealed_at).unwrap(),
                ],
            )
            .unwrap();
        }
        for source in (HEAD - 15)..=HEAD {
            db.execute(
                "INSERT INTO journal_checkpoints(
                   checkpoint_id, source_sequence, reducer_version, state_json,
                   content_refs_json, sha256, created_at_ms
                 ) VALUES(?1, ?2, 1, '{}', '[]', ?3, ?4)",
                params![
                    format!("checkpoint_{source}"),
                    i64::try_from(source).unwrap(),
                    digest("checkpoint", source),
                    i64::try_from(now).unwrap(),
                ],
            )
            .unwrap();
        }
    }
    reducer_at(&registry, AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, HEAD);
    reducer_at(&registry, AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION, HEAD);
    registry
}

fn reducer_at(registry: &WorkspaceRegistry, reducer: &str, version: u32, cursor: u64) {
    registry.connection.finish_journal_reducer_rebuild(reducer, version, cursor, "{}").unwrap();
}

fn hook(registry: &WorkspaceRegistry, version: u32, enabled: bool, cursor: u64) {
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO journal_hooks(
               hook_id, manifest_version, manifest_json, enabled, cursor_sequence,
               installed_at_ms
             ) VALUES('floor_hook', ?1, '{}', ?2, ?3, 1)",
            params![i64::from(version), i64::from(enabled), i64::try_from(cursor).unwrap()],
        )
        .unwrap();
}

fn delivery(registry: &WorkspaceRegistry, version: u32, event_sequence: u64, state: &str) {
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO journal_hook_deliveries(
               hook_id, manifest_version, event_id, event_sequence, attempt, state,
               next_attempt_at_ms, scheduled_at_ms
             ) VALUES('floor_hook', ?1, ?2, ?3, 0, ?4, 1, 1)",
            params![
                i64::from(version),
                format!("event_{event_sequence}"),
                i64::try_from(event_sequence).unwrap(),
                state,
            ],
        )
        .unwrap();
}

fn receipt(registry: &WorkspaceRegistry, sequence: u64) {
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO journal_ingress_receipts(
               producer_id, origin, idempotency_key, fingerprint, event_id, journal_sequence,
               result_json
             ) VALUES(?1, 'floor-test', ?2, ?3, ?4, ?5, '{}')",
            params![
                crate::AGENT_HOOK_PRODUCER_ID,
                format!("key_{sequence}"),
                digest("receipt", sequence),
                format!("event_{sequence}"),
                i64::try_from(sequence).unwrap(),
            ],
        )
        .unwrap();
}

fn receipts(registry: &WorkspaceRegistry) -> Vec<u64> {
    let db = registry.connection.get();
    let mut statement = db
        .prepare("SELECT journal_sequence FROM journal_ingress_receipts ORDER BY journal_sequence")
        .unwrap();
    statement
        .query_map([], |row| row.get::<_, i64>(0))
        .unwrap()
        .map(|sequence| u64::try_from(sequence.unwrap()).unwrap())
        .collect()
}

fn floor(registry: &WorkspaceRegistry) -> u64 {
    journal_retention_floor(&registry.connection.get()).unwrap()
}

/// The retention pass of the maintenance worker, to its end.
fn prune(registry: &mut WorkspaceRegistry) {
    let floor = registry.journal_retention_floor().unwrap();
    while registry.prune_oldest_journal_segment(floor).unwrap() {}
}

impl WorkspaceRegistry {
    /// Test seam: makes every sealed segment older than the age window, as
    /// if the daemon had sealed it more than an hour ago. A test that seals
    /// and wants retention to delete in the same run calls it before the
    /// retention pass (`Mux::run_journal_maintenance_for_test` does).
    pub(crate) fn age_journal_segments_for_test(&self) {
        let age_ms = MIN_RETAINED_AGE_MS + 60_000;
        let now = crate::workspace_registry::unix_epoch_ms().unwrap();
        let young_after = now.saturating_sub(MIN_RETAINED_AGE_MS);
        self.connection
            .get()
            .execute_batch(&format!(
                "DROP TRIGGER journal_segments_reject_update;
                 UPDATE journal_segments SET sealed_at_ms = MAX(sealed_at_ms - {age_ms}, 0)
                 WHERE sealed_at_ms > {young_after};
                 CREATE TRIGGER journal_segments_reject_update
                   BEFORE UPDATE ON journal_segments
                 BEGIN
                   SELECT RAISE(ABORT, 'journal segments are immutable');
                 END;"
            ))
            .unwrap();
    }
}

/// S1, the record window. A client that asks for a checkpoint after each
/// record has the newest 16 checkpoints on the newest 16 records. The oldest
/// kept checkpoint is then no bound at all: the floor would be the end of
/// the last sealed segment but one.
#[test]
fn sixteen_fast_checkpoints_do_not_move_the_floor_near_the_head() {
    let registry = registry(|_| OLD);
    let floor = floor(&registry);
    assert!(
        HEAD - floor >= 1_024,
        "16 checkpoints on the newest 16 records moved the floor to {floor} of head {HEAD}: \
         {} records stay",
        HEAD - floor
    );
    // The window is no reason to keep more than it asks for.
    assert_eq!(floor, HEAD - 1_024);
}

/// S1, the age window. A segment that the daemon sealed less than 60 minutes
/// ago stays, with every row of its records, however many checkpoints follow.
#[test]
fn a_segment_sealed_in_the_last_hour_stays() {
    let young_after = HEAD / 2;
    let young = registry(|end| if end > young_after { 59 } else { OLD });
    assert_eq!(
        floor(&young),
        young_after,
        "segments sealed 59 minutes ago are below the floor (head {HEAD})"
    );
    let aged = registry(|end| if end > young_after { 61 } else { OLD });
    assert_eq!(floor(&aged), HEAD - 1_024, "segments sealed 61 minutes ago still hold the floor");
}

/// S2, receipts. The receipt of an ingress event is what makes a retry with
/// the same key a replay, not a second record. The table has no time column:
/// a receipt lives as long as its record's segment, so a retry in the hour
/// after the append finds it.
#[test]
fn an_ingress_receipt_stays_for_the_hour_after_its_record() {
    let young_after = HEAD / 2;
    let mut registry = registry(|end| if end > young_after { 30 } else { OLD });
    receipt(&registry, 100);
    receipt(&registry, young_after + 100);
    prune(&mut registry);
    assert_eq!(
        receipts(&registry),
        vec![young_after + 100],
        "retention keeps the receipt of a record sealed 30 minutes ago and deletes the old one"
    );
}

/// The History cursor (the saved agent history fold) far behind the head,
/// the roster at the head, no hook: the shape of a daemon where nobody opened
/// History for a long time. The fold is the one copy of each agent session
/// whose records are deleted, so no record after its cursor may go.
#[test]
fn the_floor_stops_at_the_history_cursor() {
    let registry = registry(|_| OLD);
    reducer_at(&registry, AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION, 3_000);
    assert_eq!(floor(&registry), FLOOR_AT_3000);
}

#[test]
fn the_floor_stops_at_the_saved_roster_cursor() {
    let registry = registry(|_| OLD);
    reducer_at(&registry, AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION, 3_000);
    assert_eq!(floor(&registry), FLOOR_AT_3000);
}

/// A reducer state of another version folds from the first record again.
#[test]
fn a_reducer_state_of_another_version_holds_the_floor_at_zero() {
    for (reducer, version) in [
        (AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION),
        (AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION),
    ] {
        let registry = registry(|_| OLD);
        reducer_at(&registry, reducer, version + 1, HEAD);
        assert_eq!(floor(&registry), 0, "{reducer}");
    }
}

#[test]
fn the_floor_stops_at_an_enabled_hook_cursor() {
    let plain = floor(&registry(|_| OLD));
    let registry = registry(|_| OLD);
    // A replaced version is never dispatched again: its cursor holds nothing.
    hook(&registry, 1, false, 500);
    assert_eq!(floor(&registry), plain);
    hook(&registry, 2, true, 3_000);
    assert_eq!(floor(&registry), FLOOR_AT_3000);
}

/// A delivery that waits or runs reads its event again: the floor stays
/// below that event. A final delivery holds nothing.
#[test]
fn the_floor_stops_below_a_delivery_that_is_not_final() {
    for state in ["scheduled", "executing"] {
        let registry = registry(|_| OLD);
        hook(&registry, 1, true, HEAD);
        // The first record of a segment: the segment before it may go.
        delivery(&registry, 1, FLOOR_AT_3000 + 1, state);
        assert_eq!(floor(&registry), FLOOR_AT_3000, "{state}");
        // The last record of that segment: the segment itself stays.
        delivery(&registry, 1, FLOOR_AT_3000, state);
        assert_eq!(floor(&registry), FLOOR_AT_3000 - SEGMENT_RECORDS, "{state}");
    }
    let plain = floor(&registry(|_| OLD));
    for state in ["completed", "failed", "abandoned"] {
        let registry = registry(|_| OLD);
        hook(&registry, 1, true, HEAD);
        delivery(&registry, 1, 100, state);
        assert_eq!(floor(&registry), plain, "{state}");
    }
}

/// No checkpoint: nothing proves that a restore can do without the records.
#[test]
fn no_checkpoint_holds_the_floor_at_zero() {
    let registry = registry(|_| OLD);
    registry
        .connection
        .get()
        .execute_batch(
            "DROP TRIGGER journal_checkpoints_keep_recent;
             DELETE FROM journal_checkpoints;",
        )
        .unwrap();
    assert_eq!(floor(&registry), 0);
}

/// The floor never goes down: what retention deleted stays deleted when a
/// reader's cursor is later found behind it.
#[test]
fn the_floor_never_goes_below_what_retention_deleted() {
    let mut registry = registry(|_| OLD);
    prune(&mut registry);
    let deleted = registry.journal_pruned_through().unwrap();
    assert!(deleted > 0, "setup: retention deleted nothing");
    reducer_at(&registry, AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION, 3_000);
    assert_eq!(floor(&registry), deleted);
}

/// The swap at open records the floor of its cut. A sealed segment at or
/// below that floor can stay in the table. The delete of that segment must
/// not move the floor in `meta` down: a cursor between the two values would
/// read a hole and get no `cursor.gap`.
#[test]
fn a_higher_floor_in_meta_survives_retention() {
    let mut registry = registry(|_| OLD);
    let higher = 20 * SEGMENT_RECORDS;
    registry
        .connection
        .get()
        .execute(
            "INSERT INTO meta(key, value) VALUES(?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            params![PRUNED_THROUGH_META_KEY, higher.to_string()],
        )
        .unwrap();
    assert!(
        registry.prune_oldest_journal_segment(higher).unwrap(),
        "setup: a segment at or below the floor stayed"
    );
    assert_eq!(registry.journal_pruned_through().unwrap(), higher);
}

/// The two reducers whose saved state holds what the journal no longer has
/// below the floor, each with this build's version.
const BASED: [(&str, u32); 2] = [
    (AGENT_ROSTER_REDUCER_ID, AGENT_ROSTER_REDUCER_VERSION),
    (AGENT_FOLD_STATE_ID, AGENT_FOLD_STATE_VERSION),
];

fn meta(registry: &WorkspaceRegistry, key: &str) -> Option<String> {
    registry
        .connection
        .get()
        .query_row("SELECT value FROM meta WHERE key = ?1", [key], |row| row.get::<_, String>(0))
        .optional()
        .unwrap()
}

/// The raw saved state of `reducer`.
fn saved(registry: &WorkspaceRegistry, reducer: &str) -> Option<String> {
    meta(registry, &format!("journal_reducer.{reducer}"))
}

/// The raw base of `reducer` (`base.rs`).
fn base(registry: &WorkspaceRegistry, reducer: &str) -> Option<String> {
    meta(registry, &format!("journal_reducer_base.{reducer}"))
}

/// A saved state of `reducer` that holds `label`, with no rebuild owed.
fn reducer_with(
    registry: &WorkspaceRegistry,
    reducer: &str,
    version: u32,
    cursor: u64,
    label: &str,
) {
    let snapshot = serde_json::json!({ "label": label }).to_string();
    registry
        .connection
        .finish_journal_reducer_rebuild(reducer, version, cursor, &snapshot)
        .unwrap();
}

/// A registry in which each reducer saved `label` at sequence 3,000 and
/// retention then deleted through [`FLOOR_AT_3000`].
fn pruned_at_3000(label: &str) -> WorkspaceRegistry {
    let mut registry = registry(|_| OLD);
    for (reducer, version) in BASED {
        reducer_with(&registry, reducer, version, 3_000, label);
    }
    prune(&mut registry);
    assert_eq!(registry.journal_pruned_through().unwrap(), FLOOR_AT_3000, "the setup");
    registry
}

/// The delete of a segment takes records from the journal for good: each
/// reducer's saved state is then the only copy of what it folded from them,
/// under a key that every build writes. The transaction that deletes first
/// copies each state to its base.
#[test]
fn the_delete_of_a_segment_first_copies_each_reducer_state_to_its_base() {
    let registry = pruned_at_3000("folded through 3,000");
    for (reducer, _) in BASED {
        let state = saved(&registry, reducer);
        assert!(state.as_deref().is_some_and(|state| state.contains("folded through 3,000")));
        assert_eq!(
            base(&registry, reducer),
            state,
            "retention deleted through {FLOOR_AT_3000} and the base of {reducer} is not the \
             state that was saved then"
        );
    }
}

/// A base stays while its cursor is at or above the floor: one copy for each
/// time the floor passes the last one, not one for each segment.
#[test]
fn a_base_is_written_again_only_when_the_floor_passes_its_cursor() {
    let mut registry = pruned_at_3000("first");
    let first = BASED.map(|(reducer, _)| base(&registry, reducer));
    assert!(first.iter().all(Option::is_some), "the first floor move wrote no base: {first:?}");

    // The readers go on to the head. The next delete passes the cursor of
    // the first base (3,000): the base is the state saved now.
    for (reducer, version) in BASED {
        reducer_with(&registry, reducer, version, HEAD, "second");
    }
    let floor = floor(&registry);
    assert!(floor > FLOOR_AT_3000 + SEGMENT_RECORDS, "the setup: the floor is {floor}");
    assert!(registry.prune_oldest_journal_segment(floor).unwrap(), "the setup: a delete");
    let second = BASED.map(|(reducer, _)| base(&registry, reducer));
    for ((reducer, _), copied) in BASED.iter().zip(&second) {
        assert_eq!(
            copied,
            &saved(&registry, reducer),
            "{reducer}: the base after the floor passed 3,000"
        );
    }

    // A later save at the same cursor, and the deletes up to the floor: the
    // floor does not pass the cursor of the second base, so it stays.
    for (reducer, version) in BASED {
        reducer_with(&registry, reducer, version, HEAD, "third");
    }
    while registry.prune_oldest_journal_segment(floor).unwrap() {}
    assert_eq!(registry.journal_pruned_through().unwrap(), floor);
    assert_eq!(BASED.map(|(reducer, _)| base(&registry, reducer)), second);
}

/// A floor of the swap at open in these tests, above the floor of
/// [`pruned_at_3000`].
const HIGHER: u64 = 20 * SEGMENT_RECORDS;

/// A state that is not this build's own fold never becomes the base, and no
/// record is deleted without a base at or above the end of its segment. The
/// floor of the maintenance worker is 0 for such a state; a caller with a
/// floor of its own (the swap at open) gets the same answer here.
#[test]
fn a_state_that_is_not_this_builds_fold_is_not_copied_and_stops_the_delete() {
    type Write = fn(&WorkspaceRegistry, &str, u32);
    let cases: [(&str, Write); 4] = [
        // The kill: an older build's empty roster, migrated by a start of
        // this build that did not end its rebuild.
        ("a rebuild is owed", |registry: &WorkspaceRegistry, reducer: &str, version: u32| {
            let empty = serde_json::json!({ "label": "empty" }).to_string();
            registry
                .start_journal_reducer_rebuild(reducer, version - 1, version, HEAD, &empty)
                .unwrap();
        }),
        ("another version", |registry: &WorkspaceRegistry, reducer: &str, version: u32| {
            reducer_with(registry, reducer, version + 1, HEAD, "empty");
        }),
        ("no saved state", |registry: &WorkspaceRegistry, reducer: &str, _: u32| {
            registry
                .connection
                .get()
                .execute("DELETE FROM meta WHERE key = ?1", [format!("journal_reducer.{reducer}")])
                .unwrap();
        }),
        // The oldest segment left ends at `FLOOR_AT_3000 + SEGMENT_RECORDS`.
        (
            "a cursor below the end of the segment",
            |registry: &WorkspaceRegistry, reducer: &str, version: u32| {
                let cursor = FLOOR_AT_3000 + SEGMENT_RECORDS - 1;
                reducer_with(registry, reducer, version, cursor, "empty");
            },
        ),
    ];
    // The control: with each state this build's own fold at the head, the
    // same call deletes.
    let mut control = pruned_at_3000("with the agent");
    for (reducer, version) in BASED {
        reducer_with(&control, reducer, version, HEAD, "at the head");
    }
    assert!(control.prune_oldest_journal_segment(HIGHER).unwrap(), "the setup: no delete");

    for (reducer, version) in BASED {
        for (name, write) in cases {
            let mut registry = pruned_at_3000("with the agent");
            let before = base(&registry, reducer);
            assert!(
                before.as_deref().is_some_and(|base| base.contains("with the agent")),
                "{reducer}, {name}: the first floor move wrote no base"
            );
            // The other reducer does not stop the delete.
            for (other, version) in BASED {
                reducer_with(&registry, other, version, HEAD, "at the head");
            }
            write(&registry, reducer, version);
            assert!(
                !registry.prune_oldest_journal_segment(HIGHER).unwrap(),
                "{reducer}, {name}: a segment was deleted with no base at or above its end"
            );
            assert_eq!(
                registry.journal_pruned_through().unwrap(),
                FLOOR_AT_3000,
                "{reducer}, {name}"
            );
            assert_eq!(base(&registry, reducer), before, "{reducer}, {name}: the base changed");
        }
    }
}
