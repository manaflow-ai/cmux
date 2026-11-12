//! The maintenance worker's retention pass over the journal's own tables
//! (`workspace_registry::journal_retention`). Only on the thread
//! `cmux-journal-maintenance`, never on a request thread.

use std::sync::PoisonError;
use std::time::{Duration, Instant};

use super::Mux;
use super::journal_maintenance::{
    JOURNAL_MAINTENANCE_CHECKPOINT_RECORDS, JOURNAL_MAINTENANCE_SEAL_BATCHES_PER_TICK,
    journal_maintenance_interval,
};
use crate::workspace_registry::wal_durability::WalRoom;

/// Sealed segments one tick deletes at most (1,024 records each at most:
/// about 1,024 kept reducer rows, event index rows and receipts, and their
/// subject rows). The seal's own bound a tick, so retention keeps up with
/// the fastest sealing.
///
/// One segment is more than one hold of the registry lock
/// ([`Mux::retain_journal_segment`]): no hold deletes the rows of more than
/// `RETENTION_RECORDS_PER_HOLD` records, and after each hold the pass waits,
/// with no lock held, for the WAL syncer's checkpoint of what the hold wrote
/// ([`Mux::after_retention_hold`]). So a tick deletes fewer segments than
/// this when the disk is slow: the tick ends at its deadline, one tick
/// period after the pass began.
const JOURNAL_RETENTION_SEGMENTS_PER_TICK: usize = JOURNAL_MAINTENANCE_SEAL_BATCHES_PER_TICK;
/// How long a tick folds the agent history toward the journal head before
/// the pass: the floor waits for that fold, so a daemon where nobody opens
/// History is bounded too. The backfill's slice (200 ms), for the same
/// reason: the tick runs every 30 s and must not hold a core.
const JOURNAL_RETENTION_HISTORY_FOLD_BUDGET: Duration = Duration::from_millis(200);

/// Records the agent history fold may be ahead of its saved cursor: the
/// worker's checkpoint cadence. The floor moves a checkpoint at a time, so
/// a save more often would not move it sooner, and each save writes the
/// whole agent history.
const JOURNAL_RETENTION_HISTORY_SAVE_RECORDS: u64 = JOURNAL_MAINTENANCE_CHECKPOINT_RECORDS;

/// The fold's budget a tick while a rebuild waits for it (see
/// [`Mux::rebuild_takes_the_run`]). The floor of a rebuild is the floor of
/// the whole swap, and the saved agent history cursor is one of its terms:
/// a registry where nobody opened History for a long time (one had 685,892
/// records to fold) would be rebuilt with all of those records in it. One
/// time per registry, on the maintenance thread, one page a lock hold.
const JOURNAL_RETENTION_REBUILD_FOLD_BUDGET: Duration = Duration::from_secs(2);
/// Ticks a rebuild waits for the agent history fold to reach the journal
/// head (10 minutes at the tick's interval). After them the rebuild takes
/// the floor as it is, so a fold that never ends (a commit storm) does not
/// hold the registry at its size.
const JOURNAL_RETENTION_REBUILD_FOLD_TICKS: u32 = 20;

