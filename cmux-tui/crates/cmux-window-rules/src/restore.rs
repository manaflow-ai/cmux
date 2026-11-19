//! Which saved windows a launch makes before its front window is live
//! (cmuxterm-hq `docs/design/launch-shell-first.md`, stage 1: only what is
//! visible). The front window is made with the restore; every other saved
//! open window waits until the front window's frame is on screen, then comes
//! back one per main-thread turn, front to back, at its saved place.

use serde::{Deserialize, Serialize};

/// One saved window, in the registry's recency order (front first).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SavedWindow {
    pub id: String,
    /// Open in the saved registry (a closed one is never restored).
    pub open: bool,
    /// Already has its window (the launch window that took its identity).
    pub made: bool,
}

/// The windows the restore makes now and the ones that wait for their turn.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Order {
    /// The window shown first: `adopted` when the launch window became one,
    /// else the front open window. None when no saved window is open.
    pub front: Option<String>,
    /// Open windows but the front one with no window yet, front to back.
    pub later: Vec<String>,
}

/// The restore's order for `windows` (recency order, front first). `adopted`
/// is the saved window the launch window became, when it became one.
pub fn order(windows: &[SavedWindow], adopted: Option<&str>) -> Order {
    let front = adopted
        .filter(|id| windows.iter().any(|w| w.id == *id && w.open))
        .map(str::to_owned)
        .or_else(|| windows.iter().find(|w| w.open).map(|w| w.id.clone()));
    let later = windows
        .iter()
        .filter(|w| w.open && !w.made && Some(&w.id) != front.as_ref())
        .map(|w| w.id.clone())
        .collect();
    Order { front, later }
}

#[cfg(test)]
#[path = "restore_tests.rs"]
mod tests;
