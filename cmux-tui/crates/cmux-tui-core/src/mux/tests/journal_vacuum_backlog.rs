//! Journal maintenance returns free pages only when the backlog matters
//! (REGISTRY WAL, the per-minute vacuum).
//!
//! On one Mac (826 workspaces, a 10.8 GB registry, 2026-11-12) the registry
//! file shrank by exactly 2 MiB in almost every minute of an hour: each
//! maintenance tick (30 s) returned 256 free pages and, because free pages
//! remained, asked for the next tick. Sealing frees pages all day and new
//! rows reuse them, so the worker never settled. An incremental vacuum does
//! not only drop pages: it moves the live pages at the end of the file into
//! free ones and rewrites what points at them, in a commit of its own.
//!
//! Now the registry keeps 64 MiB of free pages and a tick returns a step
//! only of what is free over them, so the worker settles.
//!
//! The tests run a real `Mux` on an on-disk registry, make a free-page
//! backlog (rows written, then deleted), run maintenance ticks through the
//! worker's own tick function and count, at the registry: WAL commits, WAL
//! frame bytes, free pages and the pages of the file. Counts, not times.

use super::*;

const PAGE_BYTES: u64 = 4096;
/// Free pages one maintenance step returns (1 MiB).
const STEP_PAGES: u64 = 256;
/// Free pages the registry keeps for its next rows (64 MiB).
const KEPT_FREE_PAGES: u64 = 16_384;
/// WAL bytes one step may write (twice the pages it returns): what bounds
/// the time it holds the registry.
const STEP_WAL_BYTES_BUDGET: u64 = 2 * STEP_PAGES * PAGE_BYTES;
/// Pages a filler row takes (one leaf cell plus its overflow chain).
const ROW_PAGES: u64 = 4;

/// What the registry holds and wrote so far.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Disk {
    pages: u64,
    free_pages: u64,
    wal_commits: u64,
    wal_frame_bytes: u64,
}

fn disk(mux: &Mux) -> Disk {
    let pragma = |name: &str| -> u64 {
        let value: i64 = mux
            .registry_connection
            .get()
            .query_row(&format!("PRAGMA {name}"), [], |row| row.get(0))
            .unwrap();
        u64::try_from(value).unwrap()
    };
    assert_eq!(pragma("page_size"), PAGE_BYTES);
    assert_eq!(pragma("auto_vacuum"), 2, "a fresh registry vacuums incrementally");
    let stats = mux.write_path_stats();
    Disk {
        pages: pragma("page_count"),
        free_pages: pragma("freelist_count"),
        wal_commits: stats.wal_commits,
        wal_frame_bytes: stats.registry_wal_frame_bytes,
    }
}

/// Writes about `pages` pages of rows into `table`, 2 MiB a commit.
fn fill(mux: &Mux, table: &str, pages: u64) {
    let db = mux.registry_connection.get();
    db.execute_batch(&format!(
        "CREATE TABLE IF NOT EXISTS {table}(id INTEGER PRIMARY KEY, body BLOB NOT NULL)"
    ))
    .unwrap();
    let body = vec![0xA5_u8; usize::try_from(ROW_PAGES * PAGE_BYTES).unwrap() - 512];
    let mut left = pages / ROW_PAGES;
    while left > 0 {
        let batch = left.min(128);
        let transaction = db.unchecked_transaction().unwrap();
        for _ in 0..batch {
            transaction
                .execute(&format!("INSERT INTO {table}(body) VALUES (?1)"), [&body])
                .unwrap();
        }
        transaction.commit().unwrap();
        left -= batch;
    }
}

fn delete_rows(mux: &Mux, table: &str) {
    mux.registry_connection.get().execute(&format!("DELETE FROM {table}"), []).unwrap();
}

