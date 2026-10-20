//! What a respawned terminal (cx-6so.49 L2) does with what it ran:
//! - an agent session whose harness is known resumes, started as it was
//!   (its flags and account directory, `relaunch_store::agent_launch`):
//!   `CLAUDE_CONFIG_DIR=<dir> claude --resume <id> <flags>` or
//!   `CODEX_HOME=<dir> codex resume <id> <flags>`. It runs (Return after it)
//!   when all of these hold:
//!   - `sessions.resumeAgents` in the settings file is on (the default;
//!     "Resume Agents After Restart");
//!   - the new shell is a POSIX shell (sh, bash, zsh, dash, ksh), the
//!     quoting it is written in;
//!   - when it is written, shell integration itself marks the prompt (OSC
//!     133), the shell holds the terminal's foreground (no program its
//!     startup files started, such as tmux or ssh) and nothing was typed on
//!     the prompt: the Return reaches the shell, with only this command.
//!
//!   Otherwise nothing is typed; the marker line shows the resume command.
//! - any other command never runs again and is never typed: the marker line
//!   shows its command line (the full argv when this daemon process
//!   launched it, else the relaunch record's argv without credential-like
//!   arguments, `relaunch_store::stored_argv`), else its program name.

use std::time::{Duration, Instant};

use super::*;
use crate::terminal_loss_log::Prefilled;
use crate::terminal_respawn_text::Ran;
use crate::workspace_registry::relaunch_store::{
    AgentLaunch, RelaunchKind, StoredRelaunch, resumable_session_id,
};

/// The longest wait for the new shell's prompt.
const PROMPT_WAIT: Duration = Duration::from_secs(10);
/// Output quiet this long after the first byte counts as a prompt.
const QUIET: Duration = Duration::from_millis(400);

/// An agent resume to run on the new prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::mux) struct Prefill {
    pub(in crate::mux) kind: Prefilled,
    text: String,
}

impl Prefill {
    /// Wait for the new shell's prompt, then run the text there when the
    /// prompt is the shell's own and empty; else write nothing.
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
        // What the person typed while the shell started is echoed only after
        // the prompt is drawn: the prompt settles (one quiet interval) before
        // it is checked for input.
        let settle = Instant::now() + PROMPT_WAIT;
        while let Ok(Some(revision)) = surface
            .wait_for_terminal_stream_change(seen, Some((Instant::now() + QUIET).min(settle)))
        {
            seen = revision;
        }
        // The shell itself holds the terminal: not a job its startup files
        // started, nor a program one of them `exec`ed in its place (`exec ssh`).
        let shell_foreground = surface.process_id().is_some_and(|pid| {
            crate::platform::shell_holds_foreground(pid)
                && crate::platform::foreground_process_name(pid)
                    .is_some_and(|name| posix_shell(&name))
        });
        let Ok(Some(text)) = surface.try_with_terminal(|term| self.input(term, shell_foreground))
        else {
            return;
        };
        if !surface.is_dead()
            && let Err(error) = surface.write_bytes(text.as_bytes())
        {
            eprintln!("cmux-tui: could not pre-fill a respawned terminal: {error}");
        }
    }
}

impl Prefill {
    /// The bytes to write on screen `term`: the text and Return, only at the
    /// shell's own empty prompt: marked by shell integration, the shell in
    /// the foreground (`shell_foreground`), and no input on it (the person
    /// typed during the shell's startup). Else none.
    fn input(&self, term: &mut ghostty_vt::Terminal, shell_foreground: bool) -> Option<String> {
        let at_empty_prompt = term.prompt_is_marked()
            && term.latest_input_text(0).is_none_or(|input| input.trim().is_empty());
        (shell_foreground && at_empty_prompt).then(|| format!("{}\r", self.text))
    }
}

/// Whether `shell` (a path or name) is a POSIX shell, the quoting of
/// [`shell_quoted`] and the `KEY=value command` form.
pub(in crate::mux) fn posix_shell(shell: &str) -> bool {
    let name = std::path::Path::new(shell).file_name().and_then(|name| name.to_str());
    let name = name.unwrap_or_default().trim_start_matches('-');
    matches!(name, "sh" | "bash" | "zsh" | "dash" | "ksh" | "mksh" | "ksh93")
}

impl Mux {
    /// What respawned terminal `terminal_id` ran, for its marker line: the
    /// resume command of its agent session, else its command line, else
    /// its program name.
    pub(in crate::mux) fn respawn_ran(
        &self,
        terminal_id: &str,
        record: Option<&StoredRelaunch>,
    ) -> Option<RanText> {
        let record = record?;
        if let Some(text) = agent_resume(record) {
            return Some(RanText::Agent(text));
        }
        if record.kind != RelaunchKind::Command {
            return None;
        }
        let argv = self.terminal_respawns.argv(terminal_id).or_else(|| record.argv.clone());
        argv.and_then(|argv| shell_quoted(&argv))
            .or_else(|| record.program.clone())
            .map(RanText::Command)
    }

    /// The agent resume respawned terminal `record` runs on its new prompt,
    /// if any: only with `resume_agents` (the setting) and a POSIX shell.
    pub(in crate::mux) fn respawn_prefill(
        record: Option<&StoredRelaunch>,
        resume_agents: bool,
    ) -> Option<Prefill> {
        let record = record?;
        let text = agent_resume(record)?;
        (resume_agents && posix_shell(&super::launch::respawn_shell(Some(record))))
            .then_some(Prefill { kind: Prefilled::Harness, text })
    }
}

/// What a respawned terminal ran, as its marker line names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::mux) enum RanText {
    Command(String),
    Agent(String),
}

impl RanText {
    pub(in crate::mux) fn as_ran(&self) -> Ran<'_> {
        match self {
            Self::Command(command) => Ran::Command(command),
            Self::Agent(command) => Ran::Agent(command),
        }
    }
}

