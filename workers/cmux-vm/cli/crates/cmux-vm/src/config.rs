//! Resolves the API key, base URL and team. Precedence for each value: flag,
//! then environment variable, then config file, then default. The API key has
//! no flag so it never lands in shell history or a process listing.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::CliError;

pub struct Settings {
    pub api_key: String,
    pub base_url: String,
    pub team_id: Option<String>,
}

/// `vm.json`. Unknown keys are ignored so newer files work with older CLIs.
#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ConfigFile {
    api_key: Option<String>,
    base_url: Option<String>,
    team_id: Option<String>,
}

impl Settings {
    pub fn resolve(
        base_url_flag: Option<&str>,
        team_flag: Option<&str>,
        config_flag: Option<&Path>,
        env: &dyn Fn(&str) -> Option<String>,
    ) -> Result<Self, CliError> {
        let env = |name: &str| env(name).filter(|v| !v.is_empty());
        let file = load_config(config_flag, &env)?;

        let api_key = env("CMUX_VM_API_KEY").or(file.api_key).ok_or_else(|| {
            CliError::unauthenticated(
                "no API key: set CMUX_VM_API_KEY or \"apiKey\" in the config file",
            )
        })?;
        let base_url = base_url_flag
            .map(str::to_owned)
            .or_else(|| env("CMUX_VM_BASE_URL"))
            .or(file.base_url)
            .unwrap_or_else(|| cmux_vm_client::DEFAULT_BASE_URL.to_owned());
        let team_id = team_flag
            .map(str::to_owned)
            .or_else(|| env("CMUX_VM_TEAM_ID"))
            .or(file.team_id);
        Ok(Self {
            api_key,
            base_url,
            team_id,
        })
    }
}

/// An explicitly named file (flag or `CMUX_VM_CONFIG`) must exist; the
/// default location is optional.
fn load_config(
    config_flag: Option<&Path>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<ConfigFile, CliError> {
    let explicit = config_flag
        .map(Path::to_path_buf)
        .or_else(|| env("CMUX_VM_CONFIG").map(PathBuf::from));
    let path = match explicit {
        Some(path) => path,
        None => match default_config_path(env) {
            Some(path) if path.is_file() => path,
            _ => return Ok(ConfigFile::default()),
        },
    };
    let text = std::fs::read_to_string(&path)
        .map_err(|e| CliError::usage(format!("read config {}: {e}", path.display())))?;
    serde_json::from_str(&text)
        .map_err(|e| CliError::usage(format!("parse config {}: {e}", path.display())))
}

fn default_config_path(env: &dyn Fn(&str) -> Option<String>) -> Option<PathBuf> {
    let base = env("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(base.join("cmux").join("vm.json"))
}
