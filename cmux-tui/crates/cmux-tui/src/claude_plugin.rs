//! The Claude Code plugin that gives every Claude in a cmux-tui pane the
//! session's hooks, however it was started.
//!
//! The `claude` shim only covers a Claude found on PATH. Launchers that run
//! Claude by its full path with their own config directory and `--settings`
//! (`sr2 claude`, version managers, a login shell that puts `~/.local/bin`
//! back in front, a typed full path) skip it. Claude Code 2.1 loads every
//! plugin folder named in `CLAUDE_CODE_PLUGIN_DIRS` for any config directory
//! and beside any `--settings`, and launchers keep the environment. So each
//! build writes a plugin (`.claude-plugin/plugin.json`, `hooks/hooks.json`)
//! into its own folder and the daemon adds that folder to the pane's
//! `CLAUDE_CODE_PLUGIN_DIRS`, after any folders the daemon inherited.
//!
//! The plugin's hooks are the installed ones marked as the plugin copy, which
//! stands down when the installed copy also runs (cmux-tui-hook
//! plugin_copy.rs), plus the `SessionStart` session context. The shim's
//! wrapper drops the plugin from the folders it passes on, because its own
//! `--settings` carries the same hooks.
//!
//! An organization policy with `disableSideloadFlags` makes Claude Code
//! refuse to start while `CLAUDE_CODE_PLUGIN_DIRS` names a folder, so the
//! daemon adds none when this machine's managed settings set it.

use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::Read as _;
use std::path::{Path, PathBuf};

use anyhow::Context as _;
use serde_json::{Value, json};

use crate::agent_hook_install;

/// The variable Claude Code reads plugin folders from (`:`-separated,
/// absolute paths only).
pub(crate) const PLUGIN_DIRS_ENV: &str = "CLAUDE_CODE_PLUGIN_DIRS";
/// The plugin's name; a folder whose manifest names it is a cmux-tui plugin
/// (so is a build's plugin folder, by its place: [`PLUGIN_FOLDER`]).
const PLUGIN_NAME: &str = "cmux-tui";
const MANIFEST: &str = ".claude-plugin/plugin.json";
/// The folder a build writes its plugin into, inside its build folder
/// (`<data>/cmux-tui/builds/<build>/claude-plugin`, own_build_helpers.rs).
pub(crate) const PLUGIN_FOLDER: &str = "claude-plugin";
const HOOKS: &str = "hooks/hooks.json";
/// The policy key that makes Claude Code refuse plugin folders from the
/// environment.
const SIDELOAD_POLICY_KEY: &str = "disableSideloadFlags";
/// Manifests and policy files are small; anything larger is not read.
const MAX_FILE_BYTES: u64 = 4 * 1024 * 1024;

/// Writes this build's plugin into `dir` (files rewritten only when their
/// content changed): hooks that run `helper` and the session context that
/// runs `executable`.
pub(crate) fn install(dir: &Path, executable: &Path, helper: &Path) -> anyhow::Result<()> {
    let manifest = json!({
        "name": PLUGIN_NAME,
        "version": env!("CARGO_PKG_VERSION"),
        "description": "cmux-tui session hooks for Claude Code in a cmux-tui terminal",
    });
    let mut hooks = agent_hook_install::claude_plugin_hook_settings(helper)?;
    let context = json!({"hooks": [{
        "type": "command",
        "command": crate::agent_session_context::hook_command(executable)
            .context("the cmux-tui path is not UTF-8")?,
        "timeout": 10,
    }]});
    hooks
        .get_mut("hooks")
        .and_then(Value::as_object_mut)
        .context("plugin hooks missing")?
        .entry("SessionStart")
        .or_insert_with(|| Value::Array(Vec::new()))
        .as_array_mut()
        .context("SessionStart hooks are not a list")?
        .push(context);
    write_if_changed(&dir.join(MANIFEST), &serde_json::to_vec_pretty(&manifest)?)?;
    write_if_changed(&dir.join(HOOKS), &serde_json::to_vec_pretty(&Value::Object(hooks))?)?;
    Ok(())
}

fn write_if_changed(path: &Path, data: &[u8]) -> anyhow::Result<()> {
    if fs::read(path).is_ok_and(|existing| existing == data) {
        return Ok(());
    }
    agent_hook_install::atomic_write(path, data, Some(0o644))
}

/// The pane's `CLAUDE_CODE_PLUGIN_DIRS`: the `inherited` folders except other
/// cmux-tui plugins (a daemon started inside another build's pane), then
/// `dir`. `None` when a folder cannot be joined (it holds a `:`).
pub(crate) fn pane_plugin_dirs(inherited: Option<&OsStr>, dir: &Path) -> Option<OsString> {
    let kept = inherited
        .map(|value| kept_folders(value, |folder| folder != dir && !is_cmux_tui_plugin(folder)))
        .unwrap_or_default();
    std::env::join_paths(kept.into_iter().chain(std::iter::once(dir.to_path_buf()))).ok()
}

