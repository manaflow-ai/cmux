//! Terminal find: the matches of a query in a terminal's retained rows, for Cmd-F in every
//! cmux terminal (the Mac and iPhone find bars, through the daemon's `terminal-find` command).
//!
//! Leo, 2026-11-24: "can we have better cmd f find for terminal gui chats? ... it doesnt have to
//! merely search the screen. but searching recent stuff is good..."
//!
//! What it does, and why here:
//!
//! - [`Matcher`] compiles a query with the bar's three toggles: case, whole word and regular
//!   expression. A plain query is a literal, so `a.b` finds `a.b` and not `axb`. A bad pattern
//!   is an error the bar shows, never a panic or an empty result that reads as "no matches".
//! - [`scan_page`] walks rows from the bottom up, newest first, joining soft-wrapped rows into
//!   one logical line so a word the terminal wrapped is still found, and maps each match back
//!   to the screen cells it covers (wide characters and their spacer cells included), which is
//!   what a find bar scrolls to and selects.
//! - It reads rows through a callback, a bounded page at a time, so the caller takes the
//!   terminal's lock for one chunk of rows and never for the whole history: output keeps
//!   flowing while a 100 000-row scrollback is searched. Each page ends on a logical line's
//!   first row, so the next page starts clean with no state carried between calls.
//! - [`find_in_lines`] runs the same matcher over plain text lines (persisted output and
//!   transcript text past the scrollback), newest line first.
//!
//! No I/O, no clock, no terminal: the daemon supplies the rows.

mod lines;
mod matcher;
mod rows;

pub use lines::{LineMatch, find_in_lines};
pub use matcher::{FindError, FindOptions, Matcher};
pub use rows::{Cell, CellRole, Page, RowCells, ScreenMatch, ScreenPoint, scan_page};

/// The most matches one find reports; past it the result says `truncated`. It bounds the work
/// a one-letter query costs on a long history ("e" in 100 000 rows).
pub const MATCH_CAP: usize = 10_000;

/// The longest snippet a match carries, in characters, centered on the match.
pub const SNIPPET_CHARS: usize = 160;

#[cfg(test)]
mod tests;
