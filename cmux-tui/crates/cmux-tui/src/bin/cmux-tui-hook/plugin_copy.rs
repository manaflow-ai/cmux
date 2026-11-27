//! The plugin copy of Claude Code's hooks stands down when it must not report.
//!
//! A cmux-tui pane names the build's Claude Code plugin in
//! `CLAUDE_CODE_PLUGIN_DIRS`, so Claude gets the session's hooks however it
//! was started (claude_plugin.rs). Claude Code runs plugin hooks beside the
//! hooks of its settings files and never merges the two, so when
//! `agent hook install claude` also put the hooks in the user settings of the
//! config directory this Claude runs with, both copies would report every
//! event. The plugin's commands export `CMUX_TUI_HOOK_ORIGIN=claude-plugin`;
//! such a run does nothing when the installed copy runs too. The `claude`
//! shim's wrapper removes the plugin from the folders it passes on, since its
//! own `--settings` carries the hooks. A copy that stands down only drains
//! the payload; the command still prints `{}`.
//!
//! Claude Code passes its environment, the plugin folder and the terminal's
//! variables too, to the commands its tools run, so a Claude that such a
//! command starts (`claude -p` in a Bash tool call) would report to the same
//! terminal, through the plugin, the installed hooks or the shim's hooks. So
//! the copy of the hooks that reports `SessionStart` claims the terminal for
//! its session and process: it appends
//! `export CMUX_TUI_CLAUDE_OWNER=<terminal>/<session>/<CLAUDE_PID>` to Claude
//! Code's `CLAUDE_ENV_FILE`, which Claude Code sources before each
//! Bash tool command (its own hooks do not see it: Claude Code 2.1.319 names
//! the file and leaves creating it to the hook). Any copy of a Claude hook
//! that finds a claim for its terminal by another session does nothing. A
//! Claude in another terminal (`cmux agent start` from a tool command)
//! reports to its own terminal.

use std::ffi::OsString;
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

/// Set by the plugin's hook commands (agent_hook_install.rs
/// `CLAUDE_PLUGIN_ORIGIN_ENV`; this helper is also built on its own, so it
/// keeps a copy that the cmux-tui tests compare).
pub(crate) const ORIGIN_ENV: &str = "CMUX_TUI_HOOK_ORIGIN";
/// The plugin's value of [`ORIGIN_ENV`] (agent_hook_install.rs
/// `CLAUDE_PLUGIN_ORIGIN`).
pub(crate) const PLUGIN_ORIGIN: &str = "claude-plugin";
/// Ends every hook command cmux-tui writes (agent_hook_install.rs
/// `COMMAND_MARKER`).
const COMMAND_MARKER: &str = "cmux-tui-journal-hook";
/// The terminal and session of the Claude whose tool commands run in this
/// environment (`<terminal>/<session>`).
const OWNER_ENV: &str = "CMUX_TUI_CLAUDE_OWNER";
/// The file a `SessionStart` hook may append `export` lines to; Claude Code
/// sources it before each Bash tool command.
const CLAUDE_ENV_FILE: &str = "CLAUDE_ENV_FILE";
/// The cmux-tui terminal the hook runs in.
const TERMINAL_ENV: &str = "CMUX_TUI_TERMINAL_ID";
/// The process id of the Claude Code that runs this hook or tool command;
/// Claude Code 2.1.319 sets it for both, and the same value in each.
const CLAUDE_PID_ENV: &str = "CLAUDE_PID";
/// `1` turns cmux-tui's Claude hooks off (claude_wrapper.rs).
const HOOKS_DISABLED_ENV: &str = "CMUX_TUI_CLAUDE_HOOKS_DISABLED";
/// Settings files are small; a larger one is not read.
const MAX_SETTINGS_BYTES: u64 = 16 * 1024 * 1024;

/// Whether this run of a Claude hook must do nothing: another session's
/// Claude claimed this terminal (this Claude runs under its tool), or it is
/// the plugin copy and cmux-tui's Claude hooks are turned off or the installed
/// copy of the same event runs in this Claude too. `session` is the hook's
/// `session_id`.
pub(super) fn stands_down(
    source: &str,
    native_event: &str,
    session: Option<&str>,
    getenv: impl Fn(&str) -> Option<OsString>,
) -> bool {
    if source != "claude" {
        return false;
    }
    if claimed_by_another(session, None, &getenv) {
        return true;
    }
    if !is_plugin_copy(source, &getenv) {
        return false;
    }
    if getenv(HOOKS_DISABLED_ENV).is_some_and(|value| value == "1") {
        return true;
    }
    installed_copy_runs(&getenv)
        && user_settings(&getenv).is_some_and(|path| installs_event(&path, native_event))
}

