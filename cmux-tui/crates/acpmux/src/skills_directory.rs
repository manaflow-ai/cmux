//! Curated skills, MCP servers and plugins installable across agent harnesses.

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::io::ErrorKind;
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
    #[serde(default)]
    pub command: Option<String>,
    #[serde(default)]
    pub args: Vec<String>,
    #[serde(default)]
    pub skill: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Catalog {
    schema_version: u64,
    entries: Vec<Entry>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ManagedMarker {
    id: String,
    version: String,
    harness: String,
    managed_by: String,
}

fn catalog() -> Catalog {
    serde_json::from_str(BUNDLED).unwrap_or(Catalog { schema_version: 1, entries: Vec::new() })
}

fn home(root: Option<&Path>) -> PathBuf {
    root.map(Path::to_path_buf).or_else(dirs::home_dir).unwrap_or_else(|| PathBuf::from("."))
}

fn target_root(root: &Path, harness: &str) -> Result<PathBuf> {
    let actual_home = dirs::home_dir();
    let configured = actual_home.as_deref() == Some(root);
    let env_path =
        |key: &str| configured.then(|| std::env::var_os(key)).flatten().map(PathBuf::from);
    Ok(match harness {
        "claude" => env_path("CLAUDE_CONFIG_DIR").unwrap_or_else(|| root.join(".claude")),
        "codex" => env_path("CODEX_HOME").unwrap_or_else(|| root.join(".codex")),
        "pi" => env_path("PI_CODING_AGENT_DIR").unwrap_or_else(|| root.join(".pi").join("agent")),
        "opencode" => env_path("OPENCODE_CONFIG_DIR")
            .or_else(|| env_path("XDG_CONFIG_HOME").map(|p| p.join("opencode")))
            .unwrap_or_else(|| root.join(".config").join("opencode")),
        _ => bail!("unsupported harness: {harness}"),
    })
}

fn claude_mcp_path(root: &Path) -> PathBuf {
    if dirs::home_dir().as_deref() == Some(root)
        && let Some(dir) = std::env::var_os("CLAUDE_CONFIG_DIR")
    {
        return PathBuf::from(dir).join(".claude.json");
    }
    root.join(".claude.json")
}

fn entry(id: &str) -> Result<Entry> {
    catalog()
        .entries
        .into_iter()
        .find(|e| e.id == id)
        .with_context(|| format!("unknown directory entry: {id}"))
}

fn requested_targets(params: &Value, entry: &Entry) -> Result<Vec<String>> {
    let targets = params
        .get("targets")
        .and_then(Value::as_array)
        .map(|v| v.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_else(|| entry.targets.clone());
    if targets.is_empty() {
        bail!("at least one harness target is required");
    }
    for target in &targets {
        if !entry.targets.iter().any(|allowed| allowed == target) {
            bail!("{} is not supported by {}", target, entry.id);
        }
    }
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

fn safe_metadata(path: &Path) -> Result<Option<fs::Metadata>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) => {
            if metadata.file_type().is_symlink() {
                bail!("refusing symlink target {}", path.display());
            }
            Ok(Some(metadata))
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error).with_context(|| format!("inspect {}", path.display())),
    }
}

fn validate_managed_dir(dir: &Path, entry: &Entry, harness: &str) -> Result<bool> {
    let Some(metadata) = safe_metadata(dir)? else { return Ok(false) };
    ensure!(metadata.is_dir(), "refusing unmanaged {}", dir.display());
    let marker = dir.join(MARKER);
    let Some(marker_metadata) = safe_metadata(&marker)? else {
        bail!("refusing to replace unmanaged {}", dir.display());
    };
    ensure!(marker_metadata.is_file(), "refusing unmanaged {}", dir.display());
    let marker: ManagedMarker = serde_json::from_slice(
        &fs::read(&marker).with_context(|| format!("read {}", marker.display()))?,
    )
    .with_context(|| format!("invalid managed marker {}", marker.display()))?;
    ensure!(marker.id == entry.id, "managed marker id mismatch for {}", dir.display());
    ensure!(marker.harness == harness, "managed marker harness mismatch for {}", dir.display());
    ensure!(
        marker.managed_by == "cmux.skills-directory",
        "managed marker owner mismatch for {}",
        dir.display()
    );
    ensure!(!marker.version.is_empty(), "managed marker version missing for {}", dir.display());
    Ok(true)
}

