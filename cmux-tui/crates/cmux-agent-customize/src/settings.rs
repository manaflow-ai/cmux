//! Claude Code's and Codex's own settings as each CLI reads them: every key on disk with the
//! scope it comes from, and set/unset for a curated list (model, effort, permission or approval
//! mode, sandbox, theme, status line, output style).
//!
//! Ground truth is the CLIs themselves (Claude Code 2.1.322, codex-cli 0.164.0):
//!
//! - Claude Code reads, highest first: managed settings (`managed-settings.json`), command-line
//!   flags, `<project>/.claude/settings.local.json`, `<project>/.claude/settings.json`, then
//!   `$CLAUDE_CONFIG_DIR/settings.json` (`~/.claude/settings.json`). Flags belong to one run, so
//!   they are not a file here. Objects merge key by key, so each leaf (`permissions.defaultMode`,
//!   `env.FOO`) has its own winner; the permission rule lists merge across scopes. A repo's
//!   settings cannot grant `permissions.defaultMode: auto` (Claude Code ignores it there).
//! - Codex reads, highest first: managed config (`/etc/codex/managed_config.toml`), `-c` flags,
//!   `--profile NAME` (`$CODEX_HOME/NAME.config.toml`, layered over the user config), the nearest
//!   `.codex/config.toml` of a trusted project (`[projects."<dir>"] trust_level = "trusted"`;
//!   an untrusted project's is ignored), then `$CODEX_HOME/config.toml`, then
//!   `/etc/codex/config.toml`. A profile applies only to a run started with `--profile`; codex
//!   0.164 has no saved active profile and refuses to load a config that still has the legacy
//!   `profile = "..."` selector or `[profiles.*]` tables, which this module reports.
//!
//! Reads never fail as a whole: an unreadable file is a layer with an `error`. Env values and
//! values whose key names a secret are masked, and so are a URL's userinfo, query values and
//! fragment; nothing here prints a secret. Writes edit the file in place (cmux-config `jsonc` for
//! settings.json, `toml_edit` for config.toml), so comments, key order and keys cmux does not know
//! survive byte for byte, then replace it atomically after a backup kept in cmux's private folder,
//! all under one lock per file ([`crate::write::Store`]). acpmux never edits these files; this is
//! the person's own edit from Settings or `cmux agent-config settings`.

use std::fmt;
use std::fs;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::paths::{Homes, project_dirs};
use crate::write;

pub use crate::Agent;

/// Where one read or write resolves: the homes, the folder a project scope starts from, and the
/// managed files (fixed system paths; tests point them into a temporary folder).
#[derive(Debug, Clone)]
pub struct Context {
    pub homes: Homes,
    /// The folder the agent would start in; `None`: no project scopes.
    pub cwd: Option<PathBuf>,
    pub claude_managed: PathBuf,
    pub codex_managed: PathBuf,
    pub codex_system: PathBuf,
}

impl Context {
    /// The environment's homes and the system's managed files; `None` without a home folder.
    pub fn from_env(cwd: Option<PathBuf>) -> Option<Self> {
        let claude_managed = if cfg!(target_os = "macos") {
            PathBuf::from("/Library/Application Support/ClaudeCode/managed-settings.json")
        } else if cfg!(windows) {
            PathBuf::from(r"C:\Program Files\ClaudeCode\managed-settings.json")
        } else {
            PathBuf::from("/etc/claude-code/managed-settings.json")
        };
        Some(Self {
            homes: Homes::from_env()?,
            cwd,
            claude_managed,
            codex_managed: PathBuf::from("/etc/codex/managed_config.toml"),
            codex_system: PathBuf::from("/etc/codex/config.toml"),
        })
    }

    /// The project root a project scope writes to: the nearest folder holding `.git` from `cwd`,
    /// else `cwd`; `None` without a `cwd` or when it is the home folder (whose `.claude` is the
    /// user scope).
    fn project_root(&self) -> Option<PathBuf> {
        let cwd = self.cwd.as_deref()?;
        // The filesystem root is where an app with no project runs from, never a project.
        project_dirs(cwd, &self.homes.home).last().filter(|root| root.parent().is_some()).cloned()
    }
}

/// A refusal: a stable code and plain words.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsError {
    pub code: &'static str,
    pub message: String,
}

impl SettingsError {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
}

impl fmt::Display for SettingsError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for SettingsError {}

/// A curated key: what cmux offers to set, and the values the agent takes.
#[derive(Debug, Clone, Copy)]
pub struct Curated {
    pub key: &'static str,
    pub title: &'static str,
    /// The only values the agent takes; empty: free text.
    pub choices: &'static [&'static str],
    /// Suggestions for a free-text key.
    pub suggestions: &'static [&'static str],
}

const MASK: &str = "••••••";

