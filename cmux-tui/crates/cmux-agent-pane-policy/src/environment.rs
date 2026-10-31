//! Where the host's acpmux daemon lives (CmuxNextAgentPane
//! AcpmuxEnvironment.swift; same rule as `cmux acp`, cmux-tui `acp.rs`
//! `build_home`): `ACPMUX_HOME` wins, else the build's own home
//! ([`BuildIdentity::acpmux_home`]: `~/.acpmux` for NIGHTLY and outside any
//! build, `~/.acpmux/builds/<key>` for every other build). A daemon in a
//! home other than `~/.acpmux` listens on an ephemeral port. `ACPMUX_SOCKET`
//! counts only with an explicit `ACPMUX_HOME`: inherited alone (an app
//! launched from another cmux's terminal), it is another daemon's socket.

use std::collections::{BTreeMap, HashSet};
use std::path::{Path, PathBuf};

use crate::build_identity::BuildIdentity;

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

/// A variable of `environment`. Windows: names are case-insensitive (the
/// system keeps `Path`, for example), so another spelling matches too.
fn variable<'a>(environment: &'a BTreeMap<String, String>, name: &str) -> Option<&'a String> {
    environment.get(name).or_else(|| {
        if cfg!(windows) {
            environment.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v)
        } else {
            None
        }
    })
}

/// The environment of `build` (None: outside any build), or None when no
/// `acpmux` executable exists.
pub fn resolve(
    build: Option<&BuildIdentity>,
    bundled_bin_directory: Option<&Path>,
    environment: &BTreeMap<String, String>,
    user_home: &Path,
    uid: u32,
    is_executable: impl Fn(&Path) -> bool,
) -> Option<Environment> {
    let executable = executable_candidates(bundled_bin_directory, environment, user_home)
        .into_iter()
        .find(|p| is_executable(p))?;
    let own_home = build.map(|build| build.acpmux_home(user_home));
    let root = user_home.join(".acpmux");
    let shared = own_home.as_ref().is_none_or(|home| *home == user_home.join(".acpmux"));
    let custom_home = variable(environment, "ACPMUX_HOME")
        .filter(|h| !h.is_empty())
        .filter(|h| !inherits_another_builds_home(h, own_home.as_deref(), &root));
    let home = match custom_home {
        Some(custom) => PathBuf::from(custom),
        None => own_home.unwrap_or_else(|| root.clone()),
    };
    let configured = custom_home
        .and(variable(environment, "ACPMUX_SOCKET"))
        .map(String::as_str)
        .filter(|s| !s.is_empty());
    let socket = platform_socket_path(configured, &home, uid, environment, user_home);
    let home_text = home.to_string_lossy().into_owned();
    Some(Environment {
        executable,
        daemon_arguments: if !shared {
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

/// Whether `ACPMUX_HOME` (`custom`) names another build's home while this
/// build has a home of its own: the shared root (NIGHTLY's `~/.acpmux`) or
/// another `<root>/builds/<key>`. Every agent shell under acpmux exports its
/// daemon's home, so a tagged DEV app launched from one inherits it; honoring
/// it handed NIGHTLY's daemon off to the DEV build's (cmux#29050). A home
/// outside the root (a Chief brain's, a test's) still wins.
pub fn inherits_another_builds_home(custom: &str, own_home: Option<&Path>, root: &Path) -> bool {
    let Some(own) = own_home else { return false };
    let own = normalize(own);
    let root = normalize(root);
    if own == root {
        return false;
    }
    let path = normalize(Path::new(custom));
    path != own && (path == root || path.starts_with(root.join("builds")))
}

/// `path` without `.`, `..` or a trailing separator (no filesystem access).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
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
        variable(environment, "PATH")
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

/// The longest Unix socket path every host can bind: macOS's `sun_path` less
/// its NUL (Linux allows 107). One limit, so every platform resolves alike.
pub const MAX_SOCKET_PATH_BYTES: usize = 103;

/// The acpmux daemon socket every host and client resolves (acpmux
/// `config::socket_path()`, cmux-tui `acp.rs`, AcpmuxEnvironment.swift, the
/// brain host's `acpmuxSocketPath`, the Chief's `socket_path`; the shared
/// cases are tests/cases/environment.json). `configured` (`ACPMUX_SOCKET`)
/// when set, except an absolute path past [`MAX_SOCKET_PATH_BYTES`] (a long
/// TMPDIR), which maps to `/tmp/acpmux-<uid>/<fnv1a64(path)>.sock`; else
/// [`default_socket_path`] for `home`.
pub fn socket_path(configured: Option<&str>, home: &Path, uid: u32) -> String {
    match configured {
        Some(configured)
            if configured.starts_with('/') && configured.len() > MAX_SOCKET_PATH_BYTES =>
        {
            short_alias(configured, uid)
        }
        Some(configured) => configured.to_owned(),
        None => default_socket_path(home, uid),
    }
}

/// `/tmp/acpmux-<uid>/<fnv1a64(key)>.sock`, the per-user directory acpmux
/// creates 0700 before it binds there.
fn short_alias(key: &str, uid: u32) -> String {
    format!("/tmp/acpmux-{uid}/{:016x}.sock", fnv1a64(key))
}

/// acpmux `config::socket_path()` without its directory check:
/// `<home>/acpmux.sock`, or `/tmp/acpmux-<uid>/<fnv1a64(home)>.sock` when that
/// is 96 bytes or longer.
pub fn default_socket_path(home: &Path, uid: u32) -> String {
    let preferred = home.join("acpmux.sock").to_string_lossy().into_owned();
    if preferred.len() < 96 {
        return preferred;
    }
    short_alias(&home.to_string_lossy(), uid)
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

/// The daemon's socket on this platform: [`socket_path`] on Unix; on Windows
/// acpmux's own rule (`configured` as given, else
/// [`default_socket_path_windows`]).
fn platform_socket_path(
    configured: Option<&str>,
    home: &Path,
    uid: u32,
    environment: &BTreeMap<String, String>,
    user_home: &Path,
) -> String {
    if !cfg!(windows) {
        return socket_path(configured, home, uid);
    }
    if let Some(configured) = configured {
        return configured.to_owned();
    }
    // GetTempPath's order: TMP, TEMP, then the profile's own temp folder.
    let temp = ["TMP", "TEMP"]
        .iter()
        .find_map(|k| variable(environment, k).filter(|v| !v.is_empty()).map(PathBuf::from))
        .unwrap_or_else(|| user_home.join("AppData").join("Local").join("Temp"));
    default_socket_path_windows(home, &temp)
}

pub fn fnv1a64(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    hash
}

/// `BuildIdentity`'s tag rule (`build_identity::tag_slug`): lowercase, runs of anything outside
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
