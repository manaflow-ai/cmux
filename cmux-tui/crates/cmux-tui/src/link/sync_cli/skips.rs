//! What a push leaves out, by name: the summary lists each skipped path with
//! a plain reason, so the person is told what stayed on this Mac instead of
//! a bare count (design/cloud.md, "Anything skipped is said, by name").

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

/// Most skipped paths a summary lists; the counts cover the rest.
pub(super) const LISTED: usize = 200;

/// Why a path was left out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Why {
    /// A `.env*` file.
    EnvFile,
    /// A private key or certificate store (`id_rsa*`, `*.pem`, `*.key`, ...).
    KeyFile,
    SymlinkInside,
    SymlinkOutside,
    /// A symlink to nothing.
    SymlinkBroken,
    /// A socket, FIFO or device.
    Special,
    NameTooLong,
    NameControl,
    NameNotUtf8,
    /// A dependency or build folder the project rebuilds on the machine.
    Heavy,
    /// The name of the sync record itself.
    Reserved,
}

impl Why {
    /// The category, a stable code the App may group by.
    pub(super) fn kind(self) -> &'static str {
        match self {
            Self::EnvFile | Self::KeyFile => "secret",
            Self::SymlinkInside | Self::SymlinkOutside | Self::SymlinkBroken => "symlink",
            Self::Special => "special",
            Self::NameTooLong | Self::NameControl | Self::NameNotUtf8 => "name",
            Self::Heavy => "heavy",
            Self::Reserved => "reserved",
        }
    }

    /// The reason in plain words.
    pub(super) fn text(self) -> &'static str {
        match self {
            Self::EnvFile => "secret: .env files are shared only on purpose",
            Self::KeyFile => "secret: key files are shared only on purpose",
            Self::SymlinkInside => "a symlink (to a place inside the folder)",
            Self::SymlinkOutside => "a symlink (to a place outside the folder)",
            Self::SymlinkBroken => "a symlink (to nothing)",
            Self::Special => "a socket, FIFO or device",
            Self::NameTooLong => "a name Linux can't hold (too long)",
            Self::NameControl => "a name Linux can't hold (control character)",
            Self::NameNotUtf8 => "a name Linux can't hold (not UTF-8)",
            Self::Heavy => "a heavy folder rebuilt on the machine",
            Self::Reserved => "the name of the sync record",
        }
    }
}

/// The paths a push left out: every one counted, the first [`LISTED`] named.
#[derive(Debug)]
pub(super) struct Skips {
    /// The pushed folder (canonical): where a symlink points is judged
    /// against it.
    top: PathBuf,
    total: u64,
    counts: BTreeMap<&'static str, u64>,
    listed: Vec<(String, Why)>,
}

impl Skips {
    pub(super) fn new(top: &Path) -> Self {
        Self { top: top.to_path_buf(), total: 0, counts: BTreeMap::new(), listed: Vec::new() }
    }

    /// `path` (relative to the folder; a folder ends in `/`) was left out.
    pub(super) fn note(&mut self, path: &str, why: Why) {
        self.total += 1;
        *self.counts.entry(why.kind()).or_default() += 1;
        if self.listed.len() < LISTED {
            self.listed.push((path.to_string(), why));
        }
    }

    /// The entry at `path` (`relative` in the folder) is not a regular file
    /// whose name the machine can hold: noted with why.
    pub(super) fn note_entry(&mut self, relative: &str, path: &Path, meta: &std::fs::Metadata) {
        let why = if meta.file_type().is_symlink() {
            match std::fs::canonicalize(path) {
                Ok(target) if target.starts_with(&self.top) => Why::SymlinkInside,
                Ok(_) => Why::SymlinkOutside,
                Err(_) => Why::SymlinkBroken,
            }
        } else if !meta.file_type().is_file() {
            Why::Special
        } else {
            unholdable(relative)
        };
        self.note(relative, why);
    }

    /// `count` more were left out without a name (`other`).
    pub(super) fn unnamed(&mut self, count: u64) {
        if count > 0 {
            self.total += count;
            *self.counts.entry("other").or_default() += count;
        }
    }

    pub(super) fn total(&self) -> u64 {
        self.total
    }

