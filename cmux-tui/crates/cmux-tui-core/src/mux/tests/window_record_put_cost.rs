//! A `window_record.put` stores its record once, and an equal put stores
//! nothing (REGISTRY WAL, small writers).
//!
//! The app puts a window's whole record on every change: `{id, open,
//! workspace_key, workspace_keys}`, 33 KB for a window of 824 workspaces. On
//! one Mac (826 workspaces, 47 min, 2026-11-12) 168 puts journaled
//! 10,974,834 payload bytes (65 KB each), and 102 of 120 consecutive puts
//! changed `workspace_key` alone (a workspace switch, median gap 0.44 s).
//! The journal payload held the record twice (`result` and
//! `changes[0].value`), and the `resource_mutations` ledger row held it
//! twice more (`fingerprint` and `result_json`).
//!
//! The test runs a real `Mux` on an on-disk registry and measures, at the
//! registry: the journal row bytes and the ledger row bytes of each put, and
//! what an equal put commits. Bytes and counts, not times.

use serde_json::{Value, json};

use super::*;
use crate::diagnostics::journal_bytes_by_kind;
use crate::state::store::StateCommit;
use crate::state::window_records::WindowRecordChange;

/// Workspaces the window lists (the measured window listed 824).
const WORKSPACES: usize = 800;
/// Puts that change the selected workspace only.
const SWITCHES: usize = 20;
/// The most journal bytes one put may cost besides one copy of its record:
/// the record's envelope, the change's envelope, the journal row's columns.
const JOURNAL_OVERHEAD_BUDGET: u64 = 2 * 1024;
/// The most ledger bytes (`fingerprint` and `result_json`) one put may cost.
const LEDGER_BUDGET: u64 = 1024;
const OPERATION: &str = "window_record.put";
const INSTALL: &str = "install_a";
const WINDOW: &str = "win_1";

/// What the registry holds and wrote so far.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Written {
    journal_head: u64,
    revision: u64,
    wal_commits: u64,
    wal_frame_bytes: u64,
}

fn written(mux: &Mux) -> Written {
    let stats = mux.write_path_stats();
    Written {
        journal_head: mux.session_journal_head().unwrap(),
        revision: mux.with_state(|state| state.resource_revision),
        wal_commits: stats.wal_commits,
        wal_frame_bytes: stats.registry_wal_frame_bytes,
    }
}

/// The rows and bytes of the live `window_record.put` journal records.
fn journal_put_bytes(mux: &Mux) -> (u64, u64) {
    mux.read_registry_state(|connection| {
        Ok(journal_bytes_by_kind(connection)?.get(OPERATION).copied().unwrap_or_default())
    })
    .unwrap()
}

/// The rows and bytes (`fingerprint` and `result_json`) of the ledger rows
/// of the puts committed after `revision`.
fn ledger_put_bytes(mux: &Mux, revision: u64) -> (u64, u64) {
    mux.read_registry_state(|connection| {
        Ok(connection.query_row(
            "SELECT COUNT(*), COALESCE(SUM(length(CAST(fingerprint AS BLOB))
                      + length(CAST(result_json AS BLOB))), 0)
             FROM resource_mutations
             WHERE operation = ?1 AND committed_revision > ?2",
            (OPERATION, i64::try_from(revision)?),
            |row| Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?)),
        )?)
    })
    .map(|(rows, bytes)| (u64::try_from(rows).unwrap(), u64::try_from(bytes).unwrap()))
    .unwrap()
}

fn put(mux: &Mux, key: &str, expected: Option<u64>, record: &Value) -> StateCommit {
    mux.state_window_record(
        &WorkspaceMutation::by_local_user(key, "window-record-cost-test").unwrap(),
        OPERATION,
        INSTALL,
        WINDOW,
        expected,
        WindowRecordChange::Put { record: record.clone() },
    )
    .unwrap_or_else(|error| panic!("put {key} failed: {error:?}"))
}

/// Every `window_record` value the event feed states after `revision`, in
/// order: what a client that follows `session.events` applies.
fn published_records(mux: &Mux, revision: u64) -> Vec<Value> {
    let mut values = Vec::new();
    let mut cursor = revision;
    loop {
        let page = mux.resource_events_after(cursor).unwrap();
        let Some(last) = page.batches.last() else { break };
        cursor = last.revision;
        for batch in &page.batches {
            for change in batch.changes.as_array().into_iter().flatten() {
                if change["resource"] == "window_record" && change["kind"] == "state_upsert" {
                    values.push(change["value"].clone());
                }
            }
        }
    }
    values
}