fn validate_managed_file(path: &Path) -> Result<()> {
    if let Some(metadata) = safe_metadata(path)? {
        ensure!(metadata.is_file(), "refusing non-file target {}", path.display());
    }
    Ok(())
}

fn validate_directory(path: &Path) -> Result<()> {
    if let Some(metadata) = safe_metadata(path)? {
        ensure!(metadata.is_dir(), "refusing non-directory target {}", path.display());
    }
    Ok(())
}

// The home is the trusted anchor (it may itself be a platform symlink). Every
// component below it, including configured harness roots, must be a real directory.
fn validate_target_path(root: &Path, path: &Path) -> Result<()> {
    for parent in path.ancestors().skip(1) {
        if root.starts_with(parent) {
            break;
        }
        validate_directory(parent)?;
    }
    safe_metadata(path)?;
    Ok(())
}

fn managed_dir(root: &Path, harness: &str, entry: &Entry) -> Result<PathBuf> {
    let dir = target_root(root, harness)?
        .join(if entry.kind == "skill" { "skills" } else { "plugins" })
        .join(&entry.id);
    validate_target_path(root, &dir)?;
    Ok(dir)
}

fn config_path(root: &Path, harness: &str) -> Result<PathBuf> {
    let path = match harness {
        "codex" => target_root(root, harness)?.join("config.toml"),
        "opencode" => target_root(root, harness)?.join("opencode.json"),
        "claude" => claude_mcp_path(root),
        _ => target_root(root, harness)?.join("settings.json"),
    };
    validate_target_path(root, &path)?;
    Ok(path)
}

fn read_toml_table(path: &Path) -> Result<Option<toml::Table>> {
    let Some(metadata) = safe_metadata(path)? else { return Ok(None) };
    ensure!(metadata.is_file(), "configuration must be a file: {}", path.display());
    Ok(Some(
        fs::read_to_string(path)
            .with_context(|| format!("read {}", path.display()))?
            .parse::<toml::Table>()
            .with_context(|| format!("parse Codex config {}", path.display()))?,
    ))
}

fn read_object(path: &Path) -> Result<Map<String, Value>> {
    let Some(metadata) = safe_metadata(path)? else { return Ok(Map::new()) };
    ensure!(metadata.is_file(), "configuration must be a file: {}", path.display());
    let bytes = fs::read(path).with_context(|| format!("read {}", path.display()))?;
    let value: Value =
        serde_json::from_slice(&bytes).with_context(|| format!("parse {}", path.display()))?;
    value.as_object().cloned().context("configuration root must be an object")
}

fn install_skill(root: &Path, harness: &str, entry: &Entry) -> Result<PathBuf> {
    let base = managed_dir(root, harness, entry)?;
    validate_managed_dir(&base, entry, harness)?;
    validate_managed_file(&base.join("SKILL.md"))?;
    ensure_dir(&base)?;
    let body = entry.skill.as_deref().unwrap_or(&entry.description);
    let document = if body.trim_start().starts_with("---") {
        body.to_owned()
    } else {
        format!("---\nname: {}\ndescription: {}\n---\n\n{}\n", entry.id, entry.description, body)
    };
    crate::config::write_atomic(&base.join("SKILL.md"), document.as_bytes())?;
    write_marker(&base, entry, harness)?;
    Ok(base)
}

fn install_plugin(root: &Path, harness: &str, entry: &Entry) -> Result<PathBuf> {
    let base = managed_dir(root, harness, entry)?;
    validate_managed_dir(&base, entry, harness)?;
    validate_directory(&base.join(".claude-plugin"))?;
    validate_managed_file(&base.join(".claude-plugin").join("plugin.json"))?;
    ensure_dir(&base)?;
    let manifest = json!({"name": entry.id, "version": entry.version, "description": entry.description, "managedBy": "cmux.skills-directory"});
    ensure_dir(&base.join(".claude-plugin"))?;
    crate::config::write_atomic(
        &base.join(".claude-plugin").join("plugin.json"),
        serde_json::to_vec_pretty(&manifest)?.as_slice(),
    )?;
    write_marker(&base, entry, harness)?;
    Ok(base)
}