/// Claude Code 2.1.322's settings cmux edits (values from its own settings schema).
pub const CLAUDE_CURATED: &[Curated] = &[
    Curated {
        key: "model",
        title: "Model",
        choices: &[],
        suggestions: &["default", "sonnet", "opus", "haiku", "opusplan"],
    },
    Curated {
        key: "effortLevel",
        title: "Effort",
        choices: &["low", "medium", "high", "xhigh"],
        suggestions: &[],
    },
    Curated {
        key: "permissions.defaultMode",
        title: "Permission mode",
        choices: &["default", "acceptEdits", "plan", "auto", "dontAsk", "bypassPermissions"],
        suggestions: &[],
    },
    Curated {
        key: "theme",
        title: "Theme",
        choices: &[
            "dark",
            "light",
            "dark-daltonized",
            "light-daltonized",
            "dark-ansi",
            "light-ansi",
        ],
        suggestions: &[],
    },
    Curated {
        key: "outputStyle",
        title: "Output style",
        choices: &[],
        suggestions: &["default", "Explanatory", "Learning"],
    },
    Curated {
        key: "statusLine.command",
        title: "Status line command",
        choices: &[],
        suggestions: &[],
    },
];

/// codex-cli 0.164.0's settings cmux edits (values from its config parser).
pub const CODEX_CURATED: &[Curated] = &[
    Curated { key: "model", title: "Model", choices: &[], suggestions: &[] },
    Curated {
        key: "model_reasoning_effort",
        title: "Reasoning effort",
        choices: &["none", "minimal", "low", "medium", "high", "xhigh"],
        suggestions: &[],
    },
    Curated {
        key: "approval_policy",
        title: "Approval policy",
        choices: &["untrusted", "on-failure", "on-request", "never"],
        suggestions: &[],
    },
    Curated {
        key: "sandbox_mode",
        title: "Sandbox",
        choices: &["read-only", "workspace-write", "danger-full-access"],
        suggestions: &[],
    },
];

pub fn curated(agent: Agent) -> &'static [Curated] {
    match agent {
        Agent::Claude => CLAUDE_CURATED,
        Agent::Codex => CODEX_CURATED,
    }
}

/// One leaf on disk: its key path, what the page may show, and the plain string when it is one.
#[derive(Debug, Clone, PartialEq)]
struct Leaf {
    parts: Vec<String>,
    display: String,
    text: Option<String>,
    masked: bool,
}

/// One file in an agent's chain.
#[derive(Debug, Clone)]
struct Layer {
    scope: String,
    label: String,
    path: PathBuf,
    exists: bool,
    writable: bool,
    /// Why the agent does not apply this file now (a profile, an untrusted project); `None`: it does.
    inactive: Option<String>,
    error: Option<String>,
    leaves: Vec<Leaf>,
}

/// The effective settings report (`cmux agent-config settings get --json`).
pub fn report(ctx: &Context, agent: Agent) -> Value {
    let (layers, notes) = match agent {
        Agent::Claude => claude_layers(ctx),
        Agent::Codex => codex_layers(ctx),
    };
    let curated_keys: Vec<&str> = curated(agent).iter().map(|c| c.key).collect();
    // Entries: active layers first, highest precedence first, then the inactive ones.
    let mut entries: Vec<Value> = Vec::new();
    let mut index: Vec<String> = Vec::new();
    let mut keys_on_disk = 0usize;
    let mut keys_shown = 0usize;
    for active in [true, false] {
        for layer in layers.iter().filter(|l| l.inactive.is_none() == active) {
            for leaf in &layer.leaves {
                keys_on_disk += 1;
                let key = render_key(&leaf.parts);
                if active && let Some(at) = index.iter().position(|k| *k == key) {
                    if let Some(list) = entries
                        .get_mut(at)
                        .and_then(|e| e.get_mut("overridden"))
                        .and_then(Value::as_array_mut)
                    {
                        list.push(json!({"scope": layer.scope, "display": leaf.display}));
                        keys_shown += 1;
                    }
                    continue;
                }
                keys_shown += 1;
                let mut entry = json!({
                    "key": key,
                    "display": leaf.display,
                    "scope": layer.scope,
                    "path": layer.path.display().to_string(),
                    "overridden": [],
                    "masked": leaf.masked,
                    "curated": curated_keys.contains(&key.as_str()),
                    "merged": agent == Agent::Claude && merged_list(&leaf.parts),
                });
                if let (Some(why), Some(obj)) = (&layer.inactive, entry.as_object_mut()) {
                    obj.insert("inactive".to_owned(), json!(why));
                }
                if active {
                    index.push(key);
                } else {
                    index.push(String::new());
                }
                entries.push(entry);
            }
        }
    }
    let writable = writable_scopes(ctx, agent, &layers);
    let curated_rows: Vec<Value> = curated(agent)
        .iter()
        .map(|c| {
            let winner = layers.iter().filter(|l| l.inactive.is_none()).find_map(|layer| {
                layer
                    .leaves
                    .iter()
                    .find(|leaf| render_key(&leaf.parts) == c.key)
                    .map(|leaf| (leaf, layer.scope.clone()))
            });
            let (value, scope) = match winner {
                Some((leaf, scope)) => (
                    if leaf.masked {
                        json!(MASK)
                    } else {
                        json!(leaf.text.clone().unwrap_or_else(|| leaf.display.clone()))
                    },
                    json!(scope),
                ),
                None => (Value::Null, Value::Null),
            };
            json!({
                "key": c.key,
                "title": c.title,
                "kind": if c.choices.is_empty() { "text" } else { "choice" },
                "choices": if c.choices.is_empty() { c.suggestions } else { c.choices },
                "value": value,
                "scope": scope,
                "writableScopes": writable,
            })
        })
        .collect();
    let files: Vec<Value> = layers
        .iter()
        .map(|l| {
            let mut file = json!({
                "scope": l.scope,
                "label": l.label,
                "path": l.path.display().to_string(),
                "exists": l.exists,
                "writable": l.writable,
                "keys": l.leaves.len(),
                "error": l.error,
            });
            if let (Some(why), Some(obj)) = (&l.inactive, file.as_object_mut()) {
                obj.insert("inactive".to_owned(), json!(why));
            }
            file
        })
        .collect();
    let profiles: Vec<Value> = layers
        .iter()
        .filter_map(|l| {
            l.scope.strip_prefix("profile:").map(|name| {
                json!({"name": name, "path": l.path.display().to_string(), "keys": l.leaves.len()})
            })
        })
        .collect();
    // The session variables, each once with its winning scope; values stay masked.
    let env_prefix = format!("{}.", env_table(agent));
    let env: Vec<Value> = entries
        .iter()
        .filter(|e| e.get("inactive").is_none())
        .filter_map(|e| {
            let name = e["key"].as_str()?.strip_prefix(&env_prefix)?;
            valid_env_name(name).then(
                || json!({"name": name, "value": MASK, "scope": e["scope"], "path": e["path"]}),
            )
        })
        .collect();
    let mut answer = json!({
        "agent": agent.id(),
        "envTable": env_table(agent),
        "env": env,
        "files": files,
        "entries": entries,
        "curated": curated_rows,
        "notes": notes,
        "keysOnDisk": keys_on_disk,
        "keysShown": keys_shown,
        // Every agent answers with a list, empty for Claude Code, so a reader never meets a gap.
        "profiles": profiles,
    });
    if agent == Agent::Codex
        && let Some(obj) = answer.as_object_mut()
    {
        obj.insert("activeProfile".to_owned(), Value::Null);
    }
    answer
}

