//! Local pairing config: `~/.config/chatmux-relay/config.json` (owner-readable,
//! normally 0600).
//!
//! Byte-level contract mirror of the JS relay (`packages/relay/bin/
//! cmux-relay.mjs` `loadConfig`/`saveConfig`): pretty-printed JSON with a
//! trailing newline, written with mode 0600. Unknown fields written by other
//! (newer or older) relay builds are preserved across load/save.

use std::fs::OpenOptions;
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};

#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

const MAX_CONFIG_BYTES: u64 = 1024 * 1024;

/// Limits shared with the server-side allowedRoots envelope policy.
pub const MAX_ALLOWED_ROOTS: usize = 32;
pub const MAX_ALLOWED_ROOT_BYTES: usize = 16 * 1024;

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

/// Runtime-only managed enrollment endpoint for session-journal forwarding.
/// The token is never persisted or included in relay wire/config output.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManagedEvents {
    pub url: String,
    pub token: String,
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
    /// Managed enrollment v2 journal endpoint. Runtime-only and secret.
    #[serde(skip)]
    pub events: Option<ManagedEvents>,
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

fn read_config(path: &Path) -> std::io::Result<Vec<u8>> {
    // Open first and validate the descriptor. On Unix, O_NOFOLLOW closes the
    // pathname-swap window between a metadata check and the read.
    #[cfg(not(unix))]
    {
        let metadata = std::fs::symlink_metadata(path)?;
        if !metadata.file_type().is_file() {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidInput,
                "relay config is not a regular file",
            ));
        }
    }
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        // A malicious replacement with a FIFO must not make startup wait for
        // a writer before the descriptor can be validated as a regular file.
        // O_NONBLOCK makes read-only FIFO opens return immediately; regular
        // files continue to use normal blocking reads.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            "relay config is not a regular file",
        ));
    }
    #[cfg(unix)]
    {
        if metadata.uid() != unsafe { libc::geteuid() } {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "relay config is not owned by the current user",
            ));
        }
        let mode = metadata.mode();
        if mode & 0o077 != 0 || mode & 0o400 == 0 {
            return Err(std::io::Error::new(
                std::io::ErrorKind::PermissionDenied,
                "relay config is not owner-readable and private",
            ));
        }
    }
    let mut bytes = Vec::new();
    file.take(MAX_CONFIG_BYTES + 1).read_to_end(&mut bytes)?;
    Ok(bytes)
}

/// Load the saved pairing, or `None` when absent/unreadable/incomplete
/// (fail-open into re-onboarding, like the JS `loadConfig`).
pub fn load_config(path: &Path) -> Option<Config> {
    let raw = read_config(path).ok()?;
    if raw.len() as u64 > MAX_CONFIG_BYTES {
        return None;
    }
    let config: Config = serde_json::from_slice(&raw).ok()?;
    if config.device_id.is_empty() || config.token.is_empty() {
        return None;
    }
    if let Some(roots) = config.allowed_roots.as_deref()
        && validate_allowed_roots(roots).is_err()
    {
        return None;
    }
    Some(config)
}

/// Load config while distinguishing a genuinely absent file from a present
/// but unsafe file. Startup uses this to avoid silently re-onboarding into an
/// unscoped session when persisted restrictions are malformed.
pub fn load_config_checked(path: &Path) -> Result<Option<Config>, String> {
    let raw = match read_config(path) {
        Ok(raw) => raw,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("could not read relay config: {error}")),
    };
    if raw.len() as u64 > MAX_CONFIG_BYTES {
        return Err("relay config exceeds the 1 MiB size limit".to_owned());
    }
    let config: Config =
        serde_json::from_slice(&raw).map_err(|error| format!("invalid relay config: {error}"))?;
    if config.device_id.is_empty() || config.token.is_empty() {
        return Err("relay config is incomplete".to_owned());
    }
    if let Some(roots) = config.allowed_roots.as_deref() {
        validate_allowed_roots(roots).map_err(str::to_owned)?;
        for root in roots {
            crate::actions::validate_request_path(root)
                .map_err(|error| format!("invalid allowed root: {error}"))?;
        }
    }
    Ok(Some(config))
}

/// Validate a local root list before it can be persisted or sent on the wire.
/// The byte budget matches the server's UTF-8 JSON value budget conservatively
/// by summing the encoded path strings, excluding JSON framing overhead.
pub fn validate_allowed_roots(roots: &[String]) -> Result<(), &'static str> {
    if roots.len() > MAX_ALLOWED_ROOTS {
        return Err("too many allowed roots (maximum is 32)");
    }
    if roots.iter().any(String::is_empty) {
        return Err("allowed roots must not be empty");
    }
    let bytes = roots.iter().try_fold(0usize, |total, root| {
        total.checked_add(root.len()).ok_or("allowed roots are too large")
    })?;
    if bytes > MAX_ALLOWED_ROOT_BYTES {
        return Err("allowed roots exceed the 16 KiB limit");
    }
    Ok(())
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
    let mut options = OpenOptions::new();
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
    let renamed = written.and_then(|()| {
        #[cfg(windows)]
        {
            use std::os::windows::ffi::OsStrExt as _;
            use windows_sys::Win32::Storage::FileSystem::{
                MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
            };
            let source: Vec<u16> = temp.as_os_str().encode_wide().chain(Some(0)).collect();
            let destination: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
            // MoveFileExW replaces the destination without a remove-then-rename gap.
            if unsafe {
                MoveFileExW(
                    source.as_ptr(),
                    destination.as_ptr(),
                    MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
                )
            } == 0
            {
                return Err(std::io::Error::last_os_error());
            }
            return Ok(());
        }
        #[cfg(not(windows))]
        std::fs::rename(&temp, path)
    });
    if renamed.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    renamed
}
