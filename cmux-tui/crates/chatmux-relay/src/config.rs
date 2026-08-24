//! Local pairing config: `~/.config/chatmux-relay/config.json` (0600).
//!
//! Byte-level contract mirror of the JS relay (`packages/relay/bin/
//! cmux-relay.mjs` `loadConfig`/`saveConfig`): pretty-printed JSON with a
//! trailing newline, written with mode 0600. Unknown fields written by other
//! (newer or older) relay builds are preserved across load/save.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// Managed enrollment identity forwarded in the hello frame
/// (`ManagedRelayEnrollment` in chatmux `packages/protocol/src/relay.ts`).
#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ManagedIdentity {
    pub client: String,
    pub org_id: String,
    pub target_ref: String,
    pub generation: String,
    pub provider: String,
}

/// The saved pairing state. Field names are the wire/disk contract
/// (camelCase, same keys the JS relay writes).
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<i64>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub backend: String,
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub token: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub platform: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trust: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending_trust: Option<String>,
    /// Owner-at-keyboard YOLO receipt. Kept as raw JSON and validated
    /// field-by-field (`trust::has_yolo_confirmation`), like the JS relay:
    /// a malformed receipt must fail closed, not fail the config load.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub yolo_confirmed_at: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allowed_roots: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub owner_user_id: Option<String>,
    /// Managed sandbox identity (`--managed`). Runtime-only: managed mode
    /// never saves its config, and personal configs never carry it.
    #[serde(skip)]
    pub managed: Option<ManagedIdentity>,
    /// Managed mode: the one-shot enrollment token was accepted at least
    /// once this process lifetime. Runtime-only.
    #[serde(skip)]
    pub enrollment_claimed: bool,
    /// Unknown fields from other relay builds, preserved verbatim.
    #[serde(flatten)]
    pub extra: Map<String, Value>,
}

/// Default config path: `$XDG_CONFIG_HOME|~/.config` + `chatmux-relay/
/// config.json` (`%APPDATA%` on Windows), same as the JS relay.
pub fn default_config_path() -> PathBuf {
    if cfg!(windows) {
        let base = std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|| home_dir().join("AppData/Roaming"));
        return base.join("chatmux-relay/config.json");
    }
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| home_dir().join(".config"));
    base.join("chatmux-relay/config.json")
}

fn home_dir() -> PathBuf {
    let var = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(var).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

/// Load the saved pairing, or `None` when absent/unreadable/incomplete
/// (fail-open into re-onboarding, like the JS `loadConfig`).
pub fn load_config(path: &Path) -> Option<Config> {
    let raw = std::fs::read_to_string(path).ok()?;
    let config: Config = serde_json::from_str(&raw).ok()?;
    if config.device_id.is_empty() || config.token.is_empty() {
        return None;
    }
    Some(config)
}

/// Persist the pairing with owner-only permissions (0600 on Unix). The
/// credential is written into a fresh 0600 temp file and renamed over the
/// destination, so it never lands in a pre-existing file with looser
/// permissions and a crashed write never leaves a half-written config.
pub fn save_config(path: &Path, config: &Config) -> std::io::Result<()> {
    let parent = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent)?;
    let body =
        format!("{}\n", serde_json::to_string_pretty(config).map_err(std::io::Error::other)?);
    let temp = parent.join(format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|name| name.to_str()).unwrap_or("config.json"),
        std::process::id(),
    ));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        options.mode(0o600);
    }
    let _ = std::fs::remove_file(&temp);
    let mut file = options.open(&temp)?;
    let written = file.write_all(body.as_bytes()).and_then(|()| file.sync_all());
    drop(file);
    let renamed = written.and_then(|()| std::fs::rename(&temp, path));
    if renamed.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    renamed
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let mut path = std::env::temp_dir();
        path.push(format!("chatmux-relay-test-{}-{name}", std::process::id()));
        path
    }

    #[test]
    fn round_trips_and_preserves_unknown_fields() {
        let path = scratch("roundtrip/config.json");
        let raw = serde_json::json!({
            "version": 2,
            "backend": "https://api.chatmux.dev",
            "deviceId": "dev_abc",
            "token": "tok_abc",
            "name": "mac",
            "scope": "personal",
            "trust": "supervised",
            "futureField": {"keep": true},
        });
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&path, serde_json::to_string(&raw).unwrap()).unwrap();
        let mut config = load_config(&path).expect("valid config loads");
        assert_eq!(config.device_id, "dev_abc");
        assert_eq!(config.extra.get("futureField"), raw.get("futureField"));
        config.pending_trust = Some("observe".to_owned());
        save_config(&path, &config).unwrap();
        let saved: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(saved.get("futureField"), raw.get("futureField"));
        assert_eq!(saved.get("pendingTrust"), Some(&Value::from("observe")));
        assert_eq!(saved.get("deviceId"), Some(&Value::from("dev_abc")));
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[test]
    fn incomplete_or_invalid_config_loads_as_none() {
        let path = scratch("invalid/config.json");
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(&path, "{\"deviceId\":\"only-half\"}").unwrap();
        assert!(load_config(&path).is_none());
        std::fs::write(&path, "not json").unwrap();
        assert!(load_config(&path).is_none());
        assert!(load_config(&scratch("missing/config.json")).is_none());
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }

    #[cfg(unix)]
    #[test]
    fn saved_config_is_owner_only_even_over_a_loose_existing_file() {
        use std::os::unix::fs::PermissionsExt as _;
        let path = scratch("perms/config.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        // A pre-existing world-readable file must never receive the token.
        std::fs::write(&path, "{}").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let config = Config {
            device_id: "dev_p".to_owned(),
            token: "tok_p".to_owned(),
            ..Config::default()
        };
        save_config(&path, &config).unwrap();
        let mode = std::fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        assert!(std::fs::read_to_string(&path).unwrap().contains("dev_p"));
        std::fs::remove_dir_all(path.parent().unwrap()).ok();
    }
}
