//! What a respawned terminal (cx-6so.49 L2) does with what it ran:
//! - the resume command a person set for the terminal (`resume-command`,
//!   `terminal_resume_store`) wins over anything the daemon would offer. It
//!   is typed without Return, so they decide whether to run it, and only on
//!   a prompt shell integration marks with the shell in the foreground, so
//!   it never lands in a program the shell's startup files started;
//! - else an agent session whose harness is known resumes, started as it was
//!   (its flags and account directory, `relaunch_store::agent_launch`):
//!   `CLAUDE_CONFIG_DIR=<dir> claude --resume <id> <flags>`,
//!   `CODEX_HOME=<dir> codex resume <id> <flags>` or
//!   `muse resume <id> <flags>`. It runs (Return after it)
//!   when all of these hold:
//!   - `sessions.resumeAgents` in the settings file is on (the default;
//!     "Resume Agents After Restart");
//!   - the new shell is a POSIX shell (sh, bash, zsh, dash, ksh), the
//!     quoting it is written in;
//!   - its flags turn no approvals off (`--dangerously-skip-permissions`,
//!     `--permission-mode bypassPermissions`, codex `--yolo`, `-s
//!     danger-full-access` or `-a never`, muse `--yolo`, `--disable-approval`,
//!     `--disable-sandbox` or `--approval-mode never`; a claude settings file
//!     or agent, a codex profile, and a muse permission profile, preset,
//!     agent overlay or `-c` setting count too, as they may): a respawn never starts an agent with its
//!     approvals off by itself (#22292). Such a resume is typed without
//!     Return instead;
//!   - when it is written, shell integration itself marks the prompt (OSC
//!     133), the shell holds the terminal's foreground (no program its
//!     startup files started, such as tmux or ssh) and nothing was typed on
//!     the prompt: the Return reaches the shell, with only this command.
//!
//!   Otherwise nothing is typed; the marker line shows the resume command.
//! - else a shell the freeing tier parked (`park-tabs`, `relaunch.on_show`)
//!   gets its last finished command (`kept_tabs.last_command_json`) typed
//!   without Return, one line only, on the same marked, empty, foreground
//!   prompt: the person runs it again with one key;
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

/// A command to type on the new prompt.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::mux) struct Prefill {
    pub(in crate::mux) kind: Prefilled,
    text: String,
    /// Return after the text: it runs. Else it waits for the person.
    run: bool,
}

