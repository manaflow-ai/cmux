//! The cmux history read model.
//!
//! Owner role: the daemon history module owns page visits and the merged
//! history read model (R62, decided 2026-10-04; plans/cmux-next/react-pages.md
//! section 2.2 and plans/cmux-next/history.md section 2). This crate is that
//! module's data layer. The daemon module wires it to ops
//! (`cmux.history.*`); this crate has no ops, no sockets and no clock.
//!
//! What lives here:
//!
//! - [`HistoryEntry`], the wire row every history surface shows (the React
//!   page, the palette, `cmux history list`, MCP).
//! - [`HistoryQuery`], the pure filter: entry kinds, a time range, search
//!   tokens folded for case, diacritics and width, and a limit. The caller
//!   supplies the time and the local start of today, so nothing here needs a
//!   time zone. Directory checks for `file:` URLs come in as a predicate, so
//!   the query does no file IO.
//! - [`AgentSessionFold`] and [`TerminalCommandFold`], which fold session
//!   journal records (`agent.*`, `shell.command.finished`) into entries. The
//!   session host owns those facts; the folds are projections that never
//!   count a record twice.
//! - [`HiddenHistory`], the hides of journal entries that the append-only
//!   journal cannot delete (Clear History, Remove from History). One writer:
//!   the daemon module.
//! - [`VisitStore`] and [`VisitStores`], the per browser profile SQLite page
//!   visit log. The app reports each finished main-frame navigation; this
//!   store is the only writer of page history.
//!
//! The location trail is client view state and stays with the app; this
//! crate only reads it as entries the caller builds.
//!
//! Every function here is ported from the Swift module `CmuxNextHistory`
//! (`Packages/macOS/CmuxNext/Sources/CmuxNextHistory`). The JSON fixtures in
//! `tests/fixtures/` are shared, so the Swift tests can adopt them.

mod entry;
mod error;
mod fold;
mod fold_agent;
mod fold_command;
mod hidden;
mod journal;
mod query;
mod visit_stores;
mod visits;

pub use entry::{ClosedKind, HistoryEntry, HistoryKind};
pub use error::HistoryError;
pub use fold::{fold, tokens};
pub use fold_agent::{
    AGENT_JOURNAL_KINDS, AgentSession, AgentSessionFold, agent_title, provider_name,
    resume_command, shell_quoted,
};
pub use fold_command::{COMMAND_JOURNAL_KIND, TerminalCommand, TerminalCommandFold};
pub use hidden::{HiddenHistory, HiddenRange, hidden_id};
pub use journal::EntryContext;
pub use query::{HistoryQuery, HistoryRange, apply, is_displayable, matches, search_text};
pub use visit_stores::{Removal, VisitStores, profile_file_name, profile_from_file_name};
pub use visits::{MAX_VISITS, NewVisit, RETENTION_MS, Visit, VisitStore, VisitSummary};
