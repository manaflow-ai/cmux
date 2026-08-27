use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::config::{self, SidebarPluginConfig};

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
struct PluginManifest {
    plugin: ManifestPlugin,
    run: ManifestRun,
    build: Option<ManifestBuild>,
}

#[derive(Debug, Clone, Deserialize)]
struct ManifestPlugin {
    name: String,
    kind: String,
    version: Option<String>,
    description: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
struct ManifestRun {
    command: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
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

pub(crate) fn execute(positionals: &[String], options: CliOptions) -> Result<Value, ManagerError> {
    match positionals.first().map(String::as_str) {
        Some("install") => install_command(positionals, &options),
        Some("list") => list_command(positionals, &options),
        Some("use") => use_command(positionals, &options),
        Some("update") => update_command(positionals, &options),
        Some("remove") => remove_command(positionals, &options),
        Some(other) => Err(ManagerError::Usage(format!("unknown plugin subcommand {other:?}"))),
        None => Err(ManagerError::Usage("plugin subcommand is required".to_string())),
    }
}

fn install_command(positionals: &[String], options: &CliOptions) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, true, true, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage(
            "usage: cmux sidebar plugin install <git-url> [--name <name>] [--force]".to_string(),
        ));
    }
    if positionals[1].is_empty() {
        return Err(ManagerError::validation(Some("git_url"), "plugin git URL must not be empty"));
    }
    let root = install_root()?;
    fs::create_dir_all(&root)?;
    let temp_dir = root.join(format!(".install-{}-{}", std::process::id(), now_nanos()));
    let clone_result =
        run_git(["clone", "--depth", "1", positionals[1].as_str()], Some(&temp_dir), None);
    if let Err(error) = clone_result {
        let _ = fs::remove_dir_all(&temp_dir);
        return Err(error.into());
    }

    let mut metadata_temp_path = None;
    let result = (|| -> Result<Value, ManagerError> {
        let manifest = read_manifest(&temp_dir)
            .map_err(|error| ManagerError::validation(None, error.to_string()))?;
        let name = installed_name(&manifest, options.name.as_deref())
            .map_err(|error| ManagerError::validation(Some("name"), error.to_string()))?;
        let target = root.join(&name);
        if target.exists() && !options.force {
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
        let metadata = PluginRegistryMetadata { id: random_plugin_id()? };
        let metadata_temp = write_registry_metadata_temp(&root, &name, &metadata)?;
        metadata_temp_path = Some(metadata_temp.clone());
        let id = metadata.id;
        replace_installed_plugin(&root, &name, &temp_dir, &metadata_temp)?;
        let selected = selected_plugin_cwd()?.is_some_and(|cwd| same_path(&cwd, &target));
        if selected {
            let command = resolved_run_command(&manifest, &target)?;
            let cwd = canonical_path(&target)?;
            persist_sidebar_plugin(Some(&SidebarPluginConfig {
                command,
                cwd: Some(cwd.display().to_string()),
            }))?;
        }
        Ok(json!({"plugin": plugin_json(&InstalledPlugin {
            id,
            name,
            manifest,
            dir: target,
            selected,
        })}))
    })();
    if result.is_err() {
        if temp_dir.exists() {
            let _ = fs::remove_dir_all(&temp_dir);
        }
        if let Some(metadata_temp) = metadata_temp_path {
            let _ = fs::remove_file(metadata_temp);
        }
    }
    result
}

fn list_command(positionals: &[String], options: &CliOptions) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 1 {
        return Err(ManagerError::Usage("usage: cmux sidebar plugin list".to_string()));
    }
    let plugins = installed_plugins()?;
    Ok(Value::Array(plugins.iter().map(plugin_json).collect()))
}

fn use_command(positionals: &[String], options: &CliOptions) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, true)?;
    match (positionals.len(), options.builtin) {
        (1, true) => return write_builtin_config(options),
        (2, false) => {}
        _ => {
            return Err(ManagerError::Usage(
                "usage: cmux sidebar plugin use <name-or-id> | cmux sidebar plugin use --builtin"
                    .to_string(),
            ));
        }
    }
    let mut plugin = resolve_installed_plugin(&positionals[1])?;
    let command = resolved_run_command(&plugin.manifest, &plugin.dir)?;
    verify_executable(&command[0])?;
    let cwd = canonical_path(&plugin.dir)?;
    persist_sidebar_plugin(Some(&SidebarPluginConfig {
        command,
        cwd: Some(cwd.display().to_string()),
    }))?;
    plugin.selected = true;
    Ok(json!({"plugin": plugin_json(&plugin)}))
}

