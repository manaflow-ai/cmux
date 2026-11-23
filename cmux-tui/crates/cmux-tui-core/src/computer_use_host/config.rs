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
//! On macOS the app also sends the policy (`computer-use-config`); a trusted
//! owner file still wins over it (`server/computer_use_command.rs`), for the
//! worker the daemon runs itself (Release and NIGHTLY builds).

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
    // Any case ("Refuse" in a managed profile); a value that is not a mode,
    // a string or not (null, false, a number), keeps menus closed rather
    // than open: a typo never loosens the setting (as MenuMode reads).
    if let Some(value) = section.get("menus") {
        use cmux_computer_use::menus::MenuMode;
        config.menus = value
            .as_str()
            .and_then(|text| MenuMode::parse(&text.trim().to_ascii_lowercase()))
            .unwrap_or(MenuMode::Refuse);
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
    if let Some(value) = flag("whileLocked") {
        config.while_locked = value;
    }
    if let Some(value) = flag("alerts") {
        config.alerts = value;
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
#[path = "config_tests.rs"]
mod tests;
