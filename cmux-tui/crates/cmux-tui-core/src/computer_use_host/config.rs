//! The Computer Use policy the worker runs with, in order of authority:
//!
//! 1. The machine owner's file, `/etc/cmux/computer-use.json` or
//!    `%ProgramData%\cmux\computer-use.json` (a `PolicyConfig`). It wins
//!    whole, and is read only when root (or SYSTEM / Administrators) owns it
//!    and no other user can write it, so the machine's owner (a Cloud image,
//!    an admin) can set a policy the person's account cannot change.
//! 2. The person's settings (`computerUse.*` in cmux.json), read through the
//!    daemon's settings owner. That file, like the worker's saved approvals,
//!    is the person's own: an agent running as the person with a shell can
//!    edit it. The policy guards against agents acting by mistake through the
//!    Computer Use tools, not against code that already runs as the person
//!    (the same-user limit, docs/computer-use/README.md "Trust").
//! 3. For every key neither sets: [`PolicyConfig::cloud_vm`] on a cmux Cloud
//!    VM (unrestricted: nobody else uses its desktop), else
//!    [`PolicyConfig::default`]. A Cloud VM is a Linux machine with the
//!    root-owned image stamp `/etc/cmux/image-stamp` that every Cloud image
//!    bake writes (`cmux-vm ...` or `cmux-devbox ...`; the same stamp the
//!    daemon trusts for `fs-v1`, cmux-tui `link/cloud_fs.rs`).
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

/// The image stamp every cmux Cloud image bake writes as root.
pub(crate) const CLOUD_IMAGE_STAMP: &str = "/etc/cmux/image-stamp";
const CLOUD_STAMP_PREFIXES: [&str; 2] = ["cmux-vm ", "cmux-devbox "];

/// The defaults for keys the settings leave out: unrestricted on a cmux Cloud VM.
pub(crate) fn base_policy() -> PolicyConfig {
    if cfg!(target_os = "linux") && cloud_stamp(Path::new(CLOUD_IMAGE_STAMP)) {
        PolicyConfig::cloud_vm()
    } else {
        PolicyConfig::default()
    }
}

/// True when `stamp` is a trusted (root-owned, not writable by others) Cloud
/// image stamp: a normal user or an agent cannot plant one to widen access.
pub(crate) fn cloud_stamp(stamp: &Path) -> bool {
    if trusted(stamp).is_err() {
        return false;
    }
    let Ok(file) = std::fs::File::open(stamp) else { return false };
    let mut text = String::new();
    if std::io::Read::read_to_string(&mut std::io::Read::take(file, 4096), &mut text).is_err() {
        return false;
    }
    CLOUD_STAMP_PREFIXES.iter().any(|prefix| text.starts_with(prefix))
}

/// The policy from the settings' effective root (`computerUse.*`) over `base`.
pub(crate) fn from_settings(root: &Value, base: PolicyConfig) -> PolicyConfig {
    let mut config = base;
    let Some(section) = root.get("computerUse").and_then(Value::as_object) else { return config };
    if let Some(mode) = section.get("mode").and_then(Value::as_str).and_then(Mode::parse) {
        config.mode = mode;
    }
    if let Some(list) = section.get("deniedApps").and_then(Value::as_array) {
        config.denied_apps = list.iter().filter_map(Value::as_str).map(str::to_string).collect();
    }
    if let Some(settle) = section
        .get("settle")
        .and_then(Value::as_str)
        .and_then(cmux_computer_use::policy::SettleMode::parse)
    {
        config.settle = settle;
    }
    if let Some(menus) = section
        .get("menus")
        .and_then(Value::as_str)
        .and_then(cmux_computer_use::menus::MenuMode::parse)
    {
        config.menus = menus;
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
        let config = from_settings(
            &json!({"computerUse": {
                "mode": "approvedApps", "deniedApps": ["com.example.*"], "allowForeground": true,
                "showCursor": false
            }}),
            PolicyConfig::default(),
        );
        assert_eq!(config.mode, Mode::ApprovedApps);
        assert_eq!(config.denied_apps, ["com.example.*"]);
        assert!(config.allow_foreground && !config.show_cursor);
        assert!(config.pause_on_takeover && config.allow_own_machines);
        assert_eq!(from_settings(&json!({}), PolicyConfig::default()), PolicyConfig::default());
        // An unknown mode keeps the default, never something wider than asked.
        assert_eq!(
            from_settings(&json!({"computerUse": {"mode": "god"}}), PolicyConfig::default()).mode,
            Mode::FullAccess
        );
    }

    #[test]
    fn menus_setting_maps_and_an_unknown_value_keeps_open() {
        use cmux_computer_use::menus::MenuMode;
        assert_eq!(PolicyConfig::default().menus, MenuMode::Open);
        let menus = |v: Value| {
            from_settings(&json!({"computerUse": {"menus": v}}), PolicyConfig::default()).menus
        };
        assert_eq!(menus(json!("refuse")), MenuMode::Refuse);
        assert_eq!(menus(json!("open")), MenuMode::Open);
        assert_eq!(menus(json!("sometimes")), MenuMode::Open);
        // The owner file and the app push use the camelCase key.
        let owner: PolicyConfig = serde_json::from_value(json!({"menus": "refuse"})).unwrap();
        assert_eq!(owner.menus, MenuMode::Refuse);
    }

    #[test]
    fn a_cloud_vm_starts_unrestricted_and_the_settings_still_apply() {
        // No settings: the cloud VM default (no deny list, foreground input).
        let cloud = from_settings(&json!({}), PolicyConfig::cloud_vm());
        assert_eq!(cloud, PolicyConfig::cloud_vm());
        assert!(cloud.denied_apps.is_empty() && cloud.allow_foreground && cloud.cloud_vm);
        // The person can still narrow it from their settings.
        let narrowed =
            from_settings(&json!({"computerUse": {"mode": "lookOnly"}}), PolicyConfig::cloud_vm());
        assert_eq!(narrowed.mode, Mode::LookOnly);
    }

    #[cfg(unix)]
    #[test]
    fn a_stamp_the_user_could_write_is_not_a_cloud_vm() {
        let dir = std::env::temp_dir().join(format!("cu-stamp-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let stamp = dir.join("image-stamp");
        std::fs::write(&stamp, "cmux-vm inputs=abc\n").unwrap();
        // SAFETY: plain call.
        if unsafe { libc::geteuid() } != 0 {
            assert!(!cloud_stamp(&stamp), "a user-owned stamp must not widen access");
        }
        assert!(!cloud_stamp(&dir.join("absent")));
        std::fs::remove_dir_all(dir).unwrap();
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
