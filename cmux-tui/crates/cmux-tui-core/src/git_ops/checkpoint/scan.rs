//! What a capture or a candidate list reads from a repository: where its git
//! directories are, the index entries and HEAD (the observation a capture
//! re-verifies before it publishes), and the untracked and ignored paths.
//! Every read uses the read runner; nothing here writes.

use std::collections::HashSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use super::record::SkipCode;
use crate::git_ops::Repository;
use crate::git_ops::run::GitFailure;
use crate::resource::ResourceError;

/// Listings larger than this cannot be trusted to be complete.
const MAX_LISTING_BYTES: usize = 64 * 1024 * 1024;
const MAX_SMALL_BYTES: usize = 64 * 1024;

/// A repository's canonical git directories.
pub(super) struct Layout {
    pub git_dir: PathBuf,
    pub common_dir: PathBuf,
}

impl Layout {
    pub(super) fn locate(
        repository: &Repository,
        operation: &'static str,
    ) -> Result<Self, ResourceError> {
        let arguments = ["rev-parse", "--path-format=absolute", "--git-common-dir", "--git-dir"];
        let output = repository
            .run(&arguments, MAX_SMALL_BYTES)
            .map_err(|failure| crate::git_ops::git_failed(operation, &failure))?;
        let text = String::from_utf8_lossy(&output.stdout).into_owned();
        let mut lines = text.lines();
        let (Some(common), Some(own)) = (lines.next(), lines.next()) else {
            return Err(failed(operation, "git_failed", "git did not name its directories"));
        };
        let canonical = |path: &str| {
            fs::canonicalize(path)
                .map_err(|error| failed(operation, "git_failed", error.to_string()))
        };
        Ok(Self { git_dir: canonical(own)?, common_dir: canonical(common)? })
    }
}

/// One stage-0 index entry.
#[derive(Debug, Clone)]
pub(super) struct IndexEntry {
    pub mode: String,
    pub oid: String,
    pub path: Vec<u8>,
}

/// HEAD and the index as a capture saw them.
pub(super) struct Observation {
    pub head: Option<String>,
    pub branch: Option<String>,
    pub entries: Vec<IndexEntry>,
    /// Changes when HEAD, the branch or any index entry, flag or stage does.
    pub fingerprint: String,
}

/// Reads HEAD and the index, refusing index modes a checkpoint cannot
/// round-trip with `unsupported_index`.
pub(super) fn observe(
    repository: &Repository,
    operation: &'static str,
) -> Result<Observation, ResourceError> {
    let listing = listing(repository, &["ls-files", "-z", "-v", "-s"], operation)?;
    let mut entries = Vec::new();
    for record in records(&listing) {
        // `<tag> <mode> <oid> <stage>\t<path>`
        let Some(tab) = record.iter().position(|byte| *byte == b'\t') else { continue };
        let header = String::from_utf8_lossy(&record[..tab]).into_owned();
        let fields = header.split(' ').collect::<Vec<_>>();
        let [tag, mode, oid, stage] = fields.as_slice() else {
            return Err(failed(operation, "git_failed", "unexpected ls-files output"));
        };
        let path = record[tab + 1..].to_vec();
        let mode_name = if *stage != "0" {
            Some("unresolved stages")
        } else if *tag == "S" {
            Some("skip-worktree (sparse checkout)")
        } else if tag.chars().all(|letter| letter.is_ascii_lowercase()) {
            Some("assume-unchanged")
        } else {
            None
        };
        if let Some(mode_name) = mode_name {
            return Err(unsupported(operation, mode_name, Some(&path)));
        }
        entries.push(IndexEntry { mode: (*mode).to_string(), oid: (*oid).to_string(), path });
    }
    let shared = repository
        .run(&["rev-parse", "--shared-index-path"], MAX_SMALL_BYTES)
        .map_err(|failure| crate::git_ops::git_failed(operation, &failure))?;
    if !String::from_utf8_lossy(&shared.stdout).trim().is_empty() {
        return Err(unsupported(operation, "split index", None));
    }
    let sparse = repository.run(&["config", "--bool", "--get", "core.sparseCheckout"], 64);
    if sparse.is_ok_and(|output| String::from_utf8_lossy(&output.stdout).trim() == "true") {
        return Err(unsupported(operation, "sparse checkout", None));
    }
    if let Some(path) = intent_to_add(repository, operation)? {
        return Err(unsupported(operation, "intent-to-add", Some(&path)));
    }
    let head = repository.commit("HEAD");
    let branch = repository
        .run(&["symbolic-ref", "--quiet", "HEAD"], MAX_SMALL_BYTES)
        .ok()
        .map(|output| String::from_utf8_lossy(&output.stdout).trim().to_string())
        .and_then(|name| name.strip_prefix("refs/heads/").map(str::to_string));
    let mut hasher = Sha256::new();
    hasher.update(head.as_deref().unwrap_or("unborn").as_bytes());
    hasher.update([0]);
    hasher.update(branch.as_deref().unwrap_or("detached").as_bytes());
    hasher.update([0]);
    hasher.update(&listing);
    let fingerprint = super::store::hex(&hasher.finalize());
    Ok(Observation { head, branch, entries, fingerprint })
}

