//! The MCP servers the person gave Claude Code and Codex, in those agents' own files: listed per
//! agent and scope, and added, removed, turned on and off there, as the agents' own CLIs would.
//!
//! Claude Code (2.1.322, measured 2026-11-19 with `claude mcp list` against these files):
//! - `user`: `mcpServers` of `~/.claude.json`; `local`: `projects.<folder>.mcpServers` there;
//!   `project`: `mcpServers` of `.mcp.json` in the folder or a parent (closest wins a name).
//! - A user or local server is off for one folder while `projects.<folder>.disabledMcpServers`
//!   names it ("Disabled for this project"). A project server is off while
//!   `disabledMcpjsonServers` names it, and waits for approval ("Pending approval") until
//!   `enabledMcpjsonServers` names it or `enableAllProjectMcpServers` is on (both in
//!   `projects.<folder>` of `~/.claude.json` or a settings file).
//! - The same name in several scopes runs once: local over project over user.
//!
//! Codex (0.164.0, measured with `codex mcp list --json`):
//! - `user`: `[mcp_servers.<name>]` of `$CODEX_HOME/config.toml`; `project`: the same in
//!   `.codex/config.toml` of the folder or a parent (closer over farther over user).
//! - `enabled = false` turns one off. A plugin's servers come from the plugin's own `.mcp.json`;
//!   `[plugins."<plugin>".mcp_servers.<name>] enabled` turns one on or off. Which plugins'
//!   servers Codex loads is its own business, so the plugin rows are the ones `codex mcp list
//!   --json` reports that no config file defines.
//!
//! Nothing here returns a secret: env values and header values never leave this module (only
//! their names), arguments that follow a secret-looking flag read `*****`, and a URL loses its
//! password.

use cmux_process::{Command, Stdio};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::Serialize;
use toml_edit::{DocumentMut, Item, Table, value};

use crate::Agent;
use crate::fsio;
use crate::ojson::Json;
use crate::paths::{Paths, project_chain};

/// What a masked value reads.
pub const MASK: &str = "*****";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    /// Every folder (Claude `~/.claude.json` `mcpServers`, Codex `config.toml`).
    User,
    /// Claude only: one folder, private to this person (`projects.<folder>` of `~/.claude.json`).
    Local,
    /// One folder, in the folder (`.mcp.json`, `.codex/config.toml`).
    Project,
    /// Codex only: from an installed plugin.
    Plugin,
}

impl Scope {
    pub fn id(self) -> &'static str {
        match self {
            Scope::User => "user",
            Scope::Local => "local",
            Scope::Project => "project",
            Scope::Plugin => "plugin",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "user" | "global" => Some(Scope::User),
            "local" => Some(Scope::Local),
            "project" => Some(Scope::Project),
            "plugin" => Some(Scope::Plugin),
            _ => None,
        }
    }
}

/// One server as the agent would see it. Never holds a secret.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Server {
    pub agent: &'static str,
    pub name: String,
    pub scope: Scope,
    /// `stdio`, `http` or `sse`.
    pub transport: String,
    pub command: Option<String>,
    /// The arguments, a secret-looking flag's value masked.
    pub args: Vec<String>,
    /// The URL without its password.
    pub url: Option<String>,
    /// Whether the agent starts it (in the listed folder, for Claude's per-folder switches).
    pub enabled: bool,
    /// Claude project servers: `approved`, or `pending` until the person approves it in Claude.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub approval: Option<&'static str>,
    /// The names of the variables it is given (values never shown).
    pub env: Vec<String>,
    /// The names of the headers it sends (values never shown).
    pub headers: Vec<String>,
    /// The file that defines it.
    pub file: String,
    /// The plugin it comes from (Codex `plugin` scope), as `<plugin>@<marketplace>`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub plugin: Option<String>,
    /// Another scope's server of the same name runs instead.
    pub shadowed: bool,
    /// Whether cmux can remove it (a plugin's server can only be turned off).
    pub removable: bool,
}

/// One agent's servers for one folder, and what could not be read.
#[derive(Debug, Clone, Default, Serialize)]
pub struct Listing {
    pub servers: Vec<Server>,
    /// Files that are there but could not be read, each with why.
    pub problems: Vec<String>,
}

/// How to list: the folder Claude's per-folder state and the project files are read for, and the
/// Codex CLI to ask about plugin servers (None: no plugin rows).
#[derive(Debug, Clone, Default)]
pub struct Options {
    pub project: Option<PathBuf>,
    pub codex_cli: Option<PathBuf>,
}

pub fn list(paths: &Paths, agent: Agent, options: &Options) -> Listing {
    match agent {
        Agent::Claude => claude::list(paths, options.project.as_deref()),
        Agent::Codex => codex::list(paths, options),
    }
}

/// A server to add.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewServer {
    pub name: String,
    pub transport: Transport,
    /// Variables for a stdio server, or headers for an http/sse one.
    pub env: Vec<(String, String)>,
    pub headers: Vec<(String, String)>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Transport {
    Stdio { command: String, args: Vec<String> },
    Http { url: String },
    Sse { url: String },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Edit {
    Add(NewServer),
    Remove,
    Enable,
    Disable,
}

/// Which server an edit is for: its agent and name, its scope (None: the one the agent runs, or
/// `user` for an add) and the folder (Claude's per-folder switches and the project files).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Target {
    pub agent: Agent,
    pub name: String,
    pub scope: Option<Scope>,
    pub project: Option<PathBuf>,
}