fn remove_managed_dir(dir: &Path, entry: &Entry, harness: &str) -> Result<()> {
    if !validate_managed_dir(dir, entry, harness)? {
        return Ok(());
    }
    let owned = if entry.kind == "skill" {
        vec![dir.join("SKILL.md"), dir.join(MARKER)]
    } else {
        vec![dir.join(".claude-plugin/plugin.json"), dir.join(MARKER)]
    };
    for path in owned {
        if let Some(metadata) = safe_metadata(&path)? {
            ensure!(metadata.is_file(), "refusing non-file target {}", path.display());
            crate::home_fs::remove_file(path)?;
        }
    }
    if entry.kind == "plugin" {
        let manifest_dir = dir.join(".claude-plugin");
        validate_directory(&manifest_dir)?;
        if manifest_dir.is_dir() && fs::read_dir(&manifest_dir)?.next().is_none() {
            crate::home_fs::remove_dir(manifest_dir)?;
        }
    }
    if dir.is_dir() && fs::read_dir(dir)?.next().is_none() {
        crate::home_fs::remove_dir(dir)?;
    }
    Ok(())
}

/// The env var that marks an MCP server entry as one this directory wrote, set to the entry's
/// id. It lives in the entry's own `env` (OpenCode: `environment`) because OpenCode's config
/// schema is strict and Codex's server rows take only known keys: an extra marker key would make
/// the harness refuse the whole file. The same way `desktop_link.rs` marks its `cmux` entry.
const OWNER_ENV: &str = "CMUX_SKILLS_DIRECTORY";

fn mcp_servers_key(harness: &str) -> &'static str {
    if harness == "opencode" { "mcp" } else { "mcpServers" }
}

fn mcp_env_key(harness: &str) -> &'static str {
    if harness == "opencode" { "environment" } else { "env" }
}

fn ours_json(harness: &str, entry: &Entry, server: &Value) -> bool {
    server.get(mcp_env_key(harness)).and_then(|env| env.get(OWNER_ENV)).and_then(Value::as_str)
        == Some(entry.id.as_str())
}

fn ours_toml(entry: &Entry, server: &toml::Value) -> bool {
    server.get("env").and_then(|env| env.get(OWNER_ENV)).and_then(toml::Value::as_str)
        == Some(entry.id.as_str())
}

fn ours_toml_edit(entry: &Entry, server: &toml_edit::Item) -> bool {
    server.get("env").and_then(|env| env.get(OWNER_ENV)).and_then(toml_edit::Item::as_str)
        == Some(entry.id.as_str())
}

fn mcp_command(entry: &Entry) -> String {
    entry.command.clone().unwrap_or_else(|| "npx".to_owned())
}

/// The server row in the harness's own shape, with only keys the harness knows.
fn mcp_json_row(harness: &str, entry: &Entry) -> Value {
    let owner = json!({ OWNER_ENV: entry.id });
    if harness == "opencode" {
        let command: Vec<String> =
            std::iter::once(mcp_command(entry)).chain(entry.args.iter().cloned()).collect();
        json!({"type": "local", "command": command, "environment": owner})
    } else {
        json!({"command": mcp_command(entry), "args": entry.args, "env": owner})
    }
}

/// Install or remove `entry`'s MCP server in `harness`'s config through `desktop_link`'s editors:
/// the person's key order, TOML comments and any concurrent writer's text stay, Codex's file is
/// edited under the shared cmux lock, and a same-named entry that is not ours is refused on every
/// edit round (it may appear while the edit runs).
fn edit_mcp(root: &Path, harness: &str, entry: &Entry, install: bool) -> Result<PathBuf> {
    let path = config_path(root, harness)?;
    let refuse = || anyhow::anyhow!("refusing to change unmanaged MCP server {}", entry.id);
    if harness == "codex" {
        crate::desktop_link::edit_toml(&path, |servers: &mut toml_edit::Table| {
            if servers.get(&entry.id).is_some_and(|row| !ours_toml_edit(entry, row)) {
                return Err(refuse());
            }
            if install {
                let mut row = toml_edit::Table::new();
                row.insert("command", toml_edit::value(mcp_command(entry)));
                let mut args = toml_edit::Array::new();
                for arg in &entry.args {
                    args.push(arg.as_str());
                }
                row.insert("args", toml_edit::value(args));
                let mut vars = toml_edit::InlineTable::new();
                vars.insert(OWNER_ENV, entry.id.as_str().into());
                row.insert("env", toml_edit::value(vars));
                servers.insert(&entry.id, toml_edit::Item::Table(row));
            } else {
                servers.remove(&entry.id);
            }
            Ok(())
        })?;
    } else {
        crate::desktop_link::edit_json(
            &path,
            mcp_servers_key(harness),
            |servers: &mut crate::desktop_link::Ordered<Value>| {
                if servers.get(&entry.id).is_some_and(|row| !ours_json(harness, entry, row)) {
                    return Err(refuse());
                }
                if install {
                    servers.insert(&entry.id, mcp_json_row(harness, entry));
                } else {
                    servers.remove(&entry.id);
                }
                Ok(())
            },
        )?;
    }
    Ok(path)
}