/// The first intent-to-add path: `git status` shows one as `.A`.
fn intent_to_add(
    repository: &Repository,
    operation: &'static str,
) -> Result<Option<Vec<u8>>, ResourceError> {
    let arguments = [
        "status",
        "--porcelain=v2",
        "-z",
        "--untracked-files=no",
        "--ignore-submodules=all",
        "--no-renames",
    ];
    let output = listing(repository, &arguments, operation)?;
    for record in records(&output) {
        // `1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>`; renames are off.
        if record.starts_with(b"1 ") && record.get(2..4) == Some(b".A".as_slice()) {
            let path = record.splitn(9, |byte| *byte == b' ').nth(8).unwrap_or_default();
            return Ok(Some(path.to_vec()));
        }
    }
    Ok(None)
}

/// What an untracked path is on disk.
#[derive(Debug, Clone)]
pub(super) enum Kind {
    File {
        size: u64,
        executable: bool,
        modified: Option<std::time::SystemTime>,
    },
    Symlink {
        target: Vec<u8>,
    },
    /// A folder git does not descend: a nested repository.
    Folder,
    Other,
}

#[derive(Debug, Clone)]
pub(super) struct Untracked {
    pub path: Vec<u8>,
    pub kind: Kind,
}

impl Untracked {
    pub(super) fn size(&self) -> u64 {
        match &self.kind {
            Kind::File { size, .. } => *size,
            Kind::Symlink { target } => target.len() as u64,
            Kind::Folder | Kind::Other => 0,
        }
    }

    /// Why this untracked path cannot be selected, or `None` when eligible.
    pub(super) fn ineligible(&self, max_file_bytes: u32) -> Option<SkipCode> {
        match self.kind {
            Kind::Folder => Some(SkipCode::NestedRepository),
            Kind::Other => Some(SkipCode::UnsupportedType),
            _ if credential(&self.path) => Some(SkipCode::Credential),
            _ if self.size() > u64::from(max_file_bytes) => Some(SkipCode::OverLimit),
            _ => None,
        }
    }
}

/// Untracked, nonignored paths in path order. A nested repository is one
/// entry ending with `/`.
pub(super) fn untracked(
    repository: &Repository,
    operation: &'static str,
) -> Result<Vec<Untracked>, ResourceError> {
    let arguments = ["ls-files", "-z", "--others", "--exclude-standard"];
    let output = listing(repository, &arguments, operation)?;
    let mut paths = records(&output).map(<[u8]>::to_vec).collect::<Vec<_>>();
    paths.sort();
    Ok(paths
        .into_iter()
        .map(|path| {
            let kind = if path.ends_with(b"/") {
                Kind::Folder
            } else {
                inspect(&repository.root, &path).ok().flatten().unwrap_or(Kind::Other)
            };
            Untracked { path, kind }
        })
        .collect())
}

/// Ignored paths, an ignored folder as one entry ending with `/`.
pub(super) fn ignored(
    repository: &Repository,
    operation: &'static str,
) -> Result<Vec<Vec<u8>>, ResourceError> {
    let arguments =
        ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"];
    let output = listing(repository, &arguments, operation)?;
    let mut paths = records(&output).map(<[u8]>::to_vec).collect::<Vec<_>>();
    paths.sort();
    Ok(paths)
}

/// What `relative` is on disk without following it, `None` when it is
/// absent, or the error that kept it from being read.
pub(super) fn inspect(root: &Path, relative: &[u8]) -> io::Result<Option<Kind>> {
    let path = join(root, relative);
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let file_type = metadata.file_type();
    Ok(Some(if file_type.is_symlink() {
        Kind::Symlink { target: link_target(&path)? }
    } else if file_type.is_file() {
        let modified = metadata.modified().ok();
        Kind::File { size: metadata.len(), executable: executable(&metadata), modified }
    } else if file_type.is_dir() {
        Kind::Folder
    } else {
        Kind::Other
    }))
}

/// Whether a leading folder of `relative` is not a real folder (a symlink, a
/// file or nothing): git then treats the path as deleted. `folders` caches
/// the folders already seen to be real.
pub(super) fn behind_a_link(root: &Path, relative: &[u8], folders: &mut HashSet<Vec<u8>>) -> bool {
    let mut end = 0;
    while let Some(offset) = relative[end..].iter().position(|byte| *byte == b'/') {
        end += offset;
        let prefix = &relative[..end];
        if !folders.contains(prefix) {
            let real = fs::symlink_metadata(join(root, prefix))
                .is_ok_and(|metadata| metadata.file_type().is_dir());
            if !real {
                return true;
            }
            folders.insert(prefix.to_vec());
        }
        end += 1;
    }
    false
}

