//! Curated skills, MCP servers and plugins installable across agent harnesses.

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

pub const RPC_LIST: &str = "skills.directory.list";
pub const RPC_INSTALL: &str = "skills.directory.install";
pub const RPC_REMOVE: &str = "skills.directory.remove";
pub const RPC_STATUS: &str = "skills.directory.status";
const MARKER: &str = ".cmux-skills-directory.json";
const BUNDLED: &str = include_str!("skills-catalog-v1.json");

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub kind: String,
    pub name: String,
    pub description: String,
    pub publisher: String,
    pub version: String,
    pub targets: Vec<String>,
    #[serde(default)] pub command: Option<String>,
    #[serde(default)] pub args: Vec<String>,
    #[serde(default)] pub skill: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Catalog { schema_version: u64, entries: Vec<Entry> }

fn catalog() -> Catalog {
    serde_json::from_str(BUNDLED).unwrap_or(Catalog { schema_version: 1, entries: Vec::new() })
}

fn home(root: Option<&Path>) -> PathBuf {
    root.map(Path::to_path_buf).or_else(dirs::home_dir).unwrap_or_else(|| PathBuf::from("."))
}

fn target_root(root: &Path, harness: &str) -> Result<PathBuf> {
    let actual_home = dirs::home_dir();
    let configured = actual_home.as_deref() == Some(root);
    let env_path = |key: &str| configured.then(|| std::env::var_os(key)).flatten().map(PathBuf::from);
    Ok(match harness {
        "claude" => env_path("CLAUDE_CONFIG_DIR").unwrap_or_else(|| root.join(".claude")),
        "codex" => env_path("CODEX_HOME").unwrap_or_else(|| root.join(".codex")),
        "pi" => env_path("PI_CODING_AGENT_DIR").unwrap_or_else(|| root.join(".pi").join("agent")),
        "opencode" => env_path("OPENCODE_CONFIG_DIR").or_else(|| env_path("XDG_CONFIG_HOME").map(|p| p.join("opencode"))).unwrap_or_else(|| root.join(".config").join("opencode")),
        _ => bail!("unsupported harness: {harness}"),
    })
}

fn entry(id: &str) -> Result<Entry> {
    catalog().entries.into_iter().find(|e| e.id == id).with_context(|| format!("unknown directory entry: {id}"))
}

fn requested_targets(params: &Value, entry: &Entry) -> Result<Vec<String>> {
    let targets = params.get("targets").and_then(Value::as_array).map(|v| v.iter().filter_map(Value::as_str).map(str::to_owned).collect()).unwrap_or_else(|| entry.targets.clone());
    if targets.is_empty() { bail!("at least one harness target is required"); }
    for target in &targets { if !entry.targets.iter().any(|allowed| allowed == target) { bail!("{} is not supported by {}", target, entry.id); } }
    Ok(targets)
}

fn ensure_dir(path: &Path) -> Result<()> {
    crate::config::private_state_dir(path).with_context(|| format!("prepare {}", path.display()))
}

fn write_marker(dir: &Path, entry: &Entry, harness: &str) -> Result<()> {
    ensure_dir(dir)?;
    let marker = json!({"id": entry.id, "version": entry.version, "harness": harness, "managedBy": "cmux.skills-directory"});
    crate::config::write_atomic(&dir.join(MARKER), serde_json::to_vec_pretty(&marker)?.as_slice())?;
    Ok(())
}

fn read_object(path: &Path) -> Result<Map<String, Value>> {
    if !path.is_file() { return Ok(Map::new()); }
    let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    let value: Value = serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))?;
    value.as_object().cloned().context("configuration root must be an object")
}

fn write_object(path: &Path, object: Map<String, Value>) -> Result<()> {
    if let Some(parent) = path.parent() { ensure_dir(parent)?; }
    crate::config::write_atomic(path, serde_json::to_vec_pretty(&Value::Object(object))?.as_slice())?;
    Ok(())
}

fn install_skill(root: &Path, harness: &str, entry: &Entry) -> Result<PathBuf> {
    let base = target_root(root, harness)?.join("skills").join(&entry.id);
    if base.exists() && !base.join(MARKER).is_file() { bail!("refusing to replace unmanaged skill {}", base.display()); }
    ensure_dir(&base)?;
    crate::config::write_atomic(&base.join("SKILL.md"), entry.skill.as_deref().unwrap_or(&entry.description).as_bytes())?;
    write_marker(&base, entry, harness)?;
    Ok(base)
}

fn install_plugin(root: &Path, harness: &str, entry: &Entry) -> Result<PathBuf> {
    let base = target_root(root, harness)?.join("plugins").join(&entry.id);
    if base.exists() && !base.join(MARKER).is_file() { bail!("refusing to replace unmanaged plugin {}", base.display()); }
    ensure_dir(&base)?;
    let manifest = json!({"name": entry.id, "version": entry.version, "description": entry.description, "managedBy": "cmux.skills-directory"});
    crate::config::write_atomic(&base.join("plugin.json"), serde_json::to_vec_pretty(&manifest)?.as_slice())?;
    write_marker(&base, entry, harness)?;
    Ok(base)
}

