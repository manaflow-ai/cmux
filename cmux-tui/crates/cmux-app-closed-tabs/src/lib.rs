//! The cmux NEXT app's closed tabs feed rules, ported from its Swift (swift-out step A,
//! cmuxterm-hq docs/rfd/drafts/why-swift.md). The daemon owns the closed history
//! (`closed-history-v2`); the app keeps no copy and reads it through these rules:
//!
//! - [`item`]: a daemon closed item (`ClosedItemSnapshot`) as the app decodes it
//!   (`CmuxNextDaemon.ClosedItem`), and every tab it would recreate.
//! - [`reading`]: how an item reads in History and Recently Closed (`DaemonClosedItem`): its
//!   kind, agent chat, shown tab, real text and whether it is worth reopening.
//! - [`listing`]: every machine's items newest first (`DaemonClosedHistory.entries`), lookups by
//!   id and group, whether any machine serves the history, and Cmd-Shift-T's pick
//!   (`DaemonClosedHistory.newest`, its owner facts).
//! - [`history`]: the History rows (`HistoryService.closedEntries`, `daemonClosedText`) and the
//!   history ids (`DaemonClosedHistory.historyID`, `daemonID(fromHistoryID:)`).
//! - [`new_tab`]: the New Tab page's Recently Closed rows (`NewTabClosed.items`, `kind`, `title`).
//! - [`records`]: window record ids (`recordID`, `CloudInstallIDs.windowID`) and which closed
//!   window a delete or clear lets go (`releaseWindow`).
//! - [`reopen`]: what a reopen shows once the daemon answered, how its failure reads, how a
//!   delete's failure reads and what Clear History clears (`reopen`, `show`, `delete`, `clear`).
//! - [`feed`]: the feed's change signature (`ClosedTabsFeed.signature`).
//! - [`undo`]: the undo toast's glue (`CloseUndoToasts`): the daemon item diff, the recent
//!   items ring, the rate limit, the toast's message, the reopen order and the waiting summary.
//!
//! The page-once rule, the owner rule and the undo reducer were already Rust (cmux-window-rules
//! `closed`); this crate calls them rather than copying them. [`ops`] serves everything over the
//! app FFI's JSON channel (cmux-layout-reducer-ffi, ops `closed_tabs_*`).

pub mod feed;
pub mod history;
pub mod item;
pub mod listing;
pub mod new_tab;
pub mod ops;
pub mod reading;
pub mod records;
pub mod reopen;
pub mod undo;