/// Credential file names an untracked file is never stored under.
const CREDENTIAL_NAMES: [&str; 8] = [
    ".env",
    ".netrc",
    ".pgpass",
    ".git-credentials",
    ".npmrc",
    ".pypirc",
    "credentials",
    ".htpasswd",
];
/// SSH private keys, and any variant of their names but the public half.
const KEY_PREFIXES: [&str; 4] = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"];
const CREDENTIAL_SUFFIXES: [&str; 6] = [".pem", ".key", ".p12", ".pfx", ".jks", ".keystore"];

/// Whether an untracked path is a credential file that is never stored.
pub(super) fn credential(path: &[u8]) -> bool {
    let name = path.rsplit(|byte| *byte == b'/').next().unwrap_or(path);
    let name = String::from_utf8_lossy(name).to_ascii_lowercase();
    let template = [".example", ".sample", ".template"].iter().any(|end| name.ends_with(end));
    CREDENTIAL_NAMES.contains(&name.as_str())
        || (name.starts_with(".env.") && !template)
        || (KEY_PREFIXES.iter().any(|prefix| name.starts_with(prefix)) && !name.ends_with(".pub"))
        || CREDENTIAL_SUFFIXES.iter().any(|suffix| name.ends_with(suffix))
}

pub(super) fn join(root: &Path, relative: &[u8]) -> PathBuf {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        root.join(std::ffi::OsStr::from_bytes(relative))
    }
    #[cfg(not(unix))]
    {
        root.join(String::from_utf8_lossy(relative).as_ref())
    }
}

pub(super) fn link_target(path: &Path) -> io::Result<Vec<u8>> {
    let target = fs::read_link(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        Ok(target.as_os_str().as_bytes().to_vec())
    }
    #[cfg(not(unix))]
    {
        Ok(target.to_string_lossy().replace('\\', "/").into_bytes())
    }
}

pub(super) fn executable(metadata: &fs::Metadata) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        let _ = metadata;
        false
    }
}

/// NUL-terminated records.
pub(super) fn records(output: &[u8]) -> impl Iterator<Item = &[u8]> {
    output.split(|byte| *byte == 0).filter(|record| !record.is_empty())
}

fn listing(
    repository: &Repository,
    arguments: &[&str],
    operation: &'static str,
) -> Result<Vec<u8>, ResourceError> {
    match repository.run(arguments, MAX_LISTING_BYTES) {
        Ok(output) if output.truncated => Err(failed(
            operation,
            "budget_exceeded",
            "the repository listing is too large to capture safely",
        )),
        Ok(output) => Ok(output.stdout),
        Err(failure) => Err(crate::git_ops::git_failed(operation, &failure)),
    }
}

/// `operation.failed` with the machine `reason` and the explanation in
/// `extra.message`, beside the object `extra` fields (or none: `Null`).
pub(super) fn refused(
    operation: &str,
    reason: &str,
    message: impl Into<String>,
    extra: Value,
) -> ResourceError {
    let mut extra = match extra {
        Value::Object(fields) => fields,
        _ => serde_json::Map::new(),
    };
    extra.insert("message".into(), Value::String(message.into()));
    ResourceError::operation_failed(operation, reason, Value::Object(extra))
}

pub(super) fn failed(
    operation: &'static str,
    reason: &str,
    message: impl Into<String>,
) -> ResourceError {
    refused(operation, reason, message, Value::Null)
}

/// Rewrites a shared git refusal that carries its reason in `extra.code`
/// (target, repository and git failures) into the checkpoint shape.
pub(super) fn normalized(error: ResourceError) -> ResourceError {
    if error.code != "operation.failed" {
        return error;
    }
    let details = &error.details;
    let (Some(code), Some(operation)) =
        (details["extra"]["code"].as_str(), details["operation"].as_str())
    else {
        return error;
    };
    let mut extra = details["extra"].clone();
    if let Some(fields) = extra.as_object_mut() {
        fields.remove("code");
    }
    let message = details["reason"].as_str().unwrap_or(code).to_string();
    refused(operation, code, message, extra)
}

fn unsupported(operation: &'static str, mode: &str, path: Option<&[u8]>) -> ResourceError {
    let mut extra = json!({"mode":mode});
    if let Some(path) = path {
        extra["path"] = json!(String::from_utf8_lossy(path));
    }
    let message = format!("the index uses {mode}, which a checkpoint cannot round-trip yet");
    refused(operation, "unsupported_index", message, extra)
}

/// A git failure as a capture refusal.
pub(super) fn git(operation: &'static str, failure: &GitFailure) -> ResourceError {
    crate::git_ops::git_failed(operation, failure)
}
