//! Claude Code and Codex hooks, read and edited where each CLI keeps them.
//!
//! Claude Code reads `hooks` (event -> matcher groups -> handlers) from
//! `<config>/settings.json`, `<config>/settings.local.json`, the project's
//! `.claude/settings.json` and `.claude/settings.local.json`, and the
//! `hooks/hooks.json` of each enabled plugin. Codex reads `hooks.json` in
//! `$CODEX_HOME` and in the project's `.codex/`, plus `[hooks]` tables in
//! `config.toml`, and keeps a per-handler state in the user
//! `config.toml` (`[hooks.state."<file>:<event>:<group>:<handler>"]`, with
//! `enabled` and `trusted_hash`).
//!
//! Disabling: Codex has a per-handler `enabled = false`, which is what cmux
//! writes. Claude Code has only the all-or-nothing `disableAllHooks`, so a
//! disabled Claude handler is moved out of the settings file into a cmux-owned
//! store (`<store>/claude-disabled-hooks.json`) with the event's layout as it
//! was before the first one went (its groups and handlers, and the order of
//! the events), and enabling puts it back there, in any order. Every write keeps the file's other keys
//! and their order, goes through a temp file and rename, and leaves the prior
//! file in `<store>/backups/`.
//!
//! Handlers cmux installs itself (cmux-tui-hooks' journal hooks, classic
//! cmux's `~/.cmux/hooks/cmux-*-hook-*` scripts) are labelled `cmux` and
//! refuse edits unless the caller passes `allow_cmux`.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Instant;

use anyhow::{Context as _, bail};
use indexmap::IndexMap;
use serde::Serialize;
use sha2::Digest as _;

use crate::hooks_ojson::OJson;
use crate::hooks_paths::AgentPaths;

/// Which coding agent a hook belongs to.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        match text {
            "claude" | "claude-code" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            other => bail!("unknown agent {other:?} (expected claude or codex)"),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }
}

/// Which config layer a hook comes from.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Scope {
    /// `~/.claude/settings.json`, `$CODEX_HOME/hooks.json`.
    User,
    /// `~/.claude/settings.local.json`.
    UserLocal,
    /// `$CODEX_HOME/config.toml` `[hooks]` tables (listed; edited in place
    /// only through `enabled`).
    UserConfig,
    /// `<project>/.claude/settings.json`, `<project>/.codex/hooks.json`.
    Project,
    /// `<project>/.claude/settings.local.json`.
    ProjectLocal,
    /// An enabled Claude Code plugin's `hooks/hooks.json` (read-only).
    Plugin,
}

impl Scope {
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        match text {
            "user" => Ok(Self::User),
            "user-local" => Ok(Self::UserLocal),
            "project" => Ok(Self::Project),
            "project-local" => Ok(Self::ProjectLocal),
            other => bail!(
                "unknown scope {other:?} (expected user, user-local, project or project-local)"
            ),
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::UserLocal => "user-local",
            Self::UserConfig => "user-config",
            Self::Project => "project",
            Self::ProjectLocal => "project-local",
            Self::Plugin => "plugin",
        }
    }
}

/// Who wrote the hook.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Owner {
    /// The person (or a tool other than cmux).
    User,
    /// cmux's own journal and session hooks.
    Cmux,
    /// A Claude Code plugin.
    Plugin,
}

/// One hook handler.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct HookEntry {
    /// Stable id: a hash of agent, scope, event, matcher and handler, with
    /// `-N` for the Nth identical handler. It survives disable/enable and
    /// edits elsewhere in the file.
    pub id: String,
    pub agent: Agent,
    pub scope: Scope,
    /// The file the handler lives in (for a disabled Claude handler: the
    /// file it goes back to).
    pub file: PathBuf,
    pub event: String,
    pub matcher: Option<String>,
    /// `command`, `prompt`, `agent`, `http`, ...
    #[serde(rename = "type")]
    pub kind: String,
    /// The command (or prompt / URL for other handler types).
    pub command: String,
    pub timeout: Option<u64>,
    pub enabled: bool,
    pub owner: Owner,
    /// cmux and plugin entries are read-only unless forced.
    pub read_only: bool,
    /// Codex only: `trusted`, `untrusted` (never approved, Codex skips it)
    /// or `modified` (changed since it was approved, Codex skips it).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub trust: Option<&'static str>,
    /// Codex only: the `hooks.state` key.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub state_key: Option<String>,
    /// Plugin entries: the plugin's name.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin: Option<String>,
    /// Handler fields Codex's trust hash covers.
    #[serde(skip)]
    asynchronous: bool,
    #[serde(skip)]
    status_message: Option<String>,
    #[serde(skip)]
    additional_context_limit: Option<u64>,
    #[serde(skip)]
    location: Location,
}

#[derive(Clone, Debug, PartialEq, Default)]
struct Location {
    group: usize,
    handler: usize,
    /// Index in the Claude disabled store.
    disabled_index: Option<usize>,
}

/// One config file the listing read.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct SourceFile {
    pub agent: Agent,
    pub scope: Scope,
    pub path: PathBuf,
    pub exists: bool,
    pub hooks: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// Claude: the file sets `disableAllHooks: true`.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    pub disable_all_hooks: bool,
}

/// Everything `list` found.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct HookList {
    pub hooks: Vec<HookEntry>,
    pub files: Vec<SourceFile>,
    /// Claude: the disabled store's path.
    pub disabled_store: PathBuf,
    /// Codex: whether `[features] hooks` is on in config.toml (Codex runs no
    /// hook while it is off).
    pub codex_hooks_feature: Option<bool>,
    pub elapsed_micros: u64,
}

impl HookList {
    pub fn count(&self, agent: Agent) -> usize {
        self.hooks.iter().filter(|hook| hook.agent == agent).count()
    }
}

/// What `add` writes.
#[derive(Clone, Debug)]
pub struct NewHook {
    pub agent: Agent,
    pub scope: Scope,
    pub event: String,
    pub matcher: Option<String>,
    pub command: String,
    pub timeout: Option<u64>,
}

/// Claude Code hook events (code.claude.com/docs/en/hooks).
pub const CLAUDE_EVENTS: &[&str] = &[
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Notification",
    "UserPromptSubmit",
    "Stop",
    "StopFailure",
    "SubagentStart",
    "SubagentStop",
    "PreCompact",
    "PostCompact",
    "SessionStart",
    "SessionEnd",
    "Setup",
    "TeammateIdle",
    "TaskCompleted",
    "ConfigChange",
    "WorktreeCreate",
    "WorktreeRemove",
    "InstructionsLoaded",
    "Elicitation",
    "ElicitationResult",
];

