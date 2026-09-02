use std::collections::HashSet;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::config::{self, AgentPluginConfig, SidebarPluginConfig};

// A manifest is supplied by a repository that the user asks cmux to install.
// Bound its parser input and argv shape before any build or plugin process is
// started, so a malformed package cannot consume unbounded host resources.
const MAX_PLUGIN_MANIFEST_BYTES: usize = 256 * 1024;
const MAX_PLUGIN_NAME_BYTES: usize = 64;
const MAX_PLUGIN_COMMAND_ARGS: usize = 256;
const MAX_PLUGIN_COMMAND_ARG_BYTES: usize = 4096;
/// Bound the number of filesystem entries inspected by one plugin-manager
/// operation. The registry is user-controlled, so a malicious or stale data
/// directory must not turn `list` or selector resolution into an unbounded
/// scan and allocation.
const MAX_INSTALLED_PLUGIN_ENTRIES: usize = 256;
const ARTIFACT_HASH_BUFFER_BYTES: usize = 64 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum PluginKind {
    Sidebar,
    Agent,
}

impl PluginKind {
    fn manifest_kind(self) -> &'static str {
        match self {
            Self::Sidebar => "sidebar",
            Self::Agent => "agent",
        }
    }

    fn command_prefix(self) -> &'static str {
        match self {
            Self::Sidebar => "cmux sidebar plugin",
            Self::Agent => "cmux agent plugin",
        }
    }

    fn id_prefix(self) -> &'static str {
        match self {
            Self::Sidebar => "sidebar_plugin_",
            Self::Agent => "agent_plugin_",
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct CliOptions {
    pub name: Option<String>,
    pub force: bool,
    pub builtin: bool,
}

#[derive(Debug)]
pub(crate) enum ManagerError {
    Usage(String),
    Validation { field: Option<&'static str>, reason: String },
    Failure(anyhow::Error),
}

impl ManagerError {
    pub(crate) fn exit_code(&self) -> i32 {
        match self {
            Self::Usage(_) => 2,
            Self::Validation { .. } | Self::Failure(_) => 1,
        }
    }

    pub(crate) fn code(&self) -> &'static str {
        match self {
            Self::Usage(_) | Self::Validation { .. } => "validation.invalid",
            Self::Failure(_) => "local.io",
        }
    }

    pub(crate) fn details(&self) -> Value {
        match self {
            Self::Usage(reason) => json!({"reason": reason}),
            Self::Validation { field, reason } => {
                let mut details = json!({"reason": reason});
                if let Some(field) = field {
                    details["field"] = Value::String((*field).to_string());
                }
                details
            }
            Self::Failure(error) => json!({"reason": error.to_string()}),
        }
    }

    fn validation(field: Option<&'static str>, reason: impl Into<String>) -> Self {
        Self::Validation { field, reason: reason.into() }
    }
}

impl std::fmt::Display for ManagerError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Usage(message) => formatter.write_str(message),
            Self::Validation { reason, .. } => formatter.write_str(reason),
            Self::Failure(error) => std::fmt::Display::fmt(error, formatter),
        }
    }
}

impl From<anyhow::Error> for ManagerError {
    fn from(error: anyhow::Error) -> Self {
        Self::Failure(error)
    }
}

impl From<std::io::Error> for ManagerError {
    fn from(error: std::io::Error) -> Self {
        Self::Failure(error.into())
    }
}

impl From<serde_json::Error> for ManagerError {
    fn from(error: serde_json::Error) -> Self {
        Self::Failure(error.into())
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct PluginManifest {
    plugin: ManifestPlugin,
    run: ManifestRun,
    build: Option<ManifestBuild>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestPlugin {
    name: String,
    kind: String,
    version: Option<String>,
    description: Option<String>,
    platforms: Option<Vec<String>>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestRun {
    command: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestBuild {
    command: Vec<String>,
}

#[derive(Debug, Clone)]
struct InstalledPlugin {
    id: String,
    name: String,
    manifest: PluginManifest,
    dir: PathBuf,
    selected: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct PluginRegistryMetadata {
    id: String,
}

pub(crate) fn execute(
    positionals: &[String],
    options: CliOptions,
    kind: PluginKind,
) -> Result<Value, ManagerError> {
    match positionals.first().map(String::as_str) {
        Some("install") => install_command(positionals, &options, kind),
        Some("list") => list_command(positionals, &options, kind),
        Some("use") => use_command(positionals, &options, kind),
        Some("update") => update_command(positionals, &options, kind),
        Some("remove") => remove_command(positionals, &options, kind),
        Some(other) => Err(ManagerError::Usage(format!("unknown plugin subcommand {other:?}"))),
        None => Err(ManagerError::Usage("plugin subcommand is required".to_string())),
    }
}

fn install_command(
    positionals: &[String],
    options: &CliOptions,
    kind: PluginKind,
) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, true, true, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage(format!(
            "usage: {} install <git-url> [--name <name>] [--force]",
            kind.command_prefix()
        )));
    }
    if positionals[1].is_empty() {
        return Err(ManagerError::validation(Some("git_url"), "plugin git URL must not be empty"));
    }
    validate_git_source(&positionals[1])
        .map_err(|error| ManagerError::validation(Some("git_url"), error.to_string()))?;
    let root = install_root(kind)?;
    fs::create_dir_all(&root)?;
    let temp_dir = root.join(format!(".install-{}-{}", std::process::id(), now_nanos()));
    // Keep the user-supplied source after `--` so a value beginning with `-`
    // cannot become a git option. The destination remains a separate final
    // argument handled by `run_git`.
    let clone_result =
        run_git(["clone", "--depth", "1", "--", positionals[1].as_str()], Some(&temp_dir), None);
    if let Err(error) = clone_result {
        let _ = fs::remove_dir_all(&temp_dir);
        return Err(error.into());
    }

    let result = (|| -> Result<Value, ManagerError> {
        let manifest = read_manifest(&temp_dir, kind)
            .map_err(|error| ManagerError::validation(None, error.to_string()))?;
        ensure_manifest_platform_supported(&manifest)
            .map_err(|error| ManagerError::validation(Some("platforms"), error.to_string()))?;
        let name = installed_name(&manifest, options.name.as_deref())
            .map_err(|error| ManagerError::validation(Some("name"), error.to_string()))?;
        let target = root.join(&name);
        if path_exists(&target)? && !options.force {
            return Err(ManagerError::validation(
                Some("name"),
                format!(
                    "plugin {name:?} is already installed at {}; use --force to replace it",
                    target.display()
                ),
            ));
        }
        run_build_if_needed(&manifest, &temp_dir)?;
        let command = resolved_run_command(&manifest, &temp_dir)?;
        verify_executable(&command[0])?;
        let metadata = PluginRegistryMetadata { id: random_plugin_id_for(kind)? };
        let id = metadata.id.clone();
        let selection = selected_plugin_config(kind)?;
        let previous_id = path_exists(&target)?
            .then(|| read_registry_metadata(&root, &name, kind).ok())
            .flatten()
            .map(|metadata| metadata.id);
        let selected = plugin_is_selected(
            selection.as_ref(),
            previous_id.as_deref().unwrap_or(&id),
            &manifest,
            &target,
        );
        let transaction =
            replace_plugin_install(&root, &name, &temp_dir, &target, &metadata, kind)?;
        if selected {
            let config_result = (|| -> Result<(), ManagerError> {
                let command = resolved_run_command(&manifest, &target)?;
                let cwd = canonical_path(&target)?;
                let revision = artifact_revision(&manifest, &target, &command);
                persist_plugin(kind, &id, &command, Some(cwd.display().to_string()), Some(revision))
            })();
            if let Err(error) = config_result {
                return match transaction.rollback() {
                    Ok(()) => Err(error),
                    Err(rollback_error) => Err(ManagerError::Failure(anyhow::anyhow!(
                        "plugin configuration failed: {error}; plugin rollback failed: {rollback_error}"
                    ))),
                };
            }
            transaction.commit();
        } else {
            transaction.commit();
        }
        Ok(json!({"plugin": plugin_json(&InstalledPlugin {
            id,
            name,
            manifest,
            dir: target,
            selected,
        })}))
    })();
    if result.is_err() && temp_dir.exists() {
        let _ = fs::remove_dir_all(&temp_dir);
    }
    result
}

fn list_command(
    positionals: &[String],
    options: &CliOptions,
    kind: PluginKind,
) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 1 {
        return Err(ManagerError::Usage(format!("usage: {} list", kind.command_prefix())));
    }
    let plugins = installed_plugins(kind)?;
    Ok(Value::Array(plugins.iter().map(plugin_json).collect()))
}

fn use_command(
    positionals: &[String],
    options: &CliOptions,
    kind: PluginKind,
) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, true)?;
    match (positionals.len(), options.builtin) {
        (1, true) => return write_builtin_config(options, kind),
        (2, false) => {}
        _ => {
            return Err(ManagerError::Usage(format!(
                "usage: {} use <name-or-id> | {} use --builtin",
                kind.command_prefix(),
                kind.command_prefix()
            )));
        }
    }
    let mut plugin = resolve_installed_plugin(&positionals[1], kind)?;
    ensure_manifest_platform_supported(&plugin.manifest)
        .map_err(|error| ManagerError::validation(Some("platforms"), error.to_string()))?;
    let command = resolved_run_command(&plugin.manifest, &plugin.dir)?;
    verify_executable(&command[0])?;
    let cwd = canonical_path(&plugin.dir)?;
    let plugin_id = plugin.id.clone();
    let revision = artifact_revision(&plugin.manifest, &plugin.dir, &command);
    persist_plugin(kind, &plugin_id, &command, Some(cwd.display().to_string()), Some(revision))?;
    plugin.selected = true;
    Ok(json!({"plugin": plugin_json(&plugin)}))
}