/// What an edit wrote.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Outcome {
    pub agent: &'static str,
    pub name: String,
    pub scope: Scope,
    pub file: String,
    /// The copy of the file before the change, when there was a file.
    pub backup: Option<String>,
    /// False when the file already said so.
    pub changed: bool,
}

/// A name either agent accepts: letters, digits, `_` and `-` (Codex refuses anything else).
pub fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

pub fn apply(
    paths: &Paths,
    target: &Target,
    edit: &Edit,
    options: &Options,
) -> Result<Outcome, String> {
    if !valid_name(&target.name) {
        return Err(format!(
            "{:?} is not a server name: use letters, digits, _ and -",
            target.name
        ));
    }
    let project = target.project.as_deref().or(options.project.as_deref());
    let scope = match (edit, target.scope) {
        (_, Some(scope)) => scope,
        (Edit::Add(_), None) => Scope::User,
        (_, None) => {
            let listing = list(
                paths,
                target.agent,
                &Options { project: project.map(Path::to_path_buf), ..options.clone() },
            );
            listing
                .servers
                .iter()
                .find(|s| s.name == target.name && !s.shadowed)
                .map(|s| s.scope)
                .ok_or_else(|| {
                format!("{} has no MCP server named {}", target.agent.id(), target.name)
            })?
        }
    };
    match (target.agent, scope) {
        (Agent::Claude, Scope::Plugin) => {
            Err("Claude Code plugin servers are not edited here".into())
        }
        (Agent::Codex, Scope::Local) => Err("Codex has no local scope: use user or project".into()),
        (Agent::Claude, _) => claude::apply(paths, &target.name, scope, project, edit),
        (Agent::Codex, _) => codex::apply(paths, &target.name, scope, project, edit, options),
    }
}

/// Masks the value after a flag that names a secret (`--api-key X`, `--token=X`) and the value
/// of a `NAME=value` argument whose name does.
pub fn mask_args(args: &[String]) -> Vec<String> {
    let mut out = Vec::with_capacity(args.len());
    let mut mask_next = false;
    for arg in args {
        if mask_next {
            out.push(MASK.to_owned());
            mask_next = false;
            continue;
        }
        if let Some((key, _)) = arg.split_once('=')
            && secret_name(key)
        {
            out.push(format!("{key}={MASK}"));
            continue;
        }
        if arg.starts_with('-') && secret_name(arg) {
            mask_next = true;
        }
        out.push(arg.clone());
    }
    out
}

fn secret_name(name: &str) -> bool {
    let lower = name.to_ascii_lowercase();
    [
        "token",
        "secret",
        "password",
        "passwd",
        "api-key",
        "api_key",
        "apikey",
        "auth",
        "bearer",
        "credential",
        "private-key",
    ]
    .iter()
    .any(|word| lower.contains(word))
}

/// The URL without its password (`https://user:pw@host` → `https://user:*****@host`) and without
/// query values that look secret.
pub fn mask_url(url: &str) -> String {
    let mut out = url.to_owned();
    if let Some((scheme, rest)) = url.split_once("://") {
        // The authority runs to the first `/`, `?` or `#`; the userinfo is what precedes its last `@`.
        let (authority, tail) = match rest.find(['/', '?', '#']) {
            Some(end) => (rest.get(..end).unwrap_or(rest), rest.get(end..).unwrap_or("")),
            None => (rest, ""),
        };
        if let Some((userinfo, host)) = authority.rsplit_once('@') {
            let masked = match userinfo.split_once(':') {
                Some((user, _)) => format!("{user}:{MASK}"),
                None => MASK.to_owned(),
            };
            out = format!("{scheme}://{masked}@{host}{tail}");
        }
    }
    if let Some(query_start) = out.find('?') {
        let (head, query) = out.split_at(query_start + 1);
        let masked: Vec<String> = query
            .split('&')
            .map(|pair| match pair.split_once('=') {
                Some((key, _)) if secret_name(key) || key.eq_ignore_ascii_case("key") => {
                    format!("{key}={MASK}")
                }
                _ => pair.to_owned(),
            })
            .collect();
        out = format!("{head}{}", masked.join("&"));
    }
    out
}

/// Marks every server but the one that runs, for each name: the first scope in `order` wins.
fn mark_shadowed(servers: &mut [Server], order: &[Scope]) {
    let rank = |scope: Scope| order.iter().position(|s| *s == scope).unwrap_or(order.len());
    // Per name: the index of the server that runs and its scope's rank.
    let mut winner: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for (index, server) in servers.iter().enumerate() {
        let server_rank = rank(server.scope);
        match winner.get(&server.name) {
            Some(&(_, best_rank)) if best_rank <= server_rank => {}
            _ => {
                winner.insert(server.name.clone(), (index, server_rank));
            }
        }
    }
    for (index, server) in servers.iter_mut().enumerate() {
        server.shadowed = winner.get(&server.name).map(|&(best, _)| best) != Some(index);
    }
}

mod claude {
    use super::*;

    const MCP_JSON: &str = ".mcp.json";

    fn read_json(path: &Path, problems: &mut Vec<String>) -> Option<Json> {
        let text = std::fs::read_to_string(path).ok()?;
        match Json::parse(&text) {
            Ok(json) => Some(json),
            Err(error) => {
                problems.push(format!("{}: {error}", path.display()));
                None
            }
        }
    }