/// Codex hook events (codex-rs/config/src/hook_config.rs `HookEventsToml`).
pub const CODEX_EVENTS: &[&str] = &[
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "SessionStart",
    "SessionEnd",
    "UserPromptSubmit",
    "SubagentStart",
    "SubagentStop",
    "Stop",
];

const DISABLED_STORE_FILE: &str = "claude-disabled-hooks.json";

/// Whether `command` is one cmux installed: cmux-tui-hooks' journal hooks or
/// classic cmux's per-agent hook scripts in `~/.cmux/hooks/`.
pub fn is_cmux_command(command: &str) -> bool {
    cmux_tui_hooks::is_owned_hook_command(command)
        || command.contains("/.cmux/hooks/cmux-")
        || command.contains("cmux-claude-hook")
        || command.contains("cmux-codex-hook")
}

// ---------------------------------------------------------------- listing

/// Every Claude Code and Codex hook under `paths`, enabled or not.
pub fn list(paths: &AgentPaths) -> HookList {
    let started = Instant::now();
    let mut hooks = Vec::new();
    let mut files = Vec::new();
    list_claude(paths, &mut hooks, &mut files);
    let codex_hooks_feature = list_codex(paths, &mut hooks, &mut files);
    assign_ids(&mut hooks);
    HookList {
        hooks,
        files,
        disabled_store: disabled_store_path(paths),
        codex_hooks_feature,
        elapsed_micros: started.elapsed().as_micros() as u64,
    }
}

fn claude_files(paths: &AgentPaths) -> Vec<(Scope, PathBuf)> {
    let mut files = vec![
        (Scope::User, paths.claude_dir.join("settings.json")),
        (Scope::UserLocal, paths.claude_dir.join("settings.local.json")),
    ];
    if let Some(project) = &paths.project {
        files.push((Scope::Project, project.join(".claude/settings.json")));
        files.push((Scope::ProjectLocal, project.join(".claude/settings.local.json")));
    }
    files
}

fn claude_file_for(paths: &AgentPaths, scope: Scope) -> anyhow::Result<PathBuf> {
    claude_files(paths)
        .into_iter()
        .find(|(candidate, _)| *candidate == scope)
        .map(|(_, path)| path)
        .with_context(|| match scope {
            Scope::Project | Scope::ProjectLocal => {
                "the project scope needs a project folder (--project)".to_string()
            }
            other => format!("Claude Code has no {} hooks file", other.as_str()),
        })
}

fn list_claude(paths: &AgentPaths, hooks: &mut Vec<HookEntry>, files: &mut Vec<SourceFile>) {
    let mut enabled_plugins: IndexMap<String, bool> = IndexMap::new();
    for (scope, path) in claude_files(paths) {
        let mut source = SourceFile {
            agent: Agent::Claude,
            scope,
            path: path.clone(),
            exists: path.exists(),
            hooks: 0,
            error: None,
            disable_all_hooks: false,
        };
        match read_json(&path) {
            Ok(Some(root)) => {
                source.disable_all_hooks =
                    root.get("disableAllHooks").and_then(OJson::as_bool) == Some(true);
                if let Some(plugins) = root.get("enabledPlugins").and_then(OJson::as_object) {
                    for (name, on) in plugins {
                        enabled_plugins.insert(name.clone(), on.as_bool().unwrap_or(false));
                    }
                }
                let before = hooks.len();
                collect_json_hooks(&root, Agent::Claude, scope, &path, None, hooks);
                source.hooks = hooks.len() - before;
            }
            Ok(None) => {}
            Err(error) => source.error = Some(format!("{error:#}")),
        }
        files.push(source);
    }
    // Disabled handlers parked in the cmux store.
    let store_path = disabled_store_path(paths);
    match read_disabled_store(&store_path) {
        Ok(store) => {
            for (index, record) in store.iter().enumerate() {
                let Some(scope) =
                    record.get("scope").and_then(OJson::as_str).and_then(|s| Scope::parse(s).ok())
                else {
                    continue;
                };
                let Some(file) = record.get("file").and_then(OJson::as_str).map(PathBuf::from)
                else {
                    continue;
                };
                // Only entries whose home file is one this listing covers.
                if !claude_files(paths).iter().any(|(_, path)| *path == file) {
                    continue;
                }
                let Some(event) = record.get("event").and_then(OJson::as_str) else { continue };
                let Some(handler) = record.get("handler") else { continue };
                let matcher = record.get("matcher").and_then(OJson::as_str).map(str::to_owned);
                let mut entry =
                    handler_entry(Agent::Claude, scope, &file, event, matcher, handler, None);
                entry.enabled = false;
                entry.location = Location {
                    group: record.get("group").and_then(OJson::as_u64).unwrap_or(0) as usize,
                    handler: record.get("index").and_then(OJson::as_u64).unwrap_or(0) as usize,
                    disabled_index: Some(index),
                };
                hooks.push(entry);
            }
        }
        Err(error) => files.push(SourceFile {
            agent: Agent::Claude,
            scope: Scope::User,
            path: store_path,
            exists: true,
            hooks: 0,
            error: Some(format!("{error:#}")),
            disable_all_hooks: false,
        }),
    }
    // Enabled plugins' hooks (read-only).
    for (plugin, folder) in claude_plugin_folders(paths, &enabled_plugins) {
        let path = folder.join("hooks/hooks.json");
        let mut source = SourceFile {
            agent: Agent::Claude,
            scope: Scope::Plugin,
            path: path.clone(),
            exists: path.exists(),
            hooks: 0,
            error: None,
            disable_all_hooks: false,
        };
        match read_json(&path) {
            Ok(Some(root)) => {
                let before = hooks.len();
                collect_json_hooks(
                    &root,
                    Agent::Claude,
                    Scope::Plugin,
                    &path,
                    Some(&plugin),
                    hooks,
                );
                source.hooks = hooks.len() - before;
            }
            Ok(None) => {}
            Err(error) => source.error = Some(format!("{error:#}")),
        }
        files.push(source);
    }
}