fn install_mcp(root: &Path, harness: &str, entry: &Entry) -> Result<PathBuf> {
    match harness {
        "claude" | "pi" | "opencode" | "codex" => edit_mcp(root, harness, entry, true),
        _ => bail!("unsupported harness: {harness}"),
    }
}

fn validate_install_target(root: &Path, harness: &str, entry: &Entry) -> Result<()> {
    match entry.kind.as_str() {
        "skill" | "plugin" => {
            let dir = managed_dir(root, harness, entry)?;
            validate_managed_dir(&dir, entry, harness)?;
            if entry.kind == "skill" {
                validate_managed_file(&dir.join("SKILL.md"))?;
            } else {
                validate_directory(&dir.join(".claude-plugin"))?;
                validate_managed_file(&dir.join(".claude-plugin").join("plugin.json"))?;
            }
        }
        "mcp" => {
            let path = config_path(root, harness)?;
            if harness == "codex" {
                if let Some(table) = read_toml_table(&path)? {
                    let servers = table
                        .get("mcp_servers")
                        .map(|v| v.as_table().context("mcp_servers is not a table"))
                        .transpose()?;
                    if servers.and_then(|m| m.get(&entry.id)).is_some_and(|v| !ours_toml(entry, v))
                    {
                        bail!("refusing to replace unmanaged MCP server {}", entry.id);
                    }
                }
            } else {
                let object = read_object(&path)?;
                let servers = object
                    .get(mcp_servers_key(harness))
                    .map(|v| v.as_object().context("MCP server table must be an object"))
                    .transpose()?;
                if servers
                    .and_then(|m| m.get(&entry.id))
                    .is_some_and(|v| !ours_json(harness, entry, v))
                {
                    bail!("refusing to replace unmanaged MCP server {}", entry.id);
                }
            }
        }
        _ => bail!("unsupported entry kind"),
    }
    Ok(())
}

fn validate_remove_target(root: &Path, harness: &str, entry: &Entry) -> Result<()> {
    match entry.kind.as_str() {
        "skill" | "plugin" => {
            let dir = managed_dir(root, harness, entry)?;
            if validate_managed_dir(&dir, entry, harness)? {
                if entry.kind == "skill" {
                    validate_managed_file(&dir.join("SKILL.md"))?;
                } else {
                    validate_directory(&dir.join(".claude-plugin"))?;
                    validate_managed_file(&dir.join(".claude-plugin").join("plugin.json"))?;
                }
            }
        }
        "mcp" => {
            let path = config_path(root, harness)?;
            if harness == "codex" {
                if let Some(table) = read_toml_table(&path)? {
                    let _ = table
                        .get("mcp_servers")
                        .map(|value| value.as_table().context("mcp_servers is not a table"))
                        .transpose()?;
                }
            } else {
                let object = read_object(&path)?;
                let key = if harness == "opencode" { "mcp" } else { "mcpServers" };
                let _ = object
                    .get(key)
                    .map(|value| value.as_object().context("MCP server table must be an object"))
                    .transpose()?;
            }
        }
        _ => bail!("unsupported entry kind"),
    }
    Ok(())
}

