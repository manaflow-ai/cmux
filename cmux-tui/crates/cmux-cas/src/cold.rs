//! The cold pass's manifest (hq `docs/design/cold-storage-and-shared-tier.md`, section 3 and P1).
//!
//! A file whose every chunk is in the [public tier](crate::public) is stored as a ref to those
//! public chunks ([`Body::Public`], plain BLAKE3 ids, the same for every tenant). Every other
//! file is private: its chunks and its whole-file hash are `Id::keyed` under the tenant's key, so
//! equal bytes under two tenants have different ids, and no id here lets one tenant learn what
//! another holds. Within one tenant a private chunk dedupes freely.
//!
//! This builds the manifest and hands each new private chunk to the caller; it deletes nothing
//! and uploads nothing.

use crate::manifest::{Chunk, check_path};
use crate::public::PublicIndex;
use crate::{Id, Result, cdc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

/// The schema this module writes.
pub const SCHEMA: u64 = 1;

/// How a file's bytes are kept.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "tier", rename_all = "lowercase")]
pub enum Body {
    /// A ref: every chunk is public (`Id::of`); no copy is stored for this tenant.
    Public { chunks: Vec<Chunk> },
    /// A copy: chunks keyed to the tenant (`Id::keyed`).
    Tenant { chunks: Vec<Chunk> },
}

impl Body {
    /// The chunks, in order.
    pub fn chunks(&self) -> &[Chunk] {
        match self {
            Self::Public { chunks } | Self::Tenant { chunks } => chunks,
        }
    }
}

/// One file.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct File {
    pub path: String,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub exec: bool,
    pub size: u64,
    /// The whole file's hash: `Id::of` for a public ref, `Id::keyed` for a tenant file.
    pub hash: Id,
    pub body: Body,
}

/// A tenant's cold manifest.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct ColdManifest {
    pub schema: u64,
    pub files: Vec<File>,
}

/// What the pass kept where.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize)]
pub struct Stats {
    pub ref_files: u64,
    pub ref_bytes: u64,
    pub tenant_files: u64,
    /// Bytes of the distinct private chunks handed to the caller: what is physically stored.
    pub tenant_chunk_bytes: u64,
}

impl ColdManifest {
    /// The cold manifest of `files` (`path -> (bytes, exec)`) for the tenant holding `key`,
    /// consulting `public`. Each distinct new private chunk goes to `put` once, keyed id first.
    /// A public ref hands nothing over: its chunks already live in the public tier.
    pub fn build(
        files: &BTreeMap<String, (Vec<u8>, bool)>,
        key: &[u8; 32],
        public: &PublicIndex,
        mut put: impl FnMut(Id, &[u8]) -> Result<()>,
    ) -> Result<(Self, Stats)> {
        let mut seen = HashSet::new();
        let mut stats = Stats::default();
        let mut out = Vec::with_capacity(files.len());
        for (path, (bytes, exec)) in files {
            check_path(path)?;
            let cuts = cdc::chunks(bytes);
            let mut pub_chunks = Vec::with_capacity(cuts.len());
            for &(at, len) in &cuts {
                let piece = bytes.get(at..at.saturating_add(len)).ok_or("chunk out of range")?;
                pub_chunks.push(Chunk { id: Id::of(piece), len: u32::try_from(len)? });
            }
            let size = bytes.len() as u64;
            if public.covers(&pub_chunks) {
                stats.ref_files += 1;
                stats.ref_bytes += size;
                out.push(File {
                    path: path.clone(),
                    exec: *exec,
                    size,
                    hash: Id::of(bytes),
                    body: Body::Public { chunks: pub_chunks },
                });
                continue;
            }
            let mut chunks = Vec::with_capacity(cuts.len());
            for &(at, len) in &cuts {
                let piece = bytes.get(at..at.saturating_add(len)).ok_or("chunk out of range")?;
                let id = Id::keyed(key, piece);
                if seen.insert(id) {
                    put(id, piece)?;
                    stats.tenant_chunk_bytes += len as u64;
                }
                chunks.push(Chunk { id, len: u32::try_from(len)? });
            }
            stats.tenant_files += 1;
            out.push(File {
                path: path.clone(),
                exec: *exec,
                size,
                hash: Id::keyed(key, bytes),
                body: Body::Tenant { chunks },
            });
        }
        Ok((Self { schema: SCHEMA, files: out }, stats))
    }

    /// Its JSON bytes.
    pub fn to_bytes(&self) -> Result<Vec<u8>> {
        Ok(serde_json::to_vec(self)?)
    }

    /// Every chunk id a tenant-tier body names: what this tenant must keep and no other may name.
    pub fn tenant_chunks(&self) -> Vec<Id> {
        self.files
            .iter()
            .filter_map(|f| match &f.body {
                Body::Tenant { chunks } => Some(chunks.iter().map(|c| c.id)),
                Body::Public { .. } => None,
            })
            .flatten()
            .collect()
    }
}