/// Whether this run is a Claude hook whose environment claims its terminal
/// for another session (the part of [`stands_down`] that also holds for the
/// installed and the shim's copies).
/// `terminal` is the hook's route when its environment names none (a tmux
/// or ancestor route); `None` reads `CMUX_TUI_TERMINAL_ID`.
pub(super) fn claimed_elsewhere(
    source: &str,
    terminal: Option<&str>,
    session: Option<&str>,
    getenv: impl Fn(&str) -> Option<OsString>,
) -> bool {
    source == "claude" && claimed_by_another(session, terminal, &getenv)
}

/// Whether this environment claims its terminal (`terminal`, else
/// `CMUX_TUI_TERMINAL_ID`) for a session other than `session` of another
/// Claude process. The claiming Claude's own hooks never stand down: after
/// `/clear` it runs a new session, and a Claude Code that let its hooks see
/// the env file would show them its own claim.
fn claimed_by_another(
    session: Option<&str>,
    terminal: Option<&str>,
    getenv: &impl Fn(&str) -> Option<OsString>,
) -> bool {
    let Some(claim) = claim(getenv) else { return false };
    let here = terminal.map(str::to_owned).or_else(|| terminal_of(getenv));
    here.as_deref() == Some(claim.terminal.as_str())
        && session != Some(claim.session.as_str())
        && claim.pid.is_none_or(|pid| claude_pid(getenv).as_deref() != Some(pid.as_str()))
}

/// After a Claude `SessionStart` that reports (any copy: the plugin, the
/// installed hooks or the shim's): claims `terminal` (the hook's route, else
/// `CMUX_TUI_TERMINAL_ID`) for `session` and this Claude process
/// (`CLAUDE_PID`) in `CLAUDE_ENV_FILE`, created when missing, so the Claudes
/// its tool commands start stand down (a later claim, after `/clear`,
/// replaces it). Does nothing when an id holds anything but letters, digits,
/// `-` and `_`.
pub(super) fn claim_terminal(
    source: &str,
    native_event: &str,
    terminal: Option<&str>,
    session: Option<&str>,
    getenv: impl Fn(&str) -> Option<OsString>,
) {
    if source != "claude" || native_event != "SessionStart" {
        return;
    }
    let plain = |id: &&str| {
        !id.is_empty()
            && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_')
    };
    let (Some(terminal), Some(session), Some(file)) = (
        terminal.map(str::to_owned).or_else(|| terminal_of(&getenv)),
        session.filter(plain),
        getenv(CLAUDE_ENV_FILE).filter(|file| !file.is_empty()),
    ) else {
        return;
    };
    if !plain(&terminal.as_str()) {
        return;
    }
    let line = match claude_pid(&getenv) {
        Some(pid) => format!("export {OWNER_ENV}={terminal}/{session}/{pid}\n"),
        None => format!("export {OWNER_ENV}={terminal}/{session}\n"),
    };
    let _ = std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .open(file)
        .and_then(|mut file| file.write_all(line.as_bytes()));
}

/// Whether this run is the plugin's copy of a Claude hook.
fn is_plugin_copy(source: &str, getenv: &impl Fn(&str) -> Option<OsString>) -> bool {
    source == "claude" && getenv(ORIGIN_ENV).is_some_and(|origin| origin == PLUGIN_ORIGIN)
}

fn terminal_of(getenv: &impl Fn(&str) -> Option<OsString>) -> Option<String> {
    getenv(TERMINAL_ENV).and_then(|terminal| terminal.into_string().ok()).filter(|t| !t.is_empty())
}

/// A claim in the environment: `<terminal>/<session>[/<pid>]` (builds
/// before W5-N3 wrote no process id).
struct Claim {
    terminal: String,
    session: String,
    pid: Option<String>,
}

/// The claim in this environment.
fn claim(getenv: &impl Fn(&str) -> Option<OsString>) -> Option<Claim> {
    let claim = getenv(OWNER_ENV)?.into_string().ok()?;
    let mut parts = claim.split('/');
    let (terminal, session) = (parts.next()?.to_owned(), parts.next()?.to_owned());
    let pid = parts.next().map(str::to_owned);
    parts.next().is_none().then_some(Claim { terminal, session, pid })
}

