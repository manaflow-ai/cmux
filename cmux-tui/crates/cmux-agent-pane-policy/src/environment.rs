//! Where the host's acpmux daemon lives (CmuxNextAgentPane
//! AcpmuxEnvironment.swift; same rule as `cmux acp`, cmux-tui `acp.rs`
//! `tagged_home`): `ACPMUX_HOME` wins, else a tagged dev build uses
//! `~/.acpmux/tags/<slug>`, else `~/.acpmux`. A tagged build's daemon listens
//! on an ephemeral port.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Environment {
    pub executable: PathBuf,
    pub home: PathBuf,
    pub socket_path: String,
    /// Extra `acpmux daemon run` arguments.
    pub daemon_arguments: Vec<String>,
    /// Variables the daemon and the status client must agree on.
    pub child_environment: BTreeMap<String, String>,
}

/// The usual install directories, searched after `PATH`.
#[cfg(not(windows))]
pub const INSTALL_DIRECTORIES: &[&str] =
    &["~/.local/bin", "~/.cargo/bin", "/opt/homebrew/bin", "/usr/local/bin"];
/// Windows: the per-user install directories (no system-wide Unix ones).
#[cfg(windows)]
pub const INSTALL_DIRECTORIES: &[&str] = &["~/.local/bin", "~/.cargo/bin"];

/// The executable's file name.
pub const EXECUTABLE: &str = if cfg!(windows) { "acpmux.exe" } else { "acpmux" };
/// `PATH`'s separator.
const PATH_SEPARATOR: char = if cfg!(windows) { ';' } else { ':' };

/// The environment, or None when no `acpmux` executable exists.
pub fn resolve(
    tag: Option<&str>,
    bundled_bin_directory: Option<&Path>,
    environment: &BTreeMap<String, String>,
    user_home: &Path,
    uid: u32,
    is_executable: impl Fn(&Path) -> bool,
) -> Option<Environment> {
    let executable = executable_candidates(bundled_bin_directory, environment, user_home)
        .into_iter()
        .find(|p| is_executable(p))?;
    let slug = tag.and_then(tag_slug);
    let home = match (environment.get("ACPMUX_HOME").filter(|h| !h.is_empty()), &slug) {
        (Some(custom), _) => PathBuf::from(custom),
        (None, Some(slug)) => user_home.join(".acpmux/tags").join(slug),
        (None, None) => user_home.join(".acpmux"),
    };
    let socket = environment
        .get("ACPMUX_SOCKET")
        .filter(|s| !s.is_empty())
        .cloned()
        .unwrap_or_else(|| platform_socket_path(&home, uid, environment, user_home));
    let home_text = home.to_string_lossy().into_owned();
    Some(Environment {
        executable,
        daemon_arguments: if slug.is_some() {
            vec!["--listen".into(), "127.0.0.1:0".into()]
        } else {
            Vec::new()
        },
        child_environment: BTreeMap::from([
            ("ACPMUX_HOME".into(), home_text),
            ("ACPMUX_SOCKET".into(), socket.clone()),
        ]),
        socket_path: socket,
        home,
    })
}

/// Search order: the bundled binary, then `PATH`, then the install
/// directories; each directory once.
pub fn executable_candidates(
    bundled_bin_directory: Option<&Path>,
    environment: &BTreeMap<String, String>,
    user_home: &Path,
) -> Vec<PathBuf> {
    let mut directories: Vec<String> = Vec::new();
    if let Some(bundled) = bundled_bin_directory {
        directories.push(bundled.to_string_lossy().into_owned());
    }
    directories.extend(
        environment
            .get("PATH")
            .map(String::as_str)
            .unwrap_or("")
            .split(PATH_SEPARATOR)
            .map(str::to_owned),
    );
    directories.extend(INSTALL_DIRECTORIES.iter().map(|d| match d.strip_prefix("~/") {
        Some(rest) => user_home.join(rest).to_string_lossy().into_owned(),
        None => (*d).to_owned(),
    }));
    let mut seen = HashSet::new();
    directories
        .into_iter()
        .filter(|d| !d.is_empty() && seen.insert(d.clone()))
        .map(|d| PathBuf::from(d).join(EXECUTABLE))
        .collect()
}

/// acpmux `config::socket_path()` without its directory check:
/// `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<fnv1a64(home)>.sock` when that
/// is 96 bytes or longer.
pub fn default_socket_path(home: &Path, uid: u32) -> String {
    let preferred = home.join("acpmux.sock").to_string_lossy().into_owned();
    if preferred.len() < 96 {
        return preferred;
    }
    format!("/tmp/acpmux-{uid}/{:016x}.sock", fnv1a64(&home.to_string_lossy()))
}

/// acpmux `config::socket_path()` on Windows without its folder check:
/// `<home>\acpmux.sock`, or `<temp>\acpmux\<fnv1a64(home)>.sock` when that
/// is 96 bytes or longer (AF_UNIX paths are limited to 108 bytes there too).
/// `temp` is the user's temp folder (`std::env::temp_dir()` in acpmux).
pub fn default_socket_path_windows(home: &Path, temp: &Path) -> String {
    let preferred = home.join("acpmux.sock").to_string_lossy().into_owned();
    if preferred.len() < 96 {
        return preferred;
    }
    let short = temp
        .join("acpmux")
        .join(format!("{:016x}.sock", fnv1a64(&home.to_string_lossy())))
        .to_string_lossy()
        .into_owned();
    if short.len() < 96 { short } else { preferred }
}

/// The daemon's default socket on this platform.
fn platform_socket_path(
    home: &Path,
    uid: u32,
    environment: &BTreeMap<String, String>,
    user_home: &Path,
) -> String {
    if cfg!(windows) {
        // GetTempPath's order: TMP, TEMP, then the profile's own temp folder.
        let temp = ["TMP", "TEMP"]
            .iter()
            .find_map(|k| environment.get(*k).filter(|v| !v.is_empty()).map(PathBuf::from))
            .unwrap_or_else(|| user_home.join("AppData").join("Local").join("Temp"));
        default_socket_path_windows(home, &temp)
    } else {
        default_socket_path(home, uid)
    }
}

pub fn fnv1a64(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// cmux-tui `acp.rs` `sanitize_tag`: lowercase, runs of anything outside
/// `[a-z0-9]` become one `-`, no leading or trailing `-`; None when empty.
pub fn tag_slug(raw: &str) -> Option<String> {
    let mut slug = String::with_capacity(raw.len());
    for c in raw.chars().flat_map(char::to_lowercase) {
        if c.is_ascii_lowercase() || c.is_ascii_digit() {
            slug.push(c);
        } else if !slug.ends_with('-') {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    (!slug.is_empty()).then(|| slug.to_owned())
}
