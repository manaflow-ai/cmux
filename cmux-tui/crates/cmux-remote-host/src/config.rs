//! The machine's Computer Use mode (docs/computer-use-approvals.md, "Modes"),
//! read only from configuration the box owner controls:
//!
//! - Linux: `/etc/cmux/computer-use.toml`, a regular file owned by root and not
//!   writable by group or others, in directories owned by root that no one
//!   else can write.
//! - Windows: `%ProgramData%\cmux\computer-use.toml`, owned by SYSTEM or
//!   Administrators, with write access for no one else (file and folder).
//!
//! An agent runs as the person's user and cannot change either. No file means
//! `ask`. A file that is present but not trusted, or does not parse, is an
//! error: the worker then refuses every call (fail closed).
//!
//! ```toml
//! mode = "ask"                 # ask | standard | bounded | unrestricted
//! manifest = "/etc/cmux/computer-use.manifest.yaml"   # bounded: the owner's manifest
//! allow_terminals = []         # executables the never-asked list lets through
//!
//! # unrestricted needs upstream's two-part opt-in, both here:
//! [environment]
//! CUA_DRIVER_PERMISSION_MODE = "unrestricted"
//! CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS = "1"
//! ```

use std::path::{Path, PathBuf};

use serde::Deserialize;

pub const PERMISSION_MODE_ENV: &str = "CUA_DRIVER_PERMISSION_MODE";
pub const BYPASS_ENV: &str = "CUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Ask,
    Standard,
    Bounded,
    Unrestricted,
}

impl Mode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ask => "ask",
            Self::Standard => "standard",
            Self::Bounded => "bounded",
            Self::Unrestricted => "unrestricted",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "ask" => Some(Self::Ask),
            "standard" => Some(Self::Standard),
            "bounded" => Some(Self::Bounded),
            "unrestricted" => Some(Self::Unrestricted),
            _ => None,
        }
    }
}

/// The owner's Computer Use configuration.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ComputerUseConfig {
    pub mode: Mode,
    /// `bounded`: the owner's capability manifest (as trusted as this file).
    pub manifest: Option<PathBuf>,
    /// Executables (paths or file names) the never-asked list lets through.
    pub allow_terminals: Vec<String>,
    /// Where it came from, for status.
    pub source: Option<PathBuf>,
}

impl Default for ComputerUseConfig {
    fn default() -> Self {
        Self { mode: Mode::Ask, manifest: None, allow_terminals: Vec::new(), source: None }
    }
}

impl ComputerUseConfig {
    /// The environment the worker sets for upstream: the two-part opt-in under
    /// `unrestricted`, nothing otherwise (the runtime's ceiling and each
    /// session's mode are constructor options). The host clears both names
    /// from everything else it passes on.
    pub fn driver_environment(&self) -> Vec<(&'static str, &'static str)> {
        match self.mode {
            Mode::Unrestricted => vec![(PERMISSION_MODE_ENV, "unrestricted"), (BYPASS_ENV, "1")],
            Mode::Ask | Mode::Standard | Mode::Bounded => Vec::new(),
        }
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawConfig {
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    manifest: Option<PathBuf>,
    #[serde(default)]
    allow_terminals: Vec<String>,
    #[serde(default)]
    environment: std::collections::BTreeMap<String, String>,
}

/// The owner's configuration file on this OS.
pub fn default_path() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("ProgramData").map(|data| PathBuf::from(data).join("cmux").join("computer-use.toml"))
    }
    #[cfg(not(windows))]
    {
        Some(PathBuf::from("/etc/cmux/computer-use.toml"))
    }
}

/// Reads the owner's configuration: `ask` when there is none, an error when it
/// is present but not trusted or not valid.
pub fn load() -> Result<ComputerUseConfig, String> {
    let Some(path) = default_path() else { return Ok(ComputerUseConfig::default()) };
    match std::fs::symlink_metadata(&path) {
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(ComputerUseConfig::default()),
        Err(error) => return Err(format!("{}: {error}", path.display())),
        Ok(_) => {}
    }
    let text = crate::platform::read_owner_file(&path)?;
    let mut config = parse(&text)?;
    if let Some(manifest) = &config.manifest {
        // The manifest is part of the owner's configuration: the same trust.
        crate::platform::read_owner_file(manifest)?;
    }
    config.source = Some(path);
    Ok(config)
}

