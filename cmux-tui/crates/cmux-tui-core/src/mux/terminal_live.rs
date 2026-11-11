//! Live terminal facts: an OSC 9;4 progress, the "last output" time and a
//! program status report that keeps its record's state and kind (a new
//! progress number of the shown record too).
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
//!
//! Two readers need the rows: a journal stream that follows
//! `terminal.progress` or `terminal.program_status` (an agent plugin's wake
//! for a terminal that prints, `spec/plugins.md`), and an enabled journal
//! hook whose kinds match one of them (a hook is delivered every row its
//! filter matches). While such a stream is live
//! (`Mux::follow_terminal_progress_rows`) or such a hook is installed, a
//! live fact is one commit, as it was. A stream reads every terminal after
//! it subscribes, so a live fact from before its subscription needs no row.

use super::*;
use crate::resource_api::{public_terminal_snapshot, terminal_tab_ids_in_canonical_order};
use crate::workspace_registry::SessionJournalReader;
use std::collections::{BTreeMap, HashMap};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

/// The journal kinds a live fact was before it left the journal: a stream
/// that follows one of them still gets the rows.
const LIVE_FACT_KINDS: [&str; 2] = ["terminal.progress", "terminal.program_status"];

/// The terminals whose live facts changed, in the order of their newest
/// change. One entry per terminal: a new change replaces the terminal's
/// older entry, so a stream that reads the entries after the sequence it
/// has seen does work in proportion to the terminals that changed.
pub(super) struct TerminalLiveLog {
    /// Names this log (this daemon process) in a stream cursor's live
    /// position: a sequence of another process says nothing here.
    epoch: String,
    sequence: AtomicU64,
    changes: Mutex<LiveChanges>,
    /// The live journal streams that follow the rows of live facts.
    journal_followers: Arc<AtomicUsize>,
    /// Whether an enabled journal hook's kind filter matches the rows of
    /// live facts; `None` until read, and after a hook changed.
    journal_hook_reads_rows: Mutex<Option<bool>>,
}

impl Default for TerminalLiveLog {
    fn default() -> Self {
        let mut epoch = crate::workspace_registry::new_uuid_v4().replace('-', "");
        epoch.truncate(16);
        Self {
            epoch,
            sequence: AtomicU64::new(0),
            changes: Mutex::default(),
            journal_followers: Arc::default(),
            journal_hook_reads_rows: Mutex::default(),
        }
    }
}

impl TerminalLiveLog {
    /// The installed journal hooks are about to change. Hold the guard
    /// through the change: a live fact that comes meanwhile waits, then
    /// reads the new hooks, so a hook installed now misses no row.
    pub(super) fn journal_hooks_changing(&self) -> MutexGuard<'_, Option<bool>> {
        let mut reads_rows =
            self.journal_hook_reads_rows.lock().unwrap_or_else(PoisonError::into_inner);
        *reads_rows = None;
        reads_rows
    }
}

/// Whether a journal hook's kind filter (`kinds`: exact kinds and
/// `family.*`; none means every kind) matches the rows of live facts.
fn hook_kinds_match_live_fact(kinds: &[String]) -> bool {
    kinds.is_empty()
        || kinds.iter().any(|filter| {
            LIVE_FACT_KINDS.iter().any(|kind| match filter.strip_suffix(".*") {
                Some(family) => kind.strip_prefix(family).is_some_and(|rest| rest.starts_with('.')),
                None => filter == kind,
            })
        })
}

/// One live journal stream whose kind filter can match the rows of live
/// facts (`Mux::follow_terminal_progress_rows`). The stream holds it for its
/// life; its drop ends the count.
pub(crate) struct TerminalProgressFollower {
    followers: Arc<AtomicUsize>,
}

impl Drop for TerminalProgressFollower {
    fn drop(&mut self) {
        self.followers.fetch_sub(1, Ordering::AcqRel);
    }
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