/// The id of the Claude Code process this hook runs under: digits only.
pub(super) fn claude_pid(getenv: &impl Fn(&str) -> Option<OsString>) -> Option<String> {
    getenv(CLAUDE_PID_ENV)
        .and_then(|pid| pid.into_string().ok())
        .filter(|pid| !pid.is_empty() && pid.bytes().all(|byte| byte.is_ascii_digit()))
}

/// Whether an installed command finds a helper: `CMUX_TUI_HOOK`, or inside
/// tmux the installed helper (agent_hook_install.rs `INSTALLED_FALLBACK`).
fn installed_copy_runs(getenv: &impl Fn(&str) -> Option<OsString>) -> bool {
    let set = |name: &str| getenv(name).filter(|value| !value.is_empty());
    if set("CMUX_TUI_HOOK").is_some() {
        return true;
    }
    if set("TMUX").is_none() {
        return false;
    }
    let data = set("XDG_DATA_HOME")
        .map(PathBuf::from)
        .or_else(|| set("HOME").map(|home| PathBuf::from(home).join(".local/share")));
    data.is_some_and(|data| data.join("cmux-tui/bin/cmux-tui-hook").is_file())
}

/// The user settings file of the config directory Claude runs with: the one
/// `agent hook install claude` writes.
fn user_settings(getenv: &impl Fn(&str) -> Option<OsString>) -> Option<PathBuf> {
    match getenv("CLAUDE_CONFIG_DIR").filter(|dir| !dir.is_empty()) {
        Some(dir) => Some(PathBuf::from(dir).join("settings.json")),
        None => Some(PathBuf::from(getenv("HOME")?).join(".claude").join("settings.json")),
    }
}