/// Claude Code's permission rule lists, which merge across scopes instead of overriding.
fn merged_list(parts: &[String]) -> bool {
    matches!(parts, [table, list] if table == "permissions"
        && matches!(list.as_str(), "allow" | "deny" | "ask" | "additionalDirectories"))
}

fn writable_scopes(ctx: &Context, agent: Agent, layers: &[Layer]) -> Vec<String> {
    let mut scopes = vec!["user".to_owned()];
    match agent {
        Agent::Claude => {
            if ctx.project_root().is_some() {
                scopes.push("project".to_owned());
                scopes.push("local".to_owned());
            }
        }
        Agent::Codex => {
            if ctx.project_root().is_some() && codex_trusted(ctx) {
                scopes.push("project".to_owned());
            }
            scopes.extend(
                layers.iter().filter(|l| l.scope.starts_with("profile:")).map(|l| l.scope.clone()),
            );
        }
    }
    scopes
}

// MARK: Claude Code

fn claude_layers(ctx: &Context) -> (Vec<Layer>, Vec<String>) {
    let mut layers = vec![json_layer("managed", "Managed", &ctx.claude_managed, false)];
    if let Some(root) = ctx.project_root() {
        layers.push(json_layer(
            "local",
            "Project (local)",
            &root.join(".claude/settings.local.json"),
            true,
        ));
        layers.push(json_layer("project", "Project", &root.join(".claude/settings.json"), true));
    }
    layers.push(json_layer("user", "User", &ctx.homes.claude_settings(), true));
    let mut notes = vec![
        "Flags given to one run (claude --model, --permission-mode, --settings) win over every file but managed settings."
            .to_owned(),
    ];
    let project_auto = layers.iter().any(|l| {
        matches!(l.scope.as_str(), "project" | "local")
            && l.leaves.iter().any(|leaf| {
                render_key(&leaf.parts) == "permissions.defaultMode"
                    && leaf.text.as_deref() == Some("auto")
            })
    });
    if project_auto {
        notes.push("Claude Code ignores permissions.defaultMode \"auto\" in a project's settings; set it in User.".to_owned());
    }
    (layers, notes)
}

