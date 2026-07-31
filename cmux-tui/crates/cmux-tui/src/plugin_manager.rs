use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::config::{self, SidebarPluginConfig};

#[derive(Debug, Clone, Default)]
pub struct CliOptions {
    pub json: bool,
    pub socket: Option<PathBuf>,
    pub session: Option<String>,
    pub name: Option<String>,
    pub force: bool,
    pub builtin: bool,
}

#[derive(Debug)]
enum ManagerError {
    Usage(String),
    Failure(anyhow::Error),
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
    manifest: PluginManifest,
    dir: PathBuf,
    selected: bool,
}

pub fn run(positionals: &[String], options: CliOptions) -> i32 {
    let result = match positionals.first().map(String::as_str) {
        Some("install") => install_command(positionals, &options),
        Some("list") => list_command(positionals, &options),
        Some("use") => use_command(positionals, &options),
        Some("disable") => disable_command(positionals, &options),
        Some("update") => update_command(positionals, &options),
        Some("remove") => remove_command(positionals, &options),
        Some(other) => Err(ManagerError::Usage(format!("unknown plugin subcommand {other:?}"))),
        None => Err(ManagerError::Usage("plugin subcommand is required".to_string())),
    };
    match result {
        Ok(()) => 0,
        Err(ManagerError::Usage(message)) => {
            eprintln!("cmux-tui: {message}");
            2
        }
        Err(ManagerError::Failure(error)) => {
            eprintln!("cmux-tui: {error}");
            1
        }
    }
}

fn install_command(positionals: &[String], options: &CliOptions) -> Result<(), ManagerError> {
    reject_plugin_flags(options, true, true, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage(
            "usage: cmux-tui plugin install <git-url> [--name <name>] [--force]".to_string(),
        ));
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

    let result = (|| -> Result<(), ManagerError> {
        let manifest = read_manifest(&temp_dir)?;
        let name = installed_name(&manifest, options.name.as_deref())?;
        let target = root.join(&name);
        if target.exists() && !options.force {
            return Err(ManagerError::Failure(anyhow::anyhow!(
                "plugin {name:?} is already installed at {}; use --force to replace it",
                target.display()
            )));
        }
        run_build_if_needed(&manifest, &temp_dir)?;
        let command = resolved_run_command(&manifest, &temp_dir)?;
        verify_executable(&command[0])?;
        if target.exists() {
            fs::remove_dir_all(&target)?;
        }
        fs::rename(&temp_dir, &target)?;
        println!("installed {}{} at {}", name, version_suffix(&manifest), target.display());
        println!("next: cmux-tui plugin use {name}");
        Ok(())
    })();
    if result.is_err() && temp_dir.exists() {
        let _ = fs::remove_dir_all(&temp_dir);
    }
    result
}

fn list_command(positionals: &[String], options: &CliOptions) -> Result<(), ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 1 {
        return Err(ManagerError::Usage("usage: cmux-tui plugin list [--json]".to_string()));
    }
    let plugins = installed_plugins()?;
    if options.json {
        let value = json!({
            "plugins": plugins.iter().map(plugin_json).collect::<Vec<_>>(),
        });
        println!("{}", serde_json::to_string(&value)?);
    } else {
        for plugin in plugins {
            println!(
                "{}\t{}\t{}\t{}\t{}",
                plugin.manifest.plugin.name,
                plugin.manifest.plugin.version.as_deref().unwrap_or(""),
                if plugin.selected { "selected" } else { "" },
                plugin.dir.display(),
                plugin.manifest.plugin.description.as_deref().unwrap_or("")
            );
        }
    }
    Ok(())
}

fn use_command(positionals: &[String], options: &CliOptions) -> Result<(), ManagerError> {
    reject_plugin_flags(options, false, false, true)?;
    match (positionals.len(), options.builtin) {
        (1, true) => return write_builtin_config(options),
        (2, false) => {}
        _ => {
            return Err(ManagerError::Usage(
                "usage: cmux-tui plugin use <name> | cmux-tui plugin use --builtin".to_string(),
            ));
        }
    }
    let name = &positionals[1];
    validate_plugin_name(name)?;
    let dir = install_root()?.join(name);
    if !dir.is_dir() {
        return Err(ManagerError::Failure(anyhow::anyhow!("plugin {name:?} is not installed")));
    }
    let manifest = read_manifest(&dir)?;
    let command = resolved_run_command(&manifest, &dir)?;
    verify_executable(&command[0])?;
    let cwd = canonical_path(&dir)?;
    let path = config::write_sidebar_plugin(Some(&SidebarPluginConfig {
        command,
        cwd: Some(cwd.display().to_string()),
    }))?;
    println!("using {name}; wrote {}", path.display());
    report_reload_config(options);
    Ok(())
}

fn disable_command(positionals: &[String], options: &CliOptions) -> Result<(), ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 1 {
        return Err(ManagerError::Usage("usage: cmux-tui plugin disable".to_string()));
    }
    write_builtin_config(options)
}

