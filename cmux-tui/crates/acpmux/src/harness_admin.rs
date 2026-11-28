//! Adding and removing your own harness (BRING-YOUR-OWN-HARNESS H2; Lawrence
//! 2026-10-08: "ensure people are able to add their own ACP stuff, via UI,
//! cli, mcp, cmd shift p"). One implementation behind every entry point: the
//! daemon methods `_acpmux/harness/add|remove|restore|doctor` and
//! `_acpmux/registry` (which the app's Settings, palette and MCP tools call)
//! and the CLI (`cmux harness add|remove|restore|doctor|registry`).
//!
//! - **add** writes `<user harness folder>/<id>.toml` from a command (with
//!   args, a display name and env), a shipped example, or an ACP Registry
//!   agent, and checks that it loads. A literal value under a secret-looking
//!   env key is refused before anything is written (H4): secrets are Keychain
//!   references (`keychain:NAME`) or login-shell copies (`env:VAR`).
//! - **remove** moves a user profile file into `<acpmux home>/harness-backups`
//!   (RECOVERABLE-BY-DEFAULT); managed (company), cmux.json, discovered and
//!   folder profiles are not removable here.
//! - **restore** moves a backup back, by its name only.
//!
//! The caller reloads the catalog afterwards (the daemon announces
//! `_acpmux/harnesses_changed`; the CLI asks a running daemon to reload).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{Value, json};

use crate::cli::harness::{self, AddRequest, DoctorReport, StepStatus};
use crate::config::profiles::{self, ProfileSources};
use crate::config::{Config, ProfileSource};
use crate::registry::{self, Launch, Registry};

/// Why an operation was refused. `reason()` is the stable code the daemon
/// puts in an error's `data.reason`.
#[derive(Debug)]
pub enum AdminError {
    /// A profile file with this id exists (add without replace, restore).
    Exists(String),
    /// The id names a harness this operation may not remove.
    NotRemovable(String),
    /// A literal value under a secret-looking env key.
    SecretInline(String),
    /// No such harness, example, registry agent or backup.
    NotFound(String),
    /// Bad parameters.
    Invalid(String),
    /// Disk or registry trouble.
    Failed(String),
}

impl AdminError {
    pub fn reason(&self) -> Option<&'static str> {
        match self {
            AdminError::Exists(_) => Some("harness.exists"),
            AdminError::NotRemovable(_) => Some("harness.not_removable"),
            AdminError::SecretInline(_) => Some("harness.secret_inline"),
            AdminError::NotFound(_) => Some("harness.not_found"),
            AdminError::Invalid(_) | AdminError::Failed(_) => None,
        }
    }

    pub fn message(&self) -> &str {
        match self {
            AdminError::Exists(m)
            | AdminError::NotRemovable(m)
            | AdminError::SecretInline(m)
            | AdminError::NotFound(m)
            | AdminError::Invalid(m)
            | AdminError::Failed(m) => m,
        }
    }
}

impl std::fmt::Display for AdminError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.message())
    }
}

impl std::error::Error for AdminError {}

fn failed(e: impl std::fmt::Display) -> AdminError {
    AdminError::Failed(e.to_string())
}

/// What to add. Exactly one of `command`, `registry` and `example`.
#[derive(Debug, Default, Clone)]
pub struct AddParams {
    pub id: Option<String>,
    pub display_name: Option<String>,
    pub command: Option<String>,
    pub args: Vec<String>,
    /// "acp" (default) or "terminal".
    pub protocol: Option<String>,
    pub registry: Option<String>,
    pub example: Option<String>,
    /// KEY -> a plain non-secret value, `keychain:NAME` or `env:VAR`.
    pub env: BTreeMap<String, String>,
    pub replace: bool,
}