fn json_layer(scope: &str, label: &str, path: &Path, writable: bool) -> Layer {
    let mut layer = Layer {
        scope: scope.to_owned(),
        label: label.to_owned(),
        path: path.to_path_buf(),
        exists: path.exists(),
        writable,
        inactive: None,
        error: None,
        leaves: Vec::new(),
    };
    match fs::read_to_string(path) {
        Ok(text) => match cmux_config::jsonc::parse(&text) {
            Ok(Value::Object(map)) => {
                let mut parts = Vec::new();
                for (key, value) in &map {
                    parts.push(key.clone());
                    json_leaves(value, &mut parts, &mut layer.leaves);
                    parts.pop();
                }
            }
            Ok(_) => layer.error = Some("the file is not a JSON object".to_owned()),
            Err(error) => layer.error = Some(format!("the file is not valid JSON ({error})")),
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => layer.error = Some(format!("cannot read the file ({error})")),
    }
    // Claude Code 2.1.322 reads settings.json as strict JSON and ignores the whole file when it has
    // a comment or a trailing comma, so such a file's keys are shown but do not apply.
    if layer.error.is_none()
        && let Ok(text) = fs::read_to_string(path)
        && !text.trim().is_empty()
        && serde_json::from_str::<Value>(&text).is_err()
    {
        layer.inactive = Some(IGNORED_JSONC.to_owned());
    }
    layer
}

const IGNORED_JSONC: &str =
    "Claude Code ignores this file: it has a comment or a trailing comma (strict JSON only)";

fn json_leaves(value: &Value, parts: &mut Vec<String>, out: &mut Vec<Leaf>) {
    if let Value::Object(map) = value
        && !map.is_empty()
    {
        for (key, inner) in map {
            parts.push(key.clone());
            json_leaves(inner, parts, out);
            parts.pop();
        }
        return;
    }
    let masked = secret(parts) && !matches!(value, Value::Bool(_) | Value::Null);
    if !masked && let Some(redacted) = value.as_str().and_then(redact_url) {
        out.push(redacted_leaf(parts, redacted));
        return;
    }
    let text = value.as_str().map(str::to_owned);
    let display = if masked {
        MASK.to_owned()
    } else {
        match value {
            Value::String(s) => short(s),
            Value::Array(items) => count(items.len()),
            Value::Object(_) => "{}".to_owned(),
            other => other.to_string(),
        }
    };
    out.push(Leaf {
        parts: parts.clone(),
        display,
        text: if masked { None } else { text },
        masked,
    });
}

// MARK: Codex

fn codex_layers(ctx: &Context) -> (Vec<Layer>, Vec<String>) {
    let mut notes = Vec::new();
    let mut layers = vec![toml_layer("managed", "Managed", &ctx.codex_managed, false)];
    let trusted = codex_trusted(ctx);
    if let Some(cwd) = ctx.cwd.as_deref() {
        let dirs = project_dirs(cwd, &ctx.homes.home);
        let root = dirs.last().cloned();
        for dir in &dirs {
            let path = dir.join(".codex/config.toml");
            let is_root = Some(dir) == root.as_ref();
            if !path.exists() && !is_root {
                continue;
            }
            let scope =
                if is_root { "project".to_owned() } else { format!("project:{}", dir.display()) };
            let mut layer = toml_layer(&scope, "Project", &path, is_root && trusted);
            if !trusted {
                layer.inactive = Some(
                    "Codex ignores a project's config until the project is trusted".to_owned(),
                );
            }
            layers.push(layer);
        }
    }
    let user = toml_layer("user", "User", &ctx.homes.codex_config(), true);
    if let Ok(text) = fs::read_to_string(&user.path)
        && let Ok(doc) = text.parse::<toml_edit::DocumentMut>()
        && (doc.contains_key("profile") || doc.contains_key("profiles"))
    {
        notes.push(
            "Codex 0.164 refuses to load this config: `profile = ...` and `[profiles.*]` are legacy. Move each profile into NAME.config.toml beside config.toml and remove them."
                .to_owned(),
        );
    }
    layers.push(user);
    layers.push(toml_layer("system", "System", &ctx.codex_system, false));
    let mut profiles: Vec<(String, PathBuf)> = fs::read_dir(&ctx.homes.codex)
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().to_string_lossy().into_owned();
            let profile = name.strip_suffix(".config.toml")?.to_owned();
            (valid_profile(&profile) && entry.path().is_file()).then(|| (profile, entry.path()))
        })
        .collect();
    profiles.sort();
    for (name, path) in &profiles {
        let mut layer =
            toml_layer(&format!("profile:{name}"), &format!("Profile {name}"), path, true);
        layer.inactive = Some(format!("applies to a run started with --profile {name}"));
        layers.push(layer);
    }
    notes.push(
        "Codex picks a profile per run (codex --profile NAME); there is no saved active profile."
            .to_owned(),
    );
    notes.push("Flags given to one run (codex -c key=value, -m, -s, -a) win over every file but managed config.".to_owned());
    (layers, notes)
}

