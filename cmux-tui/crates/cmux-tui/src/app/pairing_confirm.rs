//! The keys of the trusted pairing dialog. Approval is explicit: Enter
//! does not approve (the Enter that ends a command line typed as the dialog
//! appears must not admit a browser), and neither do shell chords such as
//! Ctrl+Y (yank) or Alt+Y. Only a plain `y` (or the Approve button) does,
//! and only where approval is possible at all ([`can_approve`]).

use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use super::OrderedSession;

/// Whether this TUI can approve a pairing: only the TUI that runs the
/// daemon (or the verified app) may (cx-ehrq). An attached TUI may deny.
pub(crate) fn can_approve(session: &OrderedSession) -> bool {
    !session.remote
}

/// `Some(true)` approves, `Some(false)` denies, `None` leaves the dialog.
pub(super) fn decision(key: &KeyEvent, session: &OrderedSession) -> Option<bool> {
    let chord =
        key.modifiers.intersects(KeyModifiers::CONTROL | KeyModifiers::ALT | KeyModifiers::SUPER);
    match key.code {
        KeyCode::Char('y' | 'Y') if !chord && can_approve(session) => Some(true),
        KeyCode::Esc => Some(false),
        KeyCode::Char('n' | 'N') if !chord => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests;
