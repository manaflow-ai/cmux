//! A chat's transcript as rows, folded in the daemon from its event log (hq#9655 stage 2).
//!
//! `rows = fold(events)`: a table of items in the order they began. An item never moves and never
//! leaves the table; a change to it bumps its `rev` and goes out as one patch. Each row has its
//! place (`index`, 0.. with no gap), the record that began it (`seq`), its revision (`rev`), its
//! `kind`, the turn it belongs to (`turn`) and whether a fork can be made at it (`forkable`). A
//! reply's text delta is appended to its row and patched as that delta alone, so streaming a
//! token costs its own length, however long the chat is.
//!
//! Keys: a reply row is keyed by the reply segment acpmux stamps on its chunks
//! (`_meta.acpmux.segment`, `hub/stream.rs`) and, on a log written before the stamp, by the same
//! `<turn>.<n>` id the stamp would have had, counted here; a tool row by its `toolCallId`; a
//! prompt row by its `promptId`. The ids are what the page keys its rows by, so a page that
//! reads rows from any record on draws the same row under the same id.
//!
//! What this module reads is the log alone. It is served as `_acpmux/rows` (`page.rs`) and kept
//! up to date per chat by `serve.rs`; nothing on the page reads it until the page opts in through
//! the `transcript-rows-v1` capability (`capabilities.rs`).

mod fold;
mod page;
mod serve;

#[cfg(test)]
mod bench;
#[cfg(test)]
mod tests;

pub use fold::{Patch, Row, RowHead, RowKind, RowTable};
#[cfg(test)]
pub use fold::{PatchError, RowMirror};
pub use page::{DEFAULT_ROW_PAGE_BYTES, MAX_ROW_PAGE_BYTES, RowPage, RowsCursor};
#[cfg(test)]
pub use serve::held_rows;
pub use serve::{Following, RowsCache, live, read};