fn install_mcp(root: &Path, harness: &str, entry: &Entry) -> Result<PathBuf> {
    let command = entry.command.clone().unwrap_or_else(|| "npx".to_owned());
    let mut marker = json!({"command": command, "args": entry.args, "x-cmux-managed": true, "description": entry.description});
    let path = match harness {
        "claude" | "pi" => {
            let path = target_root(root, harness)?.join("settings.json");
            let mut object = read_object(&path)?;
            if object.get("mcpServers").and_then(Value::as_object).and_then(|servers| servers.get(&entry.id)).is_some_and(|value| value.get("x-cmux-managed").and_then(Value::as_bool) != Some(true)) { bail!("refusing to replace unmanaged MCP server {}", entry.id); }
            let servers = object.entry("mcpServers").or_insert_with(|| json!({}));
            servers.as_object_mut().context("mcpServers is not an object")?.insert(entry.id.clone(), marker);
            write_object(&path, object)?;
            path
        }
        "opencode" => {
            let path = target_root(root, harness)?.join("opencode.json");
            let mut object = read_object(&path)?;
            if object.get("mcp").and_then(Value::as_object).and_then(|servers| servers.get(&entry.id)).is_some_and(|value| value.get("x-cmux-managed").and_then(Value::as_bool) != Some(true)) { bail!("refusing to replace unmanaged MCP server {}", entry.id); }
            marker["type"] = Value::String("local".to_owned());
            marker["command"] = Value::Array(std::iter::once(Value::String(command)).chain(entry.args.iter().cloned().map(Value::String)).collect());
            let servers = object.entry("mcp").or_insert_with(|| json!({}));
            servers.as_object_mut().context("mcp is not an object")?.insert(entry.id.clone(), marker);
            write_object(&path, object)?;
            path
        }
        "codex" => {
            let path = target_root(root, harness)?.join("config.toml");
            let mut table = if path.is_file() { fs::read_to_string(&path)?.parse::<toml::Table>().context("parse Codex config")? } else { toml::Table::new() };
            let servers = table.entry("mcp_servers").or_insert_with(|| toml::Value::Table(toml::map::Map::new()));
            let servers = servers.as_table_mut().context("mcp_servers is not a table")?;
            if servers.get(&entry.id).is_some_and(|value| value.as_table().and_then(|table| table.get("x_cmux_managed")).and_then(toml::Value::as_bool) != Some(true)) { bail!("refusing to replace unmanaged MCP server {}", entry.id); }
            let mut row = toml::map::Map::new();
            row.insert("command".into(), toml::Value::String(command));
            row.insert("args".into(), toml::Value::Array(entry.args.iter().cloned().map(toml::Value::String).collect()));
            row.insert("x_cmux_managed".into(), toml::Value::Boolean(true));
            servers.insert(entry.id.clone(), toml::Value::Table(row));
            if let Some(parent) = path.parent() { ensure_dir(parent)?; }
            crate::config::write_atomic(&path, toml::to_string_pretty(&table)?.as_bytes())?;
            path
        }
        _ => bail!("unsupported harness: {harness}"),
    };
    Ok(path)
}

fn is_installed(root: &Path, harness: &str, entry: &Entry) -> bool {
    match entry.kind.as_str() {
        "skill" => target_root(root, harness).map(|p| p.join("skills").join(&entry.id).join(MARKER).is_file()).unwrap_or(false),
        "plugin" => target_root(root, harness).map(|p| p.join("plugins").join(&entry.id).join(MARKER).is_file()).unwrap_or(false),
        "mcp" => match harness {
            "codex" => target_root(root, harness).ok().and_then(|p| fs::read_to_string(p.join("config.toml")).ok()).and_then(|s| s.parse::<toml::Table>().ok()).and_then(|t| t.get("mcp_servers").and_then(toml::Value::as_table).and_then(|m| m.get(&entry.id)).and_then(toml::Value::as_table).and_then(|m| m.get("x_cmux_managed")).and_then(toml::Value::as_bool)).unwrap_or(false),
            "opencode" => target_root(root, harness).ok().and_then(|p| read_object(&p.join("opencode.json")).ok()).and_then(|o| o.get("mcp").and_then(Value::as_object).and_then(|m| m.get(&entry.id)).and_then(|v| v.get("x-cmux-managed")).and_then(Value::as_bool)).unwrap_or(false),
            _ => target_root(root, harness).ok().and_then(|p| read_object(&p.join("settings.json")).ok()).and_then(|o| o.get("mcpServers").and_then(Value::as_object).and_then(|m| m.get(&entry.id)).and_then(|v| v.get("x-cmux-managed")).and_then(Value::as_bool)).unwrap_or(false),
        },
        _ => false,
    }
}

