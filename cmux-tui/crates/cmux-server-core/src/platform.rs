//! Install mode, target platform and a path type for the target platform.
//!
//! Paths are built as strings with the target's separator, so a Linux test
//! (or the Linux control plane) can compute a Windows layout exactly.

use std::fmt;

/// `user`: no root, runs as the installing user. `system`: root once, a
/// dedicated service user and per-app OS users (server.md 2).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum InstallMode {
    User,
    System,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Platform {
    Linux,
    MacOs,
    Windows,
}

impl Platform {
    pub fn separator(self) -> char {
        match self {
            Platform::Windows => '\\',
            Platform::Linux | Platform::MacOs => '/',
        }
    }

    /// File name of the `cmux` binary on this platform.
    pub fn cmux_exe(self) -> &'static str {
        match self {
            Platform::Windows => "cmux.exe",
            Platform::Linux | Platform::MacOs => "cmux",
        }
    }

    /// True when `path` is absolute on this platform. Windows accepts a drive
    /// path (`C:\…`) or a UNC path (`\\server\share`).
    pub fn is_absolute(self, path: &str) -> bool {
        match self {
            Platform::Linux | Platform::MacOs => path.starts_with('/'),
            Platform::Windows => {
                let bytes = path.as_bytes();
                let drive = bytes.len() >= 3
                    && bytes[0].is_ascii_alphabetic()
                    && bytes[1] == b':'
                    && (bytes[2] == b'\\' || bytes[2] == b'/');
                drive || path.starts_with("\\\\")
            }
        }
    }
}

/// An absolute path on a target platform, kept as a string.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct HostPath {
    platform: Platform,
    path: String,
}

impl HostPath {
    /// Accepts an absolute path without NUL, newline or carriage return.
    /// Trailing separators are removed (except for a root).
    pub fn new(platform: Platform, path: &str) -> Option<HostPath> {
        if !platform.is_absolute(path) || path.contains(['\0', '\n', '\r']) {
            return None;
        }
        let sep = platform.separator();
        let mut path =
            if platform == Platform::Windows { path.replace('/', "\\") } else { path.to_owned() };
        while path.len() > 1 && path.ends_with(sep) && !is_windows_drive_root(platform, &path) {
            path.pop();
        }
        Some(HostPath { platform, path })
    }

    /// A Unix path that is absolute by construction: a literal that starts
    /// with `/`, or `/` followed by literals and numeric ids. Skips the
    /// `Option` of [`HostPath::new`]; `debug_assert` and the layout tests
    /// check that `new` would accept it unchanged.
    pub(crate) fn unix_absolute(platform: Platform, path: String) -> HostPath {
        debug_assert!(
            platform != Platform::Windows
                && HostPath::new(platform, &path).is_some_and(|checked| checked.path == path),
            "not a clean absolute Unix path: {path:?}"
        );
        HostPath { platform, path }
    }

    pub fn platform(&self) -> Platform {
        self.platform
    }

    pub fn as_str(&self) -> &str {
        &self.path
    }

    /// Appends relative components separated by `/`. Each component must be
    /// non-empty, not `.` or `..`, and free of either separator; callers
    /// pass literals or validated ids.
    ///
    /// # Panics
    ///
    /// On a component that breaks these rules.
    pub fn join(&self, relative: &str) -> HostPath {
        let sep = self.platform.separator();
        let mut path = self.path.clone();
        for part in relative.split('/') {
            assert!(
                !part.is_empty() && part != "." && part != ".." && !part.contains(['/', '\\']),
                "HostPath::join takes clean relative components, got {relative:?}"
            );
            if !path.ends_with(sep) {
                path.push(sep);
            }
            path.push_str(part);
        }
        HostPath { platform: self.platform, path }
    }
}

fn is_windows_drive_root(platform: Platform, path: &str) -> bool {
    platform == Platform::Windows && path.len() == 3 && path.as_bytes()[1] == b':'
}

impl fmt::Display for HostPath {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.path)
    }
}