    /// Claude's key for a folder in `projects`: the path as given; a folder reached through a
    /// link is also found under its real path.
    fn project_entry<'a>(config: &'a Json, project: &Path) -> Option<&'a Json> {
        let projects = config.get("projects")?;
        let key = project.to_string_lossy();
        projects.get(&key).or_else(|| {
            let real = std::fs::canonicalize(project).ok()?;
            projects.get(&real.to_string_lossy())
        })
    }

    fn project_key(config: &Json, project: &Path) -> String {
        let given = project.to_string_lossy().into_owned();
        if config.get("projects").and_then(|p| p.get(&given)).is_some() {
            return given;
        }
        if let Ok(real) = std::fs::canonicalize(project) {
            let real = real.to_string_lossy().into_owned();
            if config.get("projects").and_then(|p| p.get(&real)).is_some() {
                return real;
            }
            return real;
        }
        given
    }

    fn server(name: &str, entry: &Json, scope: Scope, file: &Path) -> Server {
        let url = entry.get("url").and_then(Json::as_str).map(str::to_owned);
        let transport = match entry.get("type").and_then(Json::as_str) {
            Some("http") | Some("streamable-http") | Some("streamable_http") => "http",
            Some("sse") => "sse",
            Some(_) | None if url.is_some() && entry.get("command").is_none() => "http",
            _ => "stdio",
        };
        let names = |key: &str| -> Vec<String> {
            entry
                .get(key)
                .and_then(Json::as_object)
                .map(|pairs| pairs.iter().map(|(k, _)| k.clone()).collect())
                .unwrap_or_default()
        };
        Server {
            agent: "claude",
            name: name.to_owned(),
            scope,
            transport: transport.to_owned(),
            command: entry.get("command").and_then(Json::as_str).map(str::to_owned),
            args: mask_args(&entry.get("args").map(Json::strings).unwrap_or_default()),
            url: url.as_deref().map(mask_url),
            enabled: true,
            approval: None,
            env: names("env"),
            headers: names("headers"),
            file: file.display().to_string(),
            plugin: None,
            shadowed: false,
            removable: true,
        }
    }

    /// The project-server switches from `~/.claude.json`'s folder entry and the settings files.
    struct Switches {
        disabled_servers: BTreeSet<String>,
        disabled_json: BTreeSet<String>,
        enabled_json: BTreeSet<String>,
        enable_all: bool,
    }

    fn switches(
        paths: &Paths,
        config: Option<&Json>,
        project: Option<&Path>,
        problems: &mut Vec<String>,
    ) -> Switches {
        let mut out = Switches {
            disabled_servers: BTreeSet::new(),
            disabled_json: BTreeSet::new(),
            enabled_json: BTreeSet::new(),
            enable_all: false,
        };
        let mut absorb = |json: &Json, servers: bool| {
            if servers {
                out.disabled_servers
                    .extend(json.get("disabledMcpServers").map(Json::strings).unwrap_or_default());
            }
            out.disabled_json
                .extend(json.get("disabledMcpjsonServers").map(Json::strings).unwrap_or_default());
            out.enabled_json
                .extend(json.get("enabledMcpjsonServers").map(Json::strings).unwrap_or_default());
            out.enable_all |=
                json.get("enableAllProjectMcpServers").and_then(Json::as_bool).unwrap_or(false);
        };
        if let (Some(config), Some(project)) = (config, project)
            && let Some(entry) = project_entry(config, project)
        {
            absorb(entry, true);
        }
        let mut settings = vec![paths.claude_dir.join("settings.json")];
        if let Some(project) = project {
            settings.push(project.join(".claude").join("settings.json"));
            settings.push(project.join(".claude").join("settings.local.json"));
        }
        for file in settings {
            if let Some(json) = read_json(&file, problems) {
                absorb(&json, false);
            }
        }
        out
    }

    pub(super) fn list(paths: &Paths, project: Option<&Path>) -> Listing {
        let mut listing = Listing::default();
        let config = read_json(&paths.claude_json, &mut listing.problems);
        let switches = switches(paths, config.as_ref(), project, &mut listing.problems);
        if let Some(config) = &config {
            for (name, entry) in
                config.get("mcpServers").and_then(Json::as_object).unwrap_or_default()
            {
                let mut row = server(name, entry, Scope::User, &paths.claude_json);
                row.enabled = !switches.disabled_servers.contains(name);
                listing.servers.push(row);
            }
            if let Some(project) = project
                && let Some(entry) = project_entry(config, project)
            {
                for (name, entry) in
                    entry.get("mcpServers").and_then(Json::as_object).unwrap_or_default()
                {
                    let mut row = server(name, entry, Scope::Local, &paths.claude_json);
                    row.enabled = !switches.disabled_servers.contains(name);
                    listing.servers.push(row);
                }
            }
        }
        if let Some(project) = project {
            let mut seen = BTreeSet::new();
            for folder in project_chain(project, &paths.home) {
                let file = folder.join(MCP_JSON);
                let Some(json) = read_json(&file, &mut listing.problems) else { continue };
                for (name, entry) in
                    json.get("mcpServers").and_then(Json::as_object).unwrap_or_default()
                {
                    if !seen.insert(name.clone()) {
                        continue;
                    }
                    let mut row = server(name, entry, Scope::Project, &file);
                    row.enabled = !switches.disabled_json.contains(name);
                    row.approval =
                        Some(if switches.enable_all || switches.enabled_json.contains(name) {
                            "approved"
                        } else {
                            "pending"
                        });
                    listing.servers.push(row);
                }
            }
        }
        mark_shadowed(&mut listing.servers, &[Scope::Local, Scope::Project, Scope::User]);
        listing
    }

    fn parse_or_new(text: Option<&str>, path: &Path) -> Result<Json, String> {
        match text {
            None => Ok(Json::object()),
            Some(text) if text.trim().is_empty() => Ok(Json::object()),
            Some(text) => {
                let json = Json::parse(text).map_err(|e| {
                    format!("{} is not JSON ({e}); nothing was written", path.display())
                })?;
                if !matches!(json, Json::Object(_)) {
                    return Err(format!(
                        "{} is not a JSON object; nothing was written",
                        path.display()
                    ));
                }
                Ok(json)
            }
        }
    }

    /// The text to write back: two-space JSON as Claude writes it, ending as the old text ended.
    fn render(json: &Json, old: Option<&str>) -> String {
        let mut text = json.pretty();
        if old.is_none_or(|old| old.ends_with('\n')) {
            text.push('\n');
        }
        text
    }

    fn entry(server: &NewServer) -> Json {
        let pairs = |items: &[(String, String)]| {
            Json::Object(items.iter().map(|(k, v)| (k.clone(), Json::String(v.clone()))).collect())
        };
        let mut out = Json::object();
        match &server.transport {
            Transport::Stdio { command, args } => {
                out.set("type", Json::String("stdio".into()));
                out.set("command", Json::String(command.clone()));
                out.set("args", Json::Array(args.iter().cloned().map(Json::String).collect()));
                out.set("env", pairs(&server.env));
            }
            Transport::Http { url } | Transport::Sse { url } => {
                let kind =
                    if matches!(server.transport, Transport::Sse { .. }) { "sse" } else { "http" };
                out.set("type", Json::String(kind.into()));
                out.set("url", Json::String(url.clone()));
                if !server.headers.is_empty() {
                    out.set("headers", pairs(&server.headers));
                }
            }
        }
        out
    }

    /// Adds or drops `name` in the string array `key` of `holder`. `prior` is the same holder
    /// before cmux's last write: when the array comes back to the names it held there, it takes
    /// their order (an off then on never reorders the person's list), and an emptied array the
    /// person did not have goes.
    fn toggle_in(
        holder: &mut Json,
        prior: Option<&Json>,
        key: &str,
        name: &str,
        present: bool,
    ) -> Result<(), String> {
        let mut items = holder.get(key).map(Json::strings).unwrap_or_default();
        let had = items.iter().any(|item| item == name);
        if present && !had {
            items.push(name.to_owned());
        } else if !present && had {
            items.retain(|item| item != name);
        } else {
            return Ok(());
        }
        let before = prior.and_then(|p| p.get(key)).map(Json::strings);
        if let Some(before) = &before {
            let same = |a: &[String], b: &[String]| {
                a.iter().collect::<BTreeSet<_>>() == b.iter().collect::<BTreeSet<_>>()
            };
            if before.len() == items.len() && same(before, &items) {
                items = before.clone();
            }
        }
        if items.is_empty() && before.is_none() && prior.is_some() {
            holder.remove(key);
            return Ok(());
        }
        if !holder.set(key, Json::Array(items.into_iter().map(Json::String).collect())) {
            return Err(format!("{key} is not in an object"));
        }
        Ok(())
    }

    pub(super) fn apply(
        paths: &Paths,
        name: &str,
        scope: Scope,
        project: Option<&Path>,
        edit: &Edit,
    ) -> Result<Outcome, String> {
        let needs_project = matches!(scope, Scope::Local | Scope::Project)
            || matches!(edit, Edit::Enable | Edit::Disable);
        let project = match project {
            Some(project) => Some(project.to_path_buf()),
            None if needs_project => {
                return Err(format!(
                    "Claude Code keeps {} per folder: give the folder (--project DIR)",
                    if matches!(scope, Scope::User) {
                        "a server's on/off switch"
                    } else {
                        "this scope"
                    }
                ));
            }
            None => None,
        };
        // A switch names a server Claude Code has: an unknown name would only leave a stray entry.
        if matches!(edit, Edit::Enable | Edit::Disable)
            && !list(paths, project.as_deref())
                .servers
                .iter()
                .any(|server| server.name == name && server.scope == scope)
        {
            return Err(format!("Claude Code has no {} server named {name}", scope.id()));
        }
        // Which file the edit writes: a project server's definition lives in `.mcp.json`, its
        // switches and every other scope's state in `~/.claude.json`.
        let file = match (scope, edit) {
            (Scope::Project, Edit::Add(_) | Edit::Remove) => {
                let project = project.as_deref().unwrap_or(Path::new("."));
                project_chain(project, &paths.home)
                    .into_iter()
                    .map(|folder| folder.join(MCP_JSON))
                    .find(|file| {
                        matches!(edit, Edit::Remove)
                            && std::fs::read_to_string(file)
                                .ok()
                                .and_then(|t| Json::parse(&t).ok())
                                .is_some_and(|j| {
                                    j.get("mcpServers").and_then(|m| m.get(name)).is_some()
                                })
                    })
                    .unwrap_or_else(|| project.join(MCP_JSON))
            }
            _ => paths.claude_json.clone(),
        };
        // An add never replaces a server the person already has under that name (its env and
        // args would be lost): they remove it first, as `claude mcp add` asks.
        let taken = || {
            format!("Claude Code already has a {} server named {name}: remove it first", scope.id())
        };
        let mut missing = false;
        let changed = fsio::update(&file, |old| {
            let mut json = parse_or_new(old, &file)?;
            missing = false;
            let key = project.as_deref().map(|p| project_key(&json, p));
            match (scope, edit) {
                (Scope::User | Scope::Project, Edit::Add(server)) => {
                    let servers =
                        json.object_at("mcpServers").ok_or("mcpServers is not an object")?;
                    if servers.get(name).is_some() {
                        return Err(taken());
                    }
                    servers.set(name, entry(server));
                }
                (Scope::Local, Edit::Add(server)) => {
                    let key = key.unwrap_or_default();
                    let projects = json.object_at("projects").ok_or("projects is not an object")?;
                    let folder =
                        projects.object_at(&key).ok_or("the folder's entry is not an object")?;
                    let servers =
                        folder.object_at("mcpServers").ok_or("mcpServers is not an object")?;
                    if servers.get(name).is_some() {
                        return Err(taken());
                    }
                    servers.set(name, entry(server));
                }
                (Scope::User | Scope::Project, Edit::Remove) => {
                    missing = json.get_mut("mcpServers").and_then(|m| m.remove(name)).is_none();
                }
                (Scope::Local, Edit::Remove) => {
                    let key = key.unwrap_or_default();
                    missing = json
                        .get_mut("projects")
                        .and_then(|p| p.get_mut(&key))
                        .and_then(|f| f.get_mut("mcpServers"))
                        .and_then(|m| m.remove(name))
                        .is_none();
                }
                (_, Edit::Enable | Edit::Disable) => {
                    let off = matches!(edit, Edit::Disable);
                    let key = key.unwrap_or_default();
                    // The folder's entry before cmux's last write, for an undo to restore.
                    let prior = std::fs::read_to_string(fsio::backup_path(&file))
                        .ok()
                        .and_then(|text| Json::parse(&text).ok());
                    let prior = prior
                        .as_ref()
                        .and_then(|p| p.get("projects"))
                        .and_then(|p| p.get(&key))
                        .cloned();
                    let prior = if off { None } else { prior };
                    let projects = json.object_at("projects").ok_or("projects is not an object")?;
                    let folder =
                        projects.object_at(&key).ok_or("the folder's entry is not an object")?;
                    if scope == Scope::Project {
                        toggle_in(folder, prior.as_ref(), "disabledMcpjsonServers", name, off)?;
                        toggle_in(folder, prior.as_ref(), "enabledMcpjsonServers", name, !off)?;
                    } else {
                        toggle_in(folder, prior.as_ref(), "disabledMcpServers", name, off)?;
                    }
                }
                (Scope::Plugin, _) => {
                    return Err("Claude Code plugin servers are not edited here".into());
                }
            }
            if missing {
                return Err(format!(
                    "Claude Code has no {} server named {name} in {}",
                    scope.id(),
                    file.display()
                ));
            }
            Ok(render(&json, old))
        })?;
        Ok(outcome(Agent::Claude, name, scope, &file, changed))
    }
}

