//! The notifications panel's keyboard selection: it moves with the arrows,
//! stays on the same notification across reloads, and falls back to the
//! row now at its old index when that one leaves. Moved from the app's
//! `NotificationsPanelSelection`. Rows are the daemon ledger's ids, newest
//! first.

/// The row an arrow press selects: `offset` rows from `selected`, kept in
/// the list; from no selection (or one no longer listed) the last row going
/// up and the first going down. None when there are no rows.
pub fn move_selection(selected: Option<&str>, offset: i64, rows: &[String]) -> Option<String> {
    let last = rows.len().checked_sub(1)?;
    let next = match selected.and_then(|id| rows.iter().position(|row| row == id)) {
        Some(current) => {
            let current = i64::try_from(current).unwrap_or(i64::MAX);
            usize::try_from(current.saturating_add(offset).max(0)).unwrap_or(usize::MAX).min(last)
        }
        None if offset < 0 => last,
        None => 0,
    };
    rows.get(next).cloned()
}

/// The selection after a reload from `old` to `new`: its row when it is
/// still listed, else the row now at its old index (the last when the list
/// got shorter), else none.
pub fn reconcile_selection(
    selected: Option<&str>,
    old: &[String],
    new: &[String],
) -> Option<String> {
    let id = selected?;
    if new.iter().any(|row| row == id) {
        return Some(id.to_owned());
    }
    let index = old.iter().position(|row| row == id)?;
    new.get(index.min(new.len().checked_sub(1)?)).cloned()
}

#[cfg(test)]
#[path = "notifications_panel_tests.rs"]
mod tests;