/// Whether the settings at `path` hold an installed cmux-tui command for
/// `event`: one that runs `CMUX_TUI_HOOK` and is not a plugin copy.
fn installs_event(path: &Path, event: &str) -> bool {
    let mut data = Vec::new();
    let read = std::fs::File::open(path)
        .and_then(|file| file.take(MAX_SETTINGS_BYTES).read_to_end(&mut data));
    if read.is_err() {
        return false;
    }
    let Ok(settings) = serde_json::from_slice::<serde_json::Value>(&data) else {
        return false;
    };
    settings
        .get("hooks")
        .and_then(|hooks| hooks.get(event))
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|group| group.get("hooks").and_then(serde_json::Value::as_array))
        .flatten()
        .filter_map(|hook| hook.get("command").and_then(serde_json::Value::as_str))
        .any(|command| {
            command.contains(COMMAND_MARKER)
                && command.contains("CMUX_TUI_HOOK")
                && !command.contains(ORIGIN_ENV)
        })
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::fs;

    use super::*;

    fn env(pairs: &[(&str, &str)]) -> impl Fn(&str) -> Option<OsString> {
        let map: HashMap<String, OsString> =
            pairs.iter().map(|(key, value)| ((*key).to_owned(), OsString::from(value))).collect();
        move |name| map.get(name).cloned()
    }

    #[test]
    fn any_launcher_nested_claude_plugin_copy_stands_down_under_the_terminal_claim() {
        let plugin = (ORIGIN_ENV, PLUGIN_ORIGIN);
        let here = (TERMINAL_ENV, "term_a");
        let claimed = (OWNER_ENV, "term_a/outer-1");
        let run = |session: &str, pairs: &[(&str, &str)]| {
            stands_down("claude", "UserPromptSubmit", Some(session), env(pairs))
        };
        // A Claude that the terminal's Claude started: another session.
        assert!(run("nested-2", &[plugin, here, claimed]));
        // The claiming Claude itself, and a terminal nobody claimed.
        assert!(!run("outer-1", &[plugin, here, claimed]));
        assert!(!run("nested-2", &[plugin, here]));
        // A claim for another terminal: this Claude runs in its own terminal
        // (`cmux agent start` from a tool command).
        assert!(!run("nested-2", &[plugin, (TERMINAL_ENV, "term_b"), claimed]));
        // Every copy reads claims: the installed and the shim's hooks too.
        assert!(run("nested-2", &[here, claimed]));
        assert!(!run("outer-1", &[here, claimed]));
        assert!(!stands_down("codex", "Stop", Some("nested-2"), env(&[here, claimed])));
        // A malformed claim is none.
        assert!(!run("nested-2", &[plugin, here, (OWNER_ENV, "term_a")]));
    }

    #[test]
    fn any_launcher_w5n3_claim_follows_the_route_terminal() {
        // A tmux or ancestor route: the environment names no terminal.
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("env.sh");
        let envfile = (CLAUDE_ENV_FILE, file.to_str().unwrap());
        claim_terminal("claude", "SessionStart", Some("term_r"), Some("outer-1"), env(&[envfile]));
        assert_eq!(
            fs::read_to_string(&file).unwrap_or_default(),
            format!("export {OWNER_ENV}=term_r/outer-1\n")
        );
        let claimed = (OWNER_ENV, "term_r/outer-1");
        assert!(claimed_elsewhere("claude", Some("term_r"), Some("nested-2"), env(&[claimed])));
        assert!(!claimed_elsewhere("claude", Some("term_r"), Some("outer-1"), env(&[claimed])));
        assert!(!claimed_elsewhere("claude", Some("term_s"), Some("nested-2"), env(&[claimed])));
    }

    #[test]
    fn any_launcher_w5n3_claim_names_the_claude_process_so_clear_keeps_reporting() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("env.sh");
        let envfile = (CLAUDE_ENV_FILE, file.to_str().unwrap());
        let here = (TERMINAL_ENV, "term_a");
        let outer = (CLAUDE_PID_ENV, "4242");
        claim_terminal(
            "claude",
            "SessionStart",
            None,
            Some("outer-1"),
            env(&[here, envfile, outer]),
        );
        assert_eq!(
            fs::read_to_string(&file).unwrap_or_default(),
            format!("export {OWNER_ENV}=term_a/outer-1/4242\n")
        );
        let claimed = (OWNER_ENV, "term_a/outer-1/4242");
        // After `/clear` the same Claude runs a new session; were its hooks
        // to see the claim, they must still report.
        assert!(!stands_down(
            "claude",
            "SessionStart",
            Some("outer-2"),
            env(&[here, claimed, outer])
        ));
        // A Claude that its tool command started is another process.
        let nested = (CLAUDE_PID_ENV, "5151");
        assert!(stands_down(
            "claude",
            "SessionStart",
            Some("nested-2"),
            env(&[here, claimed, nested])
        ));
        // A claim without a process (an older build) keeps the session rule.
        let old = (OWNER_ENV, "term_a/outer-1");
        assert!(stands_down("claude", "Stop", Some("outer-2"), env(&[here, old, outer])));
        // A process id that is not a number is not written.
        fs::remove_file(&file).unwrap();
        let odd = (CLAUDE_PID_ENV, "42;x");
        claim_terminal("claude", "SessionStart", None, Some("outer-1"), env(&[here, envfile, odd]));
        assert_eq!(
            fs::read_to_string(&file).unwrap_or_default(),
            format!("export {OWNER_ENV}=term_a/outer-1\n")
        );
    }

    #[test]
    fn any_launcher_plugin_session_start_claims_the_terminal_in_the_env_file() {
        let dir = tempfile::tempdir().unwrap();
        // Claude Code names the file but does not create it.
        let file = dir.path().join("env.sh");
        let path = file.to_str().unwrap();
        let plugin = (ORIGIN_ENV, PLUGIN_ORIGIN);
        let here = (TERMINAL_ENV, "term_a");
        let envfile = (CLAUDE_ENV_FILE, path);
        claim_terminal(
            "claude",
            "SessionStart",
            None,
            Some("outer-1"),
            env(&[plugin, here, envfile]),
        );
        assert_eq!(
            fs::read_to_string(&file).unwrap_or_default(),
            format!("export {OWNER_ENV}=term_a/outer-1\n")
        );
        // The installed or shim copy of SessionStart claims too.
        let installed_file = dir.path().join("installed.sh");
        let installed_path = installed_file.to_str().unwrap();
        claim_terminal(
            "claude",
            "SessionStart",
            None,
            Some("outer-1"),
            env(&[here, (CLAUDE_ENV_FILE, installed_path)]),
        );
        assert_eq!(
            fs::read_to_string(&installed_file).unwrap_or_default(),
            format!("export {OWNER_ENV}=term_a/outer-1\n")
        );
        fs::write(&file, "export KEEP=1\n").unwrap();
        claim_terminal(
            "claude",
            "SessionStart",
            None,
            Some("outer-1"),
            env(&[plugin, here, envfile]),
        );
        // Not a SessionStart, not Claude, an id a shell would read as code, or
        // no session: nothing is written.
        claim_terminal("claude", "Stop", None, Some("outer-1"), env(&[plugin, here, envfile]));
        claim_terminal(
            "codex",
            "SessionStart",
            None,
            Some("outer-1"),
            env(&[plugin, here, envfile]),
        );
        claim_terminal(
            "claude",
            "SessionStart",
            None,
            Some("x;rm -rf ~"),
            env(&[plugin, here, envfile]),
        );
        claim_terminal("claude", "SessionStart", None, None, env(&[plugin, here, envfile]));
        claim_terminal(
            "claude",
            "SessionStart",
            None,
            Some("outer-1"),
            env(&[plugin, (TERMINAL_ENV, "term_a$(x)"), envfile]),
        );
        assert_eq!(
            fs::read_to_string(&file).unwrap(),
            format!("export KEEP=1\nexport {OWNER_ENV}=term_a/outer-1\n")
        );
        // The claim it exports makes a Claude that a tool command starts
        // stand down (tests/claude_any_launcher.rs sources the file in a shell).
        let written = fs::read_to_string(&file).unwrap();
        let claim = written
            .lines()
            .find_map(|line| line.strip_prefix(&format!("export {OWNER_ENV}=")))
            .unwrap();
        assert!(stands_down(
            "claude",
            "SessionStart",
            Some("nested-2"),
            env(&[plugin, here, (OWNER_ENV, claim)])
        ));
    }

    #[test]
    fn any_launcher_plugin_copy_stands_down_only_beside_an_installed_copy() {
        let dir = tempfile::tempdir().unwrap();
        let installed = dir.path().join("installed");
        let other = dir.path().join("other");
        let home = dir.path().join("home");
        for folder in [installed.clone(), other.clone(), home.join(".claude")] {
            fs::create_dir_all(folder).unwrap();
        }
        let installed_command = r#"h=${CMUX_TUI_HOOK:-x};"${h:-:}" 'claude' 'Stop' 2>/dev/null||:;echo {};#cmux-tui-journal-hook"#;
        let settings = |command: &str| {
            serde_json::json!({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": command}]}]}})
                .to_string()
        };
        fs::write(installed.join("settings.json"), settings(installed_command)).unwrap();
        // A user hook of its own, and a copied plugin command, are not installs.
        fs::write(other.join("settings.json"), settings("echo mine; echo {}")).unwrap();
        fs::write(
            home.join(".claude/settings.json"),
            settings(&format!("export {ORIGIN_ENV}={PLUGIN_ORIGIN};{installed_command}")),
        )
        .unwrap();
        let (installed, other, home) =
            (installed.to_str().unwrap(), other.to_str().unwrap(), home.to_str().unwrap());
        let plugin = (ORIGIN_ENV, PLUGIN_ORIGIN);
        let hook = ("CMUX_TUI_HOOK", "/opt/cmux-tui-hook");
        // The installed copy runs: the plugin copy stands down, for that event only.
        assert!(stands_down(
            "claude",
            "Stop",
            None,
            env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        assert!(!stands_down(
            "claude",
            "SessionStart",
            None,
            env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        // The installed command finds no helper: it is a no-op, the plugin reports.
        assert!(!stands_down(
            "claude",
            "Stop",
            None,
            env(&[plugin, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        // Another config directory without the install, or the default one.
        assert!(!stands_down(
            "claude",
            "Stop",
            None,
            env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", other)])
        ));
        assert!(!stands_down("claude", "Stop", None, env(&[plugin, hook, ("HOME", home)])));
        // Not the plugin copy: the installed run itself always reports.
        assert!(!stands_down(
            "claude",
            "Stop",
            None,
            env(&[hook, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        assert!(!stands_down(
            "codex",
            "Stop",
            None,
            env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        // Hooks turned off: the plugin copy does nothing.
        assert!(stands_down(
            "claude",
            "Stop",
            None,
            env(&[plugin, (HOOKS_DISABLED_ENV, "1"), ("CLAUDE_CONFIG_DIR", other)])
        ));
    }
}