/// Folders of the enabled Claude Code plugins: `enabledPlugins` names looked
/// up in `plugins/installed_plugins.json`, plus `CLAUDE_CODE_PLUGIN_DIRS`.
fn claude_plugin_folders(
    paths: &AgentPaths,
    enabled: &IndexMap<String, bool>,
) -> Vec<(String, PathBuf)> {
    let mut folders = Vec::new();
    if let Ok(Some(installed)) = read_json(&paths.claude_dir.join("plugins/installed_plugins.json"))
    {
        let plugins = installed.get("plugins").unwrap_or(&installed);
        for (name, on) in enabled {
            if !on {
                continue;
            }
            let installs = plugins.get(name);
            let install = match installs {
                Some(OJson::Array(items)) => items.first(),
                Some(other @ OJson::Object(_)) => Some(other),
                _ => None,
            };
            if let Some(path) =
                install.and_then(|install| install.get("installPath")).and_then(OJson::as_str)
            {
                folders.push((name.clone(), PathBuf::from(path)));
            }
        }
    }
    for folder in &paths.claude_plugin_dirs {
        if acpmux_free_is_cmux_plugin(folder) {
            continue;
        }
        let name =
            folder.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default();
        folders.push((name, folder.clone()));
    }
    folders
}

/// cmux-tui's own Claude plugin (`…/cmux-tui/builds/<build>/claude-plugin`)
/// carries its journal hooks; the session settings already show those.
fn acpmux_free_is_cmux_plugin(folder: &Path) -> bool {
    let parts: Vec<_> = folder
        .components()
        .rev()
        .take(4)
        .map(|part| part.as_os_str().to_string_lossy().into_owned())
        .collect();
    matches!(
        parts.as_slice(),
        [plugin, _, builds, tui] if plugin == "claude-plugin" && builds == "builds" && tui == "cmux-tui"
    )
}

fn list_codex(
    paths: &AgentPaths,
    hooks: &mut Vec<HookEntry>,
    files: &mut Vec<SourceFile>,
) -> Option<bool> {
    let config_path = paths.codex_home.join("config.toml");
    let config = match fs::read_to_string(&config_path) {
        Ok(text) => match text.parse::<toml_edit::DocumentMut>() {
            Ok(document) => Some(document),
            Err(error) => {
                files.push(SourceFile {
                    agent: Agent::Codex,
                    scope: Scope::UserConfig,
                    path: config_path.clone(),
                    exists: true,
                    hooks: 0,
                    error: Some(error.to_string()),
                    disable_all_hooks: false,
                });
                None
            }
        },
        Err(_) => None,
    };
    let states = config.as_ref().map(codex_states).unwrap_or_default();
    let feature = config.as_ref().and_then(|document| {
        document
            .get("features")
            .and_then(|features| features.get("hooks"))
            .and_then(|value| value.as_bool())
    });
    for (scope, path) in codex_files(paths) {
        let mut source = SourceFile {
            agent: Agent::Codex,
            scope,
            path: path.clone(),
            exists: path.exists(),
            hooks: 0,
            error: None,
            disable_all_hooks: false,
        };
        match read_json(&path) {
            Ok(Some(root)) => {
                let before = hooks.len();
                collect_json_hooks(&root, Agent::Codex, scope, &path, None, hooks);
                let key_path = paths.codex_state_key_path(&path);
                for hook in hooks.iter_mut().skip(before) {
                    apply_codex_state(hook, &key_path, &states);
                }
                source.hooks = hooks.len() - before;
            }
            Ok(None) => {}
            Err(error) => source.error = Some(format!("{error:#}")),
        }
        files.push(source);
    }
    // `[hooks.<Event>]` tables inside config.toml itself.
    if let Some(document) = &config
        && let Some(table) = document.get("hooks").and_then(|item| item.as_table_like())
    {
        let root = toml_hooks_as_json(table);
        let before = hooks.len();
        collect_json_hooks(&root, Agent::Codex, Scope::UserConfig, &config_path, None, hooks);
        let key_path = paths.codex_state_key_path(&config_path);
        for hook in hooks.iter_mut().skip(before) {
            hook.read_only = true;
            apply_codex_state(hook, &key_path, &states);
        }
        if hooks.len() > before {
            files.push(SourceFile {
                agent: Agent::Codex,
                scope: Scope::UserConfig,
                path: config_path,
                exists: true,
                hooks: hooks.len() - before,
                error: None,
                disable_all_hooks: false,
            });
        }
    }
    feature
}

fn codex_files(paths: &AgentPaths) -> Vec<(Scope, PathBuf)> {
    let mut files = vec![(Scope::User, paths.codex_home.join("hooks.json"))];
    if let Some(project) = &paths.project {
        files.push((Scope::Project, project.join(".codex/hooks.json")));
    }
    files
}

fn codex_file_for(paths: &AgentPaths, scope: Scope) -> anyhow::Result<PathBuf> {
    codex_files(paths)
        .into_iter()
        .find(|(candidate, _)| *candidate == scope)
        .map(|(_, path)| path)
        .with_context(|| match scope {
            Scope::Project => "the project scope needs a project folder (--project)".to_string(),
            other => format!("Codex has no {} hooks file (use user or project)", other.as_str()),
        })
}

#[derive(Clone, Debug, Default, PartialEq)]
struct CodexState {
    enabled: Option<bool>,
    trusted_hash: Option<String>,
}

fn codex_states(document: &toml_edit::DocumentMut) -> HashMap<String, CodexState> {
    let mut states = HashMap::new();
    let Some(table) = document
        .get("hooks")
        .and_then(|hooks| hooks.get("state"))
        .and_then(|state| state.as_table_like())
    else {
        return states;
    };
    for (key, item) in table.iter() {
        let Some(entry) = item.as_table_like() else { continue };
        states.insert(
            key.to_owned(),
            CodexState {
                enabled: entry.get("enabled").and_then(|value| value.as_bool()),
                trusted_hash: entry
                    .get("trusted_hash")
                    .and_then(|value| value.as_str())
                    .map(str::to_owned),
            },
        );
    }
    states
}

fn apply_codex_state(hook: &mut HookEntry, key_path: &Path, states: &HashMap<String, CodexState>) {
    let Ok(label) = cmux_tui_hooks::codex_hook_state_label(&hook.event) else {
        hook.trust = Some("unsupported");
        return;
    };
    let key =
        format!("{}:{label}:{}:{}", key_path.display(), hook.location.group, hook.location.handler);
    let state = states.get(&key);
    hook.enabled = state.and_then(|state| state.enabled) != Some(false);
    let current = codex_hash(hook);
    hook.trust = Some(match state.and_then(|state| state.trusted_hash.as_deref()) {
        Some(trusted) if Some(trusted) == current.as_deref() => "trusted",
        Some(_) => "modified",
        None => "untrusted",
    });
    hook.state_key = Some(key);
}

