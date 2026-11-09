//! The plugin copy of Claude Code's hooks stands down when another copy runs.
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

use std::ffi::OsString;
use std::io::Read as _;
use std::path::{Path, PathBuf};

/// Set by the plugin's hook commands (cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN_ENV).
const ORIGIN_ENV: &str = "CMUX_TUI_HOOK_ORIGIN";
/// The plugin's value of [`ORIGIN_ENV`] (cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN).
const PLUGIN_ORIGIN: &str = "claude-plugin";
/// Ends every hook command cmux-tui writes (cmux_tui_hooks COMMAND_MARKER).
const COMMAND_MARKER: &str = "cmux-tui-journal-hook";
/// `1` turns cmux-tui's Claude hooks off (claude_wrapper.rs).
const HOOKS_DISABLED_ENV: &str = "CMUX_TUI_CLAUDE_HOOKS_DISABLED";
/// Settings files are small; a larger one is not read.
const MAX_SETTINGS_BYTES: u64 = 16 * 1024 * 1024;

/// Whether this run is the plugin copy of a Claude hook that must do nothing:
/// cmux-tui's Claude hooks are turned off, or the installed copy of the same
/// event runs in this Claude too.
pub(super) fn stands_down(
    source: &str,
    native_event: &str,
    getenv: impl Fn(&str) -> Option<OsString>,
) -> bool {
    if source != "claude" || getenv(ORIGIN_ENV).is_none_or(|origin| origin != PLUGIN_ORIGIN) {
        return false;
    }
    if getenv(HOOKS_DISABLED_ENV).is_some_and(|value| value == "1") {
        return true;
    }
    installed_copy_runs(&getenv)
        && user_settings(&getenv).is_some_and(|path| installs_event(&path, native_event))
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
    fn any_launcher_plugin_copy_constants_match_the_command_writer() {
        assert_eq!(ORIGIN_ENV, cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN_ENV);
        assert_eq!(PLUGIN_ORIGIN, cmux_tui_hooks::CLAUDE_PLUGIN_ORIGIN);
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
            env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        assert!(!stands_down(
            "claude",
            "SessionStart",
            env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        // The installed command finds no helper: it is a no-op, the plugin reports.
        assert!(!stands_down("claude", "Stop", env(&[plugin, ("CLAUDE_CONFIG_DIR", installed)])));
        // Another config directory without the install, or the default one.
        assert!(!stands_down("claude", "Stop", env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", other)])));
        assert!(!stands_down("claude", "Stop", env(&[plugin, hook, ("HOME", home)])));
        // Not the plugin copy: the installed run itself always reports.
        assert!(!stands_down("claude", "Stop", env(&[hook, ("CLAUDE_CONFIG_DIR", installed)])));
        assert!(!stands_down(
            "codex",
            "Stop",
            env(&[plugin, hook, ("CLAUDE_CONFIG_DIR", installed)])
        ));
        // Hooks turned off: the plugin copy does nothing.
        assert!(stands_down(
            "claude",
            "Stop",
            env(&[plugin, (HOOKS_DISABLED_ENV, "1"), ("CLAUDE_CONFIG_DIR", other)])
        ));
    }
}