impl AddParams {
    /// The daemon's `_acpmux/harness/add` params.
    pub fn from_json(params: &Value) -> Result<Self, AdminError> {
        let text = |key: &str| -> Result<Option<String>, AdminError> {
            match params.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.trim().is_empty() => Ok(None),
                Some(Value::String(s)) => Ok(Some(s.trim().to_owned())),
                Some(_) => Err(AdminError::Invalid(format!("{key} must be a string"))),
            }
        };
        let args = match params.get("args") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items
                .iter()
                .map(|a| {
                    a.as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| AdminError::Invalid("args must be strings".into()))
                })
                .collect::<Result<_, _>>()?,
            Some(_) => return Err(AdminError::Invalid("args must be an array of strings".into())),
        };
        let env = match params.get("env") {
            None | Some(Value::Null) => BTreeMap::new(),
            Some(Value::Object(map)) => map
                .iter()
                .map(|(k, v)| {
                    v.as_str()
                        .map(|v| (k.clone(), v.to_owned()))
                        .ok_or_else(|| AdminError::Invalid(format!("env {k} must be a string")))
                })
                .collect::<Result<_, _>>()?,
            Some(_) => return Err(AdminError::Invalid("env must be an object".into())),
        };
        Ok(Self {
            id: text("id")?,
            display_name: text("displayName")?,
            command: text("command")?,
            args,
            protocol: text("protocol")?,
            registry: text("registry")?,
            example: text("example")?,
            env,
            replace: params.get("replace").and_then(Value::as_bool).unwrap_or(false),
        })
    }
}

#[derive(Debug, Serialize)]
pub struct Added {
    pub id: String,
    pub path: PathBuf,
    /// Every problem the written file has (never env values).
    pub diagnostics: Vec<String>,
}

fn toml_string(s: &str) -> String {
    // A JSON string is a valid TOML basic string.
    serde_json::to_string(s).unwrap_or_else(|_| "\"\"".into())
}

/// One `[env]` line, or why the value may not be written.
fn env_line(id: &str, key: &str, value: &str) -> Result<String, AdminError> {
    if !profiles::valid_env_key(key) {
        return Err(AdminError::Invalid(format!("env key {key:?} is not a valid variable name")));
    }
    if let Some(item) = value.strip_prefix("keychain:") {
        if item.trim().is_empty() || item.contains('}') {
            return Err(AdminError::Invalid(format!("env {key}: give a Keychain item name")));
        }
        return Ok(format!("{key} = {{ keychain = {} }}", toml_string(item.trim())));
    }
    if let Some(var) = value.strip_prefix("env:") {
        if !profiles::valid_env_key(var.trim()) {
            return Err(AdminError::Invalid(format!("env {key}: {var:?} is not a variable name")));
        }
        return Ok(format!("{key} = {{ env = {} }}", toml_string(var.trim())));
    }
    if profiles::secret_looking(key) && !value.is_empty() {
        return Err(AdminError::SecretInline(format!(
            "env {key} looks like a secret: store it with `cmux harness secret set {id} {key}` and pass \"keychain:cmux-harness/{id}/{key}\""
        )));
    }
    Ok(format!("{key} = {}", toml_string(value)))
}

/// A profile file for a program: what `add` writes for `command`.
fn command_profile(
    id: &str,
    p: &AddParams,
    command: &str,
    protocol: &str,
) -> Result<String, AdminError> {
    let name = p.display_name.clone().unwrap_or_else(|| default_name(id));
    let mut out = format!(
        "# cmux harness profile. Guide: docs/add-your-harness.md\n\
         # Check it with: cmux harness doctor {id}\n\
         schema = 1\nid = {}\nname = {}\nprotocol = {}\ncommand = {}\nargs = [{}]\n",
        toml_string(id),
        toml_string(&name),
        toml_string(protocol),
        toml_string(command),
        p.args.iter().map(|a| toml_string(a)).collect::<Vec<_>>().join(", "),
    );
    if !p.env.is_empty() {
        out.push_str("\n[env]\n");
        for (k, v) in &p.env {
            out.push_str(&env_line(id, k, v)?);
            out.push('\n');
        }
    }
    Ok(out)
}