fn is_installed(root: &Path, harness: &str, entry: &Entry) -> bool {
    match entry.kind.as_str() {
        "skill" | "plugin" => managed_dir(root, harness, entry)
            .and_then(|dir| validate_managed_dir(&dir, entry, harness))
            .unwrap_or(false),
        "mcp" => {
            let Ok(path) = config_path(root, harness) else { return false };
            if harness == "codex" {
                read_toml_table(&path)
                    .ok()
                    .flatten()
                    .and_then(|t| {
                        t.get("mcp_servers")
                            .and_then(toml::Value::as_table)
                            .and_then(|m| m.get(&entry.id))
                            .map(|v| ours_toml(entry, v))
                    })
                    .unwrap_or(false)
            } else {
                read_object(&path)
                    .ok()
                    .and_then(|o| {
                        o.get(mcp_servers_key(harness))
                            .and_then(Value::as_object)
                            .and_then(|m| m.get(&entry.id))
                            .map(|v| ours_json(harness, entry, v))
                    })
                    .unwrap_or(false)
            }
        }
        _ => false,
    }
}

pub fn list(params: &Value, root: Option<&Path>) -> Value {
    let query = params.get("query").and_then(Value::as_str).unwrap_or("").to_ascii_lowercase();
    let kind = params.get("kind").and_then(Value::as_str);
    let root = home(root);
    let entries: Vec<Value> = catalog().entries.into_iter().filter(|e| kind.is_none_or(|k| e.kind == k)).filter(|e| query.is_empty() || [e.name.as_str(), e.description.as_str(), e.publisher.as_str()].iter().any(|v| v.to_ascii_lowercase().contains(&query))).map(|e| {
        let installed: BTreeMap<_, _> = e.targets.iter().map(|h| (h.clone(), is_installed(&root, h, &e))).collect();
        json!({"id": e.id, "kind": e.kind, "name": e.name, "description": e.description, "publisher": e.publisher, "version": e.version, "targets": e.targets, "installed": installed})
    }).collect();
    json!({"schemaVersion": catalog().schema_version, "entries": entries})
}

pub fn status(params: &Value, root: Option<&Path>) -> Result<Value> {
    let id = params.get("id").and_then(Value::as_str).context("id is required")?;
    let e = entry(id)?;
    let root = home(root);
    Ok(
        json!({"id": id, "installed": e.targets.iter().map(|h| (h, is_installed(&root, h, &e))).collect::<BTreeMap<_, _>>() }),
    )
}

pub fn install(params: &Value, root: Option<&Path>) -> Result<Value> {
    let id = params.get("id").and_then(Value::as_str).context("id is required")?;
    let e = entry(id)?;
    let root = home(root);
    let targets = requested_targets(params, &e)?;
    for harness in &targets {
        validate_install_target(&root, harness, &e)?;
    }
    let mut paths = BTreeMap::new();
    for harness in targets {
        let path = match e.kind.as_str() {
            "skill" => install_skill(&root, &harness, &e)?,
            "plugin" => install_plugin(&root, &harness, &e)?,
            "mcp" => install_mcp(&root, &harness, &e)?,
            _ => bail!("unsupported entry kind"),
        };
        paths.insert(harness, path.display().to_string());
    }
    Ok(json!({"id": id, "version": e.version, "installed": paths}))
}

