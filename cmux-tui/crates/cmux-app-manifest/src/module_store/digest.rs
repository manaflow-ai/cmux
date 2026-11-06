//! The content digest of a module tree: what the user approves and what the
//! installed copy must still match.
//!
//! Canonical form (`cmux-module-tree/1`): a header line, then one line per
//! regular file in byte order of its path: `<mode> <sha256> <size> <path>`,
//! where mode is `755` (executable) or `644`. The digest is `sha256:<hex>`
//! of that text. Paths are ASCII, so case-folding and Unicode normalisation
//! cannot make two different files look the same.

use super::Refusal;
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};

/// A module has at most this many files.
pub const MAX_FILES: usize = 1024;
/// One file is at most this big.
pub const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;
/// The whole tree is at most this big.
pub const MAX_TOTAL_BYTES: u64 = 32 * 1024 * 1024;

const MAX_PATH_LEN: usize = 512;
const MAX_COMPONENT_LEN: usize = 128;
const MAX_DEPTH: usize = 16;

/// Checks one path inside a module tree: relative, ASCII, no `.git`, no
/// dot-segments, no leading hyphen (so no option-looking name reaches git).
pub fn validate_module_path(path: &str) -> Result<(), Refusal> {
    if path.is_empty() || path.len() > MAX_PATH_LEN {
        return Err(Refusal::new("path.invalid", "a path is empty or longer than 512 bytes"));
    }
    if path.starts_with('/') || path.ends_with('/') {
        return Err(Refusal::new("path.invalid", format!("{path:?} is absolute or ends with '/'")));
    }
    for component in path.split('/') {
        if component.is_empty() || component == "." || component == ".." {
            return Err(Refusal::new(
                "path.invalid",
                format!("{path:?} has an empty or dot segment"),
            ));
        }
        if component.len() > MAX_COMPONENT_LEN || component.starts_with('-') {
            return Err(Refusal::new(
                "path.invalid",
                format!("{component:?} is too long or starts with '-'"),
            ));
        }
        if component.eq_ignore_ascii_case(".git") {
            return Err(Refusal::new("path.git", format!("{path:?} enters a git directory")));
        }
        if !component.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
        {
            return Err(Refusal::new(
                "path.invalid",
                format!("{path:?} has a character outside ASCII letters, digits, . _ -"),
            ));
        }
    }
    Ok(())
}

/// One file as bytes, for [`TreeDigest::from_files`].
#[derive(Debug, Clone, Copy)]
pub struct FileInput<'a> {
    pub path: &'a str,
    pub executable: bool,
    pub bytes: &'a [u8],
}

/// One file of a digested tree.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ModuleFile {
    pub path: String,
    pub executable: bool,
    pub size: u64,
    /// Lower-case hex SHA-256 of the file bytes.
    pub sha256: String,
}

/// The digest of a whole tree (`sha256:<hex>`) and its file list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TreeDigest {
    digest: String,
    files: Vec<ModuleFile>,
}

