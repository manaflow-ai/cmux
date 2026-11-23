//! The text of a byte replay while a resize's prompt clear waits for the
//! shell (option `PROMPT_REDRAW_WAITS_FOR_SHELL`, 1028).
//!
//! A byte mirror (a remote session, a hosted reader, the app's byte mode,
//! iOS) writes the replay into a fresh terminal, which holds no waiting
//! clear. At the shell's first byte the host clears its prompt and the
//! mirror does not, so the shell's redraw leaves a second prompt on the
//! mirror (#21341). So the replay text comes from a copy of the terminal
//! that has already run the clear: a GHOSTSNP round trip, then option 1028
//! off on the copy, which runs `settlePromptRedraw`. The copy clears only if
//! the grid differs from the grid the shell drew at, exactly as the host
//! will, so after the shell's redraw both show the same screen, and a bounce
//! back to that grid keeps the prompt on both. The live terminal keeps its
//! clear waiting. Snapshot mirrors get the waiting clear itself (record
//! PROMPT_REDRAW) and do not use this.

use super::*;
use crate::snapshot::{DecodedTerminal, SnapshotPhase, snapshot_records, tag};

impl Terminal {
    /// A copy of this terminal that has run the prompt clear a resize put
    /// off, or `None` when no clear waits. A copy that cannot be made (an
    /// unfinished sequence past the snapshot limit, say) is also `None`:
    /// the replay then shows the live screen, as it did before option 1028.
    pub(super) fn settled_prompt_copy(&mut self) -> Option<DecodedTerminal> {
        if !self.prompt_clear_may_wait {
            return None;
        }
        // The READY prefix holds the PROMPT_REDRAW record and costs the
        // active screens only; the history comes only when a clear waits.
        let ready = self.encode_snapshot(SnapshotPhase::Ready).ok()?;
        let Some(pending) =
            snapshot_records(&ready).find(|record| record.tag == tag::PROMPT_REDRAW)
        else {
            // Only a resize puts a clear off, and none waits now.
            self.prompt_clear_may_wait = false;
            return None;
        };
        // The record starts with the grid the shell drew at (u16 columns,
        // u16 rows). Back at that grid, the clear will do nothing
        // (`settlePromptRedraw`), so the live screen is already the settled
        // one: a bounce the shell never answered, which can wait until the
        // person types, costs no copy.
        let &[cols_lo, cols_hi, rows_lo, rows_hi] = pending.payload().first_chunk::<4>()?;
        let drawn_grid =
            (u16::from_le_bytes([cols_lo, cols_hi]), u16::from_le_bytes([rows_lo, rows_hi]));
        if drawn_grid == (self.cols(), self.rows()) {
            return None;
        }
        let complete = self.encode_snapshot(SnapshotPhase::Complete).ok()?;
        let copy = DecodedTerminal::decode(&complete).ok()?;
        let waits = false;
        check(unsafe {
            sys::ghostty_terminal_set(
                copy.raw(),
                sys::GHOSTTY_TERMINAL_OPT_PROMPT_REDRAW_WAITS_FOR_SHELL,
                (&waits as *const bool).cast(),
            )
        })
        .ok()?;
        // The replay plans its Kitty rows and history window on this
        // terminal's rows and lays the text out on the copy's: they must be
        // the same rows (the clear only blanks cells and moves the cursor).
        let live_rows = self.scrollbar().map(|scrollbar| scrollbar.total);
        let copy_rows =
            self.with_replay_grid(Some(&copy), |term| term.scrollbar().map(|s| s.total));
        (live_rows == copy_rows).then_some(copy)
    }

    /// Run `layout` with this terminal's grid, formatter and cursor reads
    /// served by `grid` (`None`: this terminal). Every Rust-side tracker
    /// (Kitty uploads in flight, the unfinished sequence, the mouse format)
    /// stays this terminal's: the copy has the same grid state but none of
    /// the stream state the trackers follow.
    pub(super) fn with_replay_grid<R>(
        &mut self,
        grid: Option<&DecodedTerminal>,
        layout: impl FnOnce(&mut Self) -> R,
    ) -> R {
        let Some(grid) = grid else {
            return layout(self);
        };
        let live = std::mem::replace(&mut self.raw, grid.raw());
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| layout(self)));
        // The copy is freed after this call; never leave its handle behind.
        self.raw = live;
        result.unwrap_or_else(|panic| std::panic::resume_unwind(panic))
    }
}