fn update_command(positionals: &[String], options: &CliOptions) -> Result<(), ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage("usage: cmux-tui plugin update <name>".to_string()));
    }
    let name = &positionals[1];
    validate_plugin_name(name)?;
    let dir = install_root()?.join(name);
    if !dir.is_dir() {
        return Err(ManagerError::Failure(anyhow::anyhow!("plugin {name:?} is not installed")));
    }
    run_git(["pull", "--ff-only"], None, Some(&dir))?;
    let manifest = read_manifest(&dir)?;
    run_build_if_needed(&manifest, &dir)?;
    let command = resolved_run_command(&manifest, &dir)?;
    verify_executable(&command[0])?;
    println!("updated {name}{}", version_suffix(&manifest));
    Ok(())
}

fn remove_command(positionals: &[String], options: &CliOptions) -> Result<(), ManagerError> {
    reject_plugin_flags(options, false, false, false)?;
    if positionals.len() != 2 {
        return Err(ManagerError::Usage("usage: cmux-tui plugin remove <name>".to_string()));
    }
    let name = &positionals[1];
    validate_plugin_name(name)?;
    let dir = install_root()?.join(name);
    if !dir.exists() {
        return Err(ManagerError::Failure(anyhow::anyhow!("plugin {name:?} is not installed")));
    }
    let selected = selected_plugin_cwd()?.is_some_and(|cwd| same_path(&cwd, &dir));
    fs::remove_dir_all(&dir)?;
    println!("removed {name}");
    if selected {
        let path = config::write_sidebar_plugin(None)?;
        println!("cleared sidebar.plugin in {}", path.display());
        report_reload_config(options);
    }
    Ok(())
}

fn write_builtin_config(options: &CliOptions) -> Result<(), ManagerError> {
    let path = config::write_sidebar_plugin(None)?;
    println!("using built-in sidebar; wrote {}", path.display());
    report_reload_config(options);
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
    let Ok(entries) = fs::read_dir(&root) else { return Ok(plugins) };
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
        match read_manifest(&dir) {
            Ok(manifest) => {
                let selected = selected.as_ref().is_some_and(|cwd| same_path(cwd, &dir));
                plugins.push(InstalledPlugin { manifest, dir, selected });
            }
            Err(error) => eprintln!("cmux-tui: skipping invalid plugin {}: {error}", dir.display()),
        }
    }
    plugins.sort_by(|a, b| a.manifest.plugin.name.cmp(&b.manifest.plugin.name));
    Ok(plugins)
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
    let status =
        Command::new(&build.command[0]).args(&build.command[1..]).current_dir(dir).status()?;
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

fn report_reload_config(options: &CliOptions) {
    let socket = resolve_socket(options);
    match send_reload_config(&socket) {
        Ok(()) => println!("reload-config: sent to {}", socket.display()),
        Err(error) => {
            println!(
                "reload-config: not sent to {} ({error}); run cmux-tui reload-config",
                socket.display()
            );
        }
    }
}

fn send_reload_config(socket: &Path) -> anyhow::Result<()> {
    let mut stream = transport::connect(socket)?;
    let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
    stream.write_all(br#"{"id":1,"cmd":"reload-config"}"#)?;
    stream.write_all(b"\n")?;
    let mut reader = BufReader::new(stream);
    loop {
        let mut line = String::new();
        let bytes = reader.read_line(&mut line)?;
        if bytes == 0 {
            anyhow::bail!("transport closed before response");
        }
        let value: Value = serde_json::from_str(&line)?;
        if value.get("event").is_some() {
            continue;
        }
        if value.get("ok").and_then(Value::as_bool) == Some(true) {
            return Ok(());
        }
        let error = value.get("error").and_then(Value::as_str).unwrap_or("unknown error");
        anyhow::bail!("{error}");
    }
}

fn resolve_socket(options: &CliOptions) -> PathBuf {
    if let Some(socket) = &options.socket {
        return socket.clone();
    }
    for name in ["CMUX_TUI_SOCKET", "CMUX_MUX_SOCKET"] {
        if let Some(socket) = std::env::var_os(name)
            && !socket.is_empty()
        {
            return PathBuf::from(socket);
        }
    }
    cmux_tui_core::server::default_socket_path(options.session.as_deref().unwrap_or("main"))
}

fn plugin_json(plugin: &InstalledPlugin) -> Value {
    json!({
        "name": &plugin.manifest.plugin.name,
        "version": &plugin.manifest.plugin.version,
        "description": &plugin.manifest.plugin.description,
        "dir": plugin.dir.display().to_string(),
        "selected": plugin.selected,
    })
}

fn version_suffix(manifest: &PluginManifest) -> String {
    manifest.plugin.version.as_ref().map(|version| format!(" {version}")).unwrap_or_default()
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
}