#[cfg(unix)]
#[test]
fn a_window_record_put_stores_its_record_once_and_an_equal_put_nothing() {
    let root = std::env::temp_dir()
        .join(format!("cmux-window-record-cost-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("window-record-cost", &root);
    // The worker would checkpoint and seal on its own ticks, which commit.
    mux.stop_journal_maintenance();
    let keys =
        (0..WORKSPACES).map(|_| crate::workspace_registry::new_uuid_v4()).collect::<Vec<_>>();
    let record = |selected: usize| {
        json!({
            "id": WINDOW,
            "open": true,
            "workspace_key": keys[selected],
            "workspace_keys": keys,
        })
    };
    let record_bytes = u64::try_from(serde_json::to_string(&record(0)).unwrap().len()).unwrap();

    let start = written(&mux);
    let mut replies = vec![put(&mux, "put-0", Some(0), &record(0))];
    let first = written(&mux);
    let (journal_rows_before, journal_bytes_before) = journal_put_bytes(&mux);
    for switch in 1..=SWITCHES {
        let expected = u64::try_from(switch).unwrap();
        replies.push(put(&mux, &format!("put-{switch}"), Some(expected), &record(switch)));
    }
    let after_switches = written(&mux);
    let (journal_rows_after, journal_bytes_after) = journal_put_bytes(&mux);
    let (ledger_rows, ledger_bytes) = ledger_put_bytes(&mux, first.revision);
    let switches = u64::try_from(SWITCHES).unwrap();
    let journal_per_put = (journal_bytes_after - journal_bytes_before) / switches;
    let ledger_per_put = ledger_bytes / switches;

    // A retry under the key of a committed put answers what the put answered.
    let last = replies.last().unwrap().clone();
    let retry = put(&mux, &format!("put-{SWITCHES}"), Some(switches), &record(SWITCHES));
    let after_retry = written(&mux);

    // A put of the stored record, under a new key, with and without the
    // revision precondition.
    let equal_checked = put(&mux, "put-equal-checked", Some(switches + 1), &record(SWITCHES));
    let equal_unchecked = put(&mux, "put-equal-unchecked", None, &record(SWITCHES));
    let after_equal = written(&mux);

    // Positive control: one more switch is one commit and one journal row.
    let changed = put(&mux, "put-changed", None, &record(0));
    let after_changed = written(&mux);

    let published = published_records(&mux, start.revision);
    let stored =
        mux.read_registry_state(crate::state::window_record_store::record_snapshots).unwrap();

    println!(
        "window_record_put_cost: workspaces={WORKSPACES} record_bytes={record_bytes} \
         switches={SWITCHES} journal_bytes_per_put={journal_per_put} \
         ledger_bytes_per_put={ledger_per_put} equal_puts=2 equal_put_revisions={} \
         equal_put_journal_rows={} equal_put_wal_commits={} equal_put_wal_frame_bytes={}",
        after_equal.revision - after_retry.revision,
        after_equal.journal_head - after_retry.journal_head,
        after_equal.wal_commits - after_retry.wal_commits,
        after_equal.wal_frame_bytes - after_retry.wal_frame_bytes,
    );
    let mut failures = Vec::new();
    if journal_rows_after - journal_rows_before != switches
        || ledger_rows != switches
        || after_switches.revision - first.revision != switches
    {
        failures.push(format!(
            "{SWITCHES} switches must be {SWITCHES} commits: {} journal rows, {ledger_rows} \
             ledger rows, {} revisions",
            journal_rows_after - journal_rows_before,
            after_switches.revision - first.revision,
        ));
    }
    if journal_per_put > record_bytes + JOURNAL_OVERHEAD_BUDGET {
        failures.push(format!(
            "a put that changes workspace_key journals {journal_per_put} bytes for a record of \
             {record_bytes} bytes (budget: one record and {JOURNAL_OVERHEAD_BUDGET} bytes): the \
             journal row holds the record more than once"
        ));
    }
    if ledger_per_put > LEDGER_BUDGET {
        failures.push(format!(
            "a put that changes workspace_key writes {ledger_per_put} bytes of fingerprint and \
             result to the mutation ledger for a record of {record_bytes} bytes (budget \
             {LEDGER_BUDGET}): the ledger row holds the record"
        ));
    }
    if !retry.replayed
        || retry.result != last.result
        || retry.revision != last.revision
        || after_retry != after_switches
    {
        failures.push(format!(
            "a retry must replay the first answer and write nothing: replayed {}, revision {} \
             (first {}), same result {}, before {after_switches:?}, after {after_retry:?}",
            retry.replayed,
            retry.revision,
            last.revision,
            retry.result == last.result,
        ));
    }
    if after_equal != after_retry {
        failures.push(format!(
            "2 puts equal to the stored record wrote to the registry: {} revisions, {} journal \
             rows, {} WAL commits, {} WAL frame bytes",
            after_equal.revision - after_retry.revision,
            after_equal.journal_head - after_retry.journal_head,
            after_equal.wal_commits - after_retry.wal_commits,
            after_equal.wal_frame_bytes - after_retry.wal_frame_bytes,
        ));
    }
    for (name, equal) in [("checked", &equal_checked), ("unchecked", &equal_unchecked)] {
        if equal.result != last.result || equal.replayed {
            failures.push(format!(
                "the {name} equal put must answer the stored record at its revision {}: \
                 revision {}, replayed {}",
                last.result["revision"], equal.result["revision"], equal.replayed,
            ));
        }
    }
    if after_changed.revision - after_equal.revision != 1
        || after_changed.journal_head - after_equal.journal_head != 1
        || after_changed.wal_commits == after_equal.wal_commits
        || changed.result["record"] != record(0)
    {
        failures.push(format!(
            "a changed put must commit exactly once: result revision {}, before {after_equal:?}, \
             after {after_changed:?}",
            changed.result["revision"]
        ));
    }
    for (index, reply) in replies.iter().enumerate() {
        if reply.result["record"] != record(index)
            || reply.result["revision"] != json!((index + 1).to_string())
        {
            failures.push(format!("put {index} answered another record or revision"));
        }
    }
    // Readers: the event feed states every answered record, whole and in
    // order; the last one is the stored record.
    let mut answered = Vec::new();
    for reply in replies.iter().chain([&equal_checked, &equal_unchecked, &changed]) {
        if answered.last() != Some(&reply.result) {
            answered.push(reply.result.clone());
        }
    }
    if published != answered {
        failures.push(format!(
            "the event feed must state the {} records the puts answered, whole and in order: it \
             states {} records",
            answered.len(),
            published.len(),
        ));
    }
    if stored.len() != 1 || published.last() != stored.first() {
        failures.push(format!(
            "a replay of the event feed must end at the stored record: {} stored",
            stored.len()
        ));
    }

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert!(failures.is_empty(), "{failures:#?}");
}
