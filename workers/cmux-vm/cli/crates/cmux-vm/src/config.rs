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
    /// Problems that did not stop the command, for stderr.
    pub warnings: Vec<String>,
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
        let mut warnings = Vec::new();
        let file = match load_config(config_flag, &env) {
            Ok(file) => file,
            // A broken file at the default location only matters when it is
            // needed: if the flags and environment already give the key and
            // the base URL, warn and go on without it.
            Err(ConfigError::Default(message))
                if env("CMUX_VM_API_KEY").is_some()
                    && (base_url_flag.is_some() || env("CMUX_VM_BASE_URL").is_some()) =>
            {
                warnings.push(format!("ignoring the config file: {message}"));
                ConfigFile::default()
            }
            Err(ConfigError::Default(message) | ConfigError::Explicit(message)) => {
                return Err(CliError::usage(message));
            }
        };

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
        if let Some(team) = &team_id
            && (team.is_empty() || team.chars().count() > 128)
        {
            return Err(CliError::usage("the team id must be 1 to 128 characters"));
        }
        Ok(Self {
            api_key,
            base_url,
            team_id,
            warnings,
        })
    }
}

enum ConfigError {
    /// The file named by `--config` or `CMUX_VM_CONFIG` is missing or broken.
    Explicit(String),
    /// The file at the default location exists but cannot be read or parsed.
    Default(String),
}

/// An explicitly named file (flag or `CMUX_VM_CONFIG`) must exist; the
/// default location is optional.
fn load_config(
    config_flag: Option<&Path>,
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<ConfigFile, ConfigError> {
    let explicit = config_flag
        .map(Path::to_path_buf)
        .or_else(|| env("CMUX_VM_CONFIG").map(PathBuf::from));
    let (path, wrap): (PathBuf, fn(String) -> ConfigError) = match explicit {
        Some(path) => (path, ConfigError::Explicit),
        None => match default_config_path(env) {
            Some(path) if path.is_file() => (path, ConfigError::Default),
            _ => return Ok(ConfigFile::default()),
        },
    };
    let text = std::fs::read_to_string(&path)
        .map_err(|e| wrap(format!("read config {}: {e}", path.display())))?;
    serde_json::from_str(&text).map_err(|e| wrap(format!("parse config {}: {e}", path.display())))
}

fn default_config_path(env: &dyn Fn(&str) -> Option<String>) -> Option<PathBuf> {
    let base = env("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env("HOME").map(|home| PathBuf::from(home).join(".config")))?;
    Some(base.join("cmux").join("vm.json"))
}

#[cfg(test)]
mod tests {
    use super::Settings;

    #[test]
    fn the_default_base_url_is_the_production_cmux_dev_host() {
        // Only the key is set: no flag, no CMUX_VM_BASE_URL, no config file
        // (HOME points to a directory without one).
        let env = |name: &str| match name {
            "CMUX_VM_API_KEY" => Some("cmuxvm_sk_test".to_owned()),
            "HOME" => Some("/nonexistent-cmux-vm-home".to_owned()),
            _ => None,
        };
        let settings = Settings::resolve(None, None, None, &env).expect("resolve");
        assert_eq!(settings.base_url, "https://vm.cmux.dev");
    }
}