fn outcome(agent: Agent, name: &str, scope: Scope, file: &Path, changed: bool) -> Outcome {
    let backup = fsio::backup_path(file);
    Outcome {
        agent: agent.id(),
        name: name.to_owned(),
        scope,
        file: file.display().to_string(),
        backup: (changed && backup.exists()).then(|| backup.display().to_string()),
        changed,
    }
}

mod codex {
    use super::*;

    fn read_toml(path: &Path, problems: &mut Vec<String>) -> Option<DocumentMut> {
        let text = std::fs::read_to_string(path).ok()?;
        match text.parse::<DocumentMut>() {
            Ok(doc) => Some(doc),
            Err(error) => {
                problems.push(format!(
                    "{}: {}",
                    path.display(),
                    error.to_string().lines().next().unwrap_or("not TOML")
                ));
                None
            }
        }
    }

    fn server(name: &str, entry: &dyn toml_edit::TableLike, scope: Scope, file: &Path) -> Server {
        let text = |key: &str| entry.get(key).and_then(Item::as_str).map(str::to_owned);
        let strings = |key: &str| -> Vec<String> {
            entry
                .get(key)
                .and_then(Item::as_array)
                .map(|a| a.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect())
                .unwrap_or_default()
        };
        let keys = |key: &str| -> Vec<String> {
            entry
                .get(key)
                .and_then(Item::as_table_like)
                .map(|t| t.iter().map(|(k, _)| k.to_owned()).collect())
                .unwrap_or_default()
        };
        let url = text("url");
        let mut env = keys("env");
        env.extend(strings("env_vars"));
        let mut headers = keys("http_headers");
        headers.extend(keys("env_http_headers"));
        if let Some(var) = text("bearer_token_env_var") {
            headers.push(format!("Authorization (${var})"));
        }
        Server {
            agent: "codex",
            name: name.to_owned(),
            scope,
            transport: if url.is_some() { "http" } else { "stdio" }.to_owned(),
            command: text("command"),
            args: mask_args(&strings("args")),
            url: url.as_deref().map(mask_url),
            enabled: entry.get("enabled").and_then(Item::as_bool).unwrap_or(true),
            approval: None,
            env,
            headers,
            file: file.display().to_string(),
            plugin: None,
            shadowed: false,
            removable: true,
        }
    }