impl TreeDigest {
    /// Digests in-memory files. Order does not matter; the input is checked
    /// against the path rules and the limits above.
    pub fn from_files(files: &[FileInput<'_>]) -> Result<Self, Refusal> {
        if files.len() > MAX_FILES {
            return Err(Refusal::new("limit.files", format!("more than {MAX_FILES} files")));
        }
        let mut total: u64 = 0;
        let mut out = Vec::with_capacity(files.len());
        for file in files {
            validate_module_path(file.path)?;
            let size = file.bytes.len() as u64;
            if size > MAX_FILE_BYTES {
                return Err(Refusal::new(
                    "limit.file",
                    format!("{} is larger than 8 MiB", file.path),
                ));
            }
            total = total.saturating_add(size);
            if total > MAX_TOTAL_BYTES {
                return Err(Refusal::new("limit.total", "the module is larger than 32 MiB"));
            }
            out.push(ModuleFile {
                path: file.path.to_string(),
                executable: file.executable,
                size,
                sha256: hex::encode(Sha256::digest(file.bytes)),
            });
        }
        finish(out)
    }

    /// Digests a staged directory. Symlinks, special files and `.git` are
    /// refused. The staging directory must be owned by the supervisor (0700):
    /// the walker trusts that nobody else writes into it while it reads.
    pub fn from_dir(root: &Path) -> Result<Self, Refusal> {
        let mut found: Vec<(String, bool, Vec<u8>)> = Vec::new();
        let mut total: u64 = 0;
        let mut stack: Vec<(PathBuf, String)> = vec![(root.to_path_buf(), String::new())];
        while let Some((dir, prefix)) = stack.pop() {
            let entries = std::fs::read_dir(&dir)
                .map_err(|e| Refusal::new("tree.read", format!("{}: {e}", dir.display())))?;
            for entry in entries {
                let entry = entry.map_err(|e| Refusal::new("tree.read", e.to_string()))?;
                let name = entry
                    .file_name()
                    .into_string()
                    .map_err(|_| Refusal::new("path.invalid", "a file name is not UTF-8"))?;
                let rel = if prefix.is_empty() { name } else { format!("{prefix}/{name}") };
                let meta = std::fs::symlink_metadata(entry.path())
                    .map_err(|e| Refusal::new("tree.read", format!("{rel}: {e}")))?;
                let kind = meta.file_type();
                if kind.is_symlink() {
                    return Err(Refusal::new("tree.symlink", format!("{rel} is a symbolic link")));
                }
                if kind.is_dir() {
                    validate_module_path(&rel)?;
                    if rel.matches('/').count() >= MAX_DEPTH {
                        return Err(Refusal::new(
                            "limit.depth",
                            format!("{rel} is nested too deep"),
                        ));
                    }
                    stack.push((entry.path(), rel));
                    continue;
                }
                if !kind.is_file() {
                    return Err(Refusal::new(
                        "tree.special",
                        format!("{rel} is not a regular file"),
                    ));
                }
                validate_module_path(&rel)?;
                if found.len() >= MAX_FILES {
                    return Err(Refusal::new(
                        "limit.files",
                        format!("more than {MAX_FILES} files"),
                    ));
                }
                let size = meta.len();
                if size > MAX_FILE_BYTES {
                    return Err(Refusal::new("limit.file", format!("{rel} is larger than 8 MiB")));
                }
                total = total.saturating_add(size);
                if total > MAX_TOTAL_BYTES {
                    return Err(Refusal::new("limit.total", "the module is larger than 32 MiB"));
                }
                let bytes = std::fs::read(entry.path())
                    .map_err(|e| Refusal::new("tree.read", format!("{rel}: {e}")))?;
                found.push((rel, is_executable(&meta), bytes));
            }
        }
        let inputs: Vec<FileInput<'_>> = found
            .iter()
            .map(|(path, executable, bytes)| FileInput { path, executable: *executable, bytes })
            .collect();
        Self::from_files(&inputs)
    }

    pub fn digest(&self) -> &str {
        &self.digest
    }

    pub fn files(&self) -> &[ModuleFile] {
        &self.files
    }

    pub fn has_file(&self, path: &str) -> bool {
        self.files.iter().any(|f| f.path == path)
    }
}

fn finish(mut files: Vec<ModuleFile>) -> Result<TreeDigest, Refusal> {
    files.sort_by_key(|f| f.path.clone());
    let mut folded = HashSet::with_capacity(files.len());
    for file in &files {
        if !folded.insert(file.path.to_ascii_lowercase()) {
            return Err(Refusal::new(
                "path.caseCollision",
                format!("{} collides with another path ignoring case", file.path),
            ));
        }
    }
    let mut canonical = String::from("cmux-module-tree/1\n");
    for file in &files {
        let mode = if file.executable { "755" } else { "644" };
        let _ = writeln!(canonical, "{mode} {} {} {}", file.sha256, file.size, file.path);
    }
    let digest = format!("sha256:{}", hex::encode(Sha256::digest(canonical.as_bytes())));
    Ok(TreeDigest { digest, files })
}

#[cfg(unix)]
fn is_executable(meta: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::PermissionsExt;
    meta.permissions().mode() & 0o111 != 0
}

#[cfg(not(unix))]
fn is_executable(_meta: &std::fs::Metadata) -> bool {
    false
}
