//! The terminal identity a coding agent started from a cmux terminal sees.
//!
//! A cmux terminal says `TERM_PROGRAM=cmux` (`cmux_pty::TERMINAL_IDENTITY`).
//! Claude Code and Codex know no `cmux` terminal: they key desktop
//! notifications (OSC 777 / OSC 9), hyperlinks, the progress bar and their
//! Ghostty quirks on `TERM_PROGRAM=ghostty`, and cmux's `TERM` is
//! `xterm-256color` by default, so `TERM=xterm-ghostty` does not name Ghostty
//! for them either. The `claude` and `codex` wrappers therefore start the agent
//! with the Ghostty identity it was tuned for, without `TERM_PROGRAM_VERSION`:
//! a Ghostty version turns their copy-on-select drag fallback off, and cmux
//! forwards a full-screen TUI's mouse reports instead of Ghostty's native
//! selection (cmux#22585).

use std::ffi::OsString;

/// One change to the agent's environment.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum IdentityEdit {
    Set(&'static str, &'static str),
    Remove(&'static str),
}

/// The edits for an agent whose launching environment reads `getenv`:
/// none outside a cmux terminal.
pub(crate) fn agent_identity_edits(getenv: impl Fn(&str) -> Option<OsString>) -> Vec<IdentityEdit> {
    if getenv("TERM_PROGRAM").is_none_or(|program| program != "cmux") {
        return Vec::new();
    }
    vec![IdentityEdit::Set("TERM_PROGRAM", "ghostty"), IdentityEdit::Remove("TERM_PROGRAM_VERSION")]
}

/// Hands [`agent_identity_edits`] for this process's environment to the
/// agent's launch command: `set(key, Some(value))` sets a key,
/// `set(key, None)` removes it.
pub(crate) fn apply(mut set: impl FnMut(&'static str, Option<&'static str>)) {
    for edit in agent_identity_edits(|key| std::env::var_os(key)) {
        match edit {
            IdentityEdit::Set(key, value) => set(key, Some(value)),
            IdentityEdit::Remove(key) => set(key, None),
        }
    }
}

#[cfg(test)]
mod tests;