fn update_command(positionals: &[String], options: &CliOptions) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage(
            "usage: cmux sidebar plugin update <name-or-id>".to_string(),
        ));
    }
    let mut plugin = resolve_installed_plugin(&positionals[1])?;
    run_git(["pull", "--ff-only"], None, Some(&plugin.dir))?;
    plugin.manifest = read_manifest(&plugin.dir)?;
    run_build_if_needed(&plugin.manifest, &plugin.dir)?;
    let command = resolved_run_command(&plugin.manifest, &plugin.dir)?;
    verify_executable(&command[0])?;
    if plugin.selected {
        let cwd = canonical_path(&plugin.dir)?;
        persist_sidebar_plugin(Some(&SidebarPluginConfig {
            command,
            cwd: Some(cwd.display().to_string()),
        }))?;
    }
    Ok(json!({"plugin": plugin_json(&plugin)}))
}

fn remove_command(positionals: &[String], options: &CliOptions) -> Result<Value, ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage(
            "usage: cmux sidebar plugin remove <name-or-id>".to_string(),
        ));
    }
    let installed = resolve_installed_plugin(&positionals[1])?;
    let mut plugin = plugin_json(&installed);
    if installed.selected {
        persist_sidebar_plugin(None)?;
    }
    fs::remove_dir_all(&installed.dir)?;
    remove_registry_metadata(&install_root()?, &installed.name)?;
    plugin["active"] = Value::Bool(false);
    plugin["enabled"] = Value::Bool(false);
    Ok(json!({"plugin": plugin}))
}

fn write_builtin_config(_options: &CliOptions) -> Result<Value, ManagerError> {
    persist_sidebar_plugin(None)?;
    let plugins = installed_plugins()?;
    Ok(json!({"plugins": plugins.iter().map(plugin_json).collect::<Vec<_>>()}))
}

