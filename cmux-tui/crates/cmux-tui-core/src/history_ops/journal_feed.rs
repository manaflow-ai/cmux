//! Folds the session journal into the agent and command history as records
//! are committed. One thread per session waits on the journal kernel's
//! commit epoch (no timeout, so it never polls) and folds every record after
//! its cursor; reads also catch up first, so a session without the shared
//! journal still answers with every committed record. The thread holds only
//! a weak mux reference and ends when the session shuts down or drops.
//!
//! The thread starts with the first history read of those kinds, not with
//! the session: a session that never serves history (most tests, a
//! reopened registry) never has a second holder that could outlive its
//! last owner by a fold.

use std::sync::{Arc, Weak};

use cmux_history::{COMMAND_JOURNAL_KIND, HistoryKind};
use serde_json::Value;

use crate::Mux;
use crate::journal_kernel::SharedJournalRead;
use crate::workspace_registry::SessionJournalRecord;

const PAGE: usize = 512;

/// True for a record kind one of the folds reads.
fn folded(kind: &str) -> bool {
    kind.starts_with("agent.") || kind == COMMAND_JOURNAL_KIND
}

/// The history kind a folded record changes.
fn kind_of(record: &SessionJournalRecord) -> HistoryKind {
    if record.kind == COMMAND_JOURNAL_KIND { HistoryKind::Command } else { HistoryKind::Agent }
}

/// One page after `cursor`: the folded records as JSON and the last
/// sequence scanned (`cursor` when nothing is new).
fn page(mux: &Mux, cursor: u64) -> anyhow::Result<(Vec<(HistoryKind, Value)>, u64)> {
    let mut scanned = cursor;
    let mut records = Vec::new();
    let mut take = |record: &SessionJournalRecord| -> anyhow::Result<()> {
        scanned = scanned.max(record.sequence);
        if folded(&record.kind) {
            records.push((kind_of(record), serde_json::to_value(record)?));
        }
        Ok(())
    };
    match mux.shared_journal_after(cursor, PAGE) {
        SharedJournalRead::Page(page) => {
            for document in &page.records {
                take(&document.record)?;
            }
            scanned = scanned.max(page.scanned_through.min(page.head_sequence));
        }
        SharedJournalRead::Gap { .. } | SharedJournalRead::Unavailable => {
            for record in &mux.session_journal_after(cursor, PAGE)?.records {
                take(record)?;
            }
        }
    }
    Ok((records, scanned))
}

/// Folds every committed record after the module's cursor. Returns the kinds
/// that changed.
pub(super) fn catch_up(mux: &Mux) -> anyhow::Result<Vec<HistoryKind>> {
    let mut changed = Vec::new();
    loop {
        let cursor = mux.history.cursor();
        let (records, scanned) = page(mux, cursor)?;
        if scanned <= cursor {
            return Ok(changed);
        }
        for kind in mux.history.fold(cursor, scanned, &records) {
            if !changed.contains(&kind) {
                changed.push(kind);
            }
        }
    }
}

/// Starts the session's history feed once, when the shared journal is on.
pub(super) fn start(mux: &Arc<Mux>) {
    if !mux.shared_journal_enabled() || mux.daemon_shutdown_requested() {
        return;
    }
    if !mux.history.claim_feed() {
        return;
    }
    let weak = Arc::downgrade(mux);
    let kernel = mux.shared_journal_handle();
    let spawned = std::thread::Builder::new()
        .name("mux-history-feed".into())
        .spawn(move || run(&weak, &kernel));
    if let Err(error) = spawned {
        eprintln!("cmux-tui: history feed did not start: {error}");
        mux.history.release_feed();
    }
}

fn run(weak: &Weak<Mux>, kernel: &crate::journal_kernel::JournalKernel) {
    let mut epoch = kernel.epoch();
    loop {
        {
            let Some(mux) = weak.upgrade() else { return };
            if mux.daemon_shutdown_requested() {
                return;
            }
            match catch_up(&mux) {
                Ok(changed) if !changed.is_empty() => mux.history.changed(&mux, &changed),
                Ok(_) => {}
                Err(error) => eprintln!("cmux-tui: history feed read failed: {error:#}"),
            }
        }
        epoch = kernel.wait_until(epoch, None);
    }
}