/// A codex profile name: `--profile` takes a plain name (`work`).
pub fn valid_profile(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// Whether the user config trusts the project `ctx.cwd` is in (any of its folders, as written
/// or with symlinks resolved).
fn codex_trusted(ctx: &Context) -> bool {
    let Some(cwd) = ctx.cwd.as_deref() else { return false };
    let Ok(text) = fs::read_to_string(ctx.homes.codex_config()) else { return false };
    let Ok(doc) = text.parse::<toml_edit::DocumentMut>() else { return false };
    let Some(projects) = doc.get("projects").and_then(toml_edit::Item::as_table_like) else {
        return false;
    };
    let trusted = |dir: &Path| {
        projects
            .get(&dir.display().to_string())
            .and_then(|item| item.as_table_like())
            .and_then(|t| t.get("trust_level"))
            .and_then(toml_edit::Item::as_str)
            == Some("trusted")
    };
    project_dirs(cwd, &ctx.homes.home)
        .iter()
        .any(|dir| trusted(dir) || fs::canonicalize(dir).is_ok_and(|real| trusted(&real)))
}

fn toml_layer(scope: &str, label: &str, path: &Path, writable: bool) -> Layer {
    let mut layer = Layer {
        scope: scope.to_owned(),
        label: label.to_owned(),
        path: path.to_path_buf(),
        exists: path.exists(),
        writable,
        inactive: None,
        error: None,
        leaves: Vec::new(),
    };
    match fs::read_to_string(path) {
        Ok(text) => match text.parse::<toml_edit::DocumentMut>() {
            Ok(doc) => toml_leaves(doc.as_table(), &mut Vec::new(), &mut layer.leaves),
            Err(error) => {
                layer.error = Some(format!("the file is not valid TOML ({})", error.message()));
            }
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => layer.error = Some(format!("cannot read the file ({error})")),
    }
    layer
}

fn toml_leaves(table: &dyn toml_edit::TableLike, parts: &mut Vec<String>, out: &mut Vec<Leaf>) {
    for (key, item) in table.iter() {
        parts.push(key.to_owned());
        match item {
            toml_edit::Item::None => {}
            toml_edit::Item::Table(inner) if !inner.is_empty() => toml_leaves(inner, parts, out),
            toml_edit::Item::Table(_) => out.push(leaf(parts, "{}".to_owned(), None)),
            toml_edit::Item::ArrayOfTables(items) => {
                out.push(leaf(parts, count(items.len()), None));
            }
            toml_edit::Item::Value(toml_edit::Value::InlineTable(inner)) if !inner.is_empty() => {
                toml_leaves(inner, parts, out);
            }
            toml_edit::Item::Value(value) => {
                let (display, text) = match value {
                    toml_edit::Value::String(s) => (short(s.value()), Some(s.value().clone())),
                    toml_edit::Value::Array(items) => (count(items.len()), None),
                    toml_edit::Value::InlineTable(_) => ("{}".to_owned(), None),
                    other => (other.clone().decorated("", "").to_string(), None),
                };
                let masked = secret(parts) && !matches!(value, toml_edit::Value::Boolean(_));
                out.push(if masked {
                    Leaf {
                        parts: parts.clone(),
                        display: MASK.to_owned(),
                        text: None,
                        masked: true,
                    }
                } else if let Some(redacted) = text.as_deref().and_then(redact_url) {
                    redacted_leaf(parts, redacted)
                } else {
                    leaf(parts, display, text)
                });
            }
        }
        parts.pop();
    }
}

fn leaf(parts: &[String], display: String, text: Option<String>) -> Leaf {
    Leaf { parts: parts.to_vec(), display, text, masked: false }
}

/// A URL whose credentials [`redact_url`] hid: shown with the rest readable, flagged masked.
fn redacted_leaf(parts: &[String], redacted: String) -> Leaf {
    Leaf { parts: parts.to_vec(), display: short(&redacted), text: Some(redacted), masked: true }
}

/// `text` with the credentials a URL can carry hidden, whatever its key is called (an MCP
/// server's `url` with `?token=...`, a `postgres://user:pw@host` string): the userinfo before
/// `@`, every query value (names stay) and the fragment become [`MASK`]; the scheme, host, port
/// and path stay. `None` when `text` is not a URL or has none of these.
fn redact_url(text: &str) -> Option<String> {
    let (scheme, rest) = text.split_once("://")?;
    let mut chars = scheme.chars();
    if !chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        || !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let (before_fragment, fragment) = match rest.split_once('#') {
        Some((before, fragment)) => (before, Some(fragment)),
        None => (rest, None),
    };
    let (before_query, query) = match before_fragment.split_once('?') {
        Some((before, query)) => (before, Some(query)),
        None => (before_fragment, None),
    };
    let authority_end = before_query.find('/').unwrap_or(before_query.len());
    let (authority, path) = before_query.split_at(authority_end);
    let host = authority.rsplit_once('@').map(|(_, host)| host);
    if host.is_none() && query.is_none() && fragment.is_none() {
        return None;
    }
    let mut out = format!("{scheme}://");
    if let Some(host) = host {
        out.push_str(MASK);
        out.push('@');
        out.push_str(host);
    } else {
        out.push_str(authority);
    }
    out.push_str(path);
    if let Some(query) = query {
        out.push('?');
        let pairs: Vec<String> = query
            .split('&')
            .map(|pair| match pair.split_once('=') {
                Some((name, _)) => format!("{name}={MASK}"),
                None if pair.is_empty() => String::new(),
                None => MASK.to_owned(),
            })
            .collect();
        out.push_str(&pairs.join("&"));
    }
    if fragment.is_some() {
        out.push('#');
        out.push_str(MASK);
    }
    Some(out)
}

// MARK: Shared

/// A dotted key path; a component that is not a bare key is quoted (`projects."/Users/x"`).
fn render_key(parts: &[String]) -> String {
    parts
        .iter()
        .map(|part| {
            if !part.is_empty()
                && part.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
            {
                part.clone()
            } else {
                serde_json::to_string(part).unwrap_or_default()
            }
        })
        .collect::<Vec<_>>()
        .join(".")
}

/// A value whose key says it may hold a secret: anything under an env or headers table (Codex's
/// `shell_environment_policy.set` is one: its children are variables the shell gets), and keys
/// naming a token, secret, password, credential or key.
fn secret(parts: &[String]) -> bool {
    let normalized: Vec<String> =
        parts.iter().map(|p| p.to_ascii_lowercase().replace('-', "_")).collect();
    let parents: &[String] = normalized.split_last().map_or(&[], |(_, rest)| rest);
    if parents.iter().any(|p| {
        matches!(
            p.as_str(),
            "env" | "environment" | "headers" | "http_headers" | "env_http_headers"
        )
    }) || parents
        .windows(2)
        .any(|w| matches!(w, [table, key] if table == "shell_environment_policy" && key == "set"))
    {
        return true;
    }
    let last = normalized.last().map(String::as_str).unwrap_or_default();
    // A key that sizes or places a secret (model_auto_compact_token_limit,
    // cli_auth_credentials_store) holds a number or a choice, not the secret.
    if last.rsplit('_').next().is_some_and(|tail| {
        matches!(tail, "limit" | "limits" | "store" | "count" | "budget" | "ttl" | "timeout")
    }) {
        return false;
    }
    [
        "token",
        "secret",
        "password",
        "passwd",
        "credential",
        "api_key",
        "apikey",
        "bearer",
        "cookie",
        "private_key",
    ]
    .iter()
    .any(|word| last.contains(word))
        || last.ends_with("_key")
        || last == "key"
}

fn short(text: &str) -> String {
    const MAX: usize = 160;
    let one_line = text.replace(['\n', '\r'], " ");
    if one_line.chars().count() <= MAX {
        one_line
    } else {
        format!("{}…", one_line.chars().take(MAX).collect::<String>())
    }
}

fn count(n: usize) -> String {
    if n == 1 { "1 item".to_owned() } else { format!("{n} items") }
}

// MARK: Writes

/// What a set or unset wrote.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Written {
    pub agent: Agent,
    pub key: String,
    pub scope: String,
    pub path: PathBuf,
    /// The prior file's copy; `None` when the file was new.
    pub backup: Option<PathBuf>,
}

impl Written {
    pub fn json(&self) -> Value {
        json!({
            "ok": true,
            "agent": self.agent.id(),
            "key": self.key,
            "scope": self.scope,
            "path": self.path.display().to_string(),
            "backup": self.backup.as_ref().map(|p| p.display().to_string()),
        })
    }
}

/// Sets (`Some`) or removes (`None`) one curated key in one scope's file (default `user`).
pub fn apply(
    ctx: &Context,
    agent: Agent,
    key: &str,
    value: Option<&str>,
    scope: Option<&str>,
) -> Result<Written, SettingsError> {
    let row = curated(agent).iter().find(|c| c.key == key).ok_or_else(|| {
        let known: Vec<&str> = curated(agent).iter().map(|c| c.key).collect();
        SettingsError::new(
            "agent_config.unknown_key",
            format!(
                "cmux edits only {} for {}; open the file for anything else",
                known.join(", "),
                agent.id()
            ),
        )
    })?;
    let scope = scope.unwrap_or("user");
    if let Some(value) = value {
        validate(row, value)?;
        if agent == Agent::Claude
            && key == "permissions.defaultMode"
            && value == "auto"
            && scope != "user"
        {
            return Err(SettingsError::new(
                "agent_config.invalid_value",
                "Claude Code ignores permission mode auto in a project's settings; set it in User",
            ));
        }
    }
    let path = scope_path(ctx, agent, scope)?;
    let store = ctx.homes.edits.clone();
    // Held across the read, edit, backup and rename, so a Settings save and a CLI edit of the
    // same file never both start from the same original and drop each other's change.
    let _lock = store.lock(&path).map_err(|e| io_error(&path, e))?;
    let backup_target = fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
    let existed = path.exists();
    match agent {
        Agent::Claude => write_json(&store, &path, key, value)?,
        Agent::Codex => {
            // The lock every cmux writer of a codex home's config takes (the hook installer,
            // acpmux, the Cloud devbox). Only in the codex home: a project's `.codex` gets no lock
            // file a commit could pick up.
            let lock_dir = path.parent().map(Path::to_path_buf).unwrap_or_default();
            let _codex_lock = (lock_dir == ctx.homes.codex).then(|| {
                cmux_tui_platform::codex_config_lock::lock(
                    &lock_dir.join(cmux_tui_platform::codex_config_lock::LOCK_FILE),
                )
            });
            write_toml(&store, &path, key, value)?;
        }
    }
    Ok(Written {
        agent,
        key: key.to_owned(),
        scope: scope.to_owned(),
        path,
        backup: existed.then(|| store.backup_path(&backup_target)),
    })
}

/// Where an agent keeps the variables every session it starts gets: Claude Code's `env` object,
/// Codex's `[shell_environment_policy.set]` table (the variables its shell tool's commands get).
pub fn env_table(agent: Agent) -> &'static str {
    match agent {
        Agent::Claude => "env",
        Agent::Codex => "shell_environment_policy.set",
    }
}

