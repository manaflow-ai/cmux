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

/// A sealed sync blob, addressed by its ciphertext. The size bounds decryption.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Part {
    pub blob: String,
    pub plain_bytes: usize,
}

/// A v2 stub. The tail is a session-pack range bundle. Other parts are ordinary
/// session-pack chunk files keyed by their uncompressed content id.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Packed {
    pub v: u32,
    pub name: String,
    pub tail: Part,
    pub first_line: u64,
    pub manifest_sha256: String,
    pub older: std::collections::BTreeMap<String, Part>,
}

impl Packed {
    pub fn blobs(&self) -> impl Iterator<Item = &str> {
        std::iter::once(&self.tail).chain(self.older.values()).map(|part| part.blob.as_str())
    }
}

pub enum History {
    Archive(Stub),
    Pack(Packed),
}

pub fn history(path: &Path) -> anyhow::Result<History> {
    parse_history(std::fs::File::open(path)?)
}

pub fn parse_history(reader: impl std::io::Read) -> anyhow::Result<History> {
    let record: serde_json::Value = serde_json::from_reader(reader)?;
    match record.get("v").and_then(serde_json::Value::as_u64) {
        Some(1) => Ok(History::Archive(serde_json::from_value(record)?)),
        Some(2) => Ok(History::Pack(serde_json::from_value(record)?)),
        version => anyhow::bail!("unknown cloud history stub version {version:?}"),
    }
}