    fn servers_of(doc: &DocumentMut, scope: Scope, file: &Path) -> Vec<Server> {
        let Some(table) = doc.get("mcp_servers").and_then(Item::as_table_like) else {
            return Vec::new();
        };
        table
            .iter()
            .filter_map(|(name, item)| {
                item.as_table_like().map(|entry| server(name, entry, scope, file))
            })
            .collect()
    }

    /// The project layers, closest first: `.codex/config.toml` of the folder and its parents.
    fn project_files(paths: &Paths, project: &Path) -> Vec<PathBuf> {
        project_chain(project, &paths.home)
            .into_iter()
            .map(|folder| folder.join(".codex").join("config.toml"))
            .filter(|file| *file != paths.codex_config())
            .collect()
    }

    pub(super) fn list(paths: &Paths, options: &Options) -> Listing {
        let mut listing = Listing::default();
        let user_file = paths.codex_config();
        let user = read_toml(&user_file, &mut listing.problems);
        if let Some(project) = &options.project {
            let mut seen = BTreeSet::new();
            for file in project_files(paths, project) {
                let Some(doc) = read_toml(&file, &mut listing.problems) else { continue };
                for row in servers_of(&doc, Scope::Project, &file) {
                    if seen.insert(row.name.clone()) {
                        listing.servers.push(row);
                    }
                }
            }
        }
        if let Some(doc) = &user {
            listing.servers.extend(servers_of(doc, Scope::User, &user_file));
        }
        mark_shadowed(&mut listing.servers, &[Scope::Project, Scope::User]);
        if let Some(cli) = &options.codex_cli {
            let defined: BTreeSet<String> =
                listing.servers.iter().map(|s| s.name.clone()).collect();
            match cli_servers(cli, paths, options.project.as_deref()) {
                Ok(reported) => {
                    let index = plugin_index(paths);
                    for entry in reported {
                        let Some(name) = entry.get("name").and_then(serde_json::Value::as_str)
                        else {
                            continue;
                        };
                        if defined.contains(name) {
                            continue;
                        }
                        listing.servers.push(plugin_server(name, &entry, index.get(name), paths));
                    }
                }
                Err(why) => listing.problems.push(why),
            }
        }
        listing
    }