/// A variable name both agents take: a letter or `_`, then letters, digits and `_`.
pub fn valid_env_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars.next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
        && name.len() <= 128
}

/// Sets (`Some`) or removes (`None`) one session variable in one scope's file (default `user`):
/// `env.NAME` for Claude Code, `shell_environment_policy.set.NAME` for Codex. The value is never
/// echoed back; `settings get` shows it masked like every env value.
pub fn apply_env(
    ctx: &Context,
    agent: Agent,
    name: &str,
    value: Option<&str>,
    scope: Option<&str>,
) -> Result<Written, SettingsError> {
    if !valid_env_name(name) {
        return Err(SettingsError::new(
            "agent_config.invalid_name",
            format!(
                "{name:?} is not a variable name; use letters, digits and _, not starting with a digit"
            ),
        ));
    }
    if let Some(value) = value
        && (value.contains(['\0', '\n', '\r']) || value.len() > 32 * 1024)
    {
        return Err(SettingsError::new(
            "agent_config.invalid_value",
            format!("{name} is one line of at most 32 KiB with no NUL"),
        ));
    }
    let scope = scope.unwrap_or("user");
    let key = format!("{}.{name}", env_table(agent));
    let path = scope_path(ctx, agent, scope)?;
    let store = ctx.homes.edits.clone();
    let _lock = store.lock(&path).map_err(|e| io_error(&path, e))?;
    let backup_target = fs::canonicalize(&path).unwrap_or_else(|_| path.clone());
    let existed = path.exists();
    match agent {
        Agent::Claude => write_json(&store, &path, &key, value)?,
        Agent::Codex => {
            let lock_dir = path.parent().map(Path::to_path_buf).unwrap_or_default();
            let _codex_lock = (lock_dir == ctx.homes.codex).then(|| {
                cmux_tui_platform::codex_config_lock::lock(
                    &lock_dir.join(cmux_tui_platform::codex_config_lock::LOCK_FILE),
                )
            });
            write_codex_env(&store, &path, name, value)?;
        }
    }
    Ok(Written {
        agent,
        key,
        scope: scope.to_owned(),
        path,
        backup: existed.then(|| store.backup_path(&backup_target)),
    })
}

