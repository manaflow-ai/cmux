//! The stub left where an offloaded file was: `<file>.cloud`, a small JSON record naming the blob.

use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

pub const SUFFIX: &str = "cloud";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Stub {
    pub v: u32,
    /// The SHA-256 of the sealed bytes: the blob's address in the store.
    pub blob: String,
    /// The SHA-256 of the original file, checked after decrypting.
    pub plain_sha256: String,
    pub plain_bytes: u64,
    pub stored_bytes: u64,
    pub offloaded_at_ms: u64,
}

/// `cold.zst` -> `cold.zst.cloud`.
pub fn stub_path(file: &Path) -> PathBuf {
    let mut name = file.as_os_str().to_owned();
    name.push(".");
    name.push(SUFFIX);
    PathBuf::from(name)
}

/// `cold.zst.cloud` -> `cold.zst`, or None for any other name.
pub fn segment_path(stub: &Path) -> Option<PathBuf> {
    let name = stub.file_name()?.to_str()?;
    let base = name.strip_suffix(".cloud")?;
    Some(stub.with_file_name(base))
}

pub fn read(stub: &Path) -> anyhow::Result<Stub> {
    Ok(serde_json::from_slice(&std::fs::read(stub)?)?)
}