/// A persistent mux whose worker is stopped (the test runs the ticks), with
/// nothing left for maintenance: a tick settles and writes nothing.
fn settled_mux(session: &str, root: &Path) -> Arc<Mux> {
    let mux = open_persistent_test_mux(session, root);
    mux.stop_journal_maintenance();
    let settled = (0..8).any(|_| mux.run_journal_maintenance_tick_for_test());
    assert!(settled, "maintenance of a new registry did not settle in 8 ticks");
    let before = disk(&mux);
    assert!(mux.run_journal_maintenance_tick_for_test(), "a settled registry stays settled");
    assert_eq!(disk(&mux), before, "control: a tick with no free page writes nothing");
    mux
}

/// What one maintenance tick did.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct Tick {
    /// The worker would sleep until the journal changes.
    settled: bool,
    wal_commits: u64,
    wal_bytes: u64,
    /// Pages the file lost.
    returned_pages: u64,
}

const IDLE_TICK: Tick = Tick { settled: true, wal_commits: 0, wal_bytes: 0, returned_pages: 0 };

fn tick(mux: &Mux) -> Tick {
    let before = disk(mux);
    let settled = mux.run_journal_maintenance_tick_for_test();
    let after = disk(mux);
    Tick {
        settled,
        wal_commits: after.wal_commits - before.wal_commits,
        wal_bytes: after.wal_frame_bytes - before.wal_frame_bytes,
        returned_pages: before.pages - after.pages,
    }
}

