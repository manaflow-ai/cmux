//! The content digest of a module tree: what the user approves and what the
//! installed copy must still match.

use super::Refusal;
use std::path::Path;

/// A module has at most this many files.
pub const MAX_FILES: usize = 1024;
/// One file is at most this big.
pub const MAX_FILE_BYTES: u64 = 8 * 1024 * 1024;
/// The whole tree is at most this big.
pub const MAX_TOTAL_BYTES: u64 = 32 * 1024 * 1024;

/// Checks one path inside a module tree: relative, ASCII, no `.git`, no
/// dot-segments, no case-folding surprises.
pub fn validate_module_path(_path: &str) -> Result<(), Refusal> {
    Err(Refusal::new("not.implemented", "path validation"))
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
    pub fn from_files(_files: &[FileInput<'_>]) -> Result<Self, Refusal> {
        Err(Refusal::new("not.implemented", "digest"))
    }

    /// Digests a staged directory. Symlinks, special files and `.git` are refused.
    pub fn from_dir(_root: &Path) -> Result<Self, Refusal> {
        Err(Refusal::new("not.implemented", "digest from dir"))
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
