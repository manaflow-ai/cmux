//! The JSON parses of one request line: every decode of a
//! line on its way to its reply goes through [`parse`], which counts it in
//! the reader thread's [`LineParses`] scope. The frame handler opens the
//! scope around a local line and reports the count as the trace instant
//! `daemon.frame.json_parses` (spec/commands.md), the
//! `json_parses_per_request` of the p05-ipc plan. Like the request-path
//! notes (`crate::request_path`), a parse is counted at the code that
//! starts it, so the count cannot drift from what the handlers really do.
//! Outside a scope [`parse`] counts nothing.

use std::cell::Cell;
use std::marker::PhantomData;

use serde::Deserialize;

thread_local! {
    static PARSES: Cell<Option<u32>> = const { Cell::new(None) };
}

/// Decodes `line` as JSON, counted in this thread's scope and in the open
/// `server-stats` `ipc` request scope (`crate::diagnostics::JsonParseScope`).
pub(crate) fn parse<'a, T: Deserialize<'a>>(line: &'a str) -> serde_json::Result<T> {
    PARSES.with(|parses| {
        if let Some(count) = parses.get() {
            parses.set(Some(count.saturating_add(1)));
        }
    });
    crate::diagnostics::note_json_parse();
    serde_json::from_str(line)
}

/// The parses of this thread's open [`LineParses`] scope so far (0 outside
/// one), for a line that leaves this thread with them.
pub(crate) fn current() -> u32 {
    PARSES.with(Cell::get).unwrap_or(0)
}

/// Counts this thread's [`parse`] calls until dropped, then restores the
/// outer scope's count. Not `Send`: it ends on the thread it began.
#[must_use = "parses are counted only while the scope lives"]
pub(crate) struct LineParses {
    outer: Option<u32>,
    _not_send: PhantomData<*const ()>,
}

impl LineParses {
    pub(crate) fn enter() -> Self {
        Self::resume(0)
    }

    /// The scope of a line that already took `parses` on another thread
    /// (the reader that queued it on its connection's control sequence).
    pub(crate) fn resume(parses: u32) -> Self {
        let outer = PARSES.with(|count| count.replace(Some(parses)));
        Self { outer, _not_send: PhantomData }
    }

    /// The parses counted so far in this scope.
    pub(crate) fn count(&self) -> u32 {
        PARSES.with(Cell::get).unwrap_or(0)
    }
}

impl Drop for LineParses {
    fn drop(&mut self) {
        PARSES.with(|parses| parses.set(self.outer));
    }
}
