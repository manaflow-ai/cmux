use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::localization::{Catalog, Locale};

pub fn default_codex_control_socket() -> PathBuf {
    std::env::var_os("CODEX_HOME").map_or_else(
        || {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".codex/app-server-control/app-server-control.sock")
        },
        |home| PathBuf::from(home).join("app-server-control/app-server-control.sock"),
    )
}

pub fn expand_user_path(path: &Path) -> PathBuf {
    let Some(value) = path.to_str() else { return path.to_path_buf() };
    if value == "~" {
        return std::env::var_os("HOME").map_or_else(|| path.to_path_buf(), PathBuf::from);
    }
    let Some(suffix) = value.strip_prefix("~/") else { return path.to_path_buf() };
    std::env::var_os("HOME")
        .map(|home| PathBuf::from(home).join(suffix))
        .unwrap_or_else(|| path.to_path_buf())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MachineConfig {
    pub id: String,
    pub name: String,
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_file: Option<PathBuf>,
}

impl MachineConfig {
    pub fn new(name: String, url: String, token_file: Option<PathBuf>) -> Self {
        let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos();
        let process_id = std::process::id();
        Self { id: format!("{now:x}-{process_id:x}"), name, url, token_file }
    }

    pub fn validate(&self) -> Result<()> {
        let catalog = Catalog::new(Locale::detect());
        if self.name.trim().is_empty() {
            anyhow::bail!(catalog.invalid_name());
        }
        if !(self.url.starts_with("ws://")
            || self.url.starts_with("wss://")
            || self.url.starts_with("unix://"))
        {
            anyhow::bail!(catalog.invalid_url());
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default)]
    pub machines: Vec<MachineConfig>,
}

#[derive(Debug, Clone)]
pub struct ConfigStore {
    path: PathBuf,
}

impl ConfigStore {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn default_path() -> PathBuf {
        if let Some(root) = std::env::var_os("XDG_CONFIG_HOME") {
            return PathBuf::from(root).join("cmux-tree/config.json");
        }
        std::env::var_os("HOME").map_or_else(
            || PathBuf::from(".config/cmux-tree/config.json"),
            |root| PathBuf::from(root).join(".config/cmux-tree/config.json"),
        )
    }

    pub fn load(&self) -> Result<Config> {
        let catalog = Catalog::new(Locale::detect());
        match fs::read_to_string(&self.path) {
            Ok(contents) => {
                let config: Config = serde_json::from_str(&contents)
                    .with_context(|| catalog.invalid_config(&self.path.display().to_string()))?;
                for machine in &config.machines {
                    machine.validate().with_context(|| {
                        catalog
                            .invalid_machine_config(&machine.name, &self.path.display().to_string())
                    })?;
                }
                Ok(config)
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Config::default()),
            Err(error) => {
                Err(error).with_context(|| catalog.read_config(&self.path.display().to_string()))
            }
        }
    }

    pub fn save(&self, config: &Config) -> Result<()> {
        let catalog = Catalog::new(Locale::detect());
        if let Some(parent) = self.path.parent() {
            fs::create_dir_all(parent)
                .with_context(|| catalog.create_config_directory(&parent.display().to_string()))?;
        }
        let bytes = serde_json::to_vec_pretty(config).context(catalog.serialize_config())?;
        let temporary_path = self.path.with_extension(format!("json.{}.tmp", std::process::id()));
        fs::write(&temporary_path, bytes)
            .with_context(|| catalog.write_config(&temporary_path.display().to_string()))?;
        restrict_to_owner(&temporary_path)?;
        fs::rename(&temporary_path, &self.path)
            .with_context(|| catalog.replace_config(&self.path.display().to_string()))?;
        Ok(())
    }
}

#[cfg(unix)]
fn restrict_to_owner(path: &Path) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;

    let catalog = Catalog::new(Locale::detect());
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
        .with_context(|| catalog.set_config_permissions(&path.display().to_string()))
}

#[cfg(not(unix))]
fn restrict_to_owner(_path: &Path) -> Result<()> {
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn machine_validation_accepts_supported_app_server_transports() {
        for url in [
            "ws://127.0.0.1:4500",
            "wss://codex.example.test/app-server",
            "unix:///tmp/codex-app-server.sock",
        ] {
            let machine = MachineConfig::new("dev".into(), url.into(), None);
            assert!(machine.validate().is_ok());
        }
    }

    #[test]
    fn config_round_trips_token_file_without_token_contents() {
        let config = Config {
            machines: vec![MachineConfig {
                id: "machine-1".into(),
                name: "studio".into(),
                url: "ws://studio:4500".into(),
                token_file: Some(PathBuf::from("/run/secrets/codex-token")),
            }],
        };
        let encoded = serde_json::to_string(&config).unwrap();
        let decoded: Config = serde_json::from_str(&encoded).unwrap();

        assert_eq!(decoded, config);
        assert!(!encoded.contains("Bearer "));
    }
}
