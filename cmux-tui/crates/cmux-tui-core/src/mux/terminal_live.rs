//! Live terminal facts: an OSC 9;4 progress, the "last output" time and a
//! program status report that keeps its record's state and kind.
//!
//! They change while a terminal only prints, so they are not durable
//! changes: a commit per change was one registry lock take, one journal row,
//! one resource revision and one WAL commit for each (4,692 lock takes and
//! 13.8 s of hold in 2 h on a session of 798 terminals). A client reads
//! them from the terminal's memory with every terminal record
//! (`resource_api/terminal_extra.rs`), so nothing durable depends on them.
//!
//! A terminal's publication marks the terminal here, in memory, and wakes
//! the `session.events` streams. It takes no registry lock, writes no
//! journal row and moves no revision. Each stream then sends the terminal's
//! current record as a `delta` item at the revision the stream already has
//! (`server/session_event_stream.rs`). A durable edge (a command, a prompt,
//! a record's state or kind) is still one commit
//! (`Mux::publish_terminal_progress`), and that commit carries the newest
//! live facts.

use super::*;
use crate::resource_api::{public_terminal_snapshot, terminal_tab_ids_in_canonical_order};
use crate::workspace_registry::SessionJournalReader;
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU64, Ordering};

/// The terminals whose live facts changed, in the order of their newest
/// change. One entry per terminal: a new change replaces the terminal's
/// older entry, so a stream that reads the entries after the sequence it
/// has seen does work in proportion to the terminals that changed.
#[derive(Default)]
pub(super) struct TerminalLiveLog {
    sequence: AtomicU64,
    changes: Mutex<LiveChanges>,
}

#[derive(Default)]
struct LiveChanges {
    by_sequence: BTreeMap<u64, TerminalPublicId>,
    of_terminal: HashMap<TerminalPublicId, u64>,
}

impl TerminalLiveLog {
    fn mark(&self, terminal: &TerminalPublicId) {
        let mut changes = self.changes.lock().unwrap_or_else(PoisonError::into_inner);
        let sequence = self.sequence.load(Ordering::Acquire).wrapping_add(1);
        if let Some(previous) = changes.of_terminal.insert(terminal.clone(), sequence) {
            changes.by_sequence.remove(&previous);
        }
        changes.by_sequence.insert(sequence, terminal.clone());
        self.sequence.store(sequence, Ordering::Release);
    }

    /// A closed terminal has no live facts: drop its entry.
    pub(super) fn forget(&self, terminal: &TerminalPublicId) {
        let mut changes = self.changes.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(sequence) = changes.of_terminal.remove(terminal) {
            changes.by_sequence.remove(&sequence);
        }
    }

    fn sequence(&self) -> u64 {
        self.sequence.load(Ordering::Acquire)
    }

    fn changed_after(&self, sequence: u64) -> (u64, Vec<TerminalPublicId>) {
        let changes = self.changes.lock().unwrap_or_else(PoisonError::into_inner);
        let terminals = changes
            .by_sequence
            .range((std::ops::Bound::Excluded(sequence), std::ops::Bound::Unbounded))
            .map(|(_, terminal)| terminal.clone())
            .collect();
        (self.sequence.load(Ordering::Acquire), terminals)
    }
}

impl Mux {
    /// `source`'s live facts changed: wake the `session.events` streams, in
    /// memory only. No registry lock, no journal row, no revision.
    pub(crate) fn publish_terminal_live(&self, source: &Surface) {
        let Some(terminal) = source.terminal_public_id() else { return };
        self.terminal_live.mark(terminal);
        // The streams wait on the journal event condition. The epoch does
        // not move (nothing was committed): a waiter that only watches the
        // epoch checks it once and waits again.
        let _epoch = self.journal_event_epoch.lock().unwrap_or_else(PoisonError::into_inner);
        self.journal_event_changed.notify_all();
    }

    /// The live sequence now. A stream takes it before it builds its
    /// snapshot, so a change after the snapshot reaches the stream.
    pub(crate) fn terminal_live_sequence(&self) -> u64 {
        self.terminal_live.sequence()
    }

    /// The newest live sequence and the terminals whose live facts changed
    /// after `sequence`, oldest change first.
    pub(crate) fn terminal_live_changes_after(
        &self,
        sequence: u64,
    ) -> (u64, Vec<TerminalPublicId>) {
        self.terminal_live.changed_after(sequence)
    }

    /// Like `wait_for_journal_event_until_interrupted`, and it returns too
    /// when the live sequence is not `live`. Returns the epoch and the live
    /// sequence it saw.
    pub(crate) fn wait_for_session_event_until_interrupted(
        &self,
        epoch: u64,
        live: u64,
        interrupt: &crate::stream_interrupt::StreamInterrupt,
    ) -> (u64, u64) {
        let mut current = self.journal_event_epoch.lock().unwrap_or_else(PoisonError::into_inner);
        while *current == epoch && self.terminal_live.sequence() == live && !interrupt.is_fired() {
            current =
                self.journal_event_changed.wait(current).unwrap_or_else(PoisonError::into_inner);
        }
        (*current, self.terminal_live.sequence())
    }

    /// The record of `terminal` as a terminal upsert carries it, with its
    /// live facts from memory, and the resource revision of the durable
    /// part. `None` when the terminal is closed, is not running or has no
    /// runtime.
    ///
    /// The durable part (lifecycle, launch size, tab ids) is still a
    /// registry read, because the wire value of a terminal upsert is the
    /// whole record. With `reader` (an on-disk registry) it is one read
    /// transaction on the stream's own read-only connection and takes no
    /// registry lock. Without one (an in-memory registry, or a reader that
    /// failed) it reads under the registry lock.
    pub(crate) fn live_terminal_upsert(
        &self,
        reader: Option<&SessionJournalReader>,
        terminal: &TerminalPublicId,
    ) -> anyhow::Result<Option<(u64, Value)>> {
        let rows = match reader {
            Some(reader) => reader.live_terminal(terminal)?,
            None => self
                .workspace_registry
                .lock()
                .unwrap_or_else(PoisonError::into_inner)
                .live_terminal(terminal)?,
        };
        let Some(durable) = rows.durable else { return Ok(None) };
        if durable.lifecycle != TerminalLifecycle::Running {
            return Ok(None);
        }
        let Some(surface) = self.terminal_resource_surface(terminal) else { return Ok(None) };
        let tabs = terminal_tab_ids_in_canonical_order(
            rows.tabs
                .into_iter()
                .map(|tab| (terminal.clone(), tab.pane_id, tab.position, tab.public_id)),
        )
        .remove(terminal)
        .unwrap_or_default();
        let value = public_terminal_snapshot(terminal, &durable, Some(&surface), tabs)?;
        Ok(Some((rows.revision, value)))
    }
}