fn validate(row: &Curated, value: &str) -> Result<(), SettingsError> {
    if !row.choices.is_empty() {
        if row.choices.contains(&value) {
            return Ok(());
        }
        return Err(SettingsError::new(
            "agent_config.invalid_value",
            format!("{} is one of {}", row.key, row.choices.join(", ")),
        ));
    }
    if value.trim().is_empty() {
        return Err(SettingsError::new(
            "agent_config.invalid_value",
            format!("{} needs a value; unset it to use the default", row.key),
        ));
    }
    if value.chars().any(char::is_control) || value.chars().count() > 1000 {
        return Err(SettingsError::new(
            "agent_config.invalid_value",
            format!("{} is one line of at most 1000 characters", row.key),
        ));
    }
    Ok(())
}

/// The file a scope writes.
fn scope_path(ctx: &Context, agent: Agent, scope: &str) -> Result<PathBuf, SettingsError> {
    let no_project = || {
        SettingsError::new(
            "agent_config.scope",
            format!("the {scope} scope needs a project folder (--cwd)"),
        )
    };
    match (agent, scope) {
        (_, "user") => Ok(match agent {
            Agent::Claude => ctx.homes.claude_settings(),
            Agent::Codex => ctx.homes.codex_config(),
        }),
        (Agent::Claude, "project") => {
            Ok(ctx.project_root().ok_or_else(no_project)?.join(".claude/settings.json"))
        }
        (Agent::Claude, "local") => {
            Ok(ctx.project_root().ok_or_else(no_project)?.join(".claude/settings.local.json"))
        }
        (Agent::Codex, "project") => {
            let root = ctx.project_root().ok_or_else(no_project)?;
            if !codex_trusted(ctx) {
                return Err(SettingsError::new(
                    "agent_config.scope",
                    "Codex ignores this project's config until the project is trusted; trust it in Codex first",
                ));
            }
            Ok(root.join(".codex/config.toml"))
        }
        (Agent::Codex, other) if other.starts_with("profile:") => {
            let name = other.strip_prefix("profile:").unwrap_or_default();
            if !valid_profile(name) {
                return Err(SettingsError::new(
                    "agent_config.scope",
                    "a profile name is letters, digits, - and _",
                ));
            }
            Ok(ctx.homes.codex.join(format!("{name}.config.toml")))
        }
        _ => Err(SettingsError::new(
            "agent_config.scope",
            match agent {
                Agent::Claude => {
                    format!("{scope} is not a scope cmux writes; use user, project or local")
                }
                Agent::Codex => {
                    format!("{scope} is not a scope cmux writes; use user, project or profile:NAME")
                }
            },
        )),
    }
}

fn read_existing(path: &Path) -> Result<String, SettingsError> {
    match fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(error) => Err(SettingsError::new(
            "agent_config.io",
            format!("cannot read {}: {error}", path.display()),
        )),
    }
}

fn io_error(path: &Path, error: std::io::Error) -> SettingsError {
    SettingsError::new("agent_config.io", format!("cannot write {}: {error}", path.display()))
}