/// `value` without cmux-tui plugin folders, for a launch whose hooks travel
/// another way; `None` when nothing is left.
pub(crate) fn without_cmux_plugins(value: &OsStr) -> Option<OsString> {
    let kept = kept_folders(value, |folder| !is_cmux_tui_plugin(folder));
    if kept.is_empty() {
        return None;
    }
    std::env::join_paths(kept).ok()
}

fn kept_folders(value: &OsStr, keep: impl Fn(&Path) -> bool) -> Vec<PathBuf> {
    std::env::split_paths(value)
        .filter(|folder| !folder.as_os_str().is_empty() && keep(folder))
        .collect()
}

/// Whether `folder` is a cmux-tui plugin: a build's plugin folder
/// (`…/cmux-tui/builds/<build>/claude-plugin`, which holds for a build
/// deleted since), or a folder whose manifest names it `cmux-tui`.
fn is_cmux_tui_plugin(folder: &Path) -> bool {
    let builds = folder.parent().and_then(Path::parent);
    let named = |path: Option<&Path>, name: &str| {
        path.and_then(Path::file_name).is_some_and(|file| file == name)
    };
    if named(Some(folder), PLUGIN_FOLDER)
        && named(builds, "builds")
        && named(builds.and_then(Path::parent), "cmux-tui")
    {
        return true;
    }
    read_small(&folder.join(MANIFEST))
        .and_then(|data| serde_json::from_slice::<Value>(&data).ok())
        .is_some_and(|manifest| manifest.get("name").and_then(Value::as_str) == Some(PLUGIN_NAME))
}

fn read_small(path: &Path) -> Option<Vec<u8>> {
    let mut data = Vec::new();
    fs::File::open(path).ok()?.take(MAX_FILE_BYTES).read_to_end(&mut data).ok()?;
    Some(data)
}

/// The places Claude Code reads policy from on this machine, for
/// [`sideloading_disabled`]: managed settings (and their `.d` drop-ins),
/// macOS managed preferences, and the cached remote settings of the
/// daemon's config directory.
pub(crate) fn policy_files(home: Option<&Path>, config_dir: Option<&Path>) -> Vec<PathBuf> {
    let managed = if cfg!(target_os = "macos") {
        PathBuf::from("/Library/Application Support/ClaudeCode")
    } else {
        PathBuf::from("/etc/claude-code")
    };
    let mut files = vec![managed.join("managed-settings.json")];
    if let Ok(entries) = fs::read_dir(managed.join("managed-settings.d")) {
        let mut dropins: Vec<PathBuf> = entries.flatten().map(|entry| entry.path()).collect();
        dropins.sort();
        files.extend(dropins);
    }
    if cfg!(target_os = "macos") {
        let preferences = Path::new("/Library/Managed Preferences");
        files.push(preferences.join("com.anthropic.claudecode.plist"));
        if let Some(user) = std::env::var_os("USER").filter(|user| !user.is_empty()) {
            files.push(preferences.join(user).join("com.anthropic.claudecode.plist"));
        }
    }
    let config =
        config_dir.map(Path::to_path_buf).or_else(|| home.map(|home| home.join(".claude")));
    if let Some(config) = config {
        files.push(config.join("remote-settings.json"));
    }
    files
}

/// Whether any of `files` turns on `disableSideloadFlags`. A JSON file
/// counts when the key is `true` anywhere in it; any other file (a property
/// list) counts when it names the key at all, so a policy is never missed.
pub(crate) fn sideloading_disabled(files: &[PathBuf]) -> bool {
    files.iter().filter_map(|file| read_small(file)).any(|data| {
        match serde_json::from_slice::<Value>(&data) {
            Ok(value) => names_policy(&value),
            Err(_) => data
                .windows(SIDELOAD_POLICY_KEY.len())
                .any(|window| window == SIDELOAD_POLICY_KEY.as_bytes()),
        }
    })
}