fn update_command(
    positionals: &[String],
    options: &CliOptions,
    kind: PluginKind,
) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage(format!(
            "usage: {} update <name-or-id>",
            kind.command_prefix()
        )));
    }
    let mut plugin = resolve_installed_plugin(&positionals[1], kind)?;
    let source = git_text(&plugin.dir, ["remote", "get-url", "origin"]).ok_or_else(|| {
        ManagerError::validation(
            Some("plugin"),
            format!("plugin {} has no readable origin remote", plugin.name),
        )
    })?;
    validate_git_source(&source)
        .map_err(|error| ManagerError::validation(Some("plugin"), error.to_string()))?;

    // Build and validate a fresh clone before touching the active install.
    // Updating in place would let a failed pull or build leave the selected
    // plugin half-updated, which is unsafe for a daemon-owned process.
    let root = install_root(kind)?;
    let temp_dir = root.join(format!(".update-{}-{}", std::process::id(), now_nanos()));
    let clone_result =
        run_git(["clone", "--depth", "1", "--", source.as_str()], Some(&temp_dir), None);
    if let Err(error) = clone_result {
        let _ = fs::remove_dir_all(&temp_dir);
        return Err(error.into());
    }

    let result = (|| -> Result<Value, ManagerError> {
        let manifest = read_manifest(&temp_dir, kind)
            .map_err(|error| ManagerError::validation(None, error.to_string()))?;
        ensure_manifest_platform_supported(&manifest)
            .map_err(|error| ManagerError::validation(Some("platforms"), error.to_string()))?;
        let name = installed_name(&manifest, None)
            .map_err(|error| ManagerError::validation(Some("name"), error.to_string()))?;
        if name != plugin.name {
            return Err(ManagerError::validation(
                Some("name"),
                format!(
                    "updated plugin changed its manifest name from {:?} to {:?}; reinstall it to rename",
                    plugin.name, name
                ),
            ));
        }
        run_build_if_needed(&manifest, &temp_dir)?;
        let command = resolved_run_command(&manifest, &temp_dir)?;
        verify_executable(&command[0])?;
        let metadata = PluginRegistryMetadata { id: plugin.id.clone() };
        let transaction =
            replace_plugin_install(&root, &plugin.name, &temp_dir, &plugin.dir, &metadata, kind)?;
        plugin.manifest = manifest;
        if plugin.selected {
            let config_result = (|| -> Result<(), ManagerError> {
                let command = resolved_run_command(&plugin.manifest, &plugin.dir)?;
                let cwd = canonical_path(&plugin.dir)?;
                let plugin_id = plugin.id.clone();
                let revision = artifact_revision(&plugin.manifest, &plugin.dir, &command);
                persist_plugin(
                    kind,
                    &plugin_id,
                    &command,
                    Some(cwd.display().to_string()),
                    Some(revision),
                )
            })();
            if let Err(error) = config_result {
                return match transaction.rollback() {
                    Ok(()) => Err(error),
                    Err(rollback_error) => Err(ManagerError::Failure(anyhow::anyhow!(
                        "plugin configuration failed: {error}; plugin rollback failed: {rollback_error}"
                    ))),
                };
            }
        }
        transaction.commit();
        Ok(json!({"plugin": plugin_json(&plugin)}))
    })();
    if result.is_err() && temp_dir.exists() {
        let _ = fs::remove_dir_all(&temp_dir);
    }
    result
}

fn remove_command(
    positionals: &[String],
    options: &CliOptions,
    kind: PluginKind,
) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage(format!(
            "usage: {} remove <name-or-id>",
            kind.command_prefix()
        )));
    }
    let installed = resolve_installed_plugin(&positionals[1], kind)?;
    let mut plugin = plugin_json(&installed);
    if installed.selected {
        persist_plugin_none(kind)?;
    }
    fs::remove_dir_all(&installed.dir)?;
    remove_registry_metadata(&install_root(kind)?, &installed.name, kind)?;
    plugin["active"] = Value::Bool(false);
    plugin["enabled"] = Value::Bool(false);
    Ok(json!({"plugin": plugin}))
}

fn write_builtin_config(_options: &CliOptions, kind: PluginKind) -> Result<Value, ManagerError> {
    persist_plugin_none(kind)?;
    let plugins = installed_plugins(kind)?;
    Ok(json!({"plugins": plugins.iter().map(plugin_json).collect::<Vec<_>>()}))
}

fn persist_plugin(
    kind: PluginKind,
    id: &str,
    command: &[String],
    cwd: Option<String>,
    revision: Option<String>,
) -> Result<(), ManagerError> {
    let outcome = match kind {
        PluginKind::Sidebar => config::write_sidebar_plugin(Some(&SidebarPluginConfig {
            command: command.to_vec(),
            cwd,
        }))?,
        PluginKind::Agent => config::write_agent_plugin(Some(&AgentPluginConfig {
            id: id.to_string(),
            command: command.to_vec(),
            cwd,
            revision,
        }))?,
    };
    if let Some(error) = outcome.into_unsynced_error() {
        crate::client_log::stderr_log!(
            "config",
            "{}",
            crate::localization::catalog().config.write_durability_warning(&error.to_string())
        );
    }
    Ok(())
}

