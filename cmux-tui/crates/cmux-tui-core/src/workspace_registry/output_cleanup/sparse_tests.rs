//! The floor on a SPARSE journal, the form of a registry that ran for
//! months: the first output cleanup left a few packed segments at low
//! sequence numbers with holes, the journal head is near 24.1 million, and
//! the file holds far fewer records than sequences (2.44 M records under a
//! head of 24.1 M on the file of 2026-11-11).
//!
//! The registry here is the generator's (`synth_registry`, the sparse part
//! of `synth_sparse.rs`): the product's own cleanup makes the packed
//! segments and their pruned ranges, and the generator then moves the end
//! of the last one to sequence 24,090,000 by SQL. Each test takes it
//! through one way the floor moves (the delete in place, the rebuild and
//! swap at the floor of a start, a rebuild at a floor inside the sparse
//! part), then the base copy and a start.
//!
//! A record at sequence 1 is in the first packed segment. The floor is the
//! END of a sealed segment, so that record goes when the end of its segment
//! is at or below the floor, with every other record of the segment; a low
//! sequence number alone never removes a record, and a count of sequences
//! is never taken for a count of records.

use serde_json::Value;

use super::*;
use crate::workspace_registry::synth::{ShapeOptions, counts, generate_shape};

/// The journal head after the sparse part.
const SPARSE_END: u64 = 24_090_000;
/// Agents with every record at the start of the journal, and agents with
/// records up to the head.
const RESTED: usize = 3;
const ACTIVE: usize = 5;
/// The provider's session id of rested agent N ends with N.
const RESTED_SESSION_PREFIX: &str = "synth-rested-";
const PUT_KIND: &str = "personal.session.put";

type Record = (u64, String, String);

struct Sparse {
    root: Root,
    db_path: PathBuf,
    /// The journal head of the generated registry.
    head: u64,
    /// Every record of the generated registry.
    all: Vec<Record>,
    /// (start, end, record count) of each packed segment of the sparse part.
    packed: Vec<(u64, u64, u64)>,
}

/// The terminal of rested agent `index` (`synth_shape.rs`).
fn rested_terminal(index: usize) -> String {
    format!("term_00000000000040008001{index:012x}")
}

fn number(counts: &Value, key: &str) -> u64 {
    counts[key].as_u64().unwrap_or_else(|| panic!("{key} is not a number in {counts}"))
}

/// A closed registry of `records` records, `sparse_records` of them written
/// before the first output cleanup, with the end of the sparse part at
/// [`SPARSE_END`]. The checks here are of the setup.
fn sparse_registry(label: &str, records: u64, sparse_records: u64) -> Sparse {
    DISK_MARGIN_FOR_TEST.with(|margin| margin.set(Some(0)));
    let root = Root::new(label);
    let options = ShapeOptions {
        session: SESSION.into(),
        records: Some(records),
        workspaces: 3,
        agent_terminals: ACTIVE,
        rested_agents: RESTED,
        live_rows: 100,
        seal_age_minutes: 120,
        young_segments: 1,
        sparse_head: 100_000,
        sparse_records,
        sparse_stretch: SPARSE_END,
        ..ShapeOptions::default()
    };
    let report = generate_shape(&root.0, &options).unwrap();
    let json = report.to_json();
    let db_path = report.registry_path;
    let head = journal_head(&db_path);
    let all = records_after(&db_path, 0, head);
    let packed = {
        let connection = read_only(&db_path);
        let mut statement = connection
            .prepare(
                "SELECT start_sequence, end_sequence, record_count FROM journal_segments
                 WHERE end_sequence <= ?1 ORDER BY start_sequence",
            )
            .unwrap();
        statement
            .query_map([SPARSE_END as i64], |row| {
                Ok((row.get::<_, i64>(0)?, row.get::<_, i64>(1)?, row.get::<_, i64>(2)?))
            })
            .unwrap()
            .map(|row| row.map(|(start, end, count)| (start as u64, end as u64, count as u64)))
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
    };
    eprintln!("sparse registry {label}: head {head}, {} records, packed {packed:?}", all.len());
    assert!(packed.len() >= 3, "the setup: the sparse part has {} segments: {json}", packed.len());
    assert_eq!(packed.first().map(|segment| segment.0), Some(1), "the setup: {json}");
    assert_eq!(packed.last().map(|segment| segment.1), Some(SPARSE_END), "the setup: {json}");
    assert!(
        head > SPARSE_END && (all.len() as u64) < head / 1_000,
        "the setup: {} records under the head {head}",
        all.len()
    );
    assert!(all.len() as u64 >= records, "the setup: a read returns {} records", all.len());
    assert!(pruned_ranges(&db_path).len() > 1_000, "the setup: the sparse part has holes: {json}");
    assert_eq!(number(&json, "retention_floor"), 0, "the setup: {json}");
    assert_eq!(number(&json, "roster_rested"), RESTED as u64, "the setup: {json}");
    assert_eq!(number(&json, "history_rested"), RESTED as u64, "the setup: {json}");
    assert!(json["roster_base"].is_null() && json["history_base"].is_null(), "the setup: {json}");
    Sparse { root, db_path, head, all, packed }
}