/// 8 MiB of free pages under 4 MiB of live rows: less than the registry
/// keeps for its next rows. Ticks must not rewrite pages to return them.
#[cfg(unix)]
#[test]
fn a_free_backlog_under_the_kept_reserve_costs_no_writes() {
    const TICKS: usize = 6;
    let root = std::env::temp_dir()
        .join(format!("cmux-vacuum-small-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = settled_mux("vacuum-small", &root);
    fill(&mux, "vacuum_test_backlog", 2_048);
    fill(&mux, "vacuum_test_live", 1_024);
    delete_rows(&mux, "vacuum_test_backlog");
    let before = disk(&mux);
    assert!(
        before.free_pages >= 2_000 && before.free_pages < KEPT_FREE_PAGES,
        "the test needs a backlog under the reserve: {before:?}"
    );

    let ticks: Vec<Tick> = (0..TICKS).map(|_| tick(&mux)).collect();
    let after = disk(&mux);
    println!(
        "journal_vacuum_backlog: arm=under_reserve free_pages={} ticks={TICKS} wal_commits={} \
         wal_frame_bytes={} returned_bytes={} per_tick={ticks:?}",
        before.free_pages,
        after.wal_commits - before.wal_commits,
        after.wal_frame_bytes - before.wal_frame_bytes,
        (before.pages - after.pages) * PAGE_BYTES,
    );
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert_eq!(
        after, before,
        "{TICKS} maintenance ticks wrote to a registry whose {} free pages are under the \
         {KEPT_FREE_PAGES} it keeps: {ticks:?}",
        before.free_pages
    );
    assert!(
        ticks.iter().all(|tick| tick.settled),
        "a backlog under the reserve is no work: the worker must settle, got {ticks:?}"
    );
}

/// A backlog 8 MiB over the reserve is returned down to the reserve, one
/// step a tick, then the worker settles. `live_pages_after` live pages sit
/// behind the backlog: with 0 the free pages end the file (dropped), with
/// more than the excess every returned page is a moved live page.
/// `wal_permille_max` bounds the WAL bytes written per 1000 bytes returned.
fn a_backlog_over_the_reserve(arm: &str, live_pages_after: u64, wal_permille_max: u64) {
    const EXCESS_PAGES: u64 = 8 * STEP_PAGES;
    let root = std::env::temp_dir()
        .join(format!("cmux-vacuum-{arm}-{}", crate::workspace_registry::new_uuid_v4()));
    let mux = settled_mux("vacuum-large", &root);
    // Leaf pages and freelist trunks come on top of the rows' pages.
    fill(&mux, "vacuum_test_backlog", KEPT_FREE_PAGES + EXCESS_PAGES);
    fill(&mux, "vacuum_test_live", live_pages_after);
    delete_rows(&mux, "vacuum_test_backlog");
    let before = disk(&mux);
    let excess = before.free_pages.saturating_sub(KEPT_FREE_PAGES);
    assert!(excess >= EXCESS_PAGES, "the test needs a backlog over the reserve: {before:?}");
    let steps_needed = usize::try_from(excess / STEP_PAGES).unwrap();

    let mut ticks = Vec::new();
    // One more tick than steps: the one that finds nothing over the reserve.
    for _ in 0..=steps_needed {
        let step = tick(&mux);
        ticks.push(step);
        if step.settled {
            break;
        }
    }
    let after = disk(&mux);
    let wal_bytes = after.wal_frame_bytes - before.wal_frame_bytes;
    let returned_bytes = (before.pages - after.pages) * PAGE_BYTES;
    let wal_permille = wal_bytes * 1000 / returned_bytes.max(1);
    let largest_step = ticks.iter().map(|tick| tick.wal_bytes).max().unwrap_or(0);
    println!(
        "journal_vacuum_backlog: arm={arm} free_pages={}->{} ticks={} wal_commits={} \
         wal_frame_bytes={wal_bytes} returned_bytes={returned_bytes} \
         wal_bytes_per_1000_returned={wal_permille} largest_step_wal_bytes={largest_step} \
         first_ticks={:?}",
        before.free_pages,
        after.free_pages,
        ticks.len(),
        after.wal_commits - before.wal_commits,
        &ticks[..ticks.len().min(3)],
    );
    let rest: Vec<Tick> = (0..3).map(|_| tick(&mux)).collect();
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);

    let mut failures = Vec::new();
    if ticks.last().is_none_or(|tick| !tick.settled) {
        failures.push(format!(
            "the worker did not settle within {} ticks of a backlog {excess} pages over the \
             reserve: {} free pages left, per tick {ticks:?}",
            steps_needed + 1,
            after.free_pages
        ));
    }
    if !(KEPT_FREE_PAGES..KEPT_FREE_PAGES + STEP_PAGES).contains(&after.free_pages) {
        failures.push(format!(
            "the backlog must be returned down to the reserve of {KEPT_FREE_PAGES} pages (less \
             than one step over it), {} free pages are left",
            after.free_pages
        ));
    }
    // A pointer-map page the file end passes leaves with the free pages.
    let left_free_list = before.free_pages.saturating_sub(after.free_pages);
    if !(left_free_list..=left_free_list + 8).contains(&(before.pages - after.pages)) {
        failures.push(format!("returned pages must leave the file: {before:?} -> {after:?}"));
    }
    if wal_permille > wal_permille_max {
        failures.push(format!(
            "returning {returned_bytes} bytes wrote {wal_bytes} WAL bytes: {wal_permille} per \
             1000 returned, over {wal_permille_max}"
        ));
    }
    if largest_step > STEP_WAL_BYTES_BUDGET {
        failures.push(format!(
            "one step wrote {largest_step} WAL bytes under the registry lock, over \
             {STEP_WAL_BYTES_BUDGET}: per tick {ticks:?}"
        ));
    }
    if rest.iter().any(|tick| *tick != IDLE_TICK) {
        failures.push(format!("ticks after the backlog is returned must write nothing: {rest:?}"));
    }
    assert!(failures.is_empty(), "{failures:#?}");
}

#[cfg(unix)]
#[test]
fn a_free_backlog_over_the_reserve_at_the_end_of_the_file_is_returned() {
    a_backlog_over_the_reserve("over_reserve_file_end", 0, 250);
}

#[cfg(unix)]
#[test]
fn a_free_backlog_over_the_reserve_under_live_pages_is_returned() {
    a_backlog_over_the_reserve("over_reserve_moves_live_pages", 3 * 8 * STEP_PAGES, 1500);
}