/// Return a content-derived revision for the selected artifact. A source
/// checkout can rebuild to the same path, so a Git commit alone does not
/// prove that the process changed. Hashing the executable also handles local
/// rebuilds and gives the core supervisor a deterministic restart fence.
fn artifact_revision(manifest: &PluginManifest, dir: &Path, command: &[String]) -> String {
    let mut digest = Sha256::new();
    if let Some(commit) = git_text(dir, ["rev-parse", "HEAD"]) {
        digest.update(b"git\0");
        digest.update(commit.as_bytes());
    }
    if let Some(version) = &manifest.plugin.version {
        digest.update(b"version\0");
        digest.update(version.as_bytes());
    }
    for argument in command {
        digest.update(b"arg\0");
        digest.update(argument.as_bytes());
    }
    let mut binary_digest = digest.clone();
    binary_digest.update(b"binary\0");
    let binary_hashed = fs::File::open(&command[0])
        .and_then(|file| update_file_digest(file, &mut binary_digest))
        .is_ok();
    if binary_hashed {
        digest = binary_digest;
    } else if let Ok(metadata) = fs::metadata(&command[0]) {
        digest.update(b"metadata\0");
        digest.update(metadata.len().to_le_bytes());
        if let Ok(modified) = metadata.modified()
            && let Ok(duration) = modified.duration_since(UNIX_EPOCH)
        {
            digest.update(duration.as_nanos().to_le_bytes());
        }
    }
    format!("sha256-{:x}", digest.finalize())
}

/// Feed a regular file into a digest without allocating an amount of memory
/// proportional to the executable size. The caller can discard the digest
/// when a read fails and retain the metadata fallback.
fn update_file_digest(mut file: fs::File, digest: &mut Sha256) -> std::io::Result<()> {
    let mut buffer = [0_u8; ARTIFACT_HASH_BUFFER_BYTES];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            return Ok(());
        }
        digest.update(&buffer[..count]);
    }
}

fn persist_plugin_none(kind: PluginKind) -> Result<(), ManagerError> {
    let outcome = match kind {
        PluginKind::Sidebar => config::write_sidebar_plugin(None)?,
        PluginKind::Agent => config::write_agent_plugin(None)?,
    };
    if let Some(error) = outcome.into_unsynced_error() {
        crate::client_log::stderr_log!(
            "config",
            "config write was committed but unsynced: {}",
            error
        );
    }
    Ok(())
}

fn reject_plugin_flags(
    options: &CliOptions,
    allow_name: bool,
    allow_force: bool,
    allow_builtin: bool,
) -> Result<(), ManagerError> {
    if !allow_name && options.name.is_some() {
        return Err(ManagerError::Usage("--name is only valid for plugin install".to_string()));
    }
    if !allow_force && options.force {
        return Err(ManagerError::Usage("--force is only valid for plugin install".to_string()));
    }
    if !allow_builtin && options.builtin {
        return Err(ManagerError::Usage("--builtin is only valid for plugin use".to_string()));
    }
    Ok(())
}

fn installed_plugins(kind: PluginKind) -> anyhow::Result<Vec<InstalledPlugin>> {
    let root = install_root(kind)?;
    let selection = selected_plugin_config(kind)?;
    let mut plugins = Vec::new();
    for entry in bounded_plugin_registry_entries(&root)? {
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let dir = entry.path();
        if dir.file_name().and_then(|name| name.to_str()).is_some_and(|name| name.starts_with('.'))
        {
            continue;
        }
        let manifest = read_manifest(&dir, kind)?;
        let name = dir
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| anyhow::anyhow!("plugin directory name is not UTF-8"))?
            .to_string();
        validate_plugin_name(&name)?;
        let metadata = read_registry_metadata(&root, &name, kind)?;
        let selected = plugin_is_selected(selection.as_ref(), &metadata.id, &manifest, &dir);
        plugins.push(InstalledPlugin { id: metadata.id, name, manifest, dir, selected });
    }
    plugins.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(plugins)
}

/// Read at most [`MAX_INSTALLED_PLUGIN_ENTRIES`] entries from an installed
/// plugin root. Count every entry, including hidden transaction leftovers and
/// the registry metadata directory, so an attacker cannot bypass the bound by
/// creating entries the normal list path later ignores.
fn bounded_plugin_registry_entries(root: &Path) -> anyhow::Result<Vec<fs::DirEntry>> {
    let entries = match fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => {
            return Err(anyhow::anyhow!(
                "failed to read plugin registry {}: {error}",
                root.display()
            ));
        }
    };

    let mut bounded = Vec::with_capacity(MAX_INSTALLED_PLUGIN_ENTRIES);
    for (index, entry) in entries.enumerate() {
        if index >= MAX_INSTALLED_PLUGIN_ENTRIES {
            anyhow::bail!(
                "plugin registry {} exceeds the entry limit of {}",
                root.display(),
                MAX_INSTALLED_PLUGIN_ENTRIES
            );
        }
        bounded.push(entry?);
    }
    Ok(bounded)
}

fn resolve_installed_plugin(
    selector: &str,
    kind: PluginKind,
) -> Result<InstalledPlugin, ManagerError> {
    let forced_name = selector.strip_prefix("name:");
    let selector = forced_name.unwrap_or(selector);
    let by_id = forced_name.is_none() && selector.starts_with(kind.id_prefix());
    if by_id {
        validate_plugin_id_for(selector, kind)
            .map_err(|error| ManagerError::validation(Some("plugin"), error.to_string()))?;
    } else {
        validate_plugin_name(selector)
            .map_err(|error| ManagerError::validation(Some("plugin"), error.to_string()))?;
    }
    installed_plugins(kind)?
        .into_iter()
        .find(|plugin| if by_id { plugin.id == selector } else { plugin.name == selector })
        .ok_or_else(|| {
            ManagerError::validation(
                Some("plugin"),
                format!("plugin {selector:?} is not installed"),
            )
        })
}

fn read_manifest(dir: &Path, kind: PluginKind) -> anyhow::Result<PluginManifest> {
    let path = dir.join("cmux-plugin.toml");
    let mut file = fs::File::open(&path)
        .map_err(|err| anyhow::anyhow!("failed to read {}: {err}", path.display()))?;
    let mut text = String::new();
    Read::by_ref(&mut file)
        .take(u64::try_from(MAX_PLUGIN_MANIFEST_BYTES).unwrap_or(u64::MAX).saturating_add(1))
        .read_to_string(&mut text)
        .map_err(|err| anyhow::anyhow!("failed to read {}: {err}", path.display()))?;
    if text.len() > MAX_PLUGIN_MANIFEST_BYTES {
        anyhow::bail!(
            "{} exceeds the {MAX_PLUGIN_MANIFEST_BYTES}-byte manifest limit",
            path.display()
        );
    }
    parse_manifest_for_kind(&text, kind)
}

#[cfg(test)]
fn parse_manifest(text: &str) -> anyhow::Result<PluginManifest> {
    parse_manifest_for_kind(text, PluginKind::Sidebar)
}

fn parse_manifest_for_kind(text: &str, kind: PluginKind) -> anyhow::Result<PluginManifest> {
    let manifest: PluginManifest =
        toml::from_str(text).map_err(|err| anyhow::anyhow!("invalid cmux-plugin.toml: {err}"))?;
    validate_manifest(&manifest, kind)?;
    Ok(manifest)
}