fn codex_hash(hook: &HookEntry) -> Option<String> {
    if hook.kind != "command" {
        return None;
    }
    let label = cmux_tui_hooks::codex_hook_state_label(&hook.event).ok()?;
    Some(cmux_tui_hooks::codex_hook_trust_hash(
        label,
        hook.matcher.as_deref(),
        &hook.command,
        hook.timeout,
        hook.asynchronous,
        hook.status_message.as_deref(),
        hook.additional_context_limit,
    ))
}

fn toml_hooks_as_json(table: &dyn toml_edit::TableLike) -> OJson {
    fn item_json(item: &toml_edit::Item) -> OJson {
        match item {
            toml_edit::Item::Value(value) => value_json(value),
            toml_edit::Item::Table(table) => OJson::Object(
                table.iter().map(|(key, item)| (key.to_owned(), item_json(item))).collect(),
            ),
            toml_edit::Item::ArrayOfTables(tables) => OJson::Array(
                tables
                    .iter()
                    .map(|table| {
                        OJson::Object(
                            table
                                .iter()
                                .map(|(key, item)| (key.to_owned(), item_json(item)))
                                .collect(),
                        )
                    })
                    .collect(),
            ),
            toml_edit::Item::None => OJson::Null,
        }
    }
    fn value_json(value: &toml_edit::Value) -> OJson {
        match value {
            toml_edit::Value::String(text) => OJson::String(text.value().clone()),
            toml_edit::Value::Integer(number) => OJson::Number((*number.value()).into()),
            toml_edit::Value::Float(number) => serde_json::Number::from_f64(*number.value())
                .map(OJson::Number)
                .unwrap_or(OJson::Null),
            toml_edit::Value::Boolean(flag) => OJson::Bool(*flag.value()),
            toml_edit::Value::Datetime(when) => OJson::String(when.value().to_string()),
            toml_edit::Value::Array(items) => OJson::Array(items.iter().map(value_json).collect()),
            toml_edit::Value::InlineTable(table) => OJson::Object(
                table.iter().map(|(key, value)| (key.to_owned(), value_json(value))).collect(),
            ),
        }
    }
    let mut events = IndexMap::new();
    for (key, item) in table.iter() {
        if key == "state" {
            continue;
        }
        events.insert(key.to_owned(), item_json(item));
    }
    let mut root = IndexMap::new();
    root.insert("hooks".to_owned(), OJson::Object(events));
    OJson::Object(root)
}

fn collect_json_hooks(
    root: &OJson,
    agent: Agent,
    scope: Scope,
    path: &Path,
    plugin: Option<&str>,
    hooks: &mut Vec<HookEntry>,
) {
    let Some(events) = root.get("hooks").and_then(OJson::as_object) else { return };
    for (event, groups) in events {
        let Some(groups) = groups.as_array() else { continue };
        for (group_index, group) in groups.iter().enumerate() {
            let matcher = group.get("matcher").and_then(OJson::as_str).map(str::to_owned);
            let Some(handlers) = group.get("hooks").and_then(OJson::as_array) else { continue };
            for (handler_index, handler) in handlers.iter().enumerate() {
                let mut entry =
                    handler_entry(agent, scope, path, event, matcher.clone(), handler, plugin);
                entry.location.group = group_index;
                entry.location.handler = handler_index;
                hooks.push(entry);
            }
        }
    }
}

fn handler_entry(
    agent: Agent,
    scope: Scope,
    path: &Path,
    event: &str,
    matcher: Option<String>,
    handler: &OJson,
    plugin: Option<&str>,
) -> HookEntry {
    let kind = handler.get("type").and_then(OJson::as_str).unwrap_or("command").to_owned();
    let command = ["command", "prompt", "url", "tool"]
        .iter()
        .find_map(|key| handler.get(key).and_then(OJson::as_str))
        .unwrap_or_default()
        .to_owned();
    let cmux = is_cmux_command(&command);
    let owner = if plugin.is_some() {
        Owner::Plugin
    } else if cmux {
        Owner::Cmux
    } else {
        Owner::User
    };
    HookEntry {
        id: String::new(),
        agent,
        scope,
        file: path.to_path_buf(),
        event: event.to_owned(),
        matcher: matcher.filter(|matcher| !matcher.is_empty()),
        kind,
        command,
        timeout: handler.get("timeout").and_then(OJson::as_u64),
        enabled: true,
        owner,
        read_only: owner != Owner::User,
        trust: None,
        state_key: None,
        plugin: plugin.map(str::to_owned),
        asynchronous: handler.get("async").and_then(OJson::as_bool).unwrap_or(false),
        status_message: handler.get("statusMessage").and_then(OJson::as_str).map(str::to_owned),
        additional_context_limit: handler.get("additionalContextLimit").and_then(OJson::as_u64),
        location: Location::default(),
    }
}

fn identity_hash(hook: &HookEntry) -> String {
    let mut hasher = sha2::Sha256::new();
    for part in [
        hook.agent.as_str(),
        hook.scope.as_str(),
        &hook.file.to_string_lossy(),
        &hook.event,
        hook.matcher.as_deref().unwrap_or(""),
        &hook.kind,
        &hook.command,
    ] {
        hasher.update(part.as_bytes());
        hasher.update([0]);
    }
    let digest = hasher.finalize();
    digest.iter().take(5).map(|byte| format!("{byte:02x}")).collect()
}

fn assign_ids(hooks: &mut [HookEntry]) {
    let mut seen: HashMap<String, usize> = HashMap::new();
    for hook in hooks.iter_mut() {
        let base = format!("{}-{}", hook.agent.as_str(), identity_hash(hook));
        let count = seen.entry(base.clone()).or_default();
        hook.id = if *count == 0 { base } else { format!("{base}-{count}") };
        *count += 1;
    }
}

// ---------------------------------------------------------------- edits

/// Looks `id` up in a fresh listing.
pub fn find(paths: &AgentPaths, id: &str) -> anyhow::Result<HookEntry> {
    let listing = list(paths);
    listing
        .hooks
        .into_iter()
        .find(|hook| hook.id == id)
        .with_context(|| format!("no hook with id {id:?} (run `cmux agent-config hooks list`)"))
}

fn check_editable(hook: &HookEntry, allow_cmux: bool) -> anyhow::Result<()> {
    match hook.owner {
        Owner::Plugin => bail!(
            "{} comes from the Claude Code plugin {}; turn the plugin off instead",
            hook.id,
            hook.plugin.as_deref().unwrap_or("?")
        ),
        Owner::Cmux if !allow_cmux => {
            bail!("{} is cmux's own hook; pass --allow-cmux to change it", hook.id)
        }
        _ => Ok(()),
    }
}

