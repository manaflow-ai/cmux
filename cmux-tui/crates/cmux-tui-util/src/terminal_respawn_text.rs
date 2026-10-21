//! The words a respawned terminal (cx-6so.49 L2) or a reopened archived
//! terminal (ARCHIVE-1) shows: one dim line under the previous screen,
//! before the new shell's first prompt.
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
    /// The marker of a respawned terminal that ran a command which does not
    /// run again; `{program}` is its command line, else its program name.
    pub restored_command: &'static str,
    /// The marker of a respawned terminal that ran an agent session;
    /// `{command}` is the command that resumes it.
    pub restored_agent: &'static str,
    /// The line under a reopened tab's archived screen when its close
    /// stopped a running program; `{program}` is the program's name.
    pub stopped: &'static str,
    /// Name of the workspace that holds terminals whose hosts outlived the
    /// owner's registry (cx-0tgl LC).
    pub recovered_workspace: &'static str,
}

/// The English text, used until [`install`] runs.
pub const ENGLISH: TerminalRespawnText = TerminalRespawnText {
    restored: "\u{2014} session restored (previous process ended) \u{2014}",
    restored_command: "\u{2014} session restored (previous process ended; it ran {program}) \u{2014}",
    restored_agent: "\u{2014} session restored; resume with {command} \u{2014}",
    recovered_workspace: "Recovered terminals",
    stopped: "\u{2014} {program} was stopped when this tab closed \u{2014}",
};

static TEXT: OnceLock<&'static TerminalRespawnText> = OnceLock::new();

/// Install the daemon's localized text. The first call wins.
pub fn install(text: &'static TerminalRespawnText) {
    let _ = TEXT.set(text);
}

pub fn text() -> &'static TerminalRespawnText {
    TEXT.get().copied().unwrap_or(&ENGLISH)
}

/// The longest command a marker line shows, in characters.
const MARKER_COMMAND_CHARS: usize = 200;

/// What a respawned terminal ran, for its marker line.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ran<'a> {
    /// A command (its command line, else its program name); it does not run
    /// again.
    Command(&'a str),
    /// An agent session; the command that resumes it.
    Agent(&'a str),
}

/// The marker line for a terminal that ran `ran`, else the plain one.
/// Control characters are dropped and a long command is cut with `…`.
pub fn marker(ran: Option<Ran<'_>>) -> String {
    let text = text();
    let clean = |command: &str| {
        let command = command.chars().filter(|c| !c.is_control()).collect::<String>();
        if command.chars().count() > MARKER_COMMAND_CHARS {
            command.chars().take(MARKER_COMMAND_CHARS - 1).chain(['\u{2026}']).collect()
        } else {
            command
        }
    };
    match ran {
        Some(Ran::Command(command)) if !clean(command).is_empty() => {
            text.restored_command.replace("{program}", &clean(command))
        }
        Some(Ran::Agent(command)) if !clean(command).is_empty() => {
            text.restored_agent.replace("{command}", &clean(command))
        }
        _ => text.restored.to_string(),
    }
}

/// The line under a reopened tab's archived screen whose close stopped
/// `program`. Control characters in the name are dropped.
pub fn stopped_marker(program: &str) -> String {
    let program = program.chars().filter(|c| !c.is_control()).collect::<String>();
    text().stopped.replace("{program}", &program)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_marker_names_a_command_without_its_control_characters() {
        assert_eq!(marker(None), ENGLISH.restored);
        assert_eq!(
            marker(Some(Ran::Command("ca\u{1b}t -n"))),
            "\u{2014} session restored (previous process ended; it ran cat -n) \u{2014}"
        );
        assert_eq!(marker(Some(Ran::Command("\u{7}"))), ENGLISH.restored);
        assert_eq!(
            marker(Some(Ran::Agent("claude --resume a1"))),
            "\u{2014} session restored; resume with claude --resume a1 \u{2014}"
        );
        let long = marker(Some(Ran::Command(&"x".repeat(500))));
        assert!(long.contains(&format!("{}\u{2026}", "x".repeat(MARKER_COMMAND_CHARS - 1))));
    }

    #[test]
    fn the_stopped_marker_names_the_program_without_control_characters() {
        assert_eq!(
            stopped_marker("sle\u{1b}ep"),
            "\u{2014} sleep was stopped when this tab closed \u{2014}"
        );
    }
}
