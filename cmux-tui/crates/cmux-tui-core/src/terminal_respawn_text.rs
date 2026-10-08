//! The words a respawned terminal shows (cx-6so.49 L2): one dim line under
//! the previous screen, before the new shell's first prompt.
//!
//! The daemon's binary owns the localization catalog and installs the text
//! of its resolved language with [`install`] before it opens the session;
//! without that (library users, unit tests) the English text is used.

use std::sync::OnceLock;

/// The respawn marker text in one language.
#[derive(Debug, PartialEq, Eq)]
pub struct TerminalRespawnText {
    /// The marker of a respawned terminal.
    pub restored: &'static str,
    /// The marker of a respawned terminal that ran a command which is not
    /// offered again; `{program}` is the command's program name.
    pub restored_command: &'static str,
}

/// The English text, used until [`install`] runs.
pub const ENGLISH: TerminalRespawnText = TerminalRespawnText {
    restored: "\u{2014} session restored (previous process ended) \u{2014}",
    restored_command: "\u{2014} session restored (previous process ended; it ran {program}) \u{2014}",
};

static TEXT: OnceLock<&'static TerminalRespawnText> = OnceLock::new();

/// Install the daemon's localized text. The first call wins.
pub fn install(text: &'static TerminalRespawnText) {
    let _ = TEXT.set(text);
}

pub(crate) fn text() -> &'static TerminalRespawnText {
    TEXT.get().copied().unwrap_or(&ENGLISH)
}

/// The marker line for a terminal that ran `program` (a command that is not
/// pre-filled again), or none. Control characters in the name are dropped.
pub(crate) fn marker(program: Option<&str>) -> String {
    let text = text();
    match program.map(|program| program.chars().filter(|c| !c.is_control()).collect::<String>()) {
        Some(program) if !program.is_empty() => {
            text.restored_command.replace("{program}", &program)
        }
        _ => text.restored.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_marker_names_a_command_without_its_control_characters() {
        assert_eq!(marker(None), ENGLISH.restored);
        assert_eq!(
            marker(Some("ca\u{1b}t")),
            "\u{2014} session restored (previous process ended; it ran cat) \u{2014}"
        );
        assert_eq!(marker(Some("\u{7}")), ENGLISH.restored);
    }
}