fn persist_sidebar_plugin(plugin: Option<&SidebarPluginConfig>) -> Result<(), ManagerError> {
    if let Some(error) = config::write_sidebar_plugin(plugin)?.into_unsynced_error() {
        crate::client_log::stderr_log!(
            "config",
            "{}",
            crate::localization::catalog().config.write_durability_warning(&error.to_string())
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

fn installed_plugins() -> anyhow::Result<Vec<InstalledPlugin>> {
    let root = install_root()?;
    let selected = selected_plugin_cwd()?;
    let mut plugins = Vec::new();
    let entries = match fs::read_dir(&root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(plugins),
        Err(error) => {
            return Err(anyhow::anyhow!(
                "failed to read plugin registry {}: {error}",
                root.display()
            ));
        }
    };
    for entry in entries {
        let entry = entry?;
        if !entry.file_type()?.is_dir() {
            continue;
        }
        let dir = entry.path();
        if dir.file_name().and_then(|name| name.to_str()).is_some_and(|name| name.starts_with('.'))
        {
            continue;
        }
        let manifest = read_manifest(&dir)?;
        let name = dir
            .file_name()
            .and_then(|value| value.to_str())
            .ok_or_else(|| anyhow::anyhow!("plugin directory name is not UTF-8"))?
            .to_string();
        validate_plugin_name(&name)?;
        let metadata = read_registry_metadata(&root, &name)?;
        let selected = selected.as_ref().is_some_and(|cwd| same_path(cwd, &dir));
        plugins.push(InstalledPlugin { id: metadata.id, name, manifest, dir, selected });
    }
    plugins.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(plugins)
}

fn resolve_installed_plugin(selector: &str) -> Result<InstalledPlugin, ManagerError> {
    let forced_name = selector.strip_prefix("name:");
    let selector = forced_name.unwrap_or(selector);
    let by_id = forced_name.is_none() && selector.starts_with("sidebar_plugin_");
    if by_id {
        validate_plugin_id(selector)
            .map_err(|error| ManagerError::validation(Some("sidebar_plugin"), error.to_string()))?;
    } else {
        validate_plugin_name(selector)
            .map_err(|error| ManagerError::validation(Some("sidebar_plugin"), error.to_string()))?;
    }
    installed_plugins()?
        .into_iter()
        .find(|plugin| if by_id { plugin.id == selector } else { plugin.name == selector })
        .ok_or_else(|| {
            ManagerError::validation(
                Some("sidebar_plugin"),
                format!("plugin {selector:?} is not installed"),
            )
        })
}

fn read_manifest(dir: &Path) -> anyhow::Result<PluginManifest> {
    let path = dir.join("cmux-plugin.toml");
    let text = fs::read_to_string(&path)
        .map_err(|err| anyhow::anyhow!("failed to read {}: {err}", path.display()))?;
    parse_manifest(&text)
}

fn parse_manifest(text: &str) -> anyhow::Result<PluginManifest> {
    let manifest: PluginManifest =
        toml::from_str(text).map_err(|err| anyhow::anyhow!("invalid cmux-plugin.toml: {err}"))?;
    validate_manifest(&manifest)?;
    Ok(manifest)
}

fn validate_manifest(manifest: &PluginManifest) -> anyhow::Result<()> {
    validate_plugin_name(&manifest.plugin.name)?;
    if manifest.plugin.kind != "sidebar" {
        anyhow::bail!("plugin.kind must be \"sidebar\"");
    }
    if manifest.run.command.first().is_none_or(|command| command.trim().is_empty()) {
        anyhow::bail!("run.command must not be empty");
    }
    if let Some(build) = &manifest.build
        && build.command.first().is_none_or(|command| command.trim().is_empty())
    {
        anyhow::bail!("build.command must not be empty when present");
    }
    Ok(())
}

fn validate_plugin_name(name: &str) -> anyhow::Result<()> {
    if name.is_empty()
        || !name.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'_'
        })
    {
        anyhow::bail!("plugin name must match [a-z0-9-_]+");
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
        command[0] = canonical_path(&dir.join(first))?.display().to_string();
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

fn install_root() -> anyhow::Result<PathBuf> {
    if let Some(data_home) = non_empty_env_path("XDG_DATA_HOME") {
        return Ok(data_home.join("cmux").join("mux-plugins"));
    }
    let home = cmux_tui_core::platform::home_dir()
        .ok_or_else(|| anyhow::anyhow!("could not resolve home directory"))?;
    Ok(home.join(".local").join("share").join("cmux").join("mux-plugins"))
}

fn selected_plugin_cwd() -> anyhow::Result<Option<PathBuf>> {
    let path = config::config_path()?;
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(anyhow::anyhow!("failed to read {}: {err}", path.display())),
    };
    let value: Value = serde_json::from_str(&text)
        .map_err(|err| anyhow::anyhow!("failed to parse {}: {err}", path.display()))?;
    Ok(value
        .get("sidebar")
        .and_then(|sidebar| sidebar.get("plugin"))
        .and_then(|plugin| plugin.get("cwd"))
        .and_then(Value::as_str)
        .map(PathBuf::from))
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
) -> anyhow::Result<PluginRegistryMetadata> {
    validate_plugin_name(name)?;
    let path = registry_metadata_path(install_root, name);
    let text = fs::read_to_string(&path)
        .map_err(|error| anyhow::anyhow!("failed to read {}: {error}", path.display()))?;
    let metadata: PluginRegistryMetadata = serde_json::from_str(&text)
        .map_err(|error| anyhow::anyhow!("invalid {}: {error}", path.display()))?;
    validate_plugin_id(&metadata.id)?;
    Ok(metadata)
}

fn registry_metadata_path(install_root: &Path, name: &str) -> PathBuf {
    install_root.join(".registry").join(format!("{name}.json"))
}

trait InstallFilesystem {
    fn rename(&self, from: &Path, to: &Path) -> std::io::Result<()>;
    fn remove_dir_all(&self, path: &Path) -> std::io::Result<()>;
    fn remove_file(&self, path: &Path) -> std::io::Result<()>;
}

struct StandardInstallFilesystem;

impl InstallFilesystem for StandardInstallFilesystem {
    fn rename(&self, from: &Path, to: &Path) -> std::io::Result<()> {
        fs::rename(from, to)
    }

    fn remove_dir_all(&self, path: &Path) -> std::io::Result<()> {
        fs::remove_dir_all(path)
    }

    fn remove_file(&self, path: &Path) -> std::io::Result<()> {
        fs::remove_file(path)
    }
}

fn unique_backup_path(parent: &Path, name: &str, suffix: &str) -> PathBuf {
    loop {
        let path = parent.join(format!(".{name}.{}-{}{suffix}", std::process::id(), now_nanos()));
        if !path.exists() {
            return path;
        }
    }
}

fn replace_installed_plugin(
    install_root: &Path,
    name: &str,
    temp_dir: &Path,
    metadata_temp: &Path,
) -> anyhow::Result<()> {
    replace_installed_plugin_with_fs(
        &StandardInstallFilesystem,
        install_root,
        name,
        temp_dir,
        metadata_temp,
    )
}

fn replace_installed_plugin_with_fs<F: InstallFilesystem>(
    filesystem: &F,
    install_root: &Path,
    name: &str,
    temp_dir: &Path,
    metadata_temp: &Path,
) -> anyhow::Result<()> {
    let target = install_root.join(name);
    let target_exists = target.exists();
    let metadata_path = registry_metadata_path(install_root, name);
    let target_backup = unique_backup_path(install_root, name, ".plugin-backup");
    let metadata_backup =
        unique_backup_path(&install_root.join(".registry"), name, ".metadata-backup.json");
    let metadata_exists = metadata_path.exists();
    let mut target_backed_up = false;
    let mut metadata_backed_up = false;
    let mut target_installed = false;
    let mut metadata_installed = false;

    let result = (|| -> anyhow::Result<()> {
        if target_exists {
            filesystem.rename(&target, &target_backup).map_err(|error| {
                anyhow::anyhow!("failed to back up {}: {error}", target.display())
            })?;
            target_backed_up = true;
        }
        if metadata_exists {
            filesystem.rename(&metadata_path, &metadata_backup).map_err(|error| {
                anyhow::anyhow!("failed to back up {}: {error}", metadata_path.display())
            })?;
            metadata_backed_up = true;
        }
        filesystem
            .rename(temp_dir, &target)
            .map_err(|error| anyhow::anyhow!("failed to install {}: {error}", target.display()))?;
        target_installed = true;
        filesystem.rename(metadata_temp, &metadata_path).map_err(|error| {
            anyhow::anyhow!("failed to persist {}: {error}", metadata_path.display())
        })?;
        metadata_installed = true;
        Ok(())
    })();

    if let Err(error) = result {
        let mut rollback_errors = Vec::new();
        if metadata_installed
            && let Err(rollback_error) = filesystem.rename(&metadata_path, metadata_temp)
        {
            rollback_errors.push(format!("metadata staging: {rollback_error}"));
        }
        if metadata_backed_up
            && let Err(rollback_error) = filesystem.rename(&metadata_backup, &metadata_path)
        {
            rollback_errors.push(format!("metadata restore: {rollback_error}"));
        }
        if target_installed && let Err(rollback_error) = filesystem.rename(&target, temp_dir) {
            rollback_errors.push(format!("plugin staging: {rollback_error}"));
        }
        if target_backed_up && let Err(rollback_error) = filesystem.rename(&target_backup, &target)
        {
            rollback_errors.push(format!("plugin restore: {rollback_error}"));
        }
        if !rollback_errors.is_empty() {
            anyhow::bail!("{error}; rollback failed: {}", rollback_errors.join("; "));
        }
        return Err(error);
    }

    // The replacement is committed once both new paths are in place. Cleanup is
    // deliberately best effort: retaining an old same-parent backup is safe and
    // preserves recovery data if the process loses access after commit.
    let _ = filesystem.remove_dir_all(&target_backup);
    let _ = filesystem.remove_file(&metadata_backup);
    Ok(())
}

fn write_registry_metadata_temp(
    install_root: &Path,
    name: &str,
    metadata: &PluginRegistryMetadata,
) -> anyhow::Result<PathBuf> {
    validate_plugin_name(name)?;
    validate_plugin_id(&metadata.id)?;
    let registry = install_root.join(".registry");
    fs::create_dir_all(&registry)?;
    let temp = registry.join(format!(".{name}.{}-{}.tmp", std::process::id(), now_nanos()));
    let encoded = serde_json::to_vec(metadata)?;
    let mut file = fs::OpenOptions::new().create_new(true).write(true).open(&temp)?;
    file.write_all(&encoded)?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    drop(file);
    Ok(temp)
}

fn replace_registry_metadata(
    install_root: &Path,
    name: &str,
    metadata: &PluginRegistryMetadata,
) -> anyhow::Result<()> {
    let path = registry_metadata_path(install_root, name);
    let temp = write_registry_metadata_temp(install_root, name, metadata)?;
    if let Err(error) = fs::rename(&temp, &path) {
        let _ = fs::remove_file(&temp);
        return Err(anyhow::anyhow!("failed to persist {}: {error}", path.display()));
    }
    Ok(())
}

fn remove_registry_metadata(install_root: &Path, name: &str) -> anyhow::Result<()> {
    let path = registry_metadata_path(install_root, name);
    match fs::remove_file(&path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(anyhow::anyhow!("failed to remove {}: {error}", path.display())),
    }
}

fn random_plugin_id() -> anyhow::Result<String> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes)
        .map_err(|error| anyhow::anyhow!("cannot allocate plugin ID: {error}"))?;
    let mut id = String::with_capacity("sidebar_plugin_".len() + 32);
    id.push_str("sidebar_plugin_");
    const HEX: &[u8; 16] = b"0123456789abcdef";
    for byte in bytes {
        id.push(char::from(HEX[usize::from(byte >> 4)]));
        id.push(char::from(HEX[usize::from(byte & 0x0f)]));
    }
    Ok(id)
}