/// The base of each reducer in the closed registry: it is there, its cursor
/// is at or above `cut`, and it holds each rested agent.
fn assert_bases(sparse: &Sparse, cut: u64) {
    let read = counts(&sparse.db_path).unwrap();
    for (reducer, key) in BASED.iter().zip(["roster_base", "history_base"]) {
        let raw = meta(&sparse.db_path, &format!("journal_reducer_base.{reducer}")).unwrap_or_else(
            || panic!("the records through {cut} are gone and {reducer} has no base"),
        );
        let cursor = read[key]["cursor"].as_u64();
        assert!(
            cursor.is_some_and(|cursor| cursor >= cut),
            "the base of {reducer} has cursor {cursor:?}, below the floor {cut}"
        );
        // The roster names an agent by its terminal, the History by its session.
        for index in 0..RESTED {
            assert!(
                raw.contains(&format!("{RESTED_SESSION_PREFIX}{index}"))
                    || raw.contains(&rested_terminal(index)),
                "the base of {reducer} does not hold rested agent {index}"
            );
        }
    }
}

/// A full owner start on the registry after the floor moved to `cut`: the
/// roster serves each rested agent, a journal read from a cursor inside the
/// removed run goes on above it, the agent history fold reaches the head,
/// and what the start saves still holds every agent.
fn assert_a_start_serves_every_agent(sparse: &Sparse, cut: u64) {
    let mux = open(&sparse.root.0);
    // The worker's tick may delete more segments in place: not in this check.
    mux.stop_journal_maintenance();
    for index in 0..RESTED {
        assert!(
            roster_state(&mux, &rested_terminal(index)).is_some(),
            "the roster of the start lost rested agent {index}, whose records are below {cut}"
        );
    }
    let page = mux.session_journal_after(cut / 2, 16).unwrap();
    assert!(
        page.records.first().is_some_and(|record| record.sequence > cut),
        "a read from sequence {} returned {:?}",
        cut / 2,
        page.records.first().map(|record| record.sequence)
    );
    assert!(
        crate::history_ops::fold_for_retention(&mux, Duration::from_secs(60), 1).unwrap(),
        "the agent history fold did not reach the journal head"
    );
    mux.shutdown();
    drop(mux);
    let saved = counts(&sparse.db_path).unwrap();
    assert_eq!(number(&saved, "roster_agents"), (ACTIVE + RESTED) as u64, "{saved}");
    assert_eq!(number(&saved, "roster_rested"), RESTED as u64, "{saved}");
    assert_eq!(number(&saved, "history_rested"), RESTED as u64, "{saved}");
}