/// Turns one hook on or off. Returns the hook as listed afterwards.
pub fn set_enabled(
    paths: &AgentPaths,
    id: &str,
    enabled: bool,
    allow_cmux: bool,
) -> anyhow::Result<HookEntry> {
    let hook = find(paths, id)?;
    check_editable(&hook, allow_cmux)?;
    if hook.enabled == enabled {
        return Ok(hook);
    }
    match hook.agent {
        Agent::Codex => {
            let key = hook.state_key.as_deref().context("this Codex hook has no state key")?;
            edit_codex_config(paths, |document| {
                let entry = codex_state_entry(document, key)?;
                if enabled {
                    entry.remove("enabled");
                    drop_empty_codex_state(document, key);
                } else {
                    entry.insert("enabled", toml_edit::value(false));
                }
                Ok(())
            })?;
        }
        Agent::Claude if enabled => claude_enable(paths, &hook)?,
        Agent::Claude => claude_disable(paths, &hook)?,
    }
    find(paths, id)
}

/// Adds a user hook at the end of the event's groups; returns it as listed.
/// A new Codex hook is also marked trusted (the person adding it through
/// cmux approves it), so Codex runs it without a separate review.
pub fn add(paths: &AgentPaths, new: &NewHook) -> anyhow::Result<HookEntry> {
    let events = match new.agent {
        Agent::Claude => CLAUDE_EVENTS,
        Agent::Codex => CODEX_EVENTS,
    };
    if !events.contains(&new.event.as_str()) {
        bail!(
            "{} has no hook event {:?} (one of: {})",
            new.agent.as_str(),
            new.event,
            events.join(", ")
        );
    }
    if new.command.trim().is_empty() {
        bail!("a hook needs a command");
    }
    let path = match new.agent {
        Agent::Claude => claude_file_for(paths, new.scope)?,
        Agent::Codex => codex_file_for(paths, new.scope)?,
    };
    let mut handler = IndexMap::new();
    handler.insert("type".to_owned(), OJson::from("command"));
    handler.insert("command".to_owned(), OJson::from(new.command.as_str()));
    if let Some(timeout) = new.timeout {
        handler.insert("timeout".to_owned(), OJson::from(timeout));
    }
    let mut group = IndexMap::new();
    if let Some(matcher) = new.matcher.as_deref().filter(|matcher| !matcher.is_empty()) {
        group.insert("matcher".to_owned(), OJson::from(matcher));
    }
    group.insert("hooks".to_owned(), OJson::Array(vec![OJson::Object(handler)]));
    let mut group_index = 0;
    edit_json(paths, &path, |root| {
        let groups = event_groups_mut(root, &new.event)?;
        groups.push(OJson::Object(group));
        group_index = groups.len() - 1;
        Ok(())
    })?;
    let listing = list(paths);
    let hook = listing
        .hooks
        .into_iter()
        .find(|hook| {
            hook.file == path
                && hook.event == new.event
                && hook.location.group == group_index
                && hook.location.handler == 0
                && hook.enabled
        })
        .context("the new hook is not in the listing after the write")?;
    if hook.agent == Agent::Codex {
        let key = hook.state_key.clone().context("the new Codex hook has no state key")?;
        let hash = codex_hash(&hook).context("the new Codex hook has no trust hash")?;
        edit_codex_config(paths, |document| {
            let entry = codex_state_entry(document, &key)?;
            entry.remove("enabled");
            entry.insert("trusted_hash", toml_edit::value(hash));
            Ok(())
        })?;
        return find(paths, &hook.id);
    }
    Ok(hook)
}

/// Removes one hook (a disabled Claude hook is dropped from the store).
pub fn remove(paths: &AgentPaths, id: &str, allow_cmux: bool) -> anyhow::Result<HookEntry> {
    let hook = find(paths, id)?;
    check_editable(&hook, allow_cmux)?;
    if hook.read_only && hook.owner == Owner::User {
        bail!("{} lives in {}; edit that file to remove it", hook.id, hook.file.display());
    }
    if let Some(index) = hook.location.disabled_index {
        edit_disabled_store(paths, |store| {
            if index < store.len() {
                store.remove(index);
            }
            Ok(())
        })?;
        return Ok(hook);
    }
    let mut group_emptied = false;
    edit_json(paths, &hook.file, |root| {
        group_emptied = take_handler(root, &hook, true)?.1;
        Ok(())
    })?;
    if hook.agent == Agent::Codex {
        rekey_codex_states_after_remove(paths, &hook, group_emptied)?;
    }
    Ok(hook)
}

fn event_groups_mut<'a>(root: &'a mut OJson, event: &str) -> anyhow::Result<&'a mut Vec<OJson>> {
    let object = root.as_object_mut().context("the settings file is not a JSON object")?;
    let hooks = object.entry("hooks".to_owned()).or_insert_with(OJson::object);
    let hooks = hooks.as_object_mut().context("`hooks` is not an object")?;
    let groups = hooks.entry(event.to_owned()).or_insert_with(|| OJson::Array(Vec::new()));
    groups.as_array_mut().with_context(|| format!("`hooks.{event}` is not an array"))
}

/// Takes `hook`'s handler out of `root`, checking it is the one listed.
/// Returns the handler and whether its group was emptied (and removed).
/// An emptied event goes; an emptied `hooks` object goes only when
/// `drop_empty_hooks` (a removal; a turned-off hook keeps `"hooks": {}` so
/// turning it back on leaves the file's key order as it was).
fn take_handler(
    root: &mut OJson,
    hook: &HookEntry,
    drop_empty_hooks: bool,
) -> anyhow::Result<(OJson, bool)> {
    let events =
        root.get_mut("hooks").and_then(OJson::as_object_mut).context("the file has no hooks")?;
    let groups = events
        .get_mut(&hook.event)
        .and_then(OJson::as_array_mut)
        .with_context(|| format!("the file has no {} hooks", hook.event))?;
    let group = groups.get_mut(hook.location.group).context("the hook moved; list again")?;
    let handlers = group
        .get_mut("hooks")
        .and_then(OJson::as_array_mut)
        .context("the hook moved; list again")?;
    let handler = handlers.get(hook.location.handler).context("the hook moved; list again")?;
    let command = ["command", "prompt", "url", "tool"]
        .iter()
        .find_map(|key| handler.get(key).and_then(OJson::as_str))
        .unwrap_or_default();
    if command != hook.command {
        bail!("the hook changed on disk since it was listed; list again");
    }
    let handler = handlers.remove(hook.location.handler);
    let emptied = handlers.is_empty();
    if emptied {
        groups.remove(hook.location.group);
    }
    if groups.is_empty() {
        events.shift_remove(&hook.event);
    }
    if drop_empty_hooks
        && events.is_empty()
        && let Some(object) = root.as_object_mut()
    {
        object.shift_remove("hooks");
    }
    Ok((handler, emptied))
}

