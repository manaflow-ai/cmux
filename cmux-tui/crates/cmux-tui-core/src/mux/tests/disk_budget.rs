//! Disk budgets, held like RAM budgets (Leo, 2026-11-09: "put the same
//! kinda scrutiny we do on RAM as we do for disk usage").
//!
//! Leo's registry was 59.3 GB (plus a 15.7 GB WAL): 96.6% of its 5.77M
//! live journal rows were `personal.session.put` facts of 6.4-7 KB, about
//! 12 a second, 7 GB a day. This guard runs a scripted slice of that day on a
//! real on-disk registry and fails when a journal kind writes more bytes per
//! simulated day than `diagnostics::JOURNAL_KIND_BUDGETS` allows, or the
//! registry grows more per session than
//! `diagnostics::REGISTRY_BYTES_PER_SESSION_PER_DAY`. Bytes are counted, not
//! timed, so the result does not depend on the machine.

use std::collections::BTreeMap;

use serde_json::{Value, json};

use super::*;
use crate::diagnostics::{
    REGISTRY_BYTES_PER_SESSION_PER_DAY, journal_bytes_by_kind, journal_kind_budget,
};

/// The simulated span: every count below is per this many seconds.
const SIMULATED_SECONDS: u64 = 120;
/// Machines that register sessions (P-AUSTIN: 32 connected machines; Leo's
/// registry had a handful).
const MACHINES: usize = 8;
/// Session puts a second across all machines, each with a field that
/// flapped (Leo's registry, 2026-11-09).
const SESSION_PUTS_PER_SECOND: u64 = 12;
/// Workspaces with a terminal created, renamed and closed a minute.
const WORKSPACES_PER_MINUTE: u64 = 2;
/// The capability list a session advertises, in bytes of JSON (5,765 on
/// 2026-10-29, about 6 KB on 2026-11-09).
const CAPABILITY_BYTES: usize = 6_000;
const SECONDS_PER_DAY: u64 = 86_400;

/// This daemon's advertised list, grown with tokens of the same shape until
/// it is at least `bytes` long as JSON.
fn capabilities_of_at_least(bytes: usize) -> Value {
    let mut names: Vec<String> =
        crate::server::static_capabilities().into_iter().map(str::to_owned).collect();
    let mut index = 0;
    while serde_json::to_string(&names).unwrap().len() < bytes {
        names.push(format!("disk-budget-probe-{index}-v1"));
        index += 1;
    }
    json!(names)
}

fn reader(mux: &Mux) -> rusqlite::Connection {
    let path = mux.journal_kernel.database_path().expect("an on-disk registry");
    crate::workspace_registry::open_registry_database_read_only(path).unwrap()
}

/// Pages the registry uses (committed size less its free pages), in bytes.
fn used_bytes(connection: &rusqlite::Connection) -> u64 {
    let pragma = |name: &str| -> u64 {
        let value: i64 =
            connection.query_row(&format!("PRAGMA {name}"), [], |row| row.get(0)).unwrap();
        u64::try_from(value).unwrap()
    };
    (pragma("page_count") - pragma("freelist_count")) * pragma("page_size")
}

fn put_session(mux: &Mux, session: &str, transport: &Value, capabilities: &Value) {
    mux.personal_mutation(|registry| {
        let before = registry.personal_revision()?;
        registry.put_session(
            session,
            Some("build-box"),
            Some("main"),
            transport,
            Some(capabilities),
            None,
        )?;
        Ok(((), registry.personal_revision()? != before))
    })
    .unwrap();
}

/// One checkpoint, then seals through it, one bounded segment per call (as
/// the maintenance worker does).
fn seal_all(mux: &Mux, key: &str) -> u64 {
    let checkpoint =
        mux.create_journal_checkpoint("disk-budget", &format!("{key}-checkpoint")).unwrap();
    let through = checkpoint.checkpoint.source_sequence;
    for attempt in 0..64 {
        let end = mux.workspace_registry.lock().unwrap().journal_segments_end().unwrap();
        if end >= through {
            return through;
        }
        mux.seal_journal_segments(through, "disk-budget", &format!("{key}-seal-{attempt}"))
            .unwrap();
    }
    panic!("sealing through {through} took more than 64 segments");
}