fn validate_plugin_id(id: &str) -> anyhow::Result<()> {
    let Some(payload) = id.strip_prefix("sidebar_plugin_") else {
        anyhow::bail!("plugin ID must start with sidebar_plugin_");
    };
    if payload.len() != 32
        || !payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    {
        anyhow::bail!("plugin ID must contain exactly 32 lowercase hexadecimal digits");
    }
    Ok(())
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
    use std::cell::Cell;

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
        replace_registry_metadata(&root, "first", &first).unwrap();
        let replay = read_registry_metadata(&root, "first").unwrap();
        let second = PluginRegistryMetadata { id: random_plugin_id().unwrap() };
        replace_registry_metadata(&root, "second", &second).unwrap();
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

    struct FailingRenameFilesystem {
        fail_at: usize,
        calls: Cell<usize>,
    }

    impl InstallFilesystem for FailingRenameFilesystem {
        fn rename(&self, from: &Path, to: &Path) -> std::io::Result<()> {
            let call = self.calls.get() + 1;
            self.calls.set(call);
            if call == self.fail_at {
                return Err(std::io::Error::other("injected rename failure"));
            }
            fs::rename(from, to)
        }

        fn remove_dir_all(&self, path: &Path) -> std::io::Result<()> {
            fs::remove_dir_all(path)
        }

        fn remove_file(&self, path: &Path) -> std::io::Result<()> {
            fs::remove_file(path)
        }
    }

    fn replacement_fixture(label: &str) -> (PathBuf, PathBuf, PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "cmux-plugin-replacement-test-{label}-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        let target = root.join("demo");
        let registry = root.join(".registry");
        let metadata_path = registry.join("demo.json");
        let temp_dir = root.join(".install");
        let metadata_temp = registry.join(".demo.tmp");
        fs::create_dir_all(target.join("bin")).unwrap();
        fs::write(target.join("marker"), "old").unwrap();
        fs::create_dir_all(&registry).unwrap();
        fs::write(
            &metadata_path,
            r#"{"id":"sidebar_plugin_11111111111111111111111111111111"}
"#,
        )
        .unwrap();
        fs::create_dir_all(temp_dir.join("bin")).unwrap();
        fs::write(temp_dir.join("marker"), "new").unwrap();
        fs::write(
            &metadata_temp,
            r#"{"id":"sidebar_plugin_22222222222222222222222222222222"}
"#,
        )
        .unwrap();
        (root, target, temp_dir, metadata_temp)
    }

    #[test]
    fn replacement_failure_after_backup_restores_plugin_and_metadata() {
        let (root, target, temp_dir, metadata_temp) = replacement_fixture("rollback");
        let filesystem = FailingRenameFilesystem { fail_at: 2, calls: Cell::new(0) };
        let error =
            replace_installed_plugin_with_fs(&filesystem, &root, "demo", &temp_dir, &metadata_temp)
                .unwrap_err();
        assert!(error.to_string().contains("back up"));
        assert_eq!(fs::read_to_string(target.join("marker")).unwrap(), "old");
        assert_eq!(
            read_registry_metadata(&root, "demo").unwrap().id,
            "sidebar_plugin_11111111111111111111111111111111"
        );
        assert!(temp_dir.exists());
        assert!(metadata_temp.exists());
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn replacement_commits_new_plugin_and_metadata_together() {
        let (root, target, temp_dir, metadata_temp) = replacement_fixture("success");
        replace_installed_plugin(&root, "demo", &temp_dir, &metadata_temp).unwrap();
        assert_eq!(fs::read_to_string(target.join("marker")).unwrap(), "new");
        assert_eq!(
            read_registry_metadata(&root, "demo").unwrap().id,
            "sidebar_plugin_22222222222222222222222222222222"
        );
        assert!(!temp_dir.exists());
        assert!(!metadata_temp.exists());
        let visible_entries = fs::read_dir(&root)
            .unwrap()
            .filter_map(Result::ok)
            .filter(|entry| !entry.file_name().to_string_lossy().starts_with('.'))
            .count();
        assert_eq!(visible_entries, 1);
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
}