fn group_matcher(group: &OJson) -> Option<&str> {
    group.get("matcher").and_then(OJson::as_str).filter(|matcher| !matcher.is_empty())
}

fn group_handlers(group: &OJson) -> &[OJson] {
    group.get("hooks").and_then(OJson::as_array).map(Vec::as_slice).unwrap_or_default()
}

/// The layout group `file_group` is: the same matcher and a handler in common.
fn layout_group_of(layout: &[OJson], file_group: &OJson) -> Option<usize> {
    layout.iter().position(|candidate| {
        group_matcher(candidate) == group_matcher(file_group)
            && group_handlers(file_group)
                .iter()
                .any(|handler| group_handlers(candidate).contains(handler))
    })
}

/// The event's groups as they were before cmux turned any of them off: the
/// layout every disabled record of one file and event shares, so turning
/// hooks back on in any order puts each where it was. Starts as the file's
/// groups at the first turn-off; a handler the layout lacks (added since) is
/// placed after the handler before it in the file.
fn claude_layout(store: &[OJson], root: &OJson, hook: &HookEntry, handler: &OJson) -> OJson {
    let file = hook.file.to_string_lossy();
    let shared = store
        .iter()
        .filter(|record| {
            record.get("file").and_then(OJson::as_str) == Some(file.as_ref())
                && record.get("event").and_then(OJson::as_str) == Some(hook.event.as_str())
        })
        .find_map(|record| record.get("layout").cloned());
    let file_groups =
        root.get("hooks").and_then(|hooks| hooks.get(&hook.event)).and_then(OJson::as_array);
    let Some(mut layout) = shared else {
        let events = root
            .get("hooks")
            .and_then(OJson::as_object)
            .map(|events| events.keys().map(|key| OJson::from(key.as_str())).collect())
            .unwrap_or_default();
        let mut map = IndexMap::new();
        map.insert("events".to_owned(), OJson::Array(events));
        map.insert("groups".to_owned(), OJson::Array(file_groups.cloned().unwrap_or_default()));
        return OJson::Object(map);
    };
    let known = layout
        .get("groups")
        .and_then(OJson::as_array)
        .is_some_and(|groups| groups.iter().any(|group| group_handlers(group).contains(handler)));
    if known {
        return layout;
    }
    let file_group = file_groups.and_then(|groups| groups.get(hook.location.group));
    if let Some(groups) = layout.get_mut("groups").and_then(OJson::as_array_mut) {
        match file_group.and_then(|group| layout_group_of(groups, group).map(|at| (group, at))) {
            Some((group, at)) => {
                let before = group_handlers(group).iter().take(hook.location.handler);
                if let Some(handlers) = groups
                    .get_mut(at)
                    .and_then(|group| group.get_mut("hooks"))
                    .and_then(OJson::as_array_mut)
                {
                    let after = before
                        .rev()
                        .find_map(|previous| handlers.iter().position(|item| item == previous))
                        .map_or(0, |index| index + 1);
                    handlers.insert(after, handler.clone());
                }
            }
            None => groups.push(file_group.cloned().unwrap_or_else(|| {
                let mut map = IndexMap::new();
                if let Some(matcher) = &hook.matcher {
                    map.insert("matcher".to_owned(), OJson::from(matcher.as_str()));
                }
                map.insert("hooks".to_owned(), OJson::Array(vec![handler.clone()]));
                OJson::Object(map)
            })),
        }
    }
    layout
}

