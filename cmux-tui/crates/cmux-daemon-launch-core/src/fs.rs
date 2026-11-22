//! The few file system questions the launch rules ask: whether a path
//! exists, is a directory or is executable. The app's calls read the real
//! disk ([`Fs::Real`]); a golden vector names what exists ([`Fs::Fake`],
//! the `fs` field of a request), as the Swift tests injected `fileExists`.

use serde::Deserialize;
use std::collections::BTreeSet;
use std::path::Path;

/// What the file system has, in a request.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FakeFs {
    /// Paths that exist as files (not directories, not executable).
    #[serde(default)]
    pub files: BTreeSet<String>,
    /// Paths that are directories.
    #[serde(default)]
    pub dirs: BTreeSet<String>,
    /// Paths that are executable files.
    #[serde(default)]
    pub executables: BTreeSet<String>,
}

#[derive(Debug, Clone, Default)]
pub enum Fs {
    #[default]
    Real,
    Fake(FakeFs),
}

impl Fs {
    /// The request's `fs` (a fake) or the real disk.
    pub fn from_request(fake: Option<FakeFs>) -> Self {
        fake.map_or(Fs::Real, Fs::Fake)
    }

    /// `FileManager.fileExists(atPath:)`: a file or a directory.
    pub fn exists(&self, path: &str) -> bool {
        match self {
            Fs::Real => Path::new(path).exists(),
            Fs::Fake(fake) => {
                fake.files.contains(path)
                    || fake.dirs.contains(path)
                    || fake.executables.contains(path)
            }
        }
    }

    /// A directory (following a symlink).
    pub fn is_dir(&self, path: &str) -> bool {
        match self {
            Fs::Real => Path::new(path).is_dir(),
            Fs::Fake(fake) => fake.dirs.contains(path),
        }
    }

    /// `FileManager.isExecutableFile(atPath:)`: a file with an execute bit.
    pub fn is_executable(&self, path: &str) -> bool {
        match self {
            Fs::Real => real_executable(path),
            Fs::Fake(fake) => fake.executables.contains(path),
        }
    }
}

#[cfg(unix)]
fn real_executable(path: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path)
        .is_ok_and(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn real_executable(path: &str) -> bool {
    Path::new(path).is_file()
}
