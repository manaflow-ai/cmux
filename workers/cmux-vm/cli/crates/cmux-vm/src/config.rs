//! Resolves the API key, base URL and team. Precedence for each value: flag,
//! then environment variable, then config file, then default. The API key has
//! no flag so it never lands in shell history or a process listing.

use std::path::{Path, PathBuf};

use serde::Deserialize;

use crate::error::CliError;
use crate::token::StoredToken;

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
    /// The settings, with the stored agent token (token.rs) as the credential when there is no `CMUX_VM_API_KEY` and no explicit
    /// config file (`--config`, `CMUX_VM_CONFIG`): it comes before the default
    /// config file, so a token minted for agents is what `cmux vm run` uses. An
    /// expired token is refused, never replaced by the default file's key. Its base URL and team fill in
    /// only what the flags and environment leave unset.
    pub fn resolve_with_token(
        base_url_flag: Option<&str>,
        team_flag: Option<&str>,
        config_flag: Option<&Path>,
        env: &dyn Fn(&str) -> Option<String>,
        stored: Option<&StoredToken>,
        now_unix: i64,
    ) -> Result<Self, CliError> {
        let env = |name: &str| env(name).filter(|v| !v.is_empty());
        let explicit_config = config_flag.is_some() || env("CMUX_VM_CONFIG").is_some();
        if let Some(token) = stored
            && env("CMUX_VM_API_KEY").is_none()
            && !explicit_config
        {
            let left = token.seconds_left(now_unix);
            if left.is_some_and(|left| left > 0) {
                // The key goes only to the service that minted it.
                let requested = base_url_flag
                    .map(str::to_owned)
                    .or_else(|| env("CMUX_VM_BASE_URL"));
                let base_url = token.issuer_for(requested.as_deref())?;
                let team_id = team_flag
                    .map(str::to_owned)
                    .or_else(|| env("CMUX_VM_TEAM_ID"))
                    .or_else(|| token.team_id.clone());
                return Ok(Self {
                    api_key: token.key.clone(),
                    base_url,
                    team_id,
                    warnings: Vec::new(),
                });
            }
            // Refused, never replaced by the default config file's key,
            // which may carry far more than the token's scopes and budget.
            return Err(CliError::unauthenticated(match left {
                Some(_) => format!(
                    "the stored VM token {} expired at {}: run `cmux vm token create`, or set CMUX_VM_API_KEY",
                    token.key_id, token.expires_at
                ),
                None => format!(
                    "the stored VM token {} has no readable expiry ({:?}): run `cmux vm token create`, or set CMUX_VM_API_KEY",
                    token.key_id, token.expires_at
                ),
            }));
        }
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
                "no API key: run `cmux vm token create` in a cmux terminal (the cmux app signed in to cmux, with Labs on), or set CMUX_VM_API_KEY or \"apiKey\" in the config file",
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
        let settings =
            Settings::resolve_with_token(None, None, None, &env, None, 0).expect("resolve");
        assert_eq!(settings.base_url, "https://vm.cmux.dev");
    }

    fn token(expires_at: &str) -> crate::token::StoredToken {
        crate::token::StoredToken {
            key: "cmuxvm_sk_stored".to_owned(),
            key_id: "vmk_x".to_owned(),
            expires_at: expires_at.to_owned(),
            team_id: Some("team_stored".to_owned()),
            base_url: None,
            scopes: vec![],
            max_vms: None,
            max_usd_per_hour: None,
        }
    }

    #[test]
    fn a_stored_token_is_the_credential_when_nothing_else_is_named() {
        let env = |name: &str| (name == "HOME").then(|| "/nonexistent-cmux-vm-home".to_owned());
        let stored = token("2026-10-29T08:00:00Z");
        let settings = Settings::resolve_with_token(None, None, None, &env, Some(&stored), 0)
            .expect("resolve");
        assert_eq!(settings.api_key, "cmuxvm_sk_stored");
        assert_eq!(settings.team_id.as_deref(), Some("team_stored"));
    }

    #[test]
    fn the_environment_key_wins_over_a_stored_token() {
        let env = |name: &str| match name {
            "CMUX_VM_API_KEY" => Some("cmuxvm_sk_env".to_owned()),
            "HOME" => Some("/nonexistent-cmux-vm-home".to_owned()),
            _ => None,
        };
        let stored = token("2026-10-29T08:00:00Z");
        let settings = Settings::resolve_with_token(None, None, None, &env, Some(&stored), 0)
            .expect("resolve");
        assert_eq!(settings.api_key, "cmuxvm_sk_env");
    }

    #[test]
    fn a_stored_key_is_never_sent_to_another_base_url() {
        let env = |name: &str| match name {
            "CMUX_VM_BASE_URL" => Some("https://elsewhere.example".to_owned()),
            "HOME" => Some("/nonexistent-cmux-vm-home".to_owned()),
            _ => None,
        };
        let stored = token("2026-10-29T08:00:00Z");
        let Err(error) = Settings::resolve_with_token(None, None, None, &env, Some(&stored), 0)
        else {
            panic!("the stored key resolved for another service");
        };
        assert!(
            error.message().contains("belongs to"),
            "{}",
            error.message()
        );
        let flag = Settings::resolve_with_token(
            Some("https://vm.cmux.dev"),
            None,
            None,
            &|name: &str| (name == "HOME").then(|| "/nonexistent-cmux-vm-home".to_owned()),
            Some(&stored),
            0,
        )
        .expect("its own issuer");
        assert_eq!(flag.base_url, "https://vm.cmux.dev");
    }

    #[test]
    fn an_expired_token_is_refused_by_name() {
        let env = |name: &str| (name == "HOME").then(|| "/nonexistent-cmux-vm-home".to_owned());
        let stored = token("1970-01-01T00:01:00Z");
        let Err(error) = Settings::resolve_with_token(None, None, None, &env, Some(&stored), 120)
        else {
            panic!("an expired token resolved");
        };
        assert_eq!(error.exit_code(), crate::exit::UNAUTHENTICATED);
    }
}
