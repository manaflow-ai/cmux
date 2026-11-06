//! The Computer Use policy the worker runs with, in order of authority:
//!
//! 1. The machine owner's file, `/etc/cmux/computer-use.json` or
//!    `%ProgramData%\cmux\computer-use.json` (a `PolicyConfig`; cmux cloud
//!    images write `PolicyConfig::cloud_vm()` there). It wins whole, and is
//!    read only when root (or SYSTEM / Administrators) owns it and no other
//!    user can write it: a file the person or an agent could write would let
//!    an agent raise its own access.
//! 2. The person's settings (`computerUse.*` in cmux.json), read through the
//!    daemon's settings owner.
//! 3. [`PolicyConfig::default`] for every key neither sets.
//!
//! On macOS the app sends the policy (`computer-use-config`) and this file's
//! owner path is not used.

use std::path::{Path, PathBuf};

use cmux_computer_use::policy::{Mode, PolicyConfig};
use serde_json::Value;

/// The owner file for this platform.
pub(crate) fn owner_path() -> PathBuf {
    #[cfg(windows)]
    {
        let base = std::env::var_os("ProgramData")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData"));
        base.join("cmux").join("computer-use.json")
    }
    #[cfg(not(windows))]
    {
        PathBuf::from("/etc/cmux/computer-use.json")
    }
}

/// The policy from the settings' effective root (`computerUse.*`).
pub(crate) fn from_settings(root: &Value) -> PolicyConfig {
    let mut config = PolicyConfig::default();
    let Some(section) = root.get("computerUse").and_then(Value::as_object) else { return config };
    if let Some(mode) = section.get("mode").and_then(Value::as_str).and_then(Mode::parse) {
        config.mode = mode;
    }
    if let Some(list) = section.get("deniedApps").and_then(Value::as_array) {
        config.denied_apps = list.iter().filter_map(Value::as_str).map(str::to_string).collect();
    }
    let flag = |key: &str| section.get(key).and_then(Value::as_bool);
    if let Some(value) = flag("allowOwnMachines") {
        config.allow_own_machines = value;
    }
    if let Some(value) = flag("pauseOnTakeover") {
        config.pause_on_takeover = value;
    }
    if let Some(value) = flag("allowForeground") {
        config.allow_foreground = value;
    }
    if let Some(value) = flag("showCursor") {
        config.show_cursor = value;
    }
    config
}

/// Where the policy came from, for status.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum Source {
    Owner(PathBuf),
    Settings,
    /// The app pushed it (`computer-use-config`).
    App,
}

impl Source {
    pub(crate) fn describe(&self) -> String {
        match self {
            Source::Owner(path) => format!("owner file {}", path.display()),
            Source::Settings => "settings".into(),
            Source::App => "app".into(),
        }
    }
}

/// The owner file's policy, when it exists, is trusted and parses. A file
/// that exists but is untrusted or broken is reported and ignored (the
/// person's settings apply).
pub(crate) fn read_owner(path: &Path) -> Result<Option<PolicyConfig>, String> {
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(format!("{}: {error}", path.display())),
    };
    trusted(path)?;
    serde_json::from_slice::<PolicyConfig>(&bytes)
        .map(Some)
        .map_err(|error| format!("{}: {error}", path.display()))
}

/// Root owns the file and every directory above it, and only root can write them.
#[cfg(unix)]
pub(crate) fn trusted(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::MetadataExt;
    let mut current = Some(path);
    while let Some(entry) = current {
        let meta =
            std::fs::symlink_metadata(entry).map_err(|e| format!("{}: {e}", entry.display()))?;
        if entry == path && !meta.is_file() {
            return Err(format!("{} is not a regular file", path.display()));
        }
        if meta.uid() != 0 {
            return Err(format!("{} is not owned by root", entry.display()));
        }
        // Group or other write; a sticky directory (like /tmp) is still writable by others.
        if meta.mode() & 0o022 != 0 {
            return Err(format!("{} is writable by other users", entry.display()));
        }
        current = entry.parent().filter(|p| !p.as_os_str().is_empty());
    }
    Ok(())
}

#[cfg(windows)]
pub(crate) fn trusted(path: &Path) -> Result<(), String> {
    super::platform::owner_only_file(path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn settings_keys_map_to_the_policy_and_missing_keys_keep_defaults() {
        let config = from_settings(&json!({"computerUse": {
            "mode": "approvedApps", "deniedApps": ["com.example.*"], "allowForeground": true,
            "showCursor": false
        }}));
        assert_eq!(config.mode, Mode::ApprovedApps);
        assert_eq!(config.denied_apps, ["com.example.*"]);
        assert!(config.allow_foreground && !config.show_cursor);
        assert!(config.pause_on_takeover && config.allow_own_machines);
        assert_eq!(from_settings(&json!({})), PolicyConfig::default());
        // An unknown mode keeps the default, never something wider than asked.
        assert_eq!(from_settings(&json!({"computerUse": {"mode": "god"}})).mode, Mode::FullAccess);
    }

    #[cfg(unix)]
    #[test]
    fn an_owner_file_the_user_can_write_is_refused() {
        let dir = std::env::temp_dir().join(format!("cu-owner-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("computer-use.json");
        std::fs::write(&path, serde_json::to_vec(&PolicyConfig::cloud_vm()).unwrap()).unwrap();
        // SAFETY: plain call.
        if unsafe { libc::geteuid() } != 0 {
            let error = read_owner(&path).unwrap_err();
            assert!(error.contains("not owned by root"), "{error}");
        }
        assert_eq!(read_owner(&dir.join("absent.json")), Ok(None));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