fn validate_manifest(manifest: &PluginManifest, kind: PluginKind) -> anyhow::Result<()> {
    validate_plugin_name(&manifest.plugin.name)?;
    if manifest.plugin.kind != kind.manifest_kind() {
        anyhow::bail!("plugin.kind must be \"{}\"", kind.manifest_kind());
    }
    validate_manifest_command(&manifest.run.command, "run.command")?;
    if let Some(build) = &manifest.build {
        validate_manifest_command(&build.command, "build.command")?;
    }
    if let Some(version) = &manifest.plugin.version {
        validate_manifest_text(version, "plugin.version", 128)?;
    }
    if let Some(description) = &manifest.plugin.description {
        validate_manifest_text(description, "plugin.description", 4096)?;
    }
    validate_manifest_platforms(manifest.plugin.platforms.as_deref())?;
    Ok(())
}

fn validate_manifest_command(command: &[String], field: &str) -> anyhow::Result<()> {
    if command.is_empty() || command[0].trim().is_empty() {
        anyhow::bail!("{field} must not be empty");
    }
    if command.len() > MAX_PLUGIN_COMMAND_ARGS {
        anyhow::bail!(
            "{field} contains {} arguments, max is {MAX_PLUGIN_COMMAND_ARGS}",
            command.len()
        );
    }
    for (index, argument) in command.iter().enumerate() {
        if argument.len() > MAX_PLUGIN_COMMAND_ARG_BYTES {
            anyhow::bail!("{field}[{index}] exceeds the {MAX_PLUGIN_COMMAND_ARG_BYTES}-byte limit");
        }
        if argument.contains('\0') {
            anyhow::bail!("{field}[{index}] must not contain NUL");
        }
    }
    Ok(())
}

fn validate_manifest_text(value: &str, field: &str, max_bytes: usize) -> anyhow::Result<()> {
    if value.trim().is_empty() {
        anyhow::bail!("{field} must not be empty");
    }
    if value.len() > max_bytes {
        anyhow::bail!("{field} exceeds the {max_bytes}-byte limit");
    }
    if value.bytes().any(|byte| byte == 0) {
        anyhow::bail!("{field} must not contain NUL");
    }
    Ok(())
}

fn current_plugin_platform() -> &'static str {
    if cfg!(target_os = "macos") {
        "macos"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(windows) {
        "windows"
    } else {
        "other"
    }
}

fn validate_manifest_platforms(platforms: Option<&[String]>) -> anyhow::Result<()> {
    let Some(platforms) = platforms else { return Ok(()) };
    if platforms.is_empty() {
        anyhow::bail!("plugin.platforms must contain at least one platform");
    }
    let mut seen = HashSet::new();
    for platform in platforms {
        if !matches!(platform.as_str(), "macos" | "linux" | "windows") {
            anyhow::bail!(
                "plugin.platforms contains unsupported platform {platform:?}; use macos, linux, or windows"
            );
        }
        if !seen.insert(platform) {
            anyhow::bail!("plugin.platforms contains duplicate platform {platform:?}");
        }
    }
    Ok(())
}

fn ensure_manifest_platform_supported(manifest: &PluginManifest) -> anyhow::Result<()> {
    if let Some(platforms) = manifest.plugin.platforms.as_deref()
        && !platforms.iter().any(|platform| platform == current_plugin_platform())
    {
        anyhow::bail!(
            "plugin does not support the current platform ({})",
            current_plugin_platform()
        );
    }
    Ok(())
}

fn validate_plugin_name(name: &str) -> anyhow::Result<()> {
    if name.is_empty()
        || name.len() > MAX_PLUGIN_NAME_BYTES
        || !name.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'_'
        })
    {
        anyhow::bail!("plugin name must match [a-z0-9-_]+");
    }
    Ok(())
}

fn validate_git_source(source: &str) -> anyhow::Result<()> {
    if source.is_empty() {
        anyhow::bail!("plugin git URL must not be empty");
    }
    if source.bytes().any(|byte| byte == 0 || byte.is_ascii_control()) {
        anyhow::bail!("plugin git URL must not contain NUL or control characters");
    }

    // Git receives this value as a process argument. Reject URL forms that
    // can carry a password or token so credentials do not enter the process
    // table, shell history, or Git's diagnostic output. SSH user names remain
    // valid because `ssh://git@host/repo` is a normal key-based source.
    if let Some(scheme_end) = source.find("://") {
        let scheme = &source[..scheme_end];
        let authority_start = scheme_end + 3;
        let authority_end = source[authority_start..]
            .find(['/', '?', '#'])
            .map_or(source.len(), |offset| authority_start + offset);
        let authority = &source[authority_start..authority_end];
        let suffix = &source[authority_end..];
        if suffix.contains(['?', '#']) {
            anyhow::bail!("plugin git URL must not contain a query or fragment");
        }
        if let Some((userinfo, _host)) = authority.rsplit_once('@')
            && (scheme.eq_ignore_ascii_case("http")
                || scheme.eq_ignore_ascii_case("https")
                || userinfo.contains([':', '%']))
        {
            anyhow::bail!("plugin git URL must not contain embedded credentials");
        }
    } else if let Some(at) = source.find('@') {
        // Also cover scp-like sources such as `user:password@host:path`.
        // A plain `git@host:path` remains valid.
        let component_start = source[..at].rfind(['/', '\\']).map_or(0, |index| index + 1);
        if source[component_start..at].contains(':') {
            anyhow::bail!("plugin git URL must not contain embedded credentials");
        }
    }
    Ok(())
}

fn installed_name(
    manifest: &PluginManifest,
    override_name: Option<&str>,
) -> anyhow::Result<String> {
    match override_name {
        Some(name) => {
            validate_plugin_name(name)?;
            Ok(name.to_string())
        }
        None => Ok(manifest.plugin.name.clone()),
    }
}