fn default_name(id: &str) -> String {
    let mut name: Vec<char> = id.replace('-', " ").chars().collect();
    if let Some(first) = name.first_mut() {
        *first = first.to_ascii_uppercase();
    }
    name.into_iter().collect()
}

/// `text` with its top-level `name = …` line set to `name`.
fn with_name(text: &str, name: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut done = false;
    for line in text.lines() {
        if !done && line.starts_with("name = ") {
            out.push_str(&format!("name = {}", toml_string(name)));
            done = true;
        } else {
            out.push_str(line);
        }
        out.push('\n');
    }
    out
}

fn diagnostics_text(text: &str, path: &Path, id: &str) -> Vec<String> {
    let found = match profiles::parse_profile_toml(text, path, Some(id), ProfileSource::UserFile) {
        Ok((_, _, _, warnings)) => warnings,
        Err(errors) => errors,
    };
    found
        .iter()
        .map(|d| match &d.fix {
            Some(fix) => format!("{} (fix: {fix})", d.message),
            None => d.message.clone(),
        })
        .collect()
}

fn user_dir(sources: &ProfileSources) -> Result<PathBuf, AdminError> {
    sources
        .user_dir
        .clone()
        .ok_or_else(|| AdminError::Failed("no harness folder: set HOME or XDG_CONFIG_HOME".into()))
}

#[cfg(unix)]
fn ensure_dir(dir: &Path) -> Result<(), AdminError> {
    use std::os::unix::fs::DirBuilderExt;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir).map_err(failed)
}
/// Windows: an owner-only folder when made here (`owner_only.rs`).
#[cfg(windows)]
fn ensure_dir(dir: &Path) -> Result<(), AdminError> {
    crate::owner_only::create_dir_all(dir).map_err(failed)
}