#[cfg(unix)]
#[test]
fn disk_budget_guard() {
    let root = std::env::temp_dir()
        .join(format!("cmux-disk-budget-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = open_persistent_test_mux("disk-budget", &root);
    // The worker would checkpoint and seal on its own ticks; this test
    // seals at the points it measures.
    mux.stop_journal_maintenance();
    let connection = reader(&mux);
    let capabilities = capabilities_of_at_least(CAPABILITY_BYTES);
    let sessions: Vec<String> = (0..MACHINES).map(|index| format!("remote-{index}")).collect();
    let transport = |flap: usize| json!({"kind":"ssh","host":format!("build-box-{}", flap % 2)});
    for session in &sessions {
        put_session(&mux, session, &transport(0), &capabilities);
    }
    let kinds_before = journal_bytes_by_kind(&connection).unwrap();
    let used_before = used_bytes(&connection);

    let puts = SESSION_PUTS_PER_SECOND * SIMULATED_SECONDS;
    let workspaces = WORKSPACES_PER_MINUTE * SIMULATED_SECONDS / 60;
    let workspace_every = puts / workspaces.max(1);
    for put in 0..puts {
        let index = usize::try_from(put).unwrap();
        // Each put flips the transport, so every one is a change the journal keeps.
        put_session(
            &mux,
            &sessions[index % MACHINES],
            &transport(index / MACHINES + 1),
            &capabilities,
        );
        if put % workspace_every == workspace_every - 1 {
            let before: Vec<WorkspaceId> =
                mux.with_state(|state| state.workspaces.iter().map(|w| w.id).collect());
            mux.new_workspace(None, Some((80, 24))).unwrap();
            let workspace = mux.with_state(|state| {
                state.workspaces.iter().map(|w| w.id).find(|id| !before.contains(id)).unwrap()
            });
            assert!(mux.rename_workspace(workspace, format!("churn {put}")));
            assert!(mux.close_workspace(workspace));
        }
    }

    let kinds_after = journal_bytes_by_kind(&connection).unwrap();
    let used_after = used_bytes(&connection);
    let per_day = |bytes: u64| bytes * SECONDS_PER_DAY / SIMULATED_SECONDS;
    let mut over = Vec::new();
    // kind, rows, bytes in the simulated span, bytes per simulated day.
    let mut table: Vec<(String, u64, u64, u64)> = kinds_after
        .iter()
        .map(|(kind, (rows, bytes))| {
            let (rows_before, bytes_before) = kinds_before.get(kind).copied().unwrap_or((0, 0));
            let bytes = bytes - bytes_before;
            (kind.clone(), rows - rows_before, bytes, per_day(bytes))
        })
        .filter(|(_, rows, _, _)| *rows > 0)
        .collect();
    table.sort_by(|a, b| b.3.cmp(&a.3).then(a.0.cmp(&b.0)));
    println!(
        "disk_budget_guard: simulated_seconds={SIMULATED_SECONDS} machines={MACHINES} \
         session_puts={puts} workspaces={workspaces}"
    );
    for (kind, rows, bytes, bytes_per_day) in &table {
        let budget = journal_kind_budget(kind);
        println!(
            "disk_budget_guard: kind={kind} rows={rows} bytes_per_row={} \
             bytes_per_day={bytes_per_day} budget={budget}",
            bytes / rows
        );
        if *bytes_per_day > budget {
            over.push(format!("{kind}: {bytes_per_day} bytes/day, budget {budget}"));
        }
    }
    let registry_per_session = per_day(used_after.saturating_sub(used_before)) / MACHINES as u64;
    println!(
        "disk_budget_guard: registry_used_bytes {used_before} -> {used_after}, \
         per_session_per_day={registry_per_session} budget={REGISTRY_BYTES_PER_SESSION_PER_DAY}"
    );
    if registry_per_session > REGISTRY_BYTES_PER_SESSION_PER_DAY {
        over.push(format!(
            "registry: {registry_per_session} bytes/session/day, budget {REGISTRY_BYTES_PER_SESSION_PER_DAY}"
        ));
    }

    // Sealing moves the rows into compressed segments, and the disk section
    // reports them; a second read adds only the segments sealed since.
    let first = seal_all(&mux, "first");
    let early = mux.disk_usage_stats().expect("an on-disk registry");
    put_session(&mux, &sessions[0], &transport(usize::MAX), &capabilities);
    let second = seal_all(&mux, "second");
    assert!(second > first);
    let disk = mux.disk_usage_stats().expect("an on-disk registry");
    let segments = disk.segments.as_ref().expect("segments read");
    let (count, compressed, uncompressed): (i64, i64, i64) = connection
        .query_row(
            "SELECT COUNT(*), SUM(length(content)), SUM(uncompressed_bytes) FROM journal_segments",
            [],
            |row| Ok((row.get(0)?, row.get(1)?, row.get(2)?)),
        )
        .unwrap();
    assert!(segments.segments > early.segments.as_ref().unwrap().segments, "{disk:?}");
    assert_eq!(segments.segments, u64::try_from(count).unwrap(), "{disk:?}");
    assert_eq!(segments.compressed_bytes, u64::try_from(compressed).unwrap(), "{disk:?}");
    assert_eq!(segments.uncompressed_bytes, u64::try_from(uncompressed).unwrap(), "{disk:?}");
    assert!(segments.compressed_bytes < segments.uncompressed_bytes, "{disk:?}");
    assert!(
        segments.kinds.iter().any(|kind| kind.kind == "personal.session.put"),
        "{:?}",
        segments.kinds
    );
    assert!(
        disk.files.iter().any(|file| file.name == "workspace-registry.sqlite3" && file.bytes > 0),
        "{:?}",
        disk.files
    );
    assert!(disk.registry_bytes > 0 && disk.page_count > 0, "{disk:?}");
    let journal = disk.journal.as_ref().expect("journal read");
    assert!(journal.head_sequence >= second && journal.sample_rows >= 1, "{journal:?}");
    println!(
        "disk_budget_guard: sealed segments={} records={} compressed={} uncompressed={} by_codec={:?}",
        segments.segments,
        segments.records,
        segments.compressed_bytes,
        segments.uncompressed_bytes,
        segments
            .by_codec
            .iter()
            .map(|codec| (&codec.codec, codec.compressed_bytes))
            .collect::<BTreeMap<_, _>>()
    );

    drop(connection);
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert!(over.is_empty(), "over the disk budget (diagnostics::JOURNAL_KIND_BUDGETS): {over:#?}");
}