    fn changed_after(&self, sequence: u64) -> (u64, Vec<(u64, TerminalPublicId)>) {
        let changes = self.changes.lock().unwrap_or_else(PoisonError::into_inner);
        let terminals = changes
            .by_sequence
            .range((std::ops::Bound::Excluded(sequence), std::ops::Bound::Unbounded))
            .map(|(sequence, terminal)| (*sequence, terminal.clone()))
            .collect();
        (self.sequence.load(Ordering::Acquire), terminals)
    }
}

impl Mux {
    /// Counts a live journal stream as a reader of the rows of live facts
    /// when its kind filter can match them (`matches_kind`). An agent plugin
    /// that follows `terminal.*` scans a terminal when a row names it
    /// (spec/plugins.md, "Event-driven journal delivery"), and terminal
    /// output is no row: for a terminal that prints, these rows are its
    /// wake. While such a stream lives, a live fact is one commit, as it was
    /// before live facts left the journal. A follower that connects reads
    /// every terminal after its subscribe is answered, so a live fact before
    /// the count needs no row.
    pub(crate) fn follow_terminal_progress_rows(
        &self,
        matches_kind: impl Fn(&str) -> bool,
    ) -> Option<TerminalProgressFollower> {
        if !LIVE_FACT_KINDS.iter().any(|kind| matches_kind(kind)) {
            return None;
        }
        let followers = self.terminal_live.journal_followers.clone();
        followers.fetch_add(1, Ordering::AcqRel);
        Some(TerminalProgressFollower { followers })
    }

    /// Whether the rows of live facts have a reader now: a live journal
    /// stream that follows them (one atomic read), or an enabled journal
    /// hook whose kinds match them.
    pub(crate) fn terminal_progress_rows_followed(&self) -> bool {
        self.terminal_live.journal_followers.load(Ordering::Acquire) > 0
            || self.journal_hook_reads_terminal_progress_rows()
    }

    /// Whether an enabled journal hook is delivered the rows of live facts.
    /// Read from the registry once after a start or a hook change; then one
    /// lock that only a hook change contends.
    fn journal_hook_reads_terminal_progress_rows(&self) -> bool {
        let mut cached = self
            .terminal_live
            .journal_hook_reads_rows
            .lock()
            .unwrap_or_else(PoisonError::into_inner);
        if let Some(reads) = *cached {
            return reads;
        }
        // An unreadable hook list keeps the rows: a hook must not miss one.
        let Ok(states) = self.journal_hook_states() else { return true };
        let reads = states
            .iter()
            .any(|state| state.enabled && hook_kinds_match_live_fact(&state.manifest.filter.kinds));
        *cached = Some(reads);
        reads
    }

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
    /// after `sequence`, each with the sequence of its newest change, oldest
    /// change first.
    pub(crate) fn terminal_live_changes_after(
        &self,
        sequence: u64,
    ) -> (u64, Vec<(u64, TerminalPublicId)>) {
        self.terminal_live.changed_after(sequence)
    }

    /// The live position `sequence` as a stream cursor carries it
    /// (`server/session_event_stream.rs`, `session-live-cursor-v1`): this
    /// process's live epoch and the sequence.
    pub(crate) fn terminal_live_position(&self, sequence: u64) -> String {
        format!("{}.{sequence}", self.terminal_live.epoch)
    }

    /// The live sequence a client's cursor position names, when this
    /// process gave it: its epoch is this log's and its sequence is not
    /// ahead of the log. `None` for a position of another daemon process
    /// (a restart) or a text this process never gave; the stream then sends
    /// every terminal with a live change.
    pub(crate) fn terminal_live_sequence_of(&self, position: &str) -> Option<u64> {
        let (epoch, sequence) = position.rsplit_once('.')?;
        let sequence = sequence.parse::<u64>().ok()?;
        (epoch == self.terminal_live.epoch && sequence <= self.terminal_live.sequence())
            .then_some(sequence)
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
