//! A Claude Code session in a cmux terminal takes an acpmux name with no one running
//! `acpmux register` in it (Leo, 2026-11-25, about a coordinator in a cmux terminal no one could
//! message: "why isn't it registered?"). At each prompt, until acpmux says the chat is reached
//! with this Claude Code process, the hook runs `cmux acp register --auto NAME --json`
//! (acpmux `cli/hook_register.rs`): acpmux proves the caller (this hook runs under the Claude Code
//! process) and its inbox, keeps a name the chat already has, and otherwise delivers a one-time
//! code the chat's model echoes. Once reached, a mark makes this a file check.
//!
//! The command runs beside the hook's inbox delivery and is waited for at most [`WAIT`]: long
//! enough for the daemon to read this process tree (its proof needs the hook alive), never long
//! enough to hold the prompt. Past it the command finishes on its own.

use super::*;

/// The longest the hook waits for the registration command.
// timeout: a side step's cap, not the hook's: past it the command still finishes on its own.
const WAIT: Duration = Duration::from_millis(1000);

/// The event that registers: a prompt. SessionStart does not: a code at a fresh session's start
/// would wake it before the person typed anything.
pub(super) fn applies(source: &str, native_event: &str) -> bool {
    source == "claude" && native_event == "UserPromptSubmit"
}

/// The command for a Claude Code hook with `getenv` and `session_id`, or `None`.
pub(super) fn command(
    getenv: impl Fn(&str) -> Option<String>,
    session_id: Option<&str>,
    host: &str,
    acpmux_home: &Path,
) -> Option<(PathBuf, Vec<String>)> {
    let cli = getenv("CMUX_TUI_CLI").filter(|v| !v.trim().is_empty())?;
    let args = acpmux::cli::hook_register::hook_args(&getenv, session_id, host, acpmux_home)?;
    Some((PathBuf::from(cli), std::iter::once("acp".to_owned()).chain(args).collect()))
}

/// A running registration command, waited for by [`Started::finish`].
pub(super) struct Started(Option<(cmux_process::Child, Instant)>);

/// Starts the command for this hook, when one applies.
pub(super) fn start(source: &str, native_event: &str, session_id: Option<&str>) -> Started {
    if !cfg!(target_os = "macos") || !applies(source, native_event) {
        return Started(None);
    }
    let getenv = |key: &str| env::var(key).ok();
    let host = acpmux::host_pressure::host_name();
    let Some((cli, args)) = command(getenv, session_id, &host, &acpmux::config::home()) else {
        return Started(None);
    };
    let child = cmux_process::Command::new(cli)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .spawn()
        .ok()
        .map(|mut child| {
            // Past WAIT the hook exits and the command finishes its one bounded request alone.
            child.detach("acpmux register finishes its bounded request after the hook returns");
            child
        });
    Started(child.map(|child| (child, Instant::now())))
}

impl Started {
    /// Waits what is left of [`WAIT`], then lets the command finish on its own.
    pub(super) fn finish(self) {
        let Some((mut child, at)) = self.0 else { return };
        let _ = child.wait_timeout(WAIT.saturating_sub(at.elapsed()));
    }
}