    /// A server `codex mcp list --json` reports that no config file defines: a plugin's.
    fn plugin_server(
        name: &str,
        entry: &serde_json::Value,
        plugin: Option<&(String, PathBuf)>,
        paths: &Paths,
    ) -> Server {
        let transport = &entry["transport"];
        let strings = |value: &serde_json::Value| -> Vec<String> {
            match value {
                serde_json::Value::Array(items) => {
                    items.iter().filter_map(|v| v.as_str().map(str::to_owned)).collect()
                }
                serde_json::Value::Object(map) => map.keys().cloned().collect(),
                _ => Vec::new(),
            }
        };
        let mut env = strings(&transport["env"]);
        env.extend(strings(&transport["env_vars"]));
        let url = transport["url"].as_str();
        let mut headers = strings(&transport["http_headers"]);
        headers.extend(strings(&transport["env_http_headers"]));
        Server {
            agent: "codex",
            name: name.to_owned(),
            scope: Scope::Plugin,
            transport: match transport["type"].as_str() {
                Some("stdio") => "stdio",
                Some("sse") => "sse",
                _ if url.is_some() => "http",
                _ => "stdio",
            }
            .to_owned(),
            command: transport["command"].as_str().map(str::to_owned),
            args: mask_args(&strings(&transport["args"])),
            url: url.map(mask_url),
            enabled: entry["enabled"].as_bool().unwrap_or(true),
            approval: None,
            env,
            headers,
            file: plugin
                .map(|(_, file)| file.display().to_string())
                .unwrap_or_else(|| paths.codex_plugin_cache().display().to_string()),
            plugin: plugin.map(|(id, _)| id.clone()),
            shadowed: false,
            removable: false,
        }
    }

    /// Each server name a cached plugin defines, with its plugin (`<plugin>@<marketplace>`) and
    /// `.mcp.json`: `plugins/cache/<marketplace>/<plugin>/<version>/.mcp.json`, the newest
    /// version's file when there are several.
    fn plugin_index(paths: &Paths) -> BTreeMap<String, (String, PathBuf)> {
        let mut out: BTreeMap<String, (String, PathBuf, std::time::SystemTime)> = BTreeMap::new();
        let dirs = |path: &Path| -> Vec<PathBuf> {
            std::fs::read_dir(path)
                .map(|it| it.flatten().map(|e| e.path()).filter(|p| p.is_dir()).collect())
                .unwrap_or_default()
        };
        for market in dirs(&paths.codex_plugin_cache()) {
            for plugin in dirs(&market) {
                for version in dirs(&plugin) {
                    let file = version.join(".mcp.json");
                    let Ok(text) = std::fs::read_to_string(&file) else { continue };
                    let Ok(json) = Json::parse(&text) else { continue };
                    let stamp = std::fs::metadata(&file)
                        .and_then(|m| m.modified())
                        .unwrap_or(std::time::UNIX_EPOCH);
                    let id = format!(
                        "{}@{}",
                        plugin.file_name().unwrap_or_default().to_string_lossy(),
                        market.file_name().unwrap_or_default().to_string_lossy()
                    );
                    for (name, _) in
                        json.get("mcpServers").and_then(Json::as_object).unwrap_or_default()
                    {
                        let newer = out.get(name).is_none_or(|(_, _, seen)| stamp > *seen);
                        if newer {
                            out.insert(name.clone(), (id.clone(), file.clone(), stamp));
                        }
                    }
                }
            }
        }
        out.into_iter().map(|(name, (id, file, _))| (name, (id, file))).collect()
    }

