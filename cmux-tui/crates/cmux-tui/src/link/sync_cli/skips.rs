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
    /// A folder of keys and logins ([`credential`]: `.ssh`, `.aws`, `.config/gh`, ...).
    CredentialFolder,
    /// A file of tokens or passwords ([`credential`]: `.netrc`,
    /// `.cargo/credentials.toml`, ...; [`secret_at`]: a registry file with a token).
    CredentialFile,
    SymlinkInside,
    SymlinkOutside,
    /// A symlink to nothing.
    SymlinkBroken,
    /// A symlink into a repository folder (`.git` under any spelling).
    SymlinkIntoRepository,
    /// A symlink the machine's daemon is too old to make or read.
    SymlinkUnsupported,
    /// A symlink whose path the other side holds something else at.
    SymlinkTaken,
    /// A socket, FIFO or device.
    Special,
    NameTooLong,
    NameControl,
    NameNotUtf8,
    /// A dependency or build folder the project rebuilds on the machine.
    Heavy,
    /// The name of the sync record itself.
    Reserved,
    /// A pull's merge with conflict markers, kept on this Mac.
    ConflictMerge,
}

impl Why {
    /// The category, a stable code the App may group by.
    pub(super) fn kind(self) -> &'static str {
        match self {
            Self::EnvFile | Self::KeyFile | Self::CredentialFolder | Self::CredentialFile => {
                "secret"
            }
            Self::SymlinkInside
            | Self::SymlinkOutside
            | Self::SymlinkBroken
            | Self::SymlinkIntoRepository
            | Self::SymlinkUnsupported
            | Self::SymlinkTaken => "symlink",
            Self::Special => "special",
            Self::NameTooLong | Self::NameControl | Self::NameNotUtf8 => "name",
            Self::Heavy => "heavy",
            Self::Reserved | Self::ConflictMerge => "reserved",
        }
    }

    /// The reason in plain words.
    pub(super) fn text(self) -> &'static str {
        match self {
            Self::EnvFile => "secret: .env files are shared only on purpose",
            Self::KeyFile => "secret: key files are shared only on purpose",
            Self::CredentialFolder => "secret: credential folders are shared only on purpose",
            Self::CredentialFile => "secret: credential files are shared only on purpose",
            Self::SymlinkInside => "a symlink (to a place inside the folder)",
            Self::SymlinkOutside => "a symlink (to a place outside the folder)",
            Self::SymlinkBroken => "a symlink (to nothing)",
            Self::SymlinkIntoRepository => "a symlink (into the repository folder)",
            Self::SymlinkUnsupported => "a symlink (this Cloud machine is too old to make one)",
            Self::SymlinkTaken => "a symlink (something else is at its path on the other side)",
            Self::Special => "a socket, FIFO or device",
            Self::NameTooLong => "a name Linux can't hold (too long)",
            Self::NameControl => "a name Linux can't hold (control character)",
            Self::NameNotUtf8 => "a name Linux can't hold (not UTF-8)",
            Self::Heavy => "a heavy folder rebuilt on the machine",
            Self::Reserved => "the name of the sync record",
            Self::ConflictMerge => "a sync conflict's merge, kept on this Mac",
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

    /// The folder whose skips these are.
    pub(super) fn top(&self) -> &Path {
        &self.top
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
pub(super) fn unholdable(relative: &str) -> Why {
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

/// Why the untracked file at `relative` (under `top`) stays on this Mac
/// because it may hold a secret: [`secret`]'s names, plus everything the git
/// seed leaves out (`git_seed::secrets::reason`: `.netrc`, a registry file
/// with a token). One rule for a chat's copy and its seed, so a folder never
/// sends a secret on one path that the other keeps here.
pub(super) fn secret_at(top: &Path, relative: &str) -> Option<Why> {
    let name = relative.rsplit('/').next().unwrap_or(relative);
    if let Some(why) = secret(name) {
        return Some(why);
    }
    cmux_tui_core::git_seed::secrets::reason(top, relative.as_bytes()).map(|_| Why::CredentialFile)
}

/// Folders of keys and logins, as paths of one or more names, left out at
/// any depth (by case too). The same list, in the same order, as the App's
/// `AgentPaneCloudFolderRefusal.secretFolders`, which refuses home's as a
/// selected folder (a test reads that list and compares): one list for both.
/// A project's own `.cargo/` and `.docker/` stay here too.
const CREDENTIAL_FOLDERS: &[&str] = &[
    ".ssh",
    ".aws",
    ".gnupg",
    ".config/gcloud",
    ".config/gh",
    ".kube",
    ".docker",
    ".secrets",
    ".azure",
    ".cargo",
    ".gem",
    ".terraform.d",
    ".password-store",
    "Library/Keychains",
];

/// Files of tokens or passwords by name, anywhere. Home's own sit in home,
/// which the App refuses as a whole, so only a copy needs them by name.
const CREDENTIAL_NAMES: &[&str] =
    &[".netrc", "_netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass"];

/// Files of tokens by path (`.config/hub`: hub's GitHub token).
const CREDENTIAL_FILES: &[&str] = &[".config/hub"];

/// Whether the names of `names` that end at `end` (exclusive) are `path`.
fn ends_with(names: &[String], end: usize, path: &str) -> bool {
    let parts: Vec<String> = path.split('/').map(str::to_ascii_lowercase).collect();
    end.checked_sub(parts.len())
        .and_then(|start| names.get(start..end))
        .is_some_and(|tail| tail == parts.as_slice())
}

/// Whether `relative` (a folder when `folder`) is, or is in, a folder of
/// keys and logins, or is a file of tokens or passwords: never copied
/// (gh's `hosts.yml`, Cargo's `credentials.toml`, `.netrc`, ...).
pub(super) fn credential(relative: &str, folder: bool) -> Option<Why> {
    let names: Vec<String> = relative.split('/').map(str::to_ascii_lowercase).collect();
    let folders = if folder { names.len() } else { names.len().saturating_sub(1) };
    for end in 1..=folders {
        if CREDENTIAL_FOLDERS.iter().any(|path| ends_with(&names, end, path)) {
            return Some(Why::CredentialFolder);
        }
    }
    if folder {
        return None;
    }
    let last = names.last().map_or("", String::as_str);
    (CREDENTIAL_NAMES.contains(&last)
        || CREDENTIAL_FILES.iter().any(|path| ends_with(&names, names.len(), path)))
    .then_some(Why::CredentialFile)
}

/// The first of [`CREDENTIAL_FOLDERS`] under `home` that the canonical `folder` is in or holds, in any case:
/// a selected folder the App refuses too (`AgentPaneCloudFolderRefusal.secretFolder`), which
/// `cloud start-chat --from-folder` checks before any machine is made.
pub(crate) fn home_credential_folder(folder: &str, home: &str) -> Option<&'static str> {
    CREDENTIAL_FOLDERS.iter().copied().find(|relative| {
        let secret = format!("{}/{relative}", home.trim_end_matches('/'));
        within(&secret, folder) || within(folder, &secret)
    })
}

/// Whether `path` is `root` or inside it, by path components and in any case (this Mac's disk does
/// not tell `~/.SSH` from `~/.ssh`). The root `/` holds every path.
pub(crate) fn within(path: &str, root: &str) -> bool {
    let (root, path) = (root.trim_end_matches('/').to_lowercase(), path.to_lowercase());
    root.is_empty()
        || path == root
        || path.strip_prefix(&root).is_some_and(|rest| rest.starts_with('/'))
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

    /// The credential folders a copy leaves out at any depth are exactly the
    /// ones the App refuses as a selected folder
    /// (`AgentPaneCloudFolderRefusal.secretFolders`), read from its source.
    #[test]
    fn credential_folders_are_the_apps_secret_folders() {
        let swift = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
            "../../../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneCloudFolder.swift",
        );
        let source = std::fs::read_to_string(&swift).unwrap();
        let list = source
            .split("public static let secretFolders = [")
            .nth(1)
            .and_then(|rest| rest.split(']').next())
            .expect("secretFolders in AgentPaneCloudFolder.swift");
        let apps: Vec<&str> = list.split('"').skip(1).step_by(2).collect();
        assert!(!apps.is_empty());
        assert_eq!(super::CREDENTIAL_FOLDERS, apps.as_slice());
    }

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