/// What a rebuild at the cut `cut` left in the closed registry: no record
/// at or below the cut, every record above it that is not a session put,
/// and no record that the old file did not have. (The rebuild also drops
/// each session put that a later one superseded.)
fn assert_rebuilt_above(sparse: &Sparse, cut: u64) {
    let Sparse { db_path, head, all, .. } = sparse;
    assert!(previous_path(db_path).is_file(), "the open did not swap: no old file is kept");
    assert!(!staging_path(db_path).exists(), "the staging file stays");
    assert_eq!(journal_head(db_path), *head, "the journal head moved");
    let read = records_after(db_path, 0, *head);
    assert!(
        read.first().is_some_and(|record| record.0 > cut),
        "a read from sequence 0 starts at {:?}; the cut is {cut}",
        read.first().map(|record| record.0)
    );
    let not_puts = |records: &[Record]| -> Vec<Record> {
        records.iter().filter(|record| record.0 > cut && record.2 != PUT_KIND).cloned().collect()
    };
    assert_eq!(not_puts(&read), not_puts(all), "the records above the cut {cut}");
    let unknown = read.iter().filter(|record| all.binary_search(record).is_err()).count();
    assert_eq!(unknown, 0, "the rebuilt registry has records that the old one did not have");
    let puts = read.iter().filter(|record| record.2 == PUT_KIND).count();
    assert!(puts > 0, "the rebuild left no session put");
    let pruned_through =
        crate::workspace_registry::journal_retention::journal_pruned_through(&read_only(db_path))
            .unwrap();
    assert_eq!(pruned_through, cut, "the registry does not say that the records are gone");
    let first = pruned_ranges(db_path).first().copied();
    assert!(
        first.is_some_and(|(start, end)| start == 1 && end as u64 >= cut),
        "the first pruned range is {first:?}; the cut is {cut}"
    );
}

/// Retention deletes sealed segments in place, 8 a tick. On the sparse
/// journal it must cross the packed segments (24 million sequences, a few
/// thousand records) and go on into the records after them: every hole of
/// the sparse part ends as ONE pruned range from sequence 1, each record
/// above the floor stays, and each reducer has its base.
#[test]
fn the_delete_in_place_crosses_the_sparse_part() {
    let sparse = sparse_registry("delete", 14_000, 8_000);
    let Sparse { root, db_path, head, all, packed } = &sparse;
    let mux = open(&root.0);
    // The worker ticks each 30 s; the test runs the same tick itself. A tick
    // deletes 8 segments, so the ticks follow the packed segments: another
    // test of this process may make them small (the environment variable
    // of `segment_record_limit`), and then the sparse part has hundreds.
    mux.stop_journal_maintenance();
    for _ in 0..packed.len() / 8 + 40 {
        if mux.run_journal_maintenance_for_test() {
            break;
        }
    }
    let floor = mux.journal_pruned_through().unwrap();
    assert!(
        floor > SPARSE_END,
        "retention deleted through {floor}: the sparse part ends at {SPARSE_END}"
    );
    assert!(floor < *head, "retention deleted through {floor}, past the head {head}");
    for index in 0..RESTED {
        assert!(
            roster_state(&mux, &rested_terminal(index)).is_some(),
            "the running daemon's roster lost rested agent {index}"
        );
    }
    mux.shutdown();
    drop(mux);

    assert_eq!(
        pruned_ranges(db_path),
        vec![(1, i64::try_from(floor).unwrap())],
        "all that is at or below the floor is one pruned range"
    );
    let kept = all.iter().filter(|record| record.0 > floor).cloned().collect::<Vec<_>>();
    assert!(kept.len() >= 500, "the setup: {} records are above the floor", kept.len());
    assert_eq!(records_after(db_path, 0, *head), kept, "the records above the floor {floor}");
    assert_eq!(
        count(
            db_path,
            &format!("SELECT COUNT(*) FROM journal_segments WHERE end_sequence <= {floor}")
        ),
        0,
        "a segment at or below the floor stays"
    );
    assert_bases(&sparse, floor);
    assert_a_start_serves_every_agent(&sparse, floor);
}