fn names_policy(value: &Value) -> bool {
    match value {
        Value::Object(map) => map.iter().any(|(key, value)| {
            (key == SIDELOAD_POLICY_KEY && value == &Value::Bool(true)) || names_policy(value)
        }),
        Value::Array(items) => items.iter().any(names_policy),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn plugin(folder: &Path, name: &str) {
        fs::create_dir_all(folder.join(".claude-plugin")).unwrap();
        fs::write(folder.join(MANIFEST), json!({"name": name}).to_string()).unwrap();
    }

    #[test]
    fn any_launcher_plugin_copy_constants_match_the_command_writer() {
        use crate::hook_helper::plugin_copy;
        assert_eq!(plugin_copy::ORIGIN_ENV, agent_hook_install::CLAUDE_PLUGIN_ORIGIN_ENV);
        assert_eq!(plugin_copy::PLUGIN_ORIGIN, agent_hook_install::CLAUDE_PLUGIN_ORIGIN);
    }

    #[test]
    fn any_launcher_pane_plugin_dirs_keep_other_plugins_and_replace_cmux_ones() {
        let root = tempfile::tempdir().unwrap();
        let mine = root.path().join("mine");
        let other_build = root.path().join("other-build");
        let person = root.path().join("person");
        plugin(&other_build, PLUGIN_NAME);
        plugin(&person, "my-plugin");
        let inherited = std::env::join_paths([&other_build, &person, &mine]).unwrap();
        let value = pane_plugin_dirs(Some(&inherited), &mine).unwrap();
        assert_eq!(
            std::env::split_paths(&value).collect::<Vec<_>>(),
            [person.clone(), mine.clone()]
        );
        assert_eq!(pane_plugin_dirs(None, &mine).unwrap().as_os_str(), mine.as_os_str());

        install(&mine, Path::new("/opt/cmux tui/cmux-tui"), Path::new("/opt/cmux tui/hook"))
            .unwrap();
        let both = std::env::join_paths([&person, &mine]).unwrap();
        assert_eq!(without_cmux_plugins(&both).unwrap().as_os_str(), person.as_os_str());
        assert_eq!(without_cmux_plugins(mine.as_os_str()), None);
    }

    #[test]
    fn any_launcher_pane_plugin_dirs_drop_the_folder_of_a_deleted_build() {
        let root = tempfile::tempdir().unwrap();
        let mine = root.path().join("data/cmux-tui/builds/0123abcd/claude-plugin");
        // Another build's plugin folder, deleted with its build: no manifest.
        let deleted = root.path().join("data/cmux-tui/builds/4567ef01/claude-plugin");
        // The person's folder of the same name, elsewhere, stays.
        let person = root.path().join("tools/claude-plugin");
        let inherited = std::env::join_paths([&deleted, &person]).unwrap();
        let value = pane_plugin_dirs(Some(&inherited), &mine).unwrap();
        assert_eq!(std::env::split_paths(&value).collect::<Vec<_>>(), [person.clone(), mine]);
        assert_eq!(without_cmux_plugins(&inherited).unwrap().as_os_str(), person.as_os_str());
    }

    #[test]
    fn any_launcher_plugin_has_the_hooks_and_the_session_context() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("plugin");
        let executable = Path::new("/opt/cmux-tui");
        install(&dir, executable, Path::new("/opt/cmux-tui-hook")).unwrap();
        let first = fs::read(dir.join(HOOKS)).unwrap();
        install(&dir, executable, Path::new("/opt/cmux-tui-hook")).unwrap();
        assert_eq!(fs::read(dir.join(HOOKS)).unwrap(), first);
        assert!(is_cmux_tui_plugin(&dir));
        let hooks: Value = serde_json::from_slice(&first).unwrap();
        let commands = |event: &str| {
            hooks["hooks"][event]
                .as_array()
                .into_iter()
                .flatten()
                .flat_map(|group| group["hooks"].as_array().into_iter().flatten())
                .filter_map(|hook| hook["command"].as_str().map(str::to_owned))
                .collect::<Vec<_>>()
        };
        let start = commands("SessionStart");
        assert_eq!(start.len(), 2, "{start:?}");
        assert!(start.iter().any(|command| command.contains("agent session-context")));
        assert!(start.iter().any(|command| command.contains("/opt/cmux-tui-hook")));
        for event in ["Stop", "UserPromptSubmit", "PreToolUse", "Notification"] {
            let found = commands(event);
            assert_eq!(found.len(), 1, "{event}: {found:?}");
            assert!(found[0].contains(agent_hook_install::CLAUDE_PLUGIN_ORIGIN_ENV), "{event}");
        }
    }

    #[test]
    fn any_launcher_sideload_policy_is_found_in_json_and_property_lists() {
        let root = tempfile::tempdir().unwrap();
        let write = |name: &str, data: &[u8]| {
            let path = root.path().join(name);
            fs::write(&path, data).unwrap();
            path
        };
        let off = write("off.json", br#"{"disableSideloadFlags": false, "env": {}}"#);
        let none = write("none.json", br#"{"permissions": {"deny": []}}"#);
        let nested = write("nested.json", br#"{"settings": {"disableSideloadFlags": true}}"#);
        let plist = write("p.plist", b"bplist00\x01disableSideloadFlags\x09");
        let missing = root.path().join("missing.json");
        assert!(!sideloading_disabled(&[off.clone(), none.clone(), missing]));
        assert!(sideloading_disabled(&[off, nested]));
        assert!(sideloading_disabled(&[none, plist]));
        let files = policy_files(Some(root.path()), None);
        assert!(files.contains(&root.path().join(".claude/remote-settings.json")), "{files:?}");
    }
}