#[cfg(test)]
thread_local! {
    /// Test seam: runs on this thread at each point where the retention
    /// pass gave the registry lock back after a hold of its delete.
    pub(crate) static AFTER_RETENTION_HOLD_FOR_TEST: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn after_retention_hold_for_test() {
    // Taken while it runs: the seam may run the pass again.
    let hook = AFTER_RETENTION_HOLD_FOR_TEST.with(|slot| slot.borrow_mut().take());
    if let Some(mut hook) = hook {
        hook();
        AFTER_RETENTION_HOLD_FOR_TEST.with(|slot| *slot.borrow_mut() = Some(hook));
    }
}

#[cfg(test)]
thread_local! {
    /// Test seam: runs on this thread after
    /// [`AFTER_RETENTION_HOLD_FOR_TEST`], at the point where the pass is
    /// free to begin its next hold or to end the tick: what it does between
    /// a hold and the next one is done.
    pub(crate) static BEFORE_NEXT_RETENTION_HOLD_FOR_TEST: std::cell::RefCell<Option<Box<dyn FnMut()>>> =
        const { std::cell::RefCell::new(None) };
}

#[cfg(test)]
fn before_next_retention_hold_for_test() {
    let hook = BEFORE_NEXT_RETENTION_HOLD_FOR_TEST.with(|slot| slot.borrow_mut().take());
    if let Some(mut hook) = hook {
        hook();
        BEFORE_NEXT_RETENTION_HOLD_FOR_TEST.with(|slot| *slot.borrow_mut() = Some(hook));
    }
}

/// How the pass left the oldest sealed segment at or below the floor
/// ([`Mux::retain_journal_segment`]).
enum SegmentPass {
    /// The segment, its content and each row of its records are gone.
    Deleted,
    /// No sealed segment is at or below the floor.
    NoSegment,
    /// A rebuild is owed that no worker of this start can make, and this
    /// start has deleted in place what one rebuild is worth: the segment
    /// stays for the rebuild of a later start.
    Bounded,
    /// The worker was paused between two holds.
    Paused,
    /// The WAL has no room for more frames of this pass
    /// ([`WalRoom::Full`]).
    NoWalRoom,
    /// No WAL syncer runs ([`WalRoom::NoSyncer`]).
    NoSyncer,
}

impl Mux {
    /// One retention pass. True while work remains for the next tick.
    pub(super) fn retain_journal(&self) -> anyhow::Result<bool> {
        // The cleanup rebuilds these tables beside the file and swaps it.
        if self.output_cleanup_pending() {
            return Ok(false);
        }
        // While the cleanup worker of this start can rebuild the registry,
        // a run that is worth a rebuild is its work, and its floor waits for
        // the fold below.
        let rebuild_possible = self.journal_rebuild_possible();
        let fold_budget = if rebuild_possible && self.journal_rebuild_fold_waits() > 0 {
            JOURNAL_RETENTION_REBUILD_FOLD_BUDGET
        } else {
            JOURNAL_RETENTION_HISTORY_FOLD_BUDGET
        };
        // A fold that fails counts as done: it is not work the next tick
        // could finish, so the worker may still settle. The pass goes on, and
        // the floor cannot move past the fold: it is read below from the
        // SAVED cursor of the fold, which a fold that failed did not move.
        let folded = crate::history_ops::fold_for_retention(
            self,
            fold_budget,
            JOURNAL_RETENTION_HISTORY_SAVE_RECORDS,
        )
        .unwrap_or_else(|error| {
            eprintln!("cmux-tui: agent history fold before retention failed: {error:#}");
            true
        });
        let floor = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_retention_floor()?;
        if rebuild_possible && self.rebuild_takes_the_run(floor, folded)? {
            // Nothing is deleted in place; the fold may still have work.
            return Ok(!folded);
        }
        // Each wait of this tick for the WAL syncer ends here: the next
        // tick would begin then.
        let deadline = Instant::now() + journal_maintenance_interval();
        // The pass asks the syncer only when it has a segment to delete, so
        // a tick with nothing to delete makes no look at the WAL.
        if !self.journal_segment_waits_in_place(floor)? {
            return Ok(!folded);
        }
        // Before the first hold: requests can have left a WAL with no room
        // (`WalRoom`). The pass then adds nothing to it; the next tick asks
        // again, and its question alone starts the syncer's look, so a
        // daemon with no request after that still gets its room.
        match self.wal_room_for_retention(deadline) {
            WalRoom::Room => {}
            WalRoom::Full { looked, file_bytes, uncopied_frames } => {
                let ticks = self.note_journal_no_wal_room_tick();
                if ticks.is_power_of_two() {
                    eprintln!(
                        "cmux-tui: journal retention: no hold in {ticks} ticks of this start; \
                         the registry WAL has no room (file {file_bytes} bytes, \
                         {uncopied_frames} frames not copied, the syncer's look ended: {looked})"
                    );
                }
                return Ok(true);
            }
            // Nothing checkpoints this WAL: the pass deletes nothing, and
            // the worker may settle (no wake by the period).
            WalRoom::NoSyncer => return Ok(!folded),
        }
        let mut pruned = 0;
        let end = loop {
            if pruned == JOURNAL_RETENTION_SEGMENTS_PER_TICK {
                // More segments can wait: the next tick looks.
                return Ok(true);
            }
            if self.journal_maintenance_paused() {
                break SegmentPass::Paused;
            }
            match self.retain_journal_segment(floor, deadline)? {
                SegmentPass::Deleted => pruned += 1,
                end => break end,
            }
        };
        Ok(match end {
            // The segments at or below the floor stay: the next tick takes
            // them when the WAL has room.
            SegmentPass::NoWalRoom => true,
            SegmentPass::Deleted
            | SegmentPass::NoSegment
            | SegmentPass::Bounded
            | SegmentPass::Paused
            | SegmentPass::NoSyncer => !folded,
        })
    }

    /// True when a sealed segment at or below `floor` waits that this start
    /// may delete in place ([`Self::next_segment_in_place`]). Reads only.
    fn journal_segment_waits_in_place(&self, floor: u64) -> anyhow::Result<bool> {
        let registry = self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
        Ok(self.next_segment_in_place(&registry, floor)?.is_ok())
    }

    /// The oldest sealed segment at or below `floor` and whether the delete
    /// of it counts toward the bound of this start, or why the pass leaves
    /// it. Reads only, under the caller's hold of the registry lock.
    ///
    /// The bound: a run at or below the floor that is worth a rebuild
    /// (`journal_in_place_room`) is the rebuild's work. When no worker of
    /// this start can make it (a rebuild failed or was refused, or the file
    /// that the last swap replaced is still kept), the pass deletes in place
    /// at most the records one rebuild is worth, in whole segments, then it
    /// leaves the run to the rebuild of a later start: at the size of a
    /// long-lived registry the delete in place of all of it is hours of
    /// ticks and tens of gigabytes of WAL frames, and it leaves the file at
    /// its size. A run that is not worth a rebuild has no bound: the pass
    /// deletes it as it does each day. That is also the rest of a run that
    /// the bounded deletes brought below that count, so one start deletes
    /// fewer than two times the records one rebuild is worth, never more.
    fn next_segment_in_place(
        &self,
        registry: &crate::workspace_registry::WorkspaceRegistry,
        floor: u64,
    ) -> anyhow::Result<Result<bool, SegmentPass>> {
        let Some(segment) = registry.journal_segment_to_prune(floor)? else {
            return Ok(Err(SegmentPass::NoSegment));
        };
        let room = registry.journal_in_place_room(floor, self.journal_in_place_records())?;
        Ok(match room {
            Some(room) if segment.records() > room => Err(SegmentPass::Bounded),
            room => Ok(room.is_some()),
        })
    }

    /// Deletes the oldest sealed segment at or below `floor`, in more than
    /// one hold of the registry lock (`workspace_registry::journal_retention`,
    /// the module doc): the base and the floor first, then the rows of at
    /// most `RETENTION_RECORDS_PER_HOLD` records a hold, the segment row with
    /// its content last. When the worker is paused between two holds, or
    /// the WAL has no room for more frames of this pass after a hold
    /// ([`Self::after_retention_hold`]), the segment stays at or below the
    /// floor, where no reader takes its rows, and the next pass takes it
    /// again.
    fn retain_journal_segment(&self, floor: u64, deadline: Instant) -> anyhow::Result<SegmentPass> {
        let (segment, bounded) = {
            let mut registry =
                self.workspace_registry.lock().unwrap_or_else(PoisonError::into_inner);
            let bounded = match self.next_segment_in_place(&registry, floor)? {
                Ok(bounded) => bounded,
                Err(left) => return Ok(left),
            };
            let Some(segment) = registry.begin_journal_segment_prune(floor)? else {
                return Ok(SegmentPass::NoSegment);
            };
            (segment, bounded)
        };
        if let Some(stop) = self.after_retention_hold(deadline) {
            return Ok(stop);
        }
        loop {
            loop {
                if self.journal_maintenance_paused() {
                    return Ok(SegmentPass::Paused);
                }
                let more = self
                    .workspace_registry
                    .lock()
                    .unwrap_or_else(PoisonError::into_inner)
                    .delete_pruned_segment_rows(&segment)?;
                if let Some(stop) = self.after_retention_hold(deadline) {
                    return Ok(stop);
                }
                if !more {
                    // The last rows are gone: the segment row and its
                    // content go next, in the one hold that this pass
                    // cannot divide.
                    break;
                }
            }
            // False: a row of the segment came back between two holds (the
            // backfill of kept reducer records runs on this thread, so not
            // in this pass; a start after a kill can leave one). The rows
            // go again before the content does.
            let gone = self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .finish_journal_segment_prune(&segment)?;
            let stop = self.after_retention_hold(deadline);
            if gone {
                if bounded {
                    // Counted when the segment is gone: a segment that a
                    // pass began and a later pass ended counts one time.
                    self.note_journal_in_place_records(segment.records());
                }
                return Ok(stop.unwrap_or(SegmentPass::Deleted));
            }
            if let Some(stop) = stop {
                return Ok(stop);
            }
        }
    }

    /// After each hold of the delete, with no lock held: the WAL syncer
    /// checkpoints what the hold wrote before the pass writes more, and
    /// then a locker that waits for the registry has its turn before the
    /// next hold (`SignaledMutex::give_way_to_waiters`: the mutex alone
    /// gives the lock to this thread again). `Some` when the pass must not
    /// write more in this tick ([`Self::wal_room_for_retention`]).
    ///
    /// The pass is a background writer that nobody waits for, so it pays
    /// for its own checkpoint (`workspace_registry::wal_durability`, the
    /// module doc). With one flush request at the tick's end the WAL file
    /// took each byte of a tick: 284 MB for 8 segments of a generated
    /// registry of a long-lived session, on a WAL the syncer keeps near
    /// 4 MiB for requests.
    fn after_retention_hold(&self, deadline: Instant) -> Option<SegmentPass> {
        #[cfg(test)]
        after_retention_hold_for_test();
        let room = self.wal_room_for_retention(deadline);
        #[cfg(test)]
        before_next_retention_hold_for_test();
        self.workspace_registry.give_way_to_waiters();
        match room {
            WalRoom::Room => None,
            WalRoom::Full { .. } => Some(SegmentPass::NoWalRoom),
            WalRoom::NoSyncer => Some(SegmentPass::NoSyncer),
        }
    }

    /// With no lock held: asks the WAL syncer for a look at the registry's
    /// WAL and waits for it, at most until `deadline` (the end of this
    /// tick's period). [`WalRoom::Full`]: the look did not end in time, or
    /// the WAL file is past its limit with frames that the look could not
    /// copy (requests write faster than the copy, or a reader holds an old
    /// snapshot). The pass then adds nothing to that WAL in this tick.
    fn wal_room_for_retention(&self, deadline: Instant) -> WalRoom {
        // MUTATION, never merge: the pass WITHOUT its wait for the syncer's
        // look. It asks for a flush, as a request's reply does, and writes on.
        let _ = deadline;
        self.registry_connection.request_flush();
        WalRoom::Room
    }

    /// True when this tick deletes nothing in place, because the rebuild
    /// beside the file (`mux/output_cleanup.rs`) removes the run at or below
    /// the floor: deleting 2 million records in place takes hours of ticks
    /// and leaves the file at its size. The rebuild gets its floor here,
    /// once the agent history fold is at the journal head (`folded`) or the
    /// wait for it is over. A run too small for a rebuild is deleted in
    /// place, as before.
    fn rebuild_takes_the_run(&self, floor: u64, folded: bool) -> anyhow::Result<bool> {
        if !folded && self.note_journal_rebuild_fold_wait() <= JOURNAL_RETENTION_REBUILD_FOLD_TICKS
        {
            // The floor still moves with the fold: no rebuild at this one,
            // and no delete in place that the rebuild would do in one swap.
            return Ok(true);
        }
        let owed = self
            .workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_rebuild_owed(floor)?;
        if owed {
            self.offer_rebuild_floor(floor);
        }
        Ok(owed)
    }

    /// The sequence retention has deleted through: a journal cursor below it
    /// names records that are gone.
    pub(crate) fn journal_pruned_through(&self) -> anyhow::Result<u64> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .journal_pruned_through()
    }
}