/// The rebuild beside the file at the floor that a start reads from the
/// registry alone, then the swap at the next open. The floor is above the
/// sparse part: the cut takes the packed segments and the sealed records
/// after them, by their stored record counts.
#[test]
fn a_rebuild_at_the_floor_of_a_start_takes_the_sparse_part() {
    let sparse = sparse_registry("rebuild", 14_000, 8_000);
    let Sparse { root, db_path, head, all, packed } = &sparse;
    let floor =
        crate::workspace_registry::journal_retention::journal_retention_floor(&read_only(db_path))
            .unwrap();
    assert!(
        floor > SPARSE_END && floor < *head,
        "the setup: the floor of a start is {floor}; the sparse part ends at {SPARSE_END}"
    );
    let below = all.iter().filter(|record| record.0 <= floor).count() as u64;
    let sparse_records = packed.iter().map(|segment| segment.2).sum::<u64>();
    assert!(below > sparse_records, "the setup: the floor takes records after the sparse part");
    let before_bytes = file_len(db_path);
    let saved = BASED.map(|reducer| meta(db_path, &format!("journal_reducer.{reducer}")));

    // 1,000 records at or below the floor are worth a rebuild here.
    PUT_RECORDS_LIMIT.with(|limit| limit.set(1_000));
    assert_eq!(stage(db_path, floor, &|| true), StageOutcome::Built);
    assert_eq!(file_len(db_path), before_bytes, "the registry file changed before the swap");
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());

    assert_rebuilt_above(&sparse, floor);
    assert!(file_len(db_path) < before_bytes, "the rebuilt registry is not smaller");
    for (reducer, saved) in BASED.iter().zip(saved) {
        assert_eq!(
            meta(db_path, &format!("journal_reducer_base.{reducer}")),
            saved,
            "the base of {reducer} is not its saved state at the swap"
        );
    }
    assert_bases(&sparse, floor);
    assert_a_start_serves_every_agent(&sparse, floor);
}

/// A rebuild at a floor INSIDE the sparse part: the last packed segment
/// (some hundred records, 24 million sequences) is above the cut, so the
/// pass reads it, keeps its records and its holes, and packs it again.
#[test]
fn a_rebuild_at_a_floor_inside_the_sparse_part_keeps_the_packed_records_above_it() {
    let sparse = sparse_registry("inside", 14_000, 12_000);
    let Sparse { root, db_path, all, packed, .. } = &sparse;
    // The cut: the end of the packed segment before the last one.
    let (below_segments, last) = packed.split_at(packed.len() - 1);
    let cut = below_segments.last().unwrap().1;
    let below = below_segments.iter().map(|segment| segment.2).sum::<u64>();
    let (last_start, last_end, last_records) = last[0];
    assert!(
        below * 2 > all.len() as u64 + 1_000,
        "the setup: {below} of {} records are at or below the cut {cut}",
        all.len()
    );
    assert!(
        last_end - last_start > 1_000_000 && last_records <= 1_024,
        "the setup: the last packed segment is {:?}",
        last[0]
    );
    let saved = BASED.map(|reducer| meta(db_path, &format!("journal_reducer.{reducer}")));

    PUT_RECORDS_LIMIT.with(|limit| limit.set(1_000));
    // The start of this test takes the floor that the test stages at.
    START_FLOOR_FOR_TEST.with(|start| start.set(Some(cut)));
    assert_eq!(stage(db_path, cut, &|| true), StageOutcome::Built);
    drop(WorkspaceRegistry::open(&root.0, SESSION).unwrap());
    START_FLOOR_FOR_TEST.with(|start| start.set(None));

    assert_rebuilt_above(&sparse, cut);
    // The holes of the last packed segment are still pruned ranges.
    let holes = pruned_ranges(db_path)
        .iter()
        .filter(|(start, end)| *start as u64 > cut && *end as u64 <= SPARSE_END)
        .count();
    assert!(holes >= 1, "{holes} pruned ranges are left between the cut {cut} and {SPARSE_END}");
    for (reducer, saved) in BASED.iter().zip(saved) {
        assert_eq!(
            meta(db_path, &format!("journal_reducer_base.{reducer}")),
            saved,
            "the base of {reducer} is not its saved state at the swap"
        );
    }
    assert_bases(&sparse, cut);
    assert_a_start_serves_every_agent(&sparse, cut);
}