/// The order of the file's events before cmux turned any of its hooks off:
/// the one its disabled records keep, with any event the file has now and the
/// order lacks placed after the event before it in the file.
fn claude_event_order(store: &[OJson], root: &OJson, file: &str) -> OJson {
    let current: Vec<&str> = root
        .get("hooks")
        .and_then(OJson::as_object)
        .map(|events| events.keys().map(String::as_str).collect())
        .unwrap_or_default();
    let mut order: Vec<String> = store
        .iter()
        .filter(|record| record.get("file").and_then(OJson::as_str) == Some(file))
        .find_map(|record| record.get("layout").and_then(|layout| layout.get("events")))
        .and_then(OJson::as_array)
        .map(|names| names.iter().filter_map(OJson::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    for (at, name) in current.iter().enumerate() {
        if order.iter().any(|known| known == name) {
            continue;
        }
        let after = current
            .iter()
            .take(at)
            .rev()
            .find_map(|previous| order.iter().position(|known| known == previous))
            .map_or(0, |index| index + 1);
        order.insert(after, (*name).to_owned());
    }
    OJson::Array(order.iter().map(|name| OJson::from(name.as_str())).collect())
}

fn claude_disable(paths: &AgentPaths, hook: &HookEntry) -> anyhow::Result<()> {
    // The store gets the handler first; when the settings write then fails,
    // the store entry is taken back, so a failure never loses the handler.
    // The settings file's lock is held from this read to the write below.
    let _lock = lock(paths, &hook.file)?;
    let original = read_json(&hook.file)?.context("the settings file is gone")?;
    let mut edited = original.clone();
    let (handler, _) = take_handler(&mut edited, hook, false)?;
    let file = hook.file.to_string_lossy().into_owned();
    let mut record = IndexMap::new();
    record.insert("file".to_owned(), OJson::from(file.as_str()));
    record.insert("scope".to_owned(), OJson::from(hook.scope.as_str()));
    record.insert("event".to_owned(), OJson::from(hook.event.as_str()));
    if let Some(matcher) = &hook.matcher {
        record.insert("matcher".to_owned(), OJson::from(matcher.as_str()));
    }
    record.insert("group".to_owned(), OJson::from(hook.location.group as u64));
    record.insert("index".to_owned(), OJson::from(hook.location.handler as u64));
    record.insert("handler".to_owned(), handler.clone());
    edit_disabled_store(paths, |store| {
        let events = claude_event_order(store, &original, &file);
        let mut layout = claude_layout(store, &original, hook, &handler);
        if let Some(map) = layout.as_object_mut() {
            map.insert("events".to_owned(), events.clone());
        }
        // Every record of this file and event shares the one layout, and
        // every record of this file the one order of the events.
        for other in store.iter_mut() {
            if other.get("file").and_then(OJson::as_str) != Some(file.as_str()) {
                continue;
            }
            let same_event =
                other.get("event").and_then(OJson::as_str) == Some(hook.event.as_str());
            let Some(map) = other.as_object_mut() else { continue };
            if same_event {
                map.insert("layout".to_owned(), layout.clone());
            } else if let Some(other_layout) = map.get_mut("layout").and_then(OJson::as_object_mut)
            {
                other_layout.insert("events".to_owned(), events.clone());
            }
        }
        record.insert("layout".to_owned(), layout);
        store.push(OJson::Object(record));
        Ok(())
    })?;
    if let Err(error) = write_json(paths, &hook.file, &edited) {
        // Undo the store append.
        let _ = edit_disabled_store(paths, |store| {
            store.pop();
            Ok(())
        });
        return Err(error);
    }
    Ok(())
}

/// Where a turned-off handler goes back: its layout group's file group (else
/// a new group after the file groups that come before it in the layout), after
/// the last handler that came before it in the layout and is still there.
fn claude_reinsert(
    root: &mut OJson,
    hook: &HookEntry,
    handler: OJson,
    layout: Option<&OJson>,
) -> anyhow::Result<()> {
    let object = root.as_object_mut().context("the settings file is not a JSON object")?;
    let events = object.entry("hooks".to_owned()).or_insert_with(OJson::object);
    let events = events.as_object_mut().context("`hooks` is not an object")?;
    if !events.contains_key(&hook.event) {
        // Back between the events it sat between.
        let order: Vec<&str> = layout
            .and_then(|layout| layout.get("events"))
            .and_then(OJson::as_array)
            .map(|names| names.iter().filter_map(OJson::as_str).collect())
            .unwrap_or_default();
        let at = order
            .iter()
            .position(|name| *name == hook.event)
            .and_then(|mine| {
                order.iter().take(mine).rev().find_map(|previous| events.get_index_of(*previous))
            })
            .map_or(if order.contains(&hook.event.as_str()) { 0 } else { events.len() }, |index| {
                index + 1
            });
        events.shift_insert(at, hook.event.clone(), OJson::Array(Vec::new()));
    }
    let groups = events
        .get_mut(&hook.event)
        .and_then(OJson::as_array_mut)
        .with_context(|| format!("`hooks.{}` is not an array", hook.event))?;
    let new_group = |handler: OJson| {
        let mut group = IndexMap::new();
        if let Some(matcher) = &hook.matcher {
            group.insert("matcher".to_owned(), OJson::from(matcher.as_str()));
        }
        group.insert("hooks".to_owned(), OJson::Array(vec![handler]));
        OJson::Object(group)
    };
    let layout_groups = layout.and_then(|layout| layout.get("groups")).and_then(OJson::as_array);
    let place = layout_groups.and_then(|layout_groups| {
        let mine =
            layout_groups.iter().position(|group| group_handlers(group).contains(&handler))?;
        Some((layout_groups, mine))
    });
    let Some((layout_groups, mine)) = place else {
        // No layout (a record from before layouts): its old group and index.
        let same_matcher = |group: &OJson| group_matcher(group) == hook.matcher.as_deref();
        match groups
            .get_mut(hook.location.group)
            .filter(|group| same_matcher(group))
            .and_then(|group| group.get_mut("hooks"))
            .and_then(OJson::as_array_mut)
        {
            Some(handlers) => {
                let at = hook.location.handler.min(handlers.len());
                handlers.insert(at, handler);
            }
            None => {
                let at = hook.location.group.min(groups.len());
                groups.insert(at, new_group(handler));
            }
        }
        return Ok(());
    };
    let mapped: Vec<Option<usize>> =
        groups.iter().map(|group| layout_group_of(layout_groups, group)).collect();
    match mapped.iter().position(|at| *at == Some(mine)) {
        Some(index) => {
            let layout_handlers = layout_groups.get(mine).map(group_handlers).unwrap_or_default();
            let position = layout_handlers.iter().position(|item| *item == handler).unwrap_or(0);
            let handlers = groups
                .get_mut(index)
                .and_then(|group| group.get_mut("hooks"))
                .and_then(OJson::as_array_mut)
                .context("a hook group has no `hooks` array")?;
            let at = layout_handlers
                .iter()
                .take(position)
                .rev()
                .find_map(|previous| handlers.iter().position(|item| item == previous))
                .map_or(0, |index| index + 1);
            handlers.insert(at, handler);
        }
        None => {
            let at = mapped
                .iter()
                .rposition(|at| at.is_some_and(|at| at < mine))
                .map_or(0, |index| index + 1);
            groups.insert(at, new_group(handler));
        }
    }
    Ok(())
}

fn claude_enable(paths: &AgentPaths, hook: &HookEntry) -> anyhow::Result<()> {
    let index = hook.location.disabled_index.context("this hook is not in the disabled store")?;
    let store = read_disabled_store(&disabled_store_path(paths))?;
    let record = store.get(index).cloned().context("the disabled store changed; list again")?;
    let handler = record.get("handler").cloned().context("the disabled record has no handler")?;
    edit_json(paths, &hook.file, |root| {
        claude_reinsert(root, hook, handler, record.get("layout"))
    })?;
    edit_disabled_store(paths, |store| {
        if store.get(index) == Some(&record) {
            store.remove(index);
        }
        Ok(())
    })
}

/// Codex keys `hooks.state` by position, so taking a handler out moves the
/// handlers after it: within its group when the group stays, or every later
/// group of that event when the group went away. Their state (enabled,
/// trusted_hash) moves with them, and the removed handler's state goes.
fn rekey_codex_states_after_remove(
    paths: &AgentPaths,
    hook: &HookEntry,
    group_emptied: bool,
) -> anyhow::Result<()> {
    let Some(removed_key) = hook.state_key.clone() else { return Ok(()) };
    let label = cmux_tui_hooks::codex_hook_state_label(&hook.event)?;
    let prefix = format!("{}:{label}:", paths.codex_state_key_path(&hook.file).display());
    let (group, handler) = (hook.location.group, hook.location.handler);
    edit_codex_config(paths, |document| {
        let Some(state) = document
            .get_mut("hooks")
            .and_then(|hooks| hooks.as_table_like_mut())
            .and_then(|hooks| hooks.get_mut("state"))
            .and_then(|state| state.as_table_like_mut())
        else {
            return Ok(());
        };
        state.remove(&removed_key);
        let mut moves = Vec::new();
        for (key, _) in state.iter() {
            let Some(rest) = key.strip_prefix(&prefix) else { continue };
            let Some((g, h)) = rest.split_once(':') else { continue };
            let (Ok(g), Ok(h)) = (g.parse::<usize>(), h.parse::<usize>()) else { continue };
            let moved = if group_emptied {
                (g > group).then(|| (g - 1, h))
            } else {
                (g == group && h > handler).then(|| (g, h - 1))
            };
            if let Some((ng, nh)) = moved {
                moves.push((key.to_owned(), format!("{prefix}{ng}:{nh}"), (g, h)));
            }
        }
        // Lowest first, so a move never lands on a key not yet moved.
        moves.sort_by_key(|(_, _, position)| *position);
        for (old, new, _) in moves {
            if let Some(item) = state.remove(&old) {
                state.insert(&new, item);
            }
        }
        Ok(())
    })
}

// ---------------------------------------------------------------- files

fn disabled_store_path(paths: &AgentPaths) -> PathBuf {
    paths.store_dir.join(DISABLED_STORE_FILE)
}

fn read_disabled_store(path: &Path) -> anyhow::Result<Vec<OJson>> {
    Ok(match read_json(path)? {
        Some(root) => root.get("disabled").and_then(OJson::as_array).cloned().unwrap_or_default(),
        None => Vec::new(),
    })
}

fn edit_disabled_store(
    paths: &AgentPaths,
    edit: impl FnOnce(&mut Vec<OJson>) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let path = disabled_store_path(paths);
    let _lock = lock(paths, &path)?;
    let mut store = read_disabled_store(&path)?;
    edit(&mut store)?;
    let mut root = IndexMap::new();
    root.insert(
        "$comment".to_owned(),
        OJson::from("Claude Code hooks cmux turned off. `cmux agent-config hooks enable ID` puts one back where it was."),
    );
    root.insert("disabled".to_owned(), OJson::Array(store));
    write_json(paths, &path, &OJson::Object(root))
}

fn read_json(path: &Path) -> anyhow::Result<Option<OJson>> {
    let text = match fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
    };
    OJson::parse(&text).map(Some).with_context(|| format!("parsing {}", path.display()))
}

fn edit_json(
    paths: &AgentPaths,
    path: &Path,
    edit: impl FnOnce(&mut OJson) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let _lock = lock(paths, path)?;
    let mut root = read_json(path)?.unwrap_or_else(OJson::object);
    edit(&mut root)?;
    write_json(paths, path, &root)
}

/// Holds `path`'s edit lock until it drops: the lock a settings edit of the same file takes
/// ([`crate::write::Store::lock`]), so a hooks edit and a settings edit never both start from
/// the same file and drop each other's change. Each edit takes it once, around its own read and
/// write, never nested for one file (a second lock of a held file waits out its deadline).
fn lock(paths: &AgentPaths, path: &Path) -> anyhow::Result<fs::File> {
    paths.edits.lock(path).with_context(|| format!("waiting to edit {}", path.display()))
}

/// Writes `root` to `path` (the caller holds `path`'s [`lock`]).
fn write_json(paths: &AgentPaths, path: &Path, root: &OJson) -> anyhow::Result<()> {
    write_text(paths, path, &root.to_pretty())
}

/// Replaces `path` with `text` through the shared store: backups of the prior file, then an
/// atomic rename. A file already holding `text` is left alone (no backup churn).
fn write_text(paths: &AgentPaths, path: &Path, text: &str) -> anyhow::Result<()> {
    if fs::read(path).ok().as_deref() == Some(text.as_bytes()) {
        return Ok(());
    }
    paths.edits.replace(path, text).with_context(|| format!("writing {}", path.display()))
}

fn edit_codex_config(
    paths: &AgentPaths,
    edit: impl FnOnce(&mut toml_edit::DocumentMut) -> anyhow::Result<()>,
) -> anyhow::Result<()> {
    let path = paths.codex_home.join("config.toml");
    let _lock = lock(paths, &path)?;
    // The lock every cmux writer of a codex home's config takes (the hook installer, acpmux,
    // the settings part).
    let _codex_lock = cmux_tui_platform::codex_config_lock::lock(
        &paths.codex_home.join(cmux_tui_platform::codex_config_lock::LOCK_FILE),
    );
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(error) => return Err(error).with_context(|| format!("reading {}", path.display())),
    };
    let mut document: toml_edit::DocumentMut =
        text.parse().with_context(|| format!("parsing {}", path.display()))?;
    edit(&mut document)?;
    write_text(paths, &path, &document.to_string())
}

