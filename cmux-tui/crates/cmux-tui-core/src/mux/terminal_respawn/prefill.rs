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
    /// resume, only with `resume_agents` (the setting) and a POSIX shell.
    pub(in crate::mux) fn respawn_prefill(
        &self,
        terminal_id: &str,
        record: Option<&StoredRelaunch>,
        resume_agents: bool,
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
        agent_prefill(record?, resume_agents)
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
mod tests {
    use super::*;

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|arg| arg.to_string()).collect()
    }

    #[test]
    fn known_harnesses_resume_valid_sessions_only() {
        assert_eq!(
            resume_command("claude", "abc-123", None).as_deref(),
            Some("claude --resume abc-123")
        );
        assert_eq!(resume_command("codex", "s.1_2", None).as_deref(), Some("codex resume s.1_2"));
        assert_eq!(resume_command("claude", "abc;rm -rf", None), None);
        assert_eq!(resume_command("claude", &"a".repeat(129), None), None);
        assert_eq!(
            resume_command("muse", "01a14ec1-9cca-7b72-832c-5148ab7bcd41", None).as_deref(),
            Some("muse resume 01a14ec1-9cca-7b72-832c-5148ab7bcd41")
        );
        assert_eq!(resume_command("opencode", "abc", None), None);
    }

    #[test]
    fn a_muse_resume_starts_the_cli_with_its_flags() {
        let launch = AgentLaunch { args: strings(&["--model", "muse-wonder-1.0"]), env: vec![] };
        assert_eq!(
            resume_command("muse", "s1", Some(&launch)).as_deref(),
            Some("muse resume s1 --model muse-wonder-1.0")
        );
    }

    #[test]
    fn a_resume_starts_the_cli_with_its_flags_and_account() {
        let launch = |args: &[&str], env: &[(&str, &str)]| AgentLaunch {
            args: strings(args),
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

    /// #22292: a respawn never starts an agent with its approvals off by itself.
    #[test]
    fn flags_that_turn_approvals_off_are_known() {
        for flags in [
            &["--dangerously-skip-permissions"][..],
            &["--model", "opus", "--permission-mode", "bypassPermissions"],
            &["--permission-mode=bypassPermissions"],
            &["--settings", "yolo.json"],
            &["--agent=reviewer"],
        ] {
            assert!(turns_approvals_off("claude", &strings(flags)), "{flags:?}");
        }
        for flags in [&["--model", "opus"][..], &["--permission-mode", "acceptEdits"], &[]] {
            assert!(!turns_approvals_off("claude", &strings(flags)), "{flags:?}");
        }
        for flags in [
            &["--yolo"][..],
            &["--dangerously-bypass-approvals-and-sandbox"],
            &["-s", "danger-full-access"],
            &["--sandbox=danger-full-access"],
            &["-a", "never"],
            &["-p", "work"],
            &["-pwork"],
            &["-sdanger-full-access"],
            &["-anever"],
            &["--profile=work"],
        ] {
            assert!(turns_approvals_off("codex", &strings(flags)), "{flags:?}");
        }
        for flags in
            [&["-m", "gpt-5.5"][..], &["--full-auto"], &["-a", "on-request"], &["-aon-request"]]
        {
            assert!(!turns_approvals_off("codex", &strings(flags)), "{flags:?}");
        }
        for flags in [
            &["--yolo"][..],
            &["--disable-approval"],
            &["--disable-sandbox"],
            &["--approval-mode", "never"],
            &["--approval-mode=never"],
            &["--permission-profile", "open"],
            &["--preset", "empty"],
            &["-c", "approval.mode=\"never\""],
        ] {
            assert!(turns_approvals_off("muse", &strings(flags)), "{flags:?}");
        }
        for flags in [&["--model", "muse-wonder-1.0"][..], &["--approval-mode", "on-request"], &[]]
        {
            assert!(!turns_approvals_off("muse", &strings(flags)), "{flags:?}");
        }
    }

    /// A 60-column screen that received `bytes`.
    fn screen(bytes: &[u8]) -> ghostty_vt::Terminal {
        let mut term = ghostty_vt::Terminal::new(60, 5, 1_000, Default::default()).unwrap();
        term.vt_write(bytes);
        term
    }

    const PROMPT: &[u8] = b"restored\r\n\x1b]133;A\x07user@host:~$ \x1b]133;B\x07";

    #[test]
    fn a_resume_runs_only_at_an_empty_marked_prompt_of_the_shell_itself() {
        let prefill =
            Prefill { kind: Prefilled::Harness, text: "claude --resume a".into(), run: true };
        // The shell's own prompt, marked by shell integration, nothing typed on it.
        assert_eq!(
            prefill.input(&mut screen(PROMPT), true).as_deref(),
            Some("claude --resume a\r")
        );
        // Else nothing is written; the marker line shows the command.
        // A program the shell's startup files started holds the terminal (tmux, ssh, a question).
        assert_eq!(prefill.input(&mut screen(PROMPT), false), None);
        // No mark: a startup question, or a shell without integration.
        let question: &[u8] = b"Update oh-my-zsh now? [Y/n] ";
        assert_eq!(prefill.input(&mut screen(question), true), None);
        // The person typed on the new prompt before it was written: never touch their line.
        let typed = [PROMPT, b"git sta".as_slice()].concat();
        assert_eq!(prefill.input(&mut screen(&typed), true), None);
        // The prompt went back to output (a command runs).
        let running = [PROMPT, b"make\r\n\x1b]133;C\x07building".as_slice()].concat();
        assert_eq!(prefill.input(&mut screen(&running), true), None);
    }

    #[test]
    fn what_does_not_run_by_itself_is_typed_without_return() {
        let bypass = Prefill {
            kind: Prefilled::Harness,
            text: "claude --resume a --dangerously-skip-permissions".into(),
            run: false,
        };
        assert_eq!(
            bypass.input(&mut screen(PROMPT), true).as_deref(),
            Some("claude --resume a --dangerously-skip-permissions")
        );
        let resume = Prefill { kind: Prefilled::Resume, text: "npm run dev".into(), run: false };
        assert_eq!(
            resume.input(&mut screen(PROMPT), true).as_deref(),
            Some("npm run dev"),
            "a person's resume command waits for Return"
        );
        let typed = [PROMPT, b"git sta".as_slice()].concat();
        assert_eq!(resume.input(&mut screen(&typed), true), None);
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
