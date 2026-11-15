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
//! own `--settings` carries the hooks.
//!
//! Claude Code passes its environment, the plugin folder and the terminal's
//! variables too, to the commands its tools run, so a Claude that such a
//! command starts (`claude -p` in a Bash tool call) would report to the same
//! terminal and take the messages queued for the terminal's agent, through the
//! plugin, the installed hooks or the shim's hooks. So the copy of the hooks
//! that reports `SessionStart` claims the terminal for its session: it
//! appends `export CMUX_TUI_CLAUDE_OWNER=<terminal>/<session>` to Claude
//! Code's `CLAUDE_ENV_FILE`, which Claude Code sources before each Bash tool
//! command (its own hooks do not see it: Claude Code 2.1.319 names the file
//! and leaves creating it to the hook). Any copy of a Claude hook that finds a
//! claim for its terminal by another session does nothing. A Claude in
//! another terminal (`cmux agent start` from a tool command) reports to its
//! own terminal.

use std::ffi::OsString;
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

/// Set by the plugin's hook commands (cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN_ENV).
const ORIGIN_ENV: &str = "CMUX_TUI_HOOK_ORIGIN";
/// The plugin's value of [`ORIGIN_ENV`] (cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN).
const PLUGIN_ORIGIN: &str = "claude-plugin";
/// The terminal and session of the Claude whose tool commands run in this
/// environment (`<terminal>/<session>`).
const OWNER_ENV: &str = "CMUX_TUI_CLAUDE_OWNER";
/// The file a `SessionStart` hook may append `export` lines to; Claude Code
/// sources it before each Bash tool command.
const CLAUDE_ENV_FILE: &str = "CLAUDE_ENV_FILE";
/// The cmux-tui terminal the hook runs in.
const TERMINAL_ENV: &str = "CMUX_TUI_TERMINAL_ID";
/// Ends every hook command cmux-tui writes (cmux_tui_hooks COMMAND_MARKER).
const COMMAND_MARKER: &str = "cmux-tui-journal-hook";
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
    if claimed_by_another(session, &getenv) {
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
pub(super) fn claimed_elsewhere(
    source: &str,
    session: Option<&str>,
    getenv: impl Fn(&str) -> Option<OsString>,
) -> bool {
    source == "claude" && claimed_by_another(session, &getenv)
}

/// Whether this environment claims its terminal for a session other than
/// `session`.
fn claimed_by_another(session: Option<&str>, getenv: &impl Fn(&str) -> Option<OsString>) -> bool {
    claim(getenv).is_some_and(|(terminal, owner)| {
        terminal_of(getenv).as_deref() == Some(terminal.as_str()) && session != Some(owner.as_str())
    })
}

/// After a Claude `SessionStart` that reports (any copy: the plugin, the
/// installed hooks or the shim's): claims the terminal for `session` in
/// `CLAUDE_ENV_FILE`, created when missing, so the Claudes its tool commands
/// start stand down (a later claim, after `/clear`, replaces it). Does nothing
/// when an id holds anything but letters, digits, `-` and `_`.
pub(super) fn claim_terminal(
    source: &str,
    native_event: &str,
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
        terminal_of(&getenv),
        session.filter(plain),
        getenv(CLAUDE_ENV_FILE).filter(|file| !file.is_empty()),
    ) else {
        return;
    };
    if !plain(&terminal.as_str()) {
        return;
    }
    let line = format!("export {OWNER_ENV}={terminal}/{session}\n");
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

/// The terminal and session of the claim in this environment.
fn claim(getenv: &impl Fn(&str) -> Option<OsString>) -> Option<(String, String)> {
    let claim = getenv(OWNER_ENV)?.into_string().ok()?;
    let (terminal, session) = claim.split_once('/')?;
    Some((terminal.to_owned(), session.to_owned()))
}

/// Whether an installed command finds a helper: `CMUX_TUI_HOOK`, or inside
/// tmux the installed helper (cmux_tui_hooks message_hooks.rs).
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
#[path = "plugin_copy_tests.rs"]
mod tests;
