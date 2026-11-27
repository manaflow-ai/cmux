//! Window record ids (`window-records-v1`, `install/window`) as the closed history reads them
//! (`DaemonClosedHistory.recordID`, `CloudInstallIDs.windowID`, the window id a reopened
//! window comes back with) and which closed window a delete lets go (`releaseWindow`).

use crate::item::{ClosedItem, Kind};

/// This install's window record id of window `window` (`recordID(window:in:)`): `install/window`,
/// None without an install id.
pub fn record_id(install: Option<&str>, window: &str) -> Option<String> {
    install.map(|install| format!("{install}/{window}"))
}

/// The window of this app a window record names (`CloudInstallIDs.windowID`): the rest of
/// `recorded` after the first of `installs` it starts with followed by `/`; None when it is
/// another install's.
pub fn window_id(recorded: &str, installs: &[String]) -> Option<String> {
    installs.iter().find_map(|install| {
        recorded
            .strip_prefix(install.as_str())
            .and_then(|rest| rest.strip_prefix('/'))
            .map(str::to_owned)
    })
}

/// The window id a reopened window's record (`ReopenedItem.window`) names: Swift's
/// `split(separator: "/", maxSplits: 1).last`, which skips empty pieces, so `abc/` reads
/// `abc`, `/w` reads `w`, `i//w` reads `/w` and an empty record reads None.
pub fn reopened_window_id(record: &str) -> Option<String> {
    split_once_omitting_empty(record, '/').pop()
}

/// `split(separator:maxSplits: 1)` with `omittingEmptySubsequences` (Swift's default): empty
/// pieces neither show nor count towards the one split.
pub fn split_once_omitting_empty(text: &str, separator: char) -> Vec<String> {
    let mut pieces: Vec<String> = Vec::new();
    let mut start = 0usize;
    for (index, ch) in text.char_indices() {
        if ch != separator {
            continue;
        }
        let piece = text.get(start..index).unwrap_or_default();
        start = index + ch.len_utf8();
        if !piece.is_empty() {
            pieces.push(piece.to_owned());
            if pieces.len() == 1 {
                break;
            }
        }
    }
    if let Some(rest) = text.get(start..).filter(|rest| !rest.is_empty()) {
        pieces.push(rest.to_owned());
    }
    pieces
}

/// The closed window a deleted `item` lets go (`releaseWindow`): a window item on this Mac's
/// daemon whose record names one of this app's windows. Nothing could reopen its workspaces
/// otherwise.
pub fn released_window(item: &ClosedItem, local: bool, installs: &[String]) -> Option<String> {
    if item.kind != Kind::Window || !local {
        return None;
    }
    window_id(item.window.as_deref()?, installs)
}