/// Parses the file's text (trust is checked by the caller).
pub fn parse(text: &str) -> Result<ComputerUseConfig, String> {
    let raw: RawConfig = toml::from_str(text).map_err(|error| format!("computer-use.toml: {error}"))?;
    let mode = match raw.mode.as_deref() {
        None => Mode::Ask,
        Some(text) => Mode::parse(text).ok_or_else(|| format!("unknown mode {text:?}"))?,
    };
    for name in raw.environment.keys() {
        if name != PERMISSION_MODE_ENV && name != BYPASS_ENV {
            return Err(format!("[environment] may set only {PERMISSION_MODE_ENV} and {BYPASS_ENV}, not {name}"));
        }
    }
    let mode_env = raw.environment.get(PERMISSION_MODE_ENV).map(String::as_str);
    let bypass_env = raw.environment.get(BYPASS_ENV).map(String::as_str);
    match mode {
        Mode::Unrestricted => {
            if mode_env != Some("unrestricted") || bypass_env != Some("1") {
                return Err(format!(
                    "unrestricted needs both {PERMISSION_MODE_ENV} = \"unrestricted\" and {BYPASS_ENV} = \"1\" in [environment]"
                ));
            }
        }
        _ => {
            if mode_env.is_some_and(|value| value != mode.as_str()) || bypass_env.is_some() {
                return Err(format!("[environment] does not match mode {:?}", mode.as_str()));
            }
        }
    }
    if mode == Mode::Bounded && raw.manifest.is_none() {
        return Err("bounded needs manifest = \"<path>\" (cmux computer-use setup writes it)".into());
    }
    if raw.manifest.as_deref().is_some_and(|path| !path.is_absolute()) {
        return Err("manifest must be an absolute path".into());
    }
    Ok(ComputerUseConfig { mode, manifest: raw.manifest, allow_terminals: raw.allow_terminals, source: None })
}

/// Whether a file's owner and permissions make it the owner's (Unix rule,
/// shared for tests): owned by root, not writable by group or others.
pub fn unix_owner_file_ok(uid: u32, mode: u32, is_file: bool) -> bool {
    is_file && uid == 0 && mode & 0o022 == 0
}

/// The same rule for each directory on the way.
pub fn unix_owner_dir_ok(uid: u32, mode: u32) -> bool {
    uid == 0 && (mode & 0o022 == 0 || mode & 0o1000 != 0 && mode & 0o002 == 0)
}

/// Reads an owner-trusted file's text (used for the manifest by the worker).
pub fn read_trusted(path: &Path) -> Result<String, String> {
    crate::platform::read_owner_file(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_mode_is_ask() {
        assert_eq!(parse("").unwrap().mode, Mode::Ask);
    }

    #[test]
    fn unrestricted_needs_both_parts() {
        assert!(parse("mode = \"unrestricted\"").is_err());
        assert!(parse("mode = \"unrestricted\"\n[environment]\nCUA_DRIVER_PERMISSION_MODE = \"unrestricted\"").is_err());
        let config = parse(
            "mode = \"unrestricted\"\n[environment]\nCUA_DRIVER_PERMISSION_MODE = \"unrestricted\"\nCUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS = \"1\"",
        )
        .unwrap();
        assert_eq!(config.mode, Mode::Unrestricted);
        assert_eq!(config.driver_environment(), vec![(PERMISSION_MODE_ENV, "unrestricted"), (BYPASS_ENV, "1")]);
    }

    #[test]
    fn the_bypass_alone_never_unlocks_anything() {
        assert!(parse("mode = \"ask\"\n[environment]\nCUA_DRIVER_DANGEROUSLY_BYPASS_APPROVALS = \"1\"").is_err());
        assert!(parse("[environment]\nLD_PRELOAD = \"/tmp/x.so\"").is_err());
    }

    #[test]
    fn bounded_needs_an_absolute_manifest() {
        assert!(parse("mode = \"bounded\"").is_err());
        assert!(parse("mode = \"bounded\"\nmanifest = \"m.yaml\"").is_err());
        assert_eq!(parse("mode = \"bounded\"\nmanifest = \"/etc/cmux/m.yaml\"").unwrap().mode, Mode::Bounded);
    }

    /// The files `cmux computer-use setup` writes (schemas/computer-use/setup-config,
    /// which the CLI's tests render) are what this parser reads back.
    #[test]
    fn what_setup_writes_parses_back_to_the_same_config() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/computer-use/setup-config");
        let cases: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(dir.join("cases.json")).unwrap()).unwrap();
        for case in cases["cases"].as_array().unwrap() {
            let file = case["file"].as_str().unwrap();
            let config = parse(&std::fs::read_to_string(dir.join(file)).unwrap())
                .unwrap_or_else(|error| panic!("{file}: {error}"));
            assert_eq!(Some(config.mode.as_str()), case["mode"].as_str(), "{file}");
            assert_eq!(config.manifest.as_deref().and_then(Path::to_str), case["manifest"].as_str(), "{file}");
        }
    }

    #[test]
    fn only_root_owned_unwritable_files_are_trusted() {
        assert!(unix_owner_file_ok(0, 0o100644, true));
        assert!(!unix_owner_file_ok(1000, 0o100644, true));
        assert!(!unix_owner_file_ok(0, 0o100664, true));
        assert!(!unix_owner_file_ok(0, 0o100646, true));
        assert!(unix_owner_dir_ok(0, 0o40755));
        assert!(!unix_owner_dir_ok(0, 0o40777));
        assert!(!unix_owner_dir_ok(1000, 0o40755));
    }
}