    /// `skipped_files` (`[{path, kind, why}]`, sorted by path) and
    /// `skipped_counts` (`{kind: N}`) of the summary.
    pub(super) fn json(&self) -> (Value, Value) {
        let mut listed = self.listed.clone();
        listed.sort_by(|a, b| a.0.cmp(&b.0));
        let files: Vec<Value> = listed
            .iter()
            .map(|(path, why)| json!({"path": path, "kind": why.kind(), "why": why.text()}))
            .collect();
        (Value::Array(files), json!(self.counts))
    }
}

/// Why the machine cannot hold a file named `relative` (its name has a
/// control character, else it is too long).
fn unholdable(relative: &str) -> Why {
    if relative.chars().any(char::is_control) { Why::NameControl } else { Why::NameTooLong }
}

/// Whether a file named `name` is a secret shared only on purpose: `.env*`,
/// SSH private keys, certificate stores and key files.
pub(super) fn secret(name: &str) -> Option<Why> {
    if name.starts_with(".env") {
        return Some(Why::EnvFile);
    }
    let lower = name.to_ascii_lowercase();
    let key = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"]
        .iter()
        .any(|prefix| lower.starts_with(prefix))
        || [".pem", ".p12", ".pfx", ".key"].iter().any(|suffix| lower.ends_with(suffix));
    key.then_some(Why::KeyFile)
}

/// Whether the folder `name` in `dir` is a dependency or build folder its
/// project rebuilds on the machine. The ambiguous names (`target`, `build`,
/// `dist`, `venv`, `Pods`) count only beside the file that makes them one.
pub(super) fn heavy(dir: &Path, name: &str) -> bool {
    let beside = |files: &[&str]| files.iter().any(|file| dir.join(file).is_file());
    match name {
        "node_modules" | ".venv" | "__pycache__" | ".next" | ".nuxt" | "DerivedData"
        | ".gradle" | ".tox" | ".mypy_cache" | ".pytest_cache" | ".cache" | ".turbo"
        | ".parcel-cache" => true,
        "venv" => dir.join("venv/pyvenv.cfg").is_file(),
        "Pods" => beside(&["Podfile", "Podfile.lock"]),
        "target" => beside(&["Cargo.toml", "pom.xml"]),
        "build" => beside(&[
            "package.json",
            "build.gradle",
            "build.gradle.kts",
            "settings.gradle",
            "settings.gradle.kts",
            "setup.py",
            "pyproject.toml",
        ]),
        "dist" => beside(&["package.json", "setup.py", "pyproject.toml"]),
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::{LISTED, Skips, Why, heavy, secret};

    #[test]
    fn secrets_are_env_files_and_keys() {
        for name in [".env", ".env.local", "id_rsa", "id_ed25519.pub", "cert.PEM", "a.p12", "x.key"]
        {
            assert!(secret(name).is_some(), "{name}");
        }
        for name in ["env.txt", "README.md", "keys.rs", "pem"] {
            assert!(secret(name).is_none(), "{name}");
        }
    }

    #[test]
    fn ambiguous_heavy_names_need_the_file_that_makes_them_one() {
        let dir = tempfile::tempdir().unwrap();
        assert!(heavy(dir.path(), "node_modules"));
        assert!(!heavy(dir.path(), "target"));
        assert!(!heavy(dir.path(), "build"));
        assert!(!heavy(dir.path(), "venv"));
        std::fs::write(dir.path().join("Cargo.toml"), "").unwrap();
        std::fs::write(dir.path().join("package.json"), "{}").unwrap();
        assert!(heavy(dir.path(), "target"));
        assert!(heavy(dir.path(), "build"));
        assert!(heavy(dir.path(), "dist"));
        assert!(!heavy(dir.path(), "src"));
    }

    #[test]
    fn every_skip_is_counted_and_the_first_ones_are_named() {
        let mut skips = Skips::new(std::path::Path::new("/top"));
        for index in 0..LISTED + 5 {
            skips.note(&format!("f{index:04}"), Why::Special);
        }
        skips.note(".env", Why::EnvFile);
        assert_eq!(skips.total(), LISTED as u64 + 6);
        let (files, counts) = skips.json();
        assert_eq!(files.as_array().unwrap().len(), LISTED);
        assert_eq!(counts["special"], LISTED as u64 + 5);
        assert_eq!(counts["secret"], 1);
    }
}