pub fn remove(params: &Value, root: Option<&Path>) -> Result<Value> {
    let id = params.get("id").and_then(Value::as_str).context("id is required")?;
    let e = entry(id)?;
    let root = home(root);
    let targets = requested_targets(params, &e)?;
    for harness in &targets {
        validate_remove_target(&root, harness, &e)?;
    }
    for harness in &targets {
        match e.kind.as_str() {
            "skill" | "plugin" => {
                let dir = managed_dir(&root, harness, &e)?;
                remove_managed_dir(&dir, &e, harness)?;
            }
            "mcp" => {
                if is_installed(&root, harness, &e) {
                    edit_mcp(&root, harness, &e, false)?;
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
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;

    fn private_test_root(temp: &tempfile::TempDir) -> &Path {
        #[cfg(unix)]
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        crate::config::private_state_dir(temp.path()).unwrap();
        temp.path()
    }

    #[test]
    fn installs_and_removes_without_touching_unmanaged_files() {
        let temp = tempfile::tempdir().unwrap();
        let root = private_test_root(&temp);
        let skill = json!({"id":"terminal-workflows","targets":["claude","codex","pi","opencode"]});
        install(&skill, Some(root)).unwrap();
        assert!(root.join(".claude/skills/terminal-workflows/SKILL.md").is_file());
        remove(&skill, Some(root)).unwrap();
        assert!(!root.join(".claude/skills/terminal-workflows").exists());

        let plugin = json!({"id":"review-kit","targets":["claude"]});
        install(&plugin, Some(root)).unwrap();
        assert!(root.join(".claude/plugins/review-kit/.claude-plugin/plugin.json").is_file());
        remove(&plugin, Some(root)).unwrap();
        assert!(!root.join(".claude/plugins/review-kit").exists());

        let mcp = json!({"id":"filesystem-tools","targets":["claude","codex","pi","opencode"]});
        install(&mcp, Some(root)).unwrap();
        assert!(root.join(".codex/config.toml").is_file());
        assert_eq!(
            status(&json!({"id":"filesystem-tools"}), Some(root)).unwrap()["installed"]["codex"],
            true
        );
        remove(&mcp, Some(root)).unwrap();
        assert_eq!(
            status(&json!({"id":"filesystem-tools"}), Some(root)).unwrap()["installed"]["codex"],
            false
        );
    }

    #[test]
    fn preflights_all_targets_before_mutating_any() {
        let temp = tempfile::tempdir().unwrap();
        let root = private_test_root(&temp);
        fs::create_dir_all(root.join(".codex")).unwrap();
        fs::write(
            root.join(".codex/config.toml"),
            "[mcp_servers.filesystem-tools]\ncommand = 'other'\n",
        )
        .unwrap();
        let request = json!({"id":"filesystem-tools","targets":["claude","codex"]});
        assert!(install(&request, Some(root)).is_err());
        assert!(!root.join(".claude.json").exists());
    }
    #[test]
    fn invalid_markers_never_authorize_overwrite_or_removal() {
        let temp = tempfile::tempdir().unwrap();
        let root = private_test_root(&temp);
        let request = json!({"id":"terminal-workflows","targets":["claude"]});
        install(&request, Some(root)).unwrap();
        let dir = root.join(".claude/skills/terminal-workflows");
        let original = fs::read(dir.join("SKILL.md")).unwrap();
        let marker = fs::read(dir.join(MARKER)).unwrap();
        for field in ["id", "harness", "managedBy", "version"] {
            let mut invalid: Value = serde_json::from_slice(&marker).unwrap();
            invalid[field] = if field == "version" { json!("") } else { json!("someone-else") };
            fs::write(dir.join(MARKER), serde_json::to_vec(&invalid).unwrap()).unwrap();
            assert!(install(&request, Some(root)).is_err(), "{field}");
            assert!(remove(&request, Some(root)).is_err(), "{field}");
            assert!(!is_installed(root, "claude", &entry("terminal-workflows").unwrap()));
            assert_eq!(fs::read(dir.join("SKILL.md")).unwrap(), original);
        }
        fs::write(dir.join(MARKER), b"not json").unwrap();
        assert!(install(&request, Some(root)).is_err());
        assert!(remove(&request, Some(root)).is_err());
        assert_eq!(fs::read(dir.join("SKILL.md")).unwrap(), original);
    }

    #[test]
    fn removal_checks_later_configs_before_touching_earlier_targets() {
        let temp = tempfile::tempdir().unwrap();
        let root = private_test_root(&temp);
        let request = json!({"id":"filesystem-tools","targets":["claude","codex"]});
        install(&request, Some(root)).unwrap();
        let claude_before = fs::read(root.join(".claude.json")).unwrap();
        fs::write(root.join(".codex/config.toml"), "[invalid").unwrap();
        assert!(remove(&request, Some(root)).is_err());
        assert_eq!(fs::read(root.join(".claude.json")).unwrap(), claude_before);
    }

    #[test]
    fn mcp_edits_keep_comments_and_write_only_keys_the_harness_knows() {
        let temp = tempfile::tempdir().unwrap();
        let root = private_test_root(&temp);
        fs::create_dir_all(root.join(".codex")).unwrap();
        let codex =
            "# my settings\nmodel = \"o3\" # keep me\n\n[mcp_servers.mine]\ncommand = \"mine\"\n";
        fs::write(root.join(".codex/config.toml"), codex).unwrap();
        fs::create_dir_all(root.join(".config/opencode")).unwrap();
        fs::write(root.join(".config/opencode/opencode.json"), r#"{"theme":"x","$schema":"s"}"#)
            .unwrap();
        let request = json!({"id":"filesystem-tools","targets":["claude","codex","opencode"]});
        install(&request, Some(root)).unwrap();

        let text = fs::read_to_string(root.join(".codex/config.toml")).unwrap();
        assert!(text.starts_with("# my settings\nmodel = \"o3\" # keep me\n"), "{text}");
        assert!(text.contains("[mcp_servers.mine]"), "{text}");
        let opencode: Value =
            serde_json::from_slice(&fs::read(root.join(".config/opencode/opencode.json")).unwrap())
                .unwrap();
        let text = fs::read_to_string(root.join(".config/opencode/opencode.json")).unwrap();
        let at = |key: &str| text.find(&format!("\"{key}\"")).unwrap();
        assert!(
            at("theme") < at("$schema") && at("$schema") < at("mcp"),
            "key order stays: {text}"
        );
        let row = opencode["mcp"]["filesystem-tools"].as_object().unwrap();
        let mut fields: Vec<_> = row.keys().cloned().collect();
        fields.sort();
        assert_eq!(fields, ["command", "environment", "type"]);
        let claude: Value =
            serde_json::from_slice(&fs::read(root.join(".claude.json")).unwrap()).unwrap();
        let mut fields: Vec<_> =
            claude["mcpServers"]["filesystem-tools"].as_object().unwrap().keys().cloned().collect();
        fields.sort();
        assert_eq!(fields, ["args", "command", "env"]);

        remove(&request, Some(root)).unwrap();
        assert_eq!(
            fs::read_to_string(root.join(".codex/config.toml"))
                .unwrap()
                .contains("filesystem-tools"),
            false
        );
        assert!(
            fs::read_to_string(root.join(".codex/config.toml"))
                .unwrap()
                .starts_with("# my settings")
        );
        let opencode: Value =
            serde_json::from_slice(&fs::read(root.join(".config/opencode/opencode.json")).unwrap())
                .unwrap();
        assert!(opencode["mcp"].get("filesystem-tools").is_none());
        assert_eq!(opencode["theme"], "x");
    }

    #[test]
    fn unmanaged_mcp_entries_are_never_replaced_or_removed() {
        let temp = tempfile::tempdir().unwrap();
        let root = private_test_root(&temp);
        let theirs = r#"{"mcpServers":{"filesystem-tools":{"command":"theirs"}}}"#;
        fs::write(root.join(".claude.json"), theirs).unwrap();
        let request = json!({"id":"filesystem-tools","targets":["claude"]});
        assert!(install(&request, Some(root)).is_err());
        remove(&request, Some(root)).unwrap();
        assert_eq!(fs::read_to_string(root.join(".claude.json")).unwrap(), theirs);
    }

    #[test]
    fn plugin_can_be_updated_with_existing_manifest_directory() {
        let temp = tempfile::tempdir().unwrap();
        let root = private_test_root(&temp);
        let request = json!({"id":"review-kit","targets":["claude"]});
        install(&request, Some(root)).unwrap();
        install(&request, Some(root)).unwrap();
        remove(&request, Some(root)).unwrap();
        assert!(!root.join(".claude/plugins/review-kit").exists());
    }

    #[cfg(unix)]
    #[test]
    fn symlinked_targets_and_ancestors_are_never_mutated() {
        use std::os::unix::fs::symlink;
        for relative in [".claude/skills/terminal-workflows", ".claude/skills", ".claude"] {
            let temp = tempfile::tempdir().unwrap();
            let root = private_test_root(&temp);
            let request = json!({"id":"terminal-workflows","targets":["claude"]});
            install(&request, Some(root)).unwrap();
            let path = root.join(relative);
            let outside = root.join("saved");
            fs::rename(&path, &outside).unwrap();
            symlink(&outside, &path).unwrap();
            let original =
                fs::read(root.join(".claude/skills/terminal-workflows/SKILL.md")).unwrap();
            assert!(install(&request, Some(root)).is_err(), "{relative}");
            assert!(remove(&request, Some(root)).is_err(), "{relative}");
            assert_eq!(
                fs::read(root.join(".claude/skills/terminal-workflows/SKILL.md")).unwrap(),
                original
            );
        }
    }
}
