//! Folds the session journal into the agent history as records are
//! committed, and notices commits that changed the closed-history store
//! (a closed workspace, tab or group, or a deleted one), so `history-changed`
//! names the Closed kind and an open History page re-reads (cx-hnmbt.9). One thread per session waits on the journal kernel's
//! commit epoch (no timeout, so it never polls) and folds every record after
//! its cursor; reads also catch up first, so a session without the shared
//! journal still answers with every committed record. The thread holds only
//! a weak mux reference and ends when the session shuts down or drops.
//!
//! The thread starts with the first history read of those kinds, not with
//! the session: a session that never serves history (most tests, a
//! reopened registry) never has a second holder that could outlive its
//! last owner by a fold.
//!
//! Cost on a long-running daemon (CLI agent papercuts item 5): the journal
//! is mostly terminal output in sealed gzip segments (gigabytes), and the
//! fold used to start at sequence 0 on every daemon start and inflate all
//! of it, page by page under the registry lock, while a list waited (`cmux
//! history list` past its timeout, the daemon near 100% CPU). Now the fold
//! resumes from its saved cursor (merged.rs `restore`/`save`), a read past
//! the in-memory journal skips terminal output and output-only segments,
//! the feed and a list take turns page by page instead of both reading the
//! same pages, and a list stops folding after its budget.

use std::sync::{Arc, Weak};
use std::time::Instant;

use cmux_history::HistoryKind;
use serde_json::Value;

use crate::Mux;
use crate::journal_kernel::SharedJournalRead;
use crate::workspace_registry::SessionJournalRecord;

const PAGE: usize = 512;

/// True for a record kind the agent fold reads. Finished commands are not
/// folded: the merged history lists the terminal command rows, and the
/// command worker announces them (cx-hnmbt.12).
fn folded(kind: &str) -> bool {
    kind.starts_with("agent.")
}

/// True for a resource commit that upserted or deleted a closed item
/// (`state_upsert`/`state_delete` of resource `closed` in its changes).
fn changes_closed(record: &SessionJournalRecord) -> bool {
    record.payload["changes"].as_array().is_some_and(|changes| {
        changes.iter().any(|change| {
            change["resource"] == "closed"
                && matches!(change["kind"].as_str(), Some("state_upsert" | "state_delete"))
        })
    })
}

/// One page after `cursor`: the folded records as JSON (a closed-history
/// change as a `Closed` marker with no body) and the last sequence scanned
/// (`cursor` when nothing is new).
fn page(mux: &Mux, cursor: u64) -> anyhow::Result<(Vec<(HistoryKind, Value)>, u64)> {
    let mut scanned = cursor;
    let mut records = Vec::new();
    let mut take = |record: &SessionJournalRecord| -> anyhow::Result<()> {
        scanned = scanned.max(record.sequence);
        if folded(&record.kind) {
            records.push((HistoryKind::Agent, serde_json::to_value(record)?));
        } else if changes_closed(record) {
            records.push((HistoryKind::Closed, Value::Null));
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
            // Past the in-memory journal: neither fold reads terminal
            // output, so skip it (and the sealed segments that hold only
            // output) instead of inflating it.
            // Read on a reader of our own, never through the registry, whose
            // lock every write takes.
            let (behind, reached) = match mux.shared_journal_handle().open_reader()? {
                Some(reader) => {
                    let head = reader.head()?;
                    reader.without_output_after(cursor, head, PAGE)?
                }
                // An in-memory registry has no file to open.
                None => {
                    let head = mux.session_journal_head()?;
                    mux.session_journal_without_output_after(cursor, head, PAGE)?
                }
            };
            for record in &behind {
                take(record)?;
            }
            scanned = scanned.max(reached);
        }
    }
    Ok((records, scanned))
}

/// What one [`catch_up`] did.
pub(super) struct CaughtUp {
    /// The kinds that changed.
    pub(super) changed: Vec<HistoryKind>,
    /// The fold reached the journal head (false: the deadline came first).
    pub(super) complete: bool,
}

/// Folds every committed record after the module's cursor, or until
/// `deadline`, one page per turn, then saves the agent fold when it moved
/// (merged.rs `save`).
pub(super) fn catch_up(mux: &Mux, deadline: Option<Instant>) -> anyhow::Result<CaughtUp> {
    let mut changed = Vec::new();
    let complete = loop {
        if deadline.is_some_and(|deadline| Instant::now() >= deadline) {
            break false;
        }
        let turn = mux.history.turn();
        mux.history.restore(mux);
        let cursor = mux.history.cursor();
        let (records, scanned) = match page(mux, cursor) {
            Ok(page) => page,
            Err(error) => {
                mux.history.save(mux);
                return Err(error);
            }
        };
        if scanned <= cursor {
            mux.history.save(mux);
            break true;
        }
        for kind in mux.history.fold(cursor, scanned, &records) {
            if !changed.contains(&kind) {
                changed.push(kind);
            }
        }
        mux.history.save(mux);
        drop(turn);
    };
    Ok(CaughtUp { changed, complete })
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
            match catch_up(&mux, None) {
                Ok(caught) if !caught.changed.is_empty() => {
                    mux.history.changed(&mux, &caught.changed);
                }
                Ok(_) => {}
                Err(error) => eprintln!("cmux-tui: history feed read failed: {error:#}"),
            }
        }
        epoch = kernel.wait_until(epoch, None);
    }
}

#[cfg(test)]
#[path = "journal_feed_tests.rs"]
mod tests;