fn run_build_if_needed(manifest: &PluginManifest, dir: &Path) -> anyhow::Result<()> {
    let Some(build) = &manifest.build else { return Ok(()) };
    let status = Command::new(&build.command[0])
        .args(&build.command[1..])
        .current_dir(dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    if !status.success() {
        anyhow::bail!("build command failed with status {status}");
    }
    Ok(())
}

fn resolved_run_command(manifest: &PluginManifest, dir: &Path) -> anyhow::Result<Vec<String>> {
    let mut command = manifest.run.command.clone();
    let first = Path::new(&command[0]);
    if first.is_relative() {
        let canonical_dir = canonical_path(dir)?;
        let resolved = canonical_path(&canonical_dir.join(first))?;
        if resolved.strip_prefix(&canonical_dir).is_err() {
            anyhow::bail!(
                "run.command[0] {} escapes plugin directory {}",
                first.display(),
                canonical_dir.display()
            );
        }
        command[0] = resolved.display().to_string();
    }
    Ok(command)
}

fn verify_executable(path: &str) -> anyhow::Result<()> {
    let path = Path::new(path);
    let metadata = fs::metadata(path).map_err(|err| {
        anyhow::anyhow!("run.command[0] {} is not readable: {err}", path.display())
    })?;
    if !metadata.is_file() {
        anyhow::bail!("run.command[0] {} is not a file", path.display());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if metadata.permissions().mode() & 0o111 == 0 {
            anyhow::bail!("run.command[0] {} is not executable", path.display());
        }
    }
    Ok(())
}

fn run_git<const N: usize>(
    args: [&str; N],
    final_arg_path: Option<&Path>,
    current_dir: Option<&Path>,
) -> anyhow::Result<()> {
    let mut command = Command::new("git");
    command.args(["-c", "protocol.file.allow=always"]).args(args);
    if let Some(path) = final_arg_path {
        command.arg(path);
    }
    if let Some(dir) = current_dir {
        command.current_dir(dir);
    }
    command.stdout(Stdio::null()).stderr(Stdio::null());
    let status = command.status()?;
    if !status.success() {
        anyhow::bail!("git failed with status {status}");
    }
    Ok(())
}

fn install_root(kind: PluginKind) -> anyhow::Result<PathBuf> {
    let root = if let Some(data_home) = non_empty_env_path("XDG_DATA_HOME") {
        data_home.join("cmux").join("mux-plugins")
    } else {
        let home = cmux_tui_core::platform::home_dir()
            .ok_or_else(|| anyhow::anyhow!("could not resolve home directory"))?;
        home.join(".local").join("share").join("cmux").join("mux-plugins")
    };
    Ok(match kind {
        PluginKind::Sidebar => root,
        PluginKind::Agent => root.join("agent"),
    })
}

#[derive(Debug, Default)]
struct SelectedPluginConfig {
    id: Option<String>,
    command: Option<Vec<String>>,
    cwd: Option<PathBuf>,
}

fn selected_plugin_config(kind: PluginKind) -> anyhow::Result<Option<SelectedPluginConfig>> {
    let path = config::config_path()?;
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(anyhow::anyhow!("failed to read {}: {err}", path.display())),
    };
    let value: Value = serde_json::from_str(&text)
        .map_err(|err| anyhow::anyhow!("failed to parse {}: {err}", path.display()))?;
    let section = match kind {
        PluginKind::Sidebar => "sidebar",
        PluginKind::Agent => "agents",
    };
    let Some(plugin) = value.get(section).and_then(|section| section.get("plugin")) else {
        return Ok(None);
    };
    Ok(Some(SelectedPluginConfig {
        id: plugin.get("id").and_then(Value::as_str).map(str::to_owned),
        command: plugin.get("command").and_then(|value| {
            let arguments = value.as_array()?;
            arguments
                .iter()
                .map(Value::as_str)
                .collect::<Option<Vec<_>>>()
                .map(|arguments| arguments.into_iter().map(str::to_owned).collect())
        }),
        cwd: plugin.get("cwd").and_then(Value::as_str).map(PathBuf::from),
    }))
}

fn plugin_is_selected(
    selection: Option<&SelectedPluginConfig>,
    plugin_id: &str,
    manifest: &PluginManifest,
    dir: &Path,
) -> bool {
    let Some(selection) = selection else {
        return false;
    };
    // The opaque registry id is the strongest identity. Path and command
    // checks remain as migration fallbacks for hand-written or pre-id config.
    if selection.id.as_deref() == Some(plugin_id) {
        return true;
    }
    // A command is a stronger migration key than `cwd`: two installations
    // can intentionally share a working directory. Do not mark both active
    // when only their common cwd matches.
    if let Some(selected_command) = selection.command.as_deref() {
        return resolved_run_command(manifest, dir)
            .ok()
            .is_some_and(|expected_command| commands_match(selected_command, &expected_command));
    }
    selection.cwd.as_deref().is_some_and(|cwd| same_path(cwd, dir))
}

fn commands_match(left: &[String], right: &[String]) -> bool {
    left.len() == right.len()
        && left.iter().zip(right).enumerate().all(|(index, (left, right))| {
            index != 0 || same_path(Path::new(left), Path::new(right)) || left == right
        })
        && left.iter().skip(1).eq(right.iter().skip(1))
}

fn plugin_json(plugin: &InstalledPlugin) -> Value {
    let source = git_text(&plugin.dir, ["remote", "get-url", "origin"])
        .map(|source| sanitized_git_source(&source))
        .or_else(|| canonical_path(&plugin.dir).ok().map(|path| path.display().to_string()))
        .unwrap_or_else(|| plugin.dir.display().to_string());
    let revision = git_text(&plugin.dir, ["rev-parse", "HEAD"]);
    let mut extra = serde_json::Map::new();
    extra.insert("dir".into(), Value::String(plugin.dir.display().to_string()));
    if plugin.manifest.plugin.name != plugin.name {
        extra.insert("manifest_name".into(), Value::String(plugin.manifest.plugin.name.clone()));
    }
    if let Some(version) = &plugin.manifest.plugin.version {
        extra.insert("version".into(), Value::String(version.clone()));
    }
    if let Some(description) = &plugin.manifest.plugin.description {
        extra.insert("description".into(), Value::String(description.clone()));
    }
    if let Some(platforms) = &plugin.manifest.plugin.platforms {
        extra.insert("platforms".into(), json!(platforms));
        extra.insert(
            "platform_supported".into(),
            Value::Bool(platforms.iter().any(|platform| platform == current_plugin_platform())),
        );
    }
    let enabled = resolved_run_command(&plugin.manifest, &plugin.dir)
        .and_then(|command| verify_executable(&command[0]))
        .is_ok();
    let mut snapshot = json!({
        "id": &plugin.id,
        "name": &plugin.name,
        "source": source,
        "active": plugin.selected,
        "enabled": enabled,
        "extra": extra,
    });
    if let Some(revision) = revision {
        snapshot["revision"] = Value::String(revision);
    }
    snapshot
}

fn sanitized_git_source(source: &str) -> String {
    let Some(scheme_end) = source.find("://") else {
        return source.to_string();
    };
    let authority_start = scheme_end + 3;
    let suffix_start = source[authority_start..]
        .find(['/', '?', '#'])
        .map_or(source.len(), |offset| authority_start + offset);
    let authority = &source[authority_start..suffix_start];
    let authority = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let suffix = &source[suffix_start..];
    let suffix_end = suffix.find(['?', '#']).unwrap_or(suffix.len());
    format!("{}://{}{}", &source[..scheme_end], authority, &suffix[..suffix_end])
}

fn read_registry_metadata(
    install_root: &Path,
    name: &str,
    kind: PluginKind,
) -> anyhow::Result<PluginRegistryMetadata> {
    validate_plugin_name(name)?;
    let path = registry_metadata_path(install_root, name);
    let text = fs::read_to_string(&path)
        .map_err(|error| anyhow::anyhow!("failed to read {}: {error}", path.display()))?;
    let metadata: PluginRegistryMetadata = serde_json::from_str(&text)
        .map_err(|error| anyhow::anyhow!("invalid {}: {error}", path.display()))?;
    validate_plugin_id_for(&metadata.id, kind)?;
    Ok(metadata)
}

fn registry_metadata_path(install_root: &Path, name: &str) -> PathBuf {
    install_root.join(".registry").join(format!("{name}.json"))
}

fn replace_registry_metadata(
    install_root: &Path,
    name: &str,
    metadata: &PluginRegistryMetadata,
    kind: PluginKind,
) -> anyhow::Result<()> {
    validate_plugin_name(name)?;
    validate_plugin_id_for(&metadata.id, kind)?;
    let registry = install_root.join(".registry");
    fs::create_dir_all(&registry)?;
    let path = registry_metadata_path(install_root, name);
    let temp = registry.join(format!(".{name}.{}-{}.tmp", std::process::id(), now_nanos()));
    let result = (|| -> anyhow::Result<()> {
        let encoded = serde_json::to_vec(metadata)?;
        let mut file = fs::OpenOptions::new().create_new(true).write(true).open(&temp)?;
        file.write_all(&encoded)?;
        file.write_all(b"\n")?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temp, &path)
            .map_err(|error| anyhow::anyhow!("failed to persist {}: {error}", path.display()))
    })();
    if result.is_err() {
        // A failed write or sync can leave a partial temporary file. Remove
        // it before returning so a later install cannot inherit stale
        // metadata and the registry does not accumulate unbounded debris.
        let _ = fs::remove_file(&temp);
    }
    result
}