/// Writes the profile `p` asks for. `registry` is the ACP Registry to use for
/// `p.registry` (the caller loads it; `None` refuses a registry add).
pub fn add(
    p: &AddParams,
    sources: &ProfileSources,
    registry: Option<&Registry>,
    which: &dyn Fn(&str) -> Option<String>,
) -> Result<Added, AdminError> {
    let kinds = [p.command.is_some(), p.registry.is_some(), p.example.is_some()];
    if kinds.iter().filter(|k| **k).count() != 1 {
        return Err(AdminError::Invalid(
            "give exactly one of command, registry and example".into(),
        ));
    }
    let protocol = p.protocol.clone().unwrap_or_else(|| "acp".into());
    if !matches!(protocol.as_str(), "acp" | "terminal") {
        return Err(AdminError::Invalid(format!(
            "protocol must be acp or terminal, got {protocol:?}"
        )));
    }
    if p.command.is_none() && (!p.args.is_empty() || !p.env.is_empty()) {
        return Err(AdminError::Invalid(
            "args and env go with command; edit an example or registry profile after adding it"
                .into(),
        ));
    }
    let dir = user_dir(sources)?;
    if let Some(rid) = &p.registry {
        let reg =
            registry.ok_or_else(|| AdminError::Failed("the ACP Registry is not loaded".into()))?;
        let agent = reg
            .agent(rid)
            .ok_or_else(|| AdminError::NotFound(format!("no ACP Registry agent {rid:?}")))?;
        let id = registry::harness_id(&agent.id).ok_or_else(|| {
            AdminError::Invalid(format!("registry id {rid:?} does not make a harness id"))
        })?;
        if p.id.as_deref().is_some_and(|given| given != id) {
            return Err(AdminError::Invalid(format!(
                "a registry agent keeps its harness id {id:?}; leave id out"
            )));
        }
        let path = dir.join(format!("{id}.toml"));
        if path.exists() && !p.replace {
            return Err(AdminError::Exists(format!("{} exists", path.display())));
        }
        let (id, path) = crate::cli::harness_registry::add(reg, rid, p.replace, sources, which)
            .map_err(|e| AdminError::Invalid(format!("{e:#}")))?;
        if let Some(name) = &p.display_name {
            let text = std::fs::read_to_string(&path).map_err(failed)?;
            crate::config::write_atomic(&path, with_name(&text, name).as_bytes())
                .map_err(failed)?;
        }
        let text = std::fs::read_to_string(&path).map_err(failed)?;
        return Ok(Added { diagnostics: diagnostics_text(&text, &path, &id), id, path });
    }
    if let Some(example) = &p.example {
        let id = p.id.clone();
        let req = AddRequest {
            id,
            command: None,
            protocol,
            example: Some(example.clone()),
            force: p.replace,
        };
        let candidate = req.id.clone().or_else(|| harness::example_id(example));
        if let Some(id) = &candidate
            && dir.join(format!("{id}.toml")).exists()
            && !p.replace
        {
            return Err(AdminError::Exists(format!(
                "{} exists",
                dir.join(format!("{id}.toml")).display()
            )));
        }
        let added =
            harness::add(&req, sources).map_err(|e| AdminError::Invalid(format!("{e:#}")))?;
        if let Some(name) = &p.display_name {
            let text = std::fs::read_to_string(&added.path).map_err(failed)?;
            crate::config::write_atomic(&added.path, with_name(&text, name).as_bytes())
                .map_err(failed)?;
        }
        let text = std::fs::read_to_string(&added.path).map_err(failed)?;
        return Ok(Added {
            diagnostics: diagnostics_text(&text, &added.path, &added.id),
            id: added.id,
            path: added.path,
        });
    }
    let command = p.command.clone().unwrap_or_default();
    let stem = Path::new(&command)
        .file_name()
        .map(|f| f.to_string_lossy().to_ascii_lowercase())
        .unwrap_or_default();
    let id = p.id.clone().unwrap_or(stem);
    if !profiles::valid_id(&id) {
        return Err(AdminError::Invalid(format!(
            "id {id:?} must be 1-40 lowercase letters, digits or '-'"
        )));
    }
    let text = command_profile(&id, p, &command, &protocol)?;
    let path = dir.join(format!("{id}.toml"));
    if path.exists() && !p.replace {
        return Err(AdminError::Exists(format!(
            "{} exists; pass replace to write it again",
            path.display()
        )));
    }
    ensure_dir(&dir)?;
    crate::config::write_atomic(&path, text.as_bytes()).map_err(failed)?;
    Ok(Added { diagnostics: diagnostics_text(&text, &path, &id), id, path })
}

#[derive(Debug, Serialize)]
pub struct Removed {
    pub id: String,
    /// The backup's name, for `restore`.
    pub backup: String,
}

/// The folder backups go to.
pub fn backup_dir(acpmux_home: &Path) -> PathBuf {
    acpmux_home.join("harness-backups")
}

fn unix_millis() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

/// Moves `from` to `to`; across file systems, copies then deletes.
fn move_file(from: &Path, to: &Path) -> Result<(), AdminError> {
    if std::fs::rename(from, to).is_ok() {
        return Ok(());
    }
    std::fs::copy(from, to).map_err(failed)?;
    std::fs::remove_file(from).map_err(failed)
}