pub fn list(params: &Value, root: Option<&Path>) -> Value {
    let query = params.get("query").and_then(Value::as_str).unwrap_or("").to_ascii_lowercase();
    let kind = params.get("kind").and_then(Value::as_str);
    let root = home(root);
    let entries: Vec<Value> = catalog().entries.into_iter().filter(|e| kind.map_or(true, |k| e.kind == k)).filter(|e| query.is_empty() || [e.name.as_str(), e.description.as_str(), e.publisher.as_str()].iter().any(|v| v.to_ascii_lowercase().contains(&query))).map(|e| {
        let installed: BTreeMap<_, _> = e.targets.iter().map(|h| (h.clone(), is_installed(&root, h, &e))).collect();
        json!({"id": e.id, "kind": e.kind, "name": e.name, "description": e.description, "publisher": e.publisher, "version": e.version, "targets": e.targets, "installed": installed})
    }).collect();
    json!({"schemaVersion": catalog().schema_version, "entries": entries})
}

pub fn status(params: &Value, root: Option<&Path>) -> Result<Value> {
    let id = params.get("id").and_then(Value::as_str).context("id is required")?;
    let e = entry(id)?;
    let root = home(root);
    Ok(json!({"id": id, "installed": e.targets.iter().map(|h| (h, is_installed(&root, h, &e))).collect::<BTreeMap<_, _>>() }))
}

pub fn install(params: &Value, root: Option<&Path>) -> Result<Value> {
    let id = params.get("id").and_then(Value::as_str).context("id is required")?;
    let e = entry(id)?;
    let root = home(root);
    let targets = requested_targets(params, &e)?;
    let mut paths = BTreeMap::new();
    for harness in targets { let path = match e.kind.as_str() { "skill" => install_skill(&root, &harness, &e)?, "plugin" => install_plugin(&root, &harness, &e)?, "mcp" => install_mcp(&root, &harness, &e)?, _ => bail!("unsupported entry kind") }; paths.insert(harness, path.display().to_string()); }
    Ok(json!({"id": id, "version": e.version, "installed": paths}))
}

pub fn remove(params: &Value, root: Option<&Path>) -> Result<Value> {
    let id = params.get("id").and_then(Value::as_str).context("id is required")?;
    let e = entry(id)?;
    let root = home(root);
    let targets = requested_targets(params, &e)?;
    for harness in &targets {
        match e.kind.as_str() {
            "skill" | "plugin" => {
                let dir = target_root(&root, harness)?.join(if e.kind == "skill" { "skills" } else { "plugins" }).join(&e.id);
                if dir.join(MARKER).is_file() { fs::remove_dir_all(dir)?; }
            }
            "mcp" => {
                let path = match harness.as_str() { "opencode" => target_root(&root, harness)?.join("opencode.json"), "codex" => target_root(&root, harness)?.join("config.toml"), _ => target_root(&root, harness)?.join("settings.json") };
                if harness == "codex" {
                    if let Ok(text) = fs::read_to_string(&path) && let Ok(mut table) = text.parse::<toml::Table>() && let Some(servers) = table.get_mut("mcp_servers").and_then(toml::Value::as_table_mut) && servers.get(&e.id).and_then(toml::Value::as_table).and_then(|m| m.get("x_cmux_managed")).and_then(toml::Value::as_bool) == Some(true) {
                        servers.remove(&e.id);
                        crate::config::write_atomic(&path, toml::to_string_pretty(&table)?.as_bytes())?;
                    }
                } else if path.is_file() {
                    let mut object = read_object(&path)?;
                    let key = if harness == "opencode" { "mcp" } else { "mcpServers" };
                    if let Some(servers) = object.get_mut(key).and_then(Value::as_object_mut) && servers.get(&e.id).and_then(|v| v.get("x-cmux-managed")).and_then(Value::as_bool) == Some(true) {
                        servers.remove(&e.id);
                        write_object(&path, object)?;
                    }
                }
            }
            _ => bail!("unsupported entry kind"),
        }
    }
    Ok(json!({"id": id, "removed": targets}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn installs_and_removes_without_touching_unmanaged_files() {
        let temp = tempfile::tempdir().unwrap();
        let root = temp.path();
        let skill = json!({"id":"terminal-workflows","targets":["claude","codex","pi","opencode"]});
        install(&skill, Some(root)).unwrap();
        assert!(root.join(".claude/skills/terminal-workflows/SKILL.md").is_file());
        remove(&skill, Some(root)).unwrap();
        assert!(!root.join(".claude/skills/terminal-workflows").exists());

        let mcp = json!({"id":"filesystem-tools","targets":["claude","codex","pi","opencode"]});
        install(&mcp, Some(root)).unwrap();
        assert!(root.join(".codex/config.toml").is_file());
        assert_eq!(status(&json!({"id":"filesystem-tools"}), Some(root)).unwrap()["installed"]["codex"], true);
        remove(&mcp, Some(root)).unwrap();
        assert_eq!(status(&json!({"id":"filesystem-tools"}), Some(root)).unwrap()["installed"]["codex"], false);
    }
}