impl Prefill {
    /// Wait for the new shell's prompt, then write the text there when the
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
        // A person's own resume command is theirs to quote for their shell.
        let shell_foreground = surface.process_id().is_some_and(|pid| {
            crate::platform::shell_holds_foreground(pid)
                && (self.kind == Prefilled::Resume
                    || crate::platform::foreground_process_name(pid)
                        .is_some_and(|name| posix_shell(&name)))
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
    /// The bytes to write on screen `term`, only at the shell's own empty
    /// prompt: marked by shell integration, the shell in the foreground
    /// (`shell_foreground`), and no input on it (the person typed during the
    /// shell's startup). The text, and Return when it runs. Else none.
    fn input(&self, term: &mut ghostty_vt::Terminal, shell_foreground: bool) -> Option<String> {
        let at_empty_prompt = term.prompt_is_marked()
            && term.latest_input_text(0).is_none_or(|input| input.trim().is_empty());
        (shell_foreground && at_empty_prompt)
            .then(|| if self.run { format!("{}\r", self.text) } else { self.text.clone() })
    }
}

/// Whether `shell` (a path or name) is a POSIX shell, the quoting of
/// [`shell_quoted`] and the `KEY=value command` form.
pub(in crate::mux) fn posix_shell(shell: &str) -> bool {
    let name = Path::new(shell).file_name().and_then(|name| name.to_str());
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

    /// What respawned terminal `terminal_id` types on its new prompt, if
    /// anything: the resume command a person set for it, else its agent's
    /// resume, only with `resume_agents` (the setting) and a POSIX shell,
    /// else the last command of a freed shell (`freed_last`), without Return.
    pub(in crate::mux) fn respawn_prefill(
        &self,
        terminal_id: &str,
        record: Option<&StoredRelaunch>,
        resume_agents: bool,
        freed_last: Option<&str>,
    ) -> Option<Prefill> {
        match self.terminal_resume_command(terminal_id) {
            Ok(Some(text)) => return Some(Prefill { kind: Prefilled::Resume, text, run: false }),
            Ok(None) => {}
            Err(error) => {
                eprintln!(
                    "cmux-tui: could not read the resume command of {terminal_id}: {error:#}"
                );
            }
        }
        record
            .and_then(|record| agent_prefill(record, resume_agents))
            .or_else(|| freed_last.and_then(last_command_prefill))
    }

    /// Set (`Some`) or clear (`None`) the resume command of one hosted
    /// terminal (`terminal_id` is the stable host id) and return the stored
    /// command. A respawn of the terminal types it on the new prompt.
    pub fn set_terminal_resume_command(
        &self,
        terminal_id: &str,
        command: Option<&str>,
    ) -> anyhow::Result<Option<String>> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .set_terminal_resume_command(terminal_id, command)
    }

    /// The resume command of one hosted terminal, if one is set.
    pub fn terminal_resume_command(&self, terminal_id: &str) -> anyhow::Result<Option<String>> {
        self.workspace_registry
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .terminal_resume_command(terminal_id)
    }
}

/// A freed shell's last command, typed on its new prompt without Return, so
/// the person runs it again with one key. One line only: a command with a
/// newline (a heredoc, a pasted script) would run its first lines by itself.
fn last_command_prefill(command: &str) -> Option<Prefill> {
    let text = command.trim();
    (!text.is_empty() && !text.contains(['\n', '\r'])).then(|| Prefill {
        kind: Prefilled::LastCommand,
        text: text.to_owned(),
        run: false,
    })
}

/// The agent resume `record` types on its new prompt, if any: only with
/// `resume_agents` and a POSIX shell; run unless its flags turn approvals off.
fn agent_prefill(record: &StoredRelaunch, resume_agents: bool) -> Option<Prefill> {
    let text = agent_resume(record)?;
    let (harness, _) = record.agent.as_ref()?;
    let flags = record.agent_launch.as_ref().map(|launch| launch.args.as_slice()).unwrap_or(&[]);
    (resume_agents && posix_shell(&launch::respawn_shell(Some(record)))).then(|| Prefill {
        kind: Prefilled::Harness,
        text,
        run: !turns_approvals_off(harness, flags),
    })
}

/// Whether `flags` may start `harness` with its approvals off. A codex
/// profile (`-p`) may set them, so it counts; an unknown harness counts.
fn turns_approvals_off(harness: &str, flags: &[String]) -> bool {
    let has = |names: &[&str]| !flag_values(flags, names).is_empty();
    let has_value = |names: &[&str], value: &str| flag_values(flags, names).contains(&value);
    match harness {
        // A settings file or an agent definition can set the permission mode.
        "claude" => {
            has(&["--dangerously-skip-permissions", "--settings", "--agent"])
                || has_value(&["--permission-mode"], "bypassPermissions")
        }
        "codex" => {
            has(&["--dangerously-bypass-approvals-and-sandbox", "--yolo", "-p", "--profile"])
                || has_value(&["-s", "--sandbox"], "danger-full-access")
                || has_value(&["-a", "--ask-for-approval"], "never")
        }
        // A permission profile, a preset, an agent overlay or a setting can
        // turn approval or the sandbox off.
        "muse" => {
            has(&[
                "--yolo",
                "--disable-approval",
                "--disable-sandbox",
                "--permission-profile",
                "--preset",
                "--agents",
                "-c",
                "--config",
            ]) || has_value(&["--approval-mode"], "never")
        }
        _ => true,
    }
}

/// The values `flags` give a flag in `names`: `name value`, `name=value`
/// or, for a short name, `-nvalue` (`relaunch_store::agent_launch` keeps
/// each form). A flag given without a value counts with an empty one.
fn flag_values<'a>(flags: &'a [String], names: &[&str]) -> Vec<&'a str> {
    let mut values = Vec::new();
    for (index, flag) in flags.iter().enumerate() {
        for name in names {
            if flag == name {
                values.push(flags.get(index + 1).map_or("", String::as_str));
            } else if let Some(rest) = flag.strip_prefix(name) {
                if let Some(value) = rest.strip_prefix('=') {
                    values.push(value);
                } else if name.len() == 2 && !rest.is_empty() {
                    values.push(rest);
                }
            }
        }
    }
    values
}

/// What a respawned terminal ran, as its marker line names it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::mux) enum RanText {
    Command(String),
    Agent(String),
    /// A freed shell's last command (`kept_tabs.last_command_json`).
    Last {
        command: String,
        exit_code: Option<i32>,
    },
}

impl RanText {
    pub(in crate::mux) fn as_ran(&self) -> Ran<'_> {
        match self {
            Self::Command(command) => Ran::Command(command),
            Self::Agent(command) => Ran::Agent(command),
            Self::Last { command, exit_code } => Ran::Last { command, exit_code: *exit_code },
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
        "codex" | "muse" => {
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
mod tests;