/// The resume command of `record`'s agent session, when it has one.
fn agent_resume(record: &StoredRelaunch) -> Option<String> {
    let (harness, session_id) = record.agent.as_ref()?;
    resume_command(harness, session_id, record.agent_launch.as_ref())
}

/// The resume command of a known harness, with how its CLI was started
/// (`launch`): the account directory as a variable before it, the flags
/// around the resume words as each CLI takes them.
pub(in crate::mux) fn resume_command(
    harness: &str,
    session_id: &str,
    launch: Option<&AgentLaunch>,
) -> Option<String> {
    if !resumable_session_id(session_id) {
        return None;
    }
    let flags = launch.map(|launch| launch.args.clone()).unwrap_or_default();
    let mut argv = vec![harness.to_string()];
    match harness {
        "claude" => {
            // The session first: no flag can take it as its value.
            argv.extend(["--resume".to_string(), session_id.to_string()]);
            argv.extend(flags);
        }
        "codex" => {
            argv.extend(["resume".to_string(), session_id.to_string()]);
            argv.extend(flags);
        }
        _ => return None,
    }
    let command = shell_quoted(&argv)?;
    let account = launch
        .into_iter()
        .flat_map(|launch| launch.env.iter())
        .map(|(key, value)| Some(format!("{key}={}", shell_quoted(std::slice::from_ref(value))?)))
        .collect::<Option<Vec<_>>>()?;
    Some(account.into_iter().chain([command]).collect::<Vec<_>>().join(" "))
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
        assert_eq!(
            resume_command("claude", "abc-123", None).as_deref(),
            Some("claude --resume abc-123")
        );
        assert_eq!(resume_command("codex", "s.1_2", None).as_deref(), Some("codex resume s.1_2"));
        assert_eq!(resume_command("claude", "abc;rm -rf", None), None);
        assert_eq!(resume_command("claude", &"a".repeat(129), None), None);
        assert_eq!(resume_command("opencode", "abc", None), None);
    }

    #[test]
    fn a_resume_starts_the_cli_with_its_flags_and_account() {
        let launch = |args: &[&str], env: &[(&str, &str)]| AgentLaunch {
            args: args.iter().map(|arg| arg.to_string()).collect(),
            env: env.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect(),
        };
        let claude = launch(
            &["--dangerously-skip-permissions", "--model", "claude-sonnet-5-5"],
            &[("CLAUDE_CONFIG_DIR", "/Users/a/Claude Work")],
        );
        assert_eq!(
            resume_command("claude", "abc-123", Some(&claude)).as_deref(),
            Some(
                "CLAUDE_CONFIG_DIR='/Users/a/Claude Work' claude --resume abc-123 \
                 --dangerously-skip-permissions --model claude-sonnet-5-5"
            )
        );
        let codex = launch(&["-m", "gpt-5.5"], &[("CODEX_HOME", "/Users/a/.codex-2")]);
        assert_eq!(
            resume_command("codex", "s1", Some(&codex)).as_deref(),
            Some("CODEX_HOME=/Users/a/.codex-2 codex resume s1 -m gpt-5.5")
        );
    }

    /// A 60-column screen that received `bytes`.
    fn screen(bytes: &[u8]) -> ghostty_vt::Terminal {
        let mut term = ghostty_vt::Terminal::new(60, 5, 1_000, Default::default()).unwrap();
        term.vt_write(bytes);
        term
    }

    #[test]
    fn a_resume_runs_only_at_an_empty_marked_prompt_of_the_shell_itself() {
        let prefill = Prefill { kind: Prefilled::Harness, text: "claude --resume a".into() };
        let prompt: &[u8] = b"restored\r\n\x1b]133;A\x07user@host:~$ \x1b]133;B\x07";
        // The shell's own prompt, marked by shell integration, nothing typed on it.
        assert_eq!(
            prefill.input(&mut screen(prompt), true).as_deref(),
            Some("claude --resume a\r")
        );
        // Else nothing is written; the marker line shows the command.
        // A program the shell's startup files started holds the terminal (tmux, ssh, a question).
        assert_eq!(prefill.input(&mut screen(prompt), false), None);
        // No mark: a startup question, or a shell without integration.
        let question: &[u8] = b"Update oh-my-zsh now? [Y/n] ";
        assert_eq!(prefill.input(&mut screen(question), true), None);
        // The person typed on the new prompt before it was written: never touch their line.
        let typed = [prompt, b"git sta".as_slice()].concat();
        assert_eq!(prefill.input(&mut screen(&typed), true), None);
        // The prompt went back to output (a command runs).
        let running = [prompt, b"make\r\n\x1b]133;C\x07building".as_slice()].concat();
        assert_eq!(prefill.input(&mut screen(&running), true), None);
    }

    #[test]
    fn only_posix_shells_run_the_resume() {
        for shell in ["/bin/zsh", "/opt/homebrew/bin/bash", "-zsh", "sh", "/bin/dash", "ksh"] {
            assert!(posix_shell(shell), "{shell}");
        }
        for shell in
            ["/opt/homebrew/bin/fish", "/bin/tcsh", "/usr/local/bin/nu", "csh", "elvish", ""]
        {
            assert!(!posix_shell(shell), "{shell}");
        }
    }

    #[test]
    fn argv_is_quoted_for_one_shell_line() {
        let argv = ["git", "commit", "-m", "it's done", ""].map(String::from);
        assert_eq!(shell_quoted(&argv).as_deref(), Some("git commit -m 'it'\\''s done' ''"));
        assert_eq!(shell_quoted(&["echo".into(), "a\nb".into()]), None);
        assert_eq!(shell_quoted(&[]), None);
    }
}
