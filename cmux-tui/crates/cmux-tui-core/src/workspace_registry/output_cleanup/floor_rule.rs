//! The rule of a rebuild at a retention floor: where the rebuild cuts the
//! journal, when the run at or below the floor is worth a rebuild, and how
//! much of that run the retention pass may delete in place when no rebuild
//! takes it. Phase A ([`super::stage`]) and the retention pass read the same
//! rule here, so the two never take the same run.

use rusqlite::Connection;

use super::build::set_state;
use super::stage::{put_records_worth_a_cleanup, state};

/// The cut of a rebuild at `floor`: the end of the last sealed segment
/// that ends at or below it (0: none), and the records of the segments
/// through it (their stored counts: a segment an earlier rebuild packed
/// counts what it holds, not the sequences it spans, so a run that is
/// already pruned never asks for a rebuild again). A segment is left out
/// whole or kept whole, and live rows always stay.
pub(super) fn floor_cut(source: &Connection, floor: u64) -> anyhow::Result<(u64, u64)> {
    #[cfg(test)]
    crate::workspace_registry::journal_retention::retention_step_for_test(
        crate::workspace_registry::journal_retention::RetentionStep::FloorCut,
    );
    let (cut, records): (i64, i64) = source.query_row(
        "SELECT COALESCE(MAX(end_sequence), 0), COALESCE(SUM(record_count), 0)
         FROM journal_segments WHERE end_sequence <= ?1",
        [i64::try_from(floor).unwrap_or(i64::MAX)],
        |row| Ok((row.get(0)?, row.get(1)?)),
    )?;
    Ok((u64::try_from(cut)?, u64::try_from(records)?))
}

/// True when a rebuild at `floor` is worth its cost: the stage's own rule
/// (the sealed segments at or below the floor hold at least
/// `stage::PUT_RECORDS_WORTH_A_CLEANUP` records). Below that, the retention pass
/// deletes those segments in place.
pub(super) fn rebuild_owed(source: &Connection, floor: u64) -> anyhow::Result<bool> {
    if floor == 0 {
        return Ok(false);
    }
    let (cut, below) = floor_cut(source, floor)?;
    Ok(cut > 0 && below >= put_records_worth_a_cleanup())
}

/// The records the retention pass may still delete in place in this start,
/// after `deleted` of them; `None` when it has no bound.
///
/// A run that is worth a rebuild ([`rebuild_owed`]) is the rebuild's work.
/// When no rebuild takes it in this start, the pass is the only way down,
/// and a delete in place writes each page of each row two times (the WAL,
/// then the checkpoint): at the size of a registry that is worth a rebuild,
/// that is hours and tens of gigabytes of writes on a person's disk. So
/// while the run is still worth a rebuild, one start deletes in place at
/// most as many of its records as are worth a rebuild
/// (`stage::PUT_RECORDS_WORTH_A_CLEANUP`), in whole segments. What then stays is
/// for the next start, which tries the rebuild again. A run below that count
/// is deleted in place with no bound: it is the daily path. So is the rest
/// of a run that the bounded deletes brought below that count, so one start
/// deletes fewer than two times that count of that run. The bound is of
/// that run only: when the floor moves up in the same start, the records
/// that it then adds to a run below that count go with no bound, as each
/// day.
pub(super) fn in_place_room(
    source: &Connection,
    floor: u64,
    deleted: u64,
) -> anyhow::Result<Option<u64>> {
    Ok(rebuild_owed(source, floor)?.then(|| put_records_worth_a_cleanup().saturating_sub(deleted)))
}

/// The cut this staging file is built at: the one it recorded when that is
/// at or below `cut` (leaving out less than the floor allows is safe), else
/// `None`: the file left out records the caller now keeps.
pub(super) fn staged_cut(staging: &Connection, cut: u64) -> anyhow::Result<Option<u64>> {
    match state(staging, "floor")?.parse::<u64>() {
        Ok(staged) if staged <= cut => Ok(Some(staged)),
        Ok(_) => Ok(None),
        // A new file: the cut is recorded before any segment is staged.
        Err(_) => {
            set_state(staging, "floor", &cut.to_string())?;
            Ok(Some(cut))
        }
    }
}
