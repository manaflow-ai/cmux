//! The command a respawned terminal offers on its new prompt (cx-6so.49
//! L2), typed without a newline so the user decides whether to run it:
//! - the agent session it last ran, when its harness is known:
//!   `claude --resume <id>` or `codex resume <id>`;
//! - else, for a command terminal this daemon process launched, its argv,
//!   shell-quoted. A later daemon has only the program name, which the
//!   marker line names instead.
//!
//! The text is written once the new shell shows its prompt (OSC 133 marks
//! from shell integration), or once its first output went quiet.

use std::time::{Duration, Instant};

use super::*;
use crate::terminal_loss_log::Prefilled;
use crate::workspace_registry::relaunch_store::{
    RelaunchKind, StoredRelaunch, resumable_session_id,
};

/// The longest wait for the new shell's prompt.
const PROMPT_WAIT: Duration = Duration::from_secs(10);
/// Output quiet this long after the first byte counts as a prompt.
const QUIET: Duration = Duration::from_millis(400);

/// A command to type on the new prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::mux) struct Prefill {
    pub(in crate::mux) kind: Prefilled,
    text: String,
}

impl Prefill {
    /// Wait for the new shell's prompt, then write the text to its input,
    /// never a newline.
    pub(in crate::mux) fn type_on_prompt(&self, surface: &Surface) {
        let deadline = Instant::now() + PROMPT_WAIT;
        let Ok(mut seen) = surface.terminal_stream_revision() else { return };
        let mut output = false;
        loop {
            let now = Instant::now();
            if now >= deadline {
                break;
            }
            if output
                && surface.try_with_terminal(|term| term.cursor_is_at_prompt()).unwrap_or(false)
            {
                break;
            }
            let until = if output { (now + QUIET).min(deadline) } else { deadline };
            match surface.wait_for_terminal_stream_change(seen, Some(until)) {
                Ok(Some(revision)) => {
                    seen = revision;
                    output = true;
                }
                Ok(None) if output => break,
                Ok(None) => {}
                Err(_) => return,
            }
        }
        if !surface.is_dead()
            && let Err(error) = surface.write_bytes(self.text.as_bytes())
        {
            eprintln!("cmux-tui: could not pre-fill a respawned terminal: {error}");
        }
    }
}

impl Mux {
    /// The pre-fill of respawned terminal `terminal_id`, if any.
    pub(in crate::mux) fn respawn_prefill(
        &self,
        terminal_id: &str,
        record: Option<&StoredRelaunch>,
    ) -> Option<Prefill> {
        let record = record?;
        if let Some(text) = record
            .agent
            .as_ref()
            .and_then(|(harness, session_id)| resume_command(harness, session_id))
        {
            return Some(Prefill { kind: Prefilled::Harness, text });
        }
        if record.kind != RelaunchKind::Command {
            return None;
        }
        let text = shell_quoted(&self.terminal_respawns.argv(terminal_id)?)?;
        Some(Prefill { kind: Prefilled::Command, text })
    }
}

/// The resume command of a known harness.
pub(in crate::mux) fn resume_command(harness: &str, session_id: &str) -> Option<String> {
    if !resumable_session_id(session_id) {
        return None;
    }
    match harness {
        "claude" => Some(format!("claude --resume {session_id}")),
        "codex" => Some(format!("codex resume {session_id}")),
        _ => None,
    }
}

/// `argv` as one POSIX shell line, or `None` when an argument holds a
/// control character (a newline would run part of it).
pub(in crate::mux) fn shell_quoted(argv: &[String]) -> Option<String> {
    if argv.is_empty() || argv.iter().any(|arg| arg.chars().any(char::is_control)) {
        return None;
    }
    let quote = |arg: &String| {
        let plain = !arg.is_empty()
            && arg
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || b"_./=:@%+,-".contains(&byte));
        if plain { arg.clone() } else { format!("'{}'", arg.replace('\'', "'\\''")) }
    };
    Some(argv.iter().map(quote).collect::<Vec<_>>().join(" "))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_harnesses_resume_valid_sessions_only() {
        assert_eq!(resume_command("claude", "abc-123").as_deref(), Some("claude --resume abc-123"));
        assert_eq!(resume_command("codex", "s.1_2").as_deref(), Some("codex resume s.1_2"));
        assert_eq!(resume_command("claude", "abc;rm -rf"), None);
        assert_eq!(resume_command("claude", &"a".repeat(129)), None);
        assert_eq!(resume_command("opencode", "abc"), None);
    }

    #[test]
    fn argv_is_quoted_for_one_shell_line() {
        let argv = ["git", "commit", "-m", "it's done", ""].map(String::from);
        assert_eq!(shell_quoted(&argv).as_deref(), Some("git commit -m 'it'\\''s done' ''"));
        assert_eq!(shell_quoted(&["echo".into(), "a\nb".into()]), None);
        assert_eq!(shell_quoted(&[]), None);
    }
}