/// A completed artifact replacement whose old files remain available until
/// the selected-plugin configuration has also been written. The guard makes
/// install and update a best-effort local transaction across the filesystem
/// and the JSON configuration file.
struct PluginInstallTransaction {
    name: String,
    target: PathBuf,
    target_backup: Option<PathBuf>,
    metadata_path: PathBuf,
    metadata_backup: Option<PathBuf>,
    finished: bool,
}

impl PluginInstallTransaction {
    fn commit(mut self) {
        if let Some(backup) = self.target_backup.take()
            && let Err(error) = remove_path_if_present(&backup)
        {
            eprintln!(
                "cmux-tui: installed plugin {:?}, but could not remove backup {}: {error}",
                self.name,
                backup.display()
            );
        }
        if let Some(backup) = self.metadata_backup.take()
            && let Err(error) = remove_path_if_present(&backup)
        {
            eprintln!(
                "cmux-tui: installed plugin {:?}, but could not remove metadata backup {}: {error}",
                self.name,
                backup.display()
            );
        }
        self.finished = true;
    }

    fn rollback(mut self) -> anyhow::Result<()> {
        self.rollback_in_place()
    }

    fn rollback_in_place(&mut self) -> anyhow::Result<()> {
        let mut errors = Vec::new();
        if let Err(error) = remove_path_if_present(&self.target) {
            errors.push(format!("remove new plugin {}: {error}", self.target.display()));
        }

        if let Some(backup) = self.metadata_backup.take() {
            if let Err(error) = remove_path_if_present(&self.metadata_path) {
                errors
                    .push(format!("remove new metadata {}: {error}", self.metadata_path.display()));
            }
            if let Err(error) = fs::rename(&backup, &self.metadata_path) {
                errors.push(format!(
                    "restore metadata {} from {}: {error}",
                    self.metadata_path.display(),
                    backup.display()
                ));
            }
        } else if let Err(error) = remove_path_if_present(&self.metadata_path) {
            errors.push(format!("remove new metadata {}: {error}", self.metadata_path.display()));
        }

        if let Some(backup) = self.target_backup.take()
            && let Err(error) = fs::rename(&backup, &self.target)
        {
            errors.push(format!(
                "restore plugin {} from {}: {error}",
                self.target.display(),
                backup.display()
            ));
        }

        self.finished = true;
        if errors.is_empty() { Ok(()) } else { anyhow::bail!(errors.join("; ")) }
    }
}

impl Drop for PluginInstallTransaction {
    fn drop(&mut self) {
        if !self.finished {
            let _ = self.rollback_in_place();
        }
    }
}

/// Replace an installed plugin and its registry identity as one local
/// transaction. A failed rename or metadata write restores the previous
/// directory and identity, so `--force` cannot leave a half-installed plugin.
fn replace_plugin_install(
    install_root: &Path,
    name: &str,
    temp_dir: &Path,
    target: &Path,
    metadata: &PluginRegistryMetadata,
    kind: PluginKind,
) -> anyhow::Result<PluginInstallTransaction> {
    validate_plugin_name(name)?;
    validate_plugin_id_for(&metadata.id, kind)?;
    let target_backup =
        install_root.join(format!(".{name}.backup-{}-{}", std::process::id(), now_nanos()));
    let registry = install_root.join(".registry");
    fs::create_dir_all(&registry)?;
    let metadata_path = registry_metadata_path(install_root, name);
    let metadata_backup =
        registry.join(format!(".{name}.backup-{}-{}.json", std::process::id(), now_nanos()));
    let target_exists = path_exists(target)?;
    let metadata_exists = path_exists(&metadata_path)?;
    let mut target_moved = false;
    let mut metadata_moved = false;
    let mut target_installed = false;
    let mut metadata_installed = false;

    let install_result = (|| -> anyhow::Result<()> {
        if target_exists {
            fs::rename(target, &target_backup).map_err(|error| {
                anyhow::anyhow!("failed to stage {}: {error}", target.display())
            })?;
            target_moved = true;
        }
        if metadata_exists {
            fs::rename(&metadata_path, &metadata_backup).map_err(|error| {
                anyhow::anyhow!("failed to stage {}: {error}", metadata_path.display())
            })?;
            metadata_moved = true;
        }
        fs::rename(temp_dir, target)
            .map_err(|error| anyhow::anyhow!("failed to install {}: {error}", target.display()))?;
        target_installed = true;
        replace_registry_metadata(install_root, name, metadata, kind)?;
        metadata_installed = true;
        Ok(())
    })();

    if let Err(error) = install_result {
        // Remove only paths this attempt installed. If staging failed before
        // a rename, the old target or metadata must remain untouched. This
        // also avoids deleting a path that appeared concurrently after a
        // failed rename.
        if target_installed {
            let _ = remove_path_if_present(target);
        }
        if metadata_moved {
            if metadata_installed {
                let _ = remove_path_if_present(&metadata_path);
            }
            let _ = fs::rename(&metadata_backup, &metadata_path);
        } else if metadata_installed {
            let _ = remove_path_if_present(&metadata_path);
        }
        if target_moved {
            let _ = fs::rename(&target_backup, target);
        }
        return Err(error);
    }

    Ok(PluginInstallTransaction {
        name: name.to_string(),
        target: target.to_path_buf(),
        target_backup: target_moved.then_some(target_backup),
        metadata_path,
        metadata_backup: metadata_moved.then_some(metadata_backup),
        finished: false,
    })
}

fn path_exists(path: &Path) -> anyhow::Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(anyhow::anyhow!("failed to inspect {}: {error}", path.display())),
    }
}

fn remove_path_if_present(path: &Path) -> anyhow::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_dir() => fs::remove_dir_all(path)
            .map_err(|error| anyhow::anyhow!("failed to remove {}: {error}", path.display())),
        Ok(_) => fs::remove_file(path)
            .map_err(|error| anyhow::anyhow!("failed to remove {}: {error}", path.display())),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(anyhow::anyhow!("failed to inspect {}: {error}", path.display())),
    }
}

fn remove_registry_metadata(
    install_root: &Path,
    name: &str,
    _kind: PluginKind,
) -> anyhow::Result<()> {
    validate_plugin_name(name)?;
    let path = registry_metadata_path(install_root, name);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(anyhow::anyhow!("failed to remove {}: {error}", path.display())),
    }
}

fn random_plugin_id_for(kind: PluginKind) -> anyhow::Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("cannot allocate plugin ID: {error}"))?;
    let prefix = kind.id_prefix();
    let mut id = String::with_capacity(prefix.len() + 32);
    id.push_str(prefix);
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in bytes {
        id.push(char::from(HEX[usize::from(byte >> 4)]));
        id.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    Ok(id)
}

fn validate_plugin_id_for(id: &str, kind: PluginKind) -> anyhow::Result<()> {
    let prefix = kind.id_prefix();
    let Some(payload) = id.strip_prefix(prefix) else {
        anyhow::bail!("plugin ID must start with {prefix}");
    };
    if payload.len() != 32
        || !payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        anyhow::bail!("plugin ID must contain exactly 32 lowercase hexadecimal digits");
    }
    Ok(())
}