    /// `codex mcp list --json` in `project` (its project layers count there), for at most 15 s.
    /// Its output goes to a private temporary file, so no reader thread is needed.
    fn cli_servers(
        cli: &Path,
        paths: &Paths,
        project: Option<&Path>,
    ) -> Result<Vec<serde_json::Value>, String> {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        let out_path = std::env::temp_dir()
            .join(format!("cmux-codex-mcp-list-{}-{nanos}.json", std::process::id()));
        let out = std::fs::File::create(&out_path).map_err(|e| format!("codex mcp list: {e}"))?;
        let result = (|| {
            let mut command = Command::new(cli);
            command
                .args(["mcp", "list", "--json"])
                .env("CODEX_HOME", &paths.codex_home)
                .stdin(Stdio::null())
                .stdout(out)
                .stderr(Stdio::null());
            if let Some(project) = project.filter(|p| p.is_dir()) {
                command.current_dir(project);
            }
            let mut child =
                command.spawn().map_err(|e| format!("{} mcp list: {e}", cli.display()))?;
            // timeout: the bound on one `codex mcp list` (0.1 s measured); a hung CLI loses only its plugin rows.
            let status = match child.wait_timeout(Duration::from_secs(15)) {
                Ok(Some(status)) => status,
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    return Err(
                        "codex mcp list did not answer in 15 s; plugin servers are not listed"
                            .to_owned(),
                    );
                }
            };
            if !status.success() {
                return Err(format!(
                    "codex mcp list exited with {status}; plugin servers are not listed"
                ));
            }
            let bytes = std::fs::read(&out_path).unwrap_or_default();
            match serde_json::from_slice::<serde_json::Value>(&bytes) {
                Ok(serde_json::Value::Array(items)) => Ok(items),
                _ => Err("codex mcp list --json printed no list; plugin servers are not listed"
                    .to_owned()),
            }
        })();
        let _ = std::fs::remove_file(&out_path);
        result
    }

    fn parse_or_new(text: Option<&str>, path: &Path) -> Result<DocumentMut, String> {
        match text {
            None => Ok(DocumentMut::new()),
            Some(text) => text.parse::<DocumentMut>().map_err(|e| {
                format!(
                    "{} is not TOML ({}); nothing was written",
                    path.display(),
                    e.to_string().lines().next().unwrap_or("")
                )
            }),
        }
    }

    fn new_table(server: &NewServer) -> Table {
        let mut table = Table::new();
        match &server.transport {
            Transport::Stdio { command, args } => {
                table.insert("command", value(command.as_str()));
                let mut list = toml_edit::Array::new();
                for arg in args {
                    list.push(arg.as_str());
                }
                table.insert("args", value(list));
                if !server.env.is_empty() {
                    let mut env = toml_edit::InlineTable::new();
                    for (k, v) in &server.env {
                        env.insert(k, v.as_str().into());
                    }
                    table.insert("env", value(env));
                }
            }
            Transport::Http { url } | Transport::Sse { url } => {
                table.insert("url", value(url.as_str()));
                if !server.headers.is_empty() {
                    let mut headers = toml_edit::InlineTable::new();
                    for (k, v) in &server.headers {
                        headers.insert(k, v.as_str().into());
                    }
                    table.insert("http_headers", value(headers));
                }
            }
        }
        table
    }

    /// The `mcp_servers` table, made (as a header-less parent, `[mcp_servers.x]` style) when absent.
    fn servers_table(doc: &mut DocumentMut) -> Result<&mut dyn toml_edit::TableLike, String> {
        if doc.get("mcp_servers").is_none() {
            let mut parent = Table::new();
            parent.set_implicit(true);
            doc.insert("mcp_servers", Item::Table(parent));
        }
        doc.get_mut("mcp_servers")
            .and_then(Item::as_table_like_mut)
            .ok_or_else(|| "mcp_servers is not a table".to_owned())
    }

    pub(super) fn apply(
        paths: &Paths,
        name: &str,
        scope: Scope,
        project: Option<&Path>,
        edit: &Edit,
        options: &Options,
    ) -> Result<Outcome, String> {
        let mut plugin_id = None;
        let file = match scope {
            Scope::User => paths.codex_config(),
            Scope::Plugin => {
                if matches!(edit, Edit::Add(_) | Edit::Remove) {
                    return Err(format!(
                        "{name} comes from a Codex plugin: it can be turned off, not removed"
                    ));
                }
                let listing = list(
                    paths,
                    &Options {
                        project: project.map(Path::to_path_buf),
                        codex_cli: options.codex_cli.clone(),
                    },
                );
                plugin_id = listing
                    .servers
                    .iter()
                    .find(|s| s.name == name && s.scope == Scope::Plugin)
                    .and_then(|s| s.plugin.clone());
                if plugin_id.is_none() {
                    plugin_id = plugin_index(paths).remove(name).map(|(id, _)| id);
                }
                if plugin_id.is_none() {
                    return Err(format!("no installed Codex plugin defines {name}"));
                }
                paths.codex_config()
            }
            Scope::Project => {
                let project =
                    project.ok_or("a Codex project server needs the folder (--project DIR)")?;
                let files = project_files(paths, project);
                let existing = files.iter().find(|file| {
                    std::fs::read_to_string(file)
                        .ok()
                        .and_then(|t| t.parse::<DocumentMut>().ok())
                        .is_some_and(|doc| {
                            doc.get("mcp_servers")
                                .and_then(Item::as_table_like)
                                .is_some_and(|t| t.contains_key(name))
                        })
                });
                match (existing, edit) {
                    (Some(file), _) => file.clone(),
                    (None, Edit::Add(_)) => project.join(".codex").join("config.toml"),
                    (None, _) => {
                        return Err(format!(
                            "Codex has no project server named {name} for {}",
                            project.display()
                        ));
                    }
                }
            }
            Scope::Local => return Err("Codex has no local scope".into()),
        };
        // The lock every cmux writer of a codex config.toml takes (cmux-tui-platform).
        let _lock = file.parent().and_then(|dir| {
            cmux_tui_platform::codex_config_lock::lock(
                &dir.join(cmux_tui_platform::codex_config_lock::LOCK_FILE),
            )
        });
        let missing =
            || format!("Codex has no {} server named {name} in {}", scope.id(), file.display());
        let changed = fsio::update(&file, |old| {
            let mut doc = parse_or_new(old, &file)?;
            match (edit, &plugin_id) {
                (Edit::Enable | Edit::Disable, Some(id)) => {
                    let on = matches!(edit, Edit::Enable);
                    let plugins = table_at(doc.as_table_mut(), "plugins")?;
                    let plugin = table_at(plugins, id)?;
                    let servers = table_at(plugin, "mcp_servers")?;
                    let entry = table_at(servers, name)?;
                    entry.insert("enabled", value(on));
                }
                (Edit::Add(server), _) => {
                    let servers = servers_table(&mut doc)?;
                    if servers.contains_key(name) {
                        // Never replaces the person's own entry (its env and args would go).
                        return Err(format!(
                            "Codex already has a {} server named {name} in {}: remove it first",
                            scope.id(),
                            file.display()
                        ));
                    }
                    servers.insert(name, Item::Table(new_table(server)));
                }
                (Edit::Remove, _) => {
                    if servers_table(&mut doc)?.remove(name).is_none() {
                        return Err(missing());
                    }
                }
                (Edit::Enable | Edit::Disable, None) => {
                    let servers = servers_table(&mut doc)?;
                    let Some(entry) = servers.get_mut(name).and_then(Item::as_table_like_mut)
                    else {
                        return Err(missing());
                    };
                    // On is Codex's default: the switch goes, as if it had never been off,
                    // unless the person had written it before cmux's last write (then it is set
                    // back to true in place, its comment kept).
                    let theirs = || {
                        std::fs::read_to_string(fsio::backup_path(&file))
                            .ok()
                            .and_then(|prior| prior.parse::<DocumentMut>().ok())
                            .is_some_and(|prior| {
                                prior
                                    .get("mcp_servers")
                                    .and_then(|s| s.get(name))
                                    .and_then(|e| e.get("enabled"))
                                    .is_some()
                            })
                    };
                    let on = matches!(edit, Edit::Enable);
                    if on && entry.get("enabled").is_some() && !theirs() {
                        entry.remove("enabled");
                    } else if let Some(existing) =
                        entry.get_mut("enabled").and_then(Item::as_value_mut)
                    {
                        let decor = existing.decor().clone();
                        *existing = toml_edit::Value::from(on);
                        *existing.decor_mut() = decor;
                    } else if !on {
                        entry.insert("enabled", value(false));
                    }
                }
            }
            Ok(doc.to_string())
        })?;
        Ok(outcome(Agent::Codex, name, scope, &file, changed))
    }

    /// The table at `key` under `parent`, made (header-less when it only holds tables) when absent.
    fn table_at<'a>(parent: &'a mut Table, key: &str) -> Result<&'a mut Table, String> {
        if !parent.contains_key(key) {
            let mut table = Table::new();
            table.set_implicit(true);
            parent.insert(key, Item::Table(table));
        }
        parent
            .get_mut(key)
            .and_then(Item::as_table_mut)
            .ok_or_else(|| format!("{key} is not a table"))
    }
}

/// Where the Codex CLI is: `$CMUX_CODEX_CLI`, else `codex` on `PATH` or in the usual install
/// folders (an app started from the Dock has a short `PATH`).
pub fn find_codex_cli(env: &BTreeMap<String, String>) -> Option<PathBuf> {
    if let Some(path) = env.get("CMUX_CODEX_CLI").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(path));
    }
    let home = env.get("HOME").map(PathBuf::from);
    let mut dirs: Vec<PathBuf> =
        env.get("PATH").map(|p| std::env::split_paths(p).collect()).unwrap_or_default();
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin"].map(PathBuf::from));
    if let Some(home) = &home {
        dirs.push(home.join(".local/bin"));
        dirs.push(home.join(".bun/bin"));
        dirs.push(home.join(".npm-global/bin"));
        dirs.push(home.join(".cargo/bin"));
    }
    dirs.into_iter().map(|dir| dir.join("codex")).find(|file| is_executable(file))
}

fn is_executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

#[cfg(test)]
mod tests;
