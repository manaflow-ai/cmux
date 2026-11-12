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
pub(crate) fn agent_identity_edits(
    _getenv: impl Fn(&str) -> Option<OsString>,
) -> Vec<IdentityEdit> {
    Vec::new()
}

/// Applies [`agent_identity_edits`] for this process's environment to `command`.
pub(crate) fn apply(command: &mut std::process::Command) {
    for edit in agent_identity_edits(|key| std::env::var_os(key)) {
        match edit {
            IdentityEdit::Set(key, value) => {
                command.env(key, value);
            }
            IdentityEdit::Remove(key) => {
                command.env_remove(key);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<OsString> {
        move |key| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| OsString::from(*v))
    }

    #[test]
    fn an_agent_in_a_cmux_terminal_sees_ghostty_without_a_version() {
        let edits = agent_identity_edits(env(&[
            ("TERM_PROGRAM", "cmux"),
            ("TERM_PROGRAM_VERSION", "1.0.0"),
        ]));
        assert_eq!(
            edits,
            vec![
                IdentityEdit::Set("TERM_PROGRAM", "ghostty"),
                IdentityEdit::Remove("TERM_PROGRAM_VERSION")
            ]
        );
    }

    #[test]
    fn an_agent_outside_cmux_keeps_its_terminal_identity() {
        assert!(
            agent_identity_edits(env(&[
                ("TERM_PROGRAM", "iTerm.app"),
                ("TERM_PROGRAM_VERSION", "3.6")
            ]))
            .is_empty()
        );
        assert!(agent_identity_edits(env(&[])).is_empty());
    }
}
