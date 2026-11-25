//! A turn a full disk cut off goes on once the disk has room again.
//!
//! 2026-11-24 on gcp-agent-lane-13: the root disk filled at 22:48Z and had room again at
//! 22:49Z, but a chat whose turn failed on "No space left on device (os error 28)" stayed failed
//! until someone prompted it (goal-cloud-carrier-ssh-backup-a sat stranded on `disk.full`). Leo,
//! the same evening: "do they get stranded!? what do we do ab stops and wakeups". A full disk
//! clears by itself (a build's output reclaimed, a cache pruned), so it is a pause like a
//! capacity outage: the continuation waits its turn's backoff (`capacity_wait`, never used up),
//! then this waker checks the chat's disk and waits on while it has less free than
//! `autoResumeDiskFreeBytes` (16 MiB), checking every [`RECHECK_MS`] (or the first
//! `autoResumeDelaysMs` wait, if shorter). Stop, Close or a new
//! prompt end the wait as they end any.
//!
//! A turn the store itself refused on a full disk, before its agent saw the prompt
//! (`fail_unstarted_turn`, `store/journal_store/space.rs`: "acpmux stores nothing until it has
//! 16 MiB free"), waits the same way: such a turn used to end failed with no continuation, so the
//! chat read `stranded: disk` until someone prompted it, though the disk had room again minutes
//! later (a lane VM's chat, 2026-11-25). Leo, that morning: "clearly we need to
//! auto cleanup harder and faster/share stuff more so we dont have to manually go through this".
//! [`Hub::resume_refused_turn`] gives it the cut turn's continuation; the wait also holds while
//! the store is still in its full state (it leaves it a few seconds after the disk has room).
//!
//! Its cost: one `statvfs` and one atomic read per waiting chat every [`RECHECK_MS`], and no task
//! at all for a chat that is not waiting (no tick, no busy loop).

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use tokio::sync::Notify;

use super::{CutTurn, Mark};
use crate::hub::{Control, Hub, Session};

/// The free space a chat waits for, unless `autoResumeDiskFreeBytes` says otherwise.
pub(in crate::hub) const DISK_FREE_MIN: u64 = 16 << 20;

/// How often a chat waiting on a full disk checks it again.
pub(in crate::hub) const RECHECK_MS: u64 = 15_000;

/// The free bytes on the filesystem holding `dir`, if it reads.
fn free_bytes(dir: &Path) -> Option<u64> {
    crate::disk_usage::statvfs(dir).map(|root| root.free)
}

/// Whether the filesystem holding `dir` has fewer than `floor` bytes free. One that does not
/// read (a cwd since removed) holds nothing up.
pub(in crate::hub) fn short_of(dir: &Path, floor: u64) -> bool {
    free_bytes(dir).is_some_and(|free| free < floor)
}

/// The rules a turn the store refused ran under, kept for its continuation: the same as the
/// continuation of a turn its agent failed gets (`turns.rs`, the cut turn's `CutTurn`).
#[derive(Clone, Copy)]
pub(in crate::hub) struct RefusedRules<'a> {
    pub control: Control,
    pub trust_gate: bool,
    /// The family sender its prompt spoke for (`subsession_guard::is_family`).
    pub from: Option<&'a str>,
    /// Whether its prompt is one a cut turn of goes on for (no trigger's, no cache compaction's,
    /// no cold wake's), as `turns.rs` decides for a turn its agent failed.
    pub goes_on: bool,
}

impl Hub {
    /// The turn `turn_id` (prompt `prompt_id`) failed before its agent saw it, on the store's
    /// `disk.full` refusal `error`: it goes on as a turn a full disk cut does, once the disk
    /// has room ([`Hub::wait_disk_free`]). Not when anything else answers for the chat already
    /// (a waiting or firing continuation, a Stop's hold: its mark), when it is closed, or for a
    /// prompt no cut turn of goes on for.
    pub(in crate::hub) fn resume_refused_turn(
        self: &Arc<Self>,
        session: &Arc<Session>,
        prompt_id: &str,
        turn_id: &str,
        error: &str,
        rules: &RefusedRules<'_>,
    ) {
        if !rules.goes_on || session.status() == crate::hub::SessionStatus::Closed {
            return;
        }
        {
            let mut pending = session.auto_resume.lock();
            // An earlier turn's wait is past: this newer turn took the chat, and that wait would
            // skip as superseded when it fires, leaving this one stranded. This one waits
            // instead. A Stop's mark, or a continuation that is firing or ending, holds.
            match pending.as_ref() {
                None => {}
                Some(Mark::Waiting { turn, .. }) if turn != turn_id => {}
                Some(_) => return,
            }
            pending.replace(Mark::Ending(turn_id.to_owned()));
        }
        let cut = CutTurn {
            from: rules.from,
            prompt_id,
            turn_id,
            control: rules.control,
            trust_gate: rules.trust_gate,
            error,
            not_before: None,
            slash: None,
        };
        self.schedule_auto_resume(session, turn_id, Some(cut));
    }

    /// Whether the store is in its full-disk state (`store/journal_store/space.rs`): it refuses
    /// every write until it has its reserve back.
    fn store_full(&self) -> bool {
        self.store.durability().and_then(|d| (d.full)()).is_some()
    }

    /// Waits while `session`'s disk (its cwd's filesystem, else the root's) has less free than
    /// the floor, or the store still refuses writes on a full disk, rechecking every
    /// [`RECHECK_MS`]; `wake` (Stop, a new prompt) ends it at once.
    pub(in crate::hub) async fn wait_disk_free(
        self: &Arc<Self>,
        session: &Arc<Session>,
        wake: &Notify,
    ) {
        let cwd = session.meta().cwd.clone();
        let dir = if cwd.as_os_str().is_empty() { Path::new("/").to_path_buf() } else { cwd };
        loop {
            let (floor, recheck) = {
                let config = self.config.read().await;
                let floor = config.auto_resume_disk_free_bytes.unwrap_or(DISK_FREE_MIN);
                (floor, recheck_ms(config.auto_resume_delays_ms.as_deref()))
            };
            if !short_of(&dir, floor) && !self.store_full() {
                return;
            }
            tokio::select! {
                () = tokio::time::sleep(Duration::from_millis(recheck)) => {}
                () = wake.notified() => return,
            }
        }
    }
}

/// How often a waiting chat checks its disk: [`RECHECK_MS`], or the first configured wait
/// (`autoResumeDelaysMs`) when that is shorter.
fn recheck_ms(delays: Option<&[u64]>) -> u64 {
    delays.and_then(|d| d.first().copied()).unwrap_or(RECHECK_MS).clamp(1, RECHECK_MS)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_disk_with_room_holds_nothing_and_a_floor_past_its_size_holds() {
        let dir = std::env::temp_dir();
        assert!(!short_of(&dir, 0));
        assert!(short_of(&dir, u64::MAX));
        assert!(!short_of(Path::new("/nonexistent/acpmux-disk-wait"), u64::MAX));
    }

    #[test]
    fn it_rechecks_every_15_s_or_sooner_when_the_first_wait_is_shorter() {
        assert_eq!(recheck_ms(None), RECHECK_MS);
        assert_eq!(recheck_ms(Some(&[20, 20])), 20);
        assert_eq!(recheck_ms(Some(&[60_000])), RECHECK_MS);
        assert_eq!(recheck_ms(Some(&[])), RECHECK_MS);
    }
}