/// Moves the user profile file of `id` into the backups. `cfg` says where
/// other harnesses of that id come from, to refuse them by name.
pub fn remove(
    id: &str,
    cfg: &Config,
    sources: &ProfileSources,
    acpmux_home: &Path,
) -> Result<Removed, AdminError> {
    if !profiles::valid_id(id) {
        return Err(AdminError::Invalid(format!("{id:?} is not a harness id")));
    }
    let path = user_dir(sources)?.join(format!("{id}.toml"));
    if !path.is_file() {
        if cfg.harnesses.contains_key(id) {
            let from = match cfg.profile_meta.get(id).map(|m| m.source) {
                Some(ProfileSource::Managed) => "your company's managed config",
                Some(ProfileSource::CmuxJson) => "cmux.json (agents.harnesses)",
                Some(ProfileSource::UserFile) => "a profile file outside your harness folder",
                None => "acpmux itself (a built-in or a program on PATH)",
            };
            return Err(AdminError::NotRemovable(format!(
                "{id} comes from {from}; only profiles in your harness folder can be removed here"
            )));
        }
        return Err(AdminError::NotFound(format!(
            "no harness profile {id} in your harness folder"
        )));
    }
    let dir = backup_dir(acpmux_home);
    ensure_dir(&dir)?;
    let backup = format!("{id}-{}.toml", unix_millis());
    move_file(&path, &dir.join(&backup))?;
    Ok(Removed { id: id.to_owned(), backup })
}

#[derive(Debug, Serialize)]
pub struct Restored {
    pub id: String,
    pub path: PathBuf,
}

/// Moves backup `name` (as `remove` named it) back into the user folder.
pub fn restore(
    name: &str,
    sources: &ProfileSources,
    acpmux_home: &Path,
) -> Result<Restored, AdminError> {
    let valid = name.ends_with(".toml")
        && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '.' | '_'));
    if !valid {
        return Err(AdminError::Invalid(format!("{name:?} is not a backup name")));
    }
    let from = backup_dir(acpmux_home).join(name);
    if !from.is_file() {
        return Err(AdminError::NotFound(format!("no backup {name}")));
    }
    let id = name
        .strip_suffix(".toml")
        .and_then(|stem| stem.rsplit_once('-'))
        .map(|(id, _)| id.to_owned())
        .filter(|id| profiles::valid_id(id))
        .ok_or_else(|| AdminError::Invalid(format!("{name:?} is not a backup name")))?;
    let dir = user_dir(sources)?;
    let to = dir.join(format!("{id}.toml"));
    if to.exists() {
        return Err(AdminError::Exists(format!(
            "{} exists; remove or rename it first",
            to.display()
        )));
    }
    ensure_dir(&dir)?;
    move_file(&from, &to)?;
    Ok(Restored { id, path: to })
}

/// The daemon's `_acpmux/harness/doctor` answer: each step as `{name, ok,
/// detail, fix?}`. A warning or a skipped step is ok; never an env value.
pub fn doctor_value(report: &DoctorReport) -> Value {
    let steps: Vec<Value> = report
        .steps
        .iter()
        .map(|s| {
            let mut step = json!({
                "name": s.step,
                "ok": s.status != StepStatus::Fail,
                "status": s.status,
                "detail": s.detail,
            });
            if let Some(fix) = &s.fix {
                step["fix"] = json!(fix);
            }
            step
        })
        .collect();
    json!({"id": report.id, "ok": report.ok, "steps": steps})
}

/// The daemon's `_acpmux/registry` answer: every agent and how it can start here.
pub fn registry_value(reg: &Registry, which: &dyn Fn(&str) -> Option<String>) -> Value {
    let platform = registry::platform();
    let agents: Vec<Value> = reg
        .agents
        .iter()
        .map(|agent| {
            let launch = agent.launch(platform, which);
            let how = match launch {
                Launch::Installed { .. } => "path",
                Launch::Npx { .. } => "npx",
                Launch::Uvx { .. } => "uvx",
                Launch::Download { .. } | Launch::Unavailable => "none",
            };
            let mut row = json!({
                "id": agent.id,
                "name": agent.name,
                "version": agent.version,
                "launch": how,
                "installed": matches!(launch, Launch::Installed { .. }),
            });
            if let Some(d) = &agent.description {
                row["description"] = json!(d);
            }
            if let Some(w) = &agent.website {
                row["website"] = json!(w);
            }
            if let Some(h) = registry::harness_id(&agent.id) {
                row["harnessId"] = json!(h);
            }
            row
        })
        .collect();
    json!({"agents": agents})
}