#[cfg(test)]
fn random_plugin_id() -> anyhow::Result<String> {
    random_plugin_id_for(PluginKind::Sidebar)
}

#[cfg(test)]
fn validate_plugin_id(id: &str) -> anyhow::Result<()> {
    validate_plugin_id_for(id, PluginKind::Sidebar)
}

fn git_text<const N: usize>(dir: &Path, args: [&str; N]) -> Option<String> {
    let output = Command::new("git")
        .arg("-c")
        .arg("protocol.file.allow=always")
        .args(args)
        .current_dir(dir)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let value = String::from_utf8(output.stdout).ok()?;
    let value = value.trim_end_matches(['\r', '\n']);
    (!value.is_empty()).then(|| value.to_string())
}

fn canonical_path(path: &Path) -> anyhow::Result<PathBuf> {
    fs::canonicalize(path)
        .map_err(|err| anyhow::anyhow!("failed to resolve {}: {err}", path.display()))
}

fn same_path(left: &Path, right: &Path) -> bool {
    let left = fs::canonicalize(left).unwrap_or_else(|_| left.to_path_buf());
    let right = fs::canonicalize(right).unwrap_or_else(|_| right.to_path_buf());
    left == right
}

fn non_empty_env_path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|value| !value.is_empty()).map(PathBuf::from)
}

