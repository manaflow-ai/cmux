//! The cmux NEXT app's error journal rules (Swift `CmuxNextErrorJournal` moved here): what is
//! kept of each problem the app, its daemons, its pages and the system report, and how.
//!
//! The app does the I/O (segment files, the unified log, crash report files, cursors, timers, the
//! page console's script) and calls these rules through the app FFI's JSON channel
//! (cmux-layout-reducer-ffi `src/error_journal.rs`, ops in [`ops`]).
//!
//! - [`redact`]: the redactor (secrets, tokens, credentials in assignments and query strings) and
//!   its rules digest, which stamps every journal line.
//! - [`normalize`]: a message's template (values replaced by placeholders).
//! - [`fingerprint`]: a problem's identity.
//! - [`entry`]: events, entries and journal lines.
//! - [`journal`]: folding, the storm cap, eviction, flush, append-or-compact, migration, clear.
//! - [`query`]: queries and Copy Logs' report text.
//! - [`log_parser`] and [`sources`]: daemon logs, crash reports, the unified log and the page
//!   console.

pub mod entry;
pub mod fingerprint;
pub mod journal;
pub mod log_parser;
pub mod normalize;
pub mod ops;
pub mod query;
pub mod redact;
pub mod sources;
pub mod text;

pub use entry::{Entry, Event, Level};
pub use fingerprint::fingerprint;
pub use journal::{AfterWrite, FlushAdvice, Journal, Limits, Purpose, Write, WriteMode, Written};
pub use ops::{ErrorJournals, OpError};
pub use query::{Order, Query, report_text};
pub use redact::Redactor;

#[cfg(test)]
mod tests;