/// Takes out what `codex_state_entry` made for KEY once it holds nothing:
/// the `[hooks.state."<key>"]` table, then `hooks.state` and `hooks` when
/// they are empty implicit tables (no header of their own in the file), so a
/// turn off and back on of a hook with no state entry gives back the file.
fn drop_empty_codex_state(document: &mut toml_edit::DocumentMut, key: &str) {
    let Some(hooks) = document.get_mut("hooks").and_then(|item| item.as_table_like_mut()) else {
        return;
    };
    if let Some(state) = hooks.get_mut("state").and_then(|item| item.as_table_like_mut())
        && state
            .get(key)
            .and_then(|item| item.as_table_like())
            .is_some_and(|entry| entry.is_empty())
    {
        state.remove(key);
    }
    let empty_implicit = |item: Option<&toml_edit::Item>| {
        item.and_then(|item| item.as_table())
            .is_some_and(|table| table.is_empty() && table.is_implicit())
    };
    if empty_implicit(hooks.get("state")) {
        hooks.remove("state");
    }
    if empty_implicit(document.get("hooks")) {
        document.remove("hooks");
    }
}

/// `hooks.state."<key>"` as a table, created (as a `[hooks.state."<key>"]`
/// header, the shape Codex writes) when absent.
fn codex_state_entry<'a>(
    document: &'a mut toml_edit::DocumentMut,
    key: &str,
) -> anyhow::Result<&'a mut dyn toml_edit::TableLike> {
    let hooks = document
        .entry("hooks")
        .or_insert_with(|| {
            let mut table = toml_edit::Table::new();
            table.set_implicit(true);
            toml_edit::Item::Table(table)
        })
        .as_table_like_mut()
        .context("`hooks` in config.toml is not a table")?;
    let state = hooks
        .entry("state")
        .or_insert_with(|| {
            let mut table = toml_edit::Table::new();
            table.set_implicit(true);
            toml_edit::Item::Table(table)
        })
        .as_table_like_mut()
        .context("`hooks.state` in config.toml is not a table")?;
    state
        .entry(key)
        .or_insert_with(|| toml_edit::Item::Table(toml_edit::Table::new()))
        .as_table_like_mut()
        .with_context(|| format!("`hooks.state.{key:?}` in config.toml is not a table"))
}

#[cfg(test)]
#[path = "hooks_tests.rs"]
mod tests;