fn now_nanos() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest_text(name: &str) -> String {
        format!(
            r#"
            [plugin]
            name = "{name}"
            kind = "sidebar"
            version = "0.1.0"
            description = "test plugin"

            [run]
            command = ["bin/sidebar"]
            "#
        )
    }

    #[test]
    fn manifest_parse_validates_required_fields() {
        let manifest = parse_manifest(&manifest_text("fzf")).unwrap();
        assert_eq!(manifest.plugin.name, "fzf");
        assert_eq!(manifest.plugin.kind, "sidebar");
        assert_eq!(manifest.run.command, vec!["bin/sidebar"]);
    }

    #[test]
    fn manifest_rejects_bad_kind() {
        let text = manifest_text("fzf").replace("sidebar", "pane");
        let error = parse_manifest(&text).unwrap_err().to_string();
        assert!(error.contains("plugin.kind"));
    }

    #[test]
    fn manifest_rejects_bad_name_chars() {
        let error = parse_manifest(&manifest_text("../bad")).unwrap_err().to_string();
        assert!(error.contains("[a-z0-9-_]+"));
    }

    #[test]
    fn manifest_rejects_overlong_name() {
        let name = "a".repeat(MAX_PLUGIN_NAME_BYTES + 1);
        let error = parse_manifest(&manifest_text(&name)).unwrap_err().to_string();
        assert!(error.contains("[a-z0-9-_]+"));
    }

    #[test]
    fn manifest_rejects_missing_run_command() {
        let text = r#"
            [plugin]
            name = "fzf"
            kind = "sidebar"
        "#;
        let error = parse_manifest(text).unwrap_err().to_string();
        assert!(error.contains("missing field `run`") || error.contains("run.command"));
    }

    #[test]
    fn manifest_platforms_are_validated_and_current_platform_is_admitted() {
        let current = current_plugin_platform();
        if current == "other" {
            return;
        }
        let text = manifest_text("fzf").replace(
            "description = \"test plugin\"",
            &format!("description = \"test plugin\"\n            platforms = [\"{current}\"]"),
        );
        let manifest = parse_manifest(&text).unwrap();
        ensure_manifest_platform_supported(&manifest).unwrap();

        let unsupported = if current == "macos" { "linux" } else { "macos" };
        let text = manifest_text("fzf").replace(
            "description = \"test plugin\"",
            &format!("description = \"test plugin\"\n            platforms = [\"{unsupported}\"]"),
        );
        let manifest = parse_manifest(&text).unwrap();
        assert!(ensure_manifest_platform_supported(&manifest).is_err());
    }

    #[test]
    fn manifest_rejects_unknown_and_duplicate_platforms() {
        for platforms in
            ["platforms = [\"plan9\"]", "platforms = [\"linux\", \"linux\"]", "platforms = []"]
        {
            let text = manifest_text("fzf").replace(
                "description = \"test plugin\"",
                &format!("description = \"test plugin\"\n            {platforms}"),
            );
            assert!(parse_manifest(&text).is_err(), "{platforms}");
        }
    }

    #[test]
    fn manifest_rejects_unknown_fields_and_unsafe_argv() {
        let unknown = manifest_text("fzf").replace(
            "description = \"test plugin\"",
            "description = \"test plugin\"\n            unexpected = true",
        );
        assert!(parse_manifest(&unknown).is_err(), "unknown manifest fields must fail closed");

        let empty_executable = manifest_text("fzf")
            .replace("command = [\"bin/sidebar\"]", "command = [\"\", \"kept\"]");
        assert!(parse_manifest(&empty_executable).is_err());

        let nul_argument = manifest_text("fzf").replace(
            "command = [\"bin/sidebar\"]",
            "command = [\"bin/sidebar\", \"bad\\u0000arg\"]",
        );
        assert!(parse_manifest(&nul_argument).is_err());

        let too_many = (0..=MAX_PLUGIN_COMMAND_ARGS)
            .map(|index| format!("\"arg-{index}\""))
            .collect::<Vec<_>>()
            .join(", ");
        let too_many = manifest_text("fzf").replace(
            "command = [\"bin/sidebar\"]",
            &format!("command = [\"bin/sidebar\", {too_many}]"),
        );
        assert!(parse_manifest(&too_many).is_err());
    }

    #[test]
    fn relative_run_command_cannot_escape_plugin_directory() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-command-boundary-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        let plugin_dir = root.join("plugin");
        let outside_dir = root.join("outside");
        fs::create_dir_all(&plugin_dir).unwrap();
        fs::create_dir_all(&outside_dir).unwrap();
        let outside_executable = outside_dir.join("agent");
        fs::write(&outside_executable, b"#!/bin/sh\n").unwrap();

        let mut manifest = parse_manifest(&manifest_text("fzf")).unwrap();
        manifest.run.command[0] = "../outside/agent".into();
        let error = resolved_run_command(&manifest, &plugin_dir).unwrap_err().to_string();
        assert!(error.contains("escapes plugin directory"), "{error}");

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bounded_manifest_reader_rejects_oversized_files() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-manifest-limit-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("cmux-plugin.toml");
        fs::write(&path, vec![b'x'; MAX_PLUGIN_MANIFEST_BYTES + 1]).unwrap();
        let error = read_manifest(&root, PluginKind::Sidebar).unwrap_err().to_string();
        assert!(error.contains("manifest limit"), "{error}");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn bounded_plugin_text_reader_rejects_oversized_files() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-text-limit-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("plugin.json");
        fs::write(&path, b"four").unwrap();
        let error = read_bounded_plugin_text(&path, 3).unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("3-byte limit"), "{error}");
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn plugin_registry_rejects_an_unbounded_entry_count() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-registry-entry-limit-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        for index in 0..=MAX_INSTALLED_PLUGIN_ENTRIES {
            fs::create_dir(root.join(format!("plugin-{index}"))).unwrap();
        }

        let error = bounded_plugin_registry_entries(&root).unwrap_err().to_string();
        assert!(error.contains("plugin registry") && error.contains("entry limit"), "{error}");

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn artifact_digest_handles_multiple_read_chunks() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-artifact-digest-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        fs::create_dir_all(&root).unwrap();
        let path = root.join("plugin");
        let bytes = (0..(ARTIFACT_HASH_BUFFER_BYTES * 2 + 17))
            .map(|index| (index % 251) as u8)
            .collect::<Vec<_>>();
        fs::write(&path, &bytes).unwrap();

        let mut actual = Sha256::new();
        update_file_digest(fs::File::open(&path).unwrap(), &mut actual).unwrap();
        assert_eq!(actual.finalize(), Sha256::digest(&bytes));

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn installed_name_uses_manifest_or_override() {
        let manifest = parse_manifest(&manifest_text("fzf")).unwrap();
        assert_eq!(installed_name(&manifest, None).unwrap(), "fzf");
        assert_eq!(installed_name(&manifest, Some("custom-name")).unwrap(), "custom-name");
        assert!(installed_name(&manifest, Some("Bad")).is_err());
    }

    #[test]
    fn registry_assigns_and_persists_secure_opaque_ids() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-registry-test-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        fs::create_dir_all(&root).unwrap();

        let first = PluginRegistryMetadata { id: random_plugin_id().unwrap() };
        replace_registry_metadata(&root, "first", &first, PluginKind::Sidebar).unwrap();
        let replay = read_registry_metadata(&root, "first", PluginKind::Sidebar).unwrap();
        let second = PluginRegistryMetadata { id: random_plugin_id().unwrap() };
        replace_registry_metadata(&root, "second", &second, PluginKind::Sidebar).unwrap();
        assert_eq!(first.id, replay.id);
        assert_ne!(first.id, second.id);
        validate_plugin_id(&first.id).unwrap();
        validate_plugin_id(&second.id).unwrap();
        assert_eq!(
            serde_json::from_str::<PluginRegistryMetadata>(
                &fs::read_to_string(registry_metadata_path(&root, "first")).unwrap()
            )
            .unwrap()
            .id,
            first.id
        );

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn install_transaction_restores_the_previous_artifact_and_identity() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-transaction-test-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        let target = root.join("agent-view");
        let staged = root.join(".staged");
        fs::create_dir_all(target.join("bin")).unwrap();
        fs::write(target.join("bin/old"), "old artifact").unwrap();
        fs::create_dir_all(staged.join("bin")).unwrap();
        fs::write(staged.join("bin/new"), "new artifact").unwrap();

        let old_metadata =
            PluginRegistryMetadata { id: "sidebar_plugin_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".into() };
        replace_registry_metadata(&root, "agent-view", &old_metadata, PluginKind::Sidebar).unwrap();
        let new_metadata =
            PluginRegistryMetadata { id: "sidebar_plugin_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".into() };

        let transaction = replace_plugin_install(
            &root,
            "agent-view",
            &staged,
            &target,
            &new_metadata,
            PluginKind::Sidebar,
        )
        .unwrap();
        assert!(target.join("bin/new").is_file());
        assert_eq!(
            read_registry_metadata(&root, "agent-view", PluginKind::Sidebar).unwrap().id,
            new_metadata.id
        );

        transaction.rollback().unwrap();
        assert!(target.join("bin/old").is_file());
        assert!(!target.join("bin/new").exists());
        assert_eq!(
            read_registry_metadata(&root, "agent-view", PluginKind::Sidebar).unwrap().id,
            old_metadata.id
        );
        assert!(!staged.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn plugin_snapshot_matches_the_closed_catalog_shape() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-snapshot-test-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        let bin = root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        let executable = bin.join("sidebar");
        fs::write(&executable, "#!/bin/sh\nexit 0\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let snapshot = plugin_json(&InstalledPlugin {
            id: "sidebar_plugin_11111111111111111111111111111111".into(),
            name: "custom-name".into(),
            manifest: parse_manifest(&manifest_text("manifest-name")).unwrap(),
            dir: root.clone(),
            selected: true,
        });
        let keys = snapshot
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect::<std::collections::BTreeSet<_>>();
        assert_eq!(
            keys,
            ["active", "enabled", "extra", "id", "name", "source"].into_iter().collect()
        );
        assert_eq!(snapshot["id"], "sidebar_plugin_11111111111111111111111111111111");
        assert_eq!(snapshot["name"], "custom-name");
        assert_eq!(snapshot["active"], true);
        assert_eq!(snapshot["enabled"], true);
        assert_eq!(snapshot["extra"]["manifest_name"], "manifest-name");
        assert!(snapshot.get("revision").is_none());

        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn plugin_source_never_exposes_url_credentials() {
        assert_eq!(
            sanitized_git_source("https://user:secret@example.com/team/plugin.git?token=secret"),
            "https://example.com/team/plugin.git"
        );
        assert_eq!(
            sanitized_git_source("ssh://git@example.com/team/plugin.git"),
            "ssh://example.com/team/plugin.git"
        );
        assert_eq!(
            sanitized_git_source("git@example.com:team/plugin.git"),
            "git@example.com:team/plugin.git"
        );
    }

    #[test]
    fn git_source_rejects_embedded_credentials_and_query_tokens() {
        for source in [
            "https://user:secret@example.com/team/plugin.git",
            "https://user@example.com/team/plugin.git",
            "https://example.com/team/plugin.git?token=secret",
            "http://example.com/team/plugin.git#token",
        ] {
            assert!(
                validate_git_source(source).is_err(),
                "unsafe source must be rejected: {source}"
            );
        }

        for source in [
            "ssh://git@example.com/team/plugin.git",
            "git@example.com:team/plugin.git",
            "/tmp/plugin.git",
        ] {
            assert!(
                validate_git_source(source).is_ok(),
                "normal source must remain valid: {source}"
            );
        }
    }

    #[test]
    fn selection_matching_uses_id_then_path_or_command_migrations() {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-selection-test-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        let dir = root.join("agent-view");
        let executable = dir.join("bin/sidebar");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::write(&executable, "#!/bin/sh\n").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        }
        let manifest = parse_manifest(&manifest_text("agent-view")).unwrap();
        let id = "sidebar_plugin_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

        let by_id = SelectedPluginConfig { id: Some(id.into()), ..Default::default() };
        assert!(plugin_is_selected(Some(&by_id), id, &manifest, &dir));

        let by_path = SelectedPluginConfig { cwd: Some(dir.clone()), ..Default::default() };
        assert!(plugin_is_selected(Some(&by_path), "other", &manifest, &dir));

        let shared_cwd_with_other_command = SelectedPluginConfig {
            cwd: Some(dir.clone()),
            command: Some(vec!["/tmp/other-plugin".into()]),
            ..Default::default()
        };
        assert!(!plugin_is_selected(
            Some(&shared_cwd_with_other_command),
            "other",
            &manifest,
            &dir
        ));

        let command = resolved_run_command(&manifest, &dir).unwrap();
        let by_command = SelectedPluginConfig { command: Some(command), ..Default::default() };
        assert!(plugin_is_selected(Some(&by_command), "other", &manifest, &dir));

        let sibling_command = SelectedPluginConfig {
            command: Some(vec![dir.join("bin/other").display().to_string()]),
            ..Default::default()
        };
        assert!(!plugin_is_selected(Some(&sibling_command), "other", &manifest, &dir));

        let unrelated_command = SelectedPluginConfig {
            command: Some(vec!["/tmp/plugin".into(), "different".into()]),
            ..Default::default()
        };
        assert!(!plugin_is_selected(Some(&unrelated_command), id, &manifest, &dir));
        fs::remove_dir_all(root).unwrap();
    }
}