fn write_json(
    store: &write::Store,
    path: &Path,
    key: &str,
    value: Option<&str>,
) -> Result<(), SettingsError> {
    let source = read_existing(path)?;
    let unchanged_missing = source.trim().is_empty() && value.is_none();
    if unchanged_missing {
        return Ok(());
    }
    let source = if source.trim().is_empty() { "{}\n".to_owned() } else { source };
    match serde_json::from_str::<Value>(&source) {
        Ok(Value::Object(_)) => {}
        _ if matches!(cmux_config::jsonc::parse(&source), Ok(Value::Object(_))) => {
            return Err(SettingsError::new(
                "agent_config.parse",
                format!("{}: {IGNORED_JSONC}; remove it in the file first", path.display()),
            ));
        }
        _ => {
            return Err(SettingsError::new(
                "agent_config.parse",
                format!("{} is not a JSON object; fix it in the file first", path.display()),
            ));
        }
    }
    let parts: Vec<String> = key.split('.').map(str::to_owned).collect();
    let edit = |text: &str, parts: &[String], value: Option<Value>| match value {
        Some(value) => cmux_config::jsonc::set(text, parts, &value),
        None => cmux_config::jsonc::remove(text, parts),
    };
    let fail = |error: cmux_config::jsonc::JsoncError| {
        SettingsError::new("agent_config.parse", format!("cannot edit {}: {error}", path.display()))
    };
    let mut text = if key == "statusLine.command" && value.is_none() {
        // The status line is one object: Claude Code's schema requires `type` and `command`, and
        // it skips a settings file with a schema error entirely ("Files with errors are skipped
        // entirely, not just the invalid settings"). A `statusLine` left with only `padding` or
        // `refreshInterval` would switch off every other setting in the file, so unset takes all
        // of it; the prior file stays in the backups.
        edit(&source, &["statusLine".to_owned()], None).map_err(fail)?
    } else {
        edit(&source, &parts, value.map(|v| Value::String(v.to_owned()))).map_err(fail)?
    };
    if value.is_none()
        && parts.len() == 2
        && parts[0] == "env"
        && serde_json::from_str::<Value>(&text).is_ok_and(|v| {
            v.get("env").is_some_and(|env| env.as_object().is_some_and(|o| o.is_empty()))
        })
    {
        // The last variable out takes its empty `env` with it.
        text = edit(&text, &parts[..1], None).map_err(fail)?;
    }
    if key == "statusLine.command" && value.is_some() {
        text = edit(&text, &["statusLine".to_owned(), "type".to_owned()], Some(json!("command")))
            .map_err(fail)?;
    }
    if text == source {
        return Ok(());
    }
    store.replace(path, &text).map_err(|e| io_error(path, e))
}

fn write_toml(
    store: &write::Store,
    path: &Path,
    key: &str,
    value: Option<&str>,
) -> Result<(), SettingsError> {
    let source = read_existing(path)?;
    let mut doc = source.parse::<toml_edit::DocumentMut>().map_err(|error| {
        SettingsError::new(
            "agent_config.parse",
            format!(
                "{} is not valid TOML ({}); fix it in the file first",
                path.display(),
                error.message()
            ),
        )
    })?;
    match value {
        Some(value) => {
            // In place when present (its comments stay); a new key goes before the first table.
            match doc.get_mut(key) {
                Some(toml_edit::Item::Value(existing)) => {
                    let decor = existing.decor().clone();
                    *existing = toml_edit::Value::from(value);
                    *existing.decor_mut() = decor;
                }
                _ => {
                    doc.insert(key, toml_edit::value(value));
                }
            }
        }
        None => {
            if doc.remove(key).is_none() {
                return Ok(());
            }
        }
    }
    let text = doc.to_string();
    if text == source {
        return Ok(());
    }
    store.replace(path, &text).map_err(|e| io_error(path, e))
}

/// Codex's `[shell_environment_policy.set]`: a table or an inline table, edited in place.
fn write_codex_env(
    store: &write::Store,
    path: &Path,
    name: &str,
    value: Option<&str>,
) -> Result<(), SettingsError> {
    let source = read_existing(path)?;
    let mut doc = source.parse::<toml_edit::DocumentMut>().map_err(|error| {
        SettingsError::new(
            "agent_config.parse",
            format!(
                "{} is not valid TOML ({}); fix it in the file first",
                path.display(),
                error.message()
            ),
        )
    })?;
    let not_table = |what: &str| {
        SettingsError::new(
            "agent_config.parse",
            format!("{} has {what} that is not a table; fix it in the file first", path.display()),
        )
    };
    match value {
        Some(value) => {
            let policy = doc.entry("shell_environment_policy").or_insert_with(|| {
                let mut table = toml_edit::Table::new();
                table.set_implicit(true);
                toml_edit::Item::Table(table)
            });
            let policy =
                policy.as_table_like_mut().ok_or_else(|| not_table("shell_environment_policy"))?;
            if policy.get("set").is_none() {
                // A table inside a table policy (`[shell_environment_policy.set]`); inside an
                // inline policy it becomes an inline table.
                policy.insert("set", toml_edit::Item::Table(toml_edit::Table::new()));
            }
            let set = policy
                .get_mut("set")
                .and_then(toml_edit::Item::as_table_like_mut)
                .ok_or_else(|| not_table("shell_environment_policy.set"))?;
            match set.get_mut(name) {
                Some(toml_edit::Item::Value(existing)) => {
                    let decor = existing.decor().clone();
                    *existing = toml_edit::Value::from(value);
                    *existing.decor_mut() = decor;
                }
                _ => {
                    set.insert(name, toml_edit::value(value));
                }
            }
        }
        None => {
            let Some(policy) = doc
                .get_mut("shell_environment_policy")
                .and_then(toml_edit::Item::as_table_like_mut)
            else {
                return Ok(());
            };
            let Some(set) = policy.get_mut("set").and_then(toml_edit::Item::as_table_like_mut)
            else {
                return Ok(());
            };
            if set.remove(name).is_none() {
                return Ok(());
            }
            // The last variable out takes its empty `set` table with it.
            if set.is_empty() {
                policy.remove("set");
            }
        }
    }
    let text = doc.to_string();
    if text == source {
        return Ok(());
    }
    store.replace(path, &text).map_err(|e| io_error(path, e))
}

#[cfg(test)]
#[path = "settings_tests.rs"]
mod tests;
