//! The argv an agent tab runs, and reading it back for `resume`.
//!
//! A launcher is a shell command line (`claude`, `sr2 claude`, `codex
//! --model o3`). The tab runs `SHELL -lc 'LAUNCHER "$@"' cmux-agent ARGS…`:
//! the login shell finds the launcher on the person's `PATH`, and every
//! extra argument (`--resume <id>`, a session id) stays its own argv word
//! that no shell parses again. `terminal <t> process show` keeps that argv
//! after the agent exits (the tab runs with `--on-exit keep`), so `resume`
//! reads the launcher back from it.

use super::super::agent_vocabulary::harness_name;

/// `$0` of the launcher script; marks an argv this module built.
pub(super) const ARG0: &str = cmux_tui_core::agent_start_launch::ARG0;
/// The launch's shell flag, shared with the daemon's mark.
const SHELL_FLAG: &str = cmux_tui_core::agent_start_launch::SHELL_FLAG;
/// What follows the launcher in the script.
const SCRIPT_TAIL: &str = " \"$@\"";
/// The environment variable that names the default launcher.
pub(super) const DEFAULT_LAUNCHER_ENV: &str = "CMUX_AGENT_COMMAND";
/// The launcher when neither `--cmd` nor the environment names one.
pub(super) const DEFAULT_LAUNCHER: &str = "claude";
/// Shells whose `-c SCRIPT NAME ARGS…` sets `$0` and `$@` the POSIX way.
const POSIX_SHELLS: &[&str] = &["sh", "bash", "zsh", "dash", "ksh", "mksh"];
/// The harnesses `resume` knows, in the order a launcher is searched.
const HARNESSES: &[&str] = &["claude", "codex", "opencode", "gemini", "amp"];

/// One agent launch: the shell, the launcher line and its extra arguments.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) struct Launch {
    pub shell: String,
    pub launcher: String,
    pub args: Vec<String>,
}

impl Launch {
    /// The argv the tab runs.
    pub(in crate::cli) fn argv(&self) -> Vec<String> {
        let mut argv = vec![
            self.shell.clone(),
            SHELL_FLAG.to_owned(),
            format!("{}{SCRIPT_TAIL}", self.launcher),
            ARG0.to_owned(),
        ];
        argv.extend(self.args.iter().cloned());
        argv
    }

    /// The launch an argv of [`Launch::argv`] came from; `None` for any
    /// other argv (an agent typed into a shell, a `pane run -- claude`).
    pub(in crate::cli) fn from_argv(argv: &[String]) -> Option<Self> {
        let [shell, flag, script, arg0, args @ ..] = argv else { return None };
        if flag != SHELL_FLAG || arg0 != ARG0 {
            return None;
        }
        let launcher = script.strip_suffix(SCRIPT_TAIL)?.trim();
        (!launcher.is_empty()).then(|| Self {
            shell: shell.clone(),
            launcher: launcher.to_owned(),
            args: args.to_vec(),
        })
    }
}

/// The shell that runs launchers: `$SHELL` when it is an absolute path to a
/// POSIX shell, else `/bin/sh`.
pub(in crate::cli) fn shell_from(env_shell: Option<&str>) -> String {
    env_shell
        .filter(|shell| shell.starts_with('/'))
        .filter(|shell| {
            let name = shell.rsplit('/').next().unwrap_or_default();
            POSIX_SHELLS.contains(&name)
        })
        .map_or_else(|| "/bin/sh".to_owned(), str::to_owned)
}

/// The launcher `--cmd` gives, else the environment's, else `claude`.
pub(in crate::cli) fn launcher_from(given: Option<&str>, env: Option<&str>) -> String {
    given
        .or(env)
        .map(str::trim)
        .filter(|launcher| !launcher.is_empty())
        .unwrap_or(DEFAULT_LAUNCHER)
        .to_owned()
}

/// The harness a launcher runs: the first word whose file name is a known
/// harness (or one of its aliases), so `sr2 claude` and
/// `/opt/bin/claude-code --x` are `claude`.
pub(in crate::cli) fn harness_of(launcher: &str) -> Option<String> {
    launcher.split_whitespace().find_map(|word| {
        let name = harness_name(word.rsplit('/').next().unwrap_or(word));
        HARNESSES.contains(&name.as_str()).then_some(name)
    })
}

/// The arguments that resume harness session `id`, in the harness's own
/// grammar; `None` for a harness `resume` does not know.
pub(in crate::cli) fn resume_args(harness: &str, id: &str) -> Option<Vec<String>> {
    let words: &[&str] = match harness_name(harness).as_str() {
        "claude" | "gemini" => &["--resume"],
        "codex" => &["resume"],
        "opencode" => &["--session"],
        "amp" => &["threads", "continue"],
        _ => return None,
    };
    let mut args: Vec<String> = words.iter().map(|word| (*word).to_owned()).collect();
    args.push(id.to_owned());
    Some(args)
}

/// Whether `id` can be a harness session id: what the daemon publishes
/// (letters, digits, `.`, `_`, `:`, `-`), not starting with `-`.
pub(in crate::cli) fn valid_session_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 256
        && !id.starts_with('-')
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
}
