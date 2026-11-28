//! A snapshot's bytes as content-addressed chunks: split, name, check and put back together.
//!
//! A chunk is at most [`CHUNK_MAX_BYTES`] and is named by the lowercase hex SHA-256 of its bytes.
//! A manifest lists chunk names per part (a git bundle, a patch, a tar); the part is its chunks
//! joined in order. A chat keeps at most [`SNAPSHOT_MAX_BYTES`]; past that the answer is
//! `auto.too_large` and the chat stays local.
//!
//! The sender builds a [`Pack`], uploads [`Pack::chunks`] and puts the lists it got from
//! [`Pack::add`] in the manifest. The receiver checks the manifest ([`validate`]), then feeds
//! each list's chunks to an [`Assembler`] (or [`assemble`]) as it downloads them.

use std::collections::BTreeMap;
use std::fmt;

use sha2::{Digest, Sha256};

use crate::consts::{CHUNK_MAX_BYTES, MANIFEST_VERSION, SNAPSHOT_MAX_BYTES};
use crate::wire::{ErrorCode, Manifest};

/// Why chunks were refused.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ChunkError {
    /// The snapshot is past the cap.
    TooLarge { bytes: u64, max: u64 },
    /// A name that is not 64 lowercase hex characters.
    BadName { name: String },
    /// One chunk is over [`CHUNK_MAX_BYTES`].
    ChunkTooLarge { name: String, bytes: usize },
    /// A chunk's bytes do not hash to its name.
    Mismatch { name: String, got: String },
    /// A chunk the list names is not there.
    Missing { name: String },
    /// More chunks came than the list names.
    Unexpected,
    /// A manifest version this build does not read.
    Version { v: u32 },
}

impl ChunkError {
    /// The store's code for this refusal, where it has one.
    pub fn code(&self) -> Option<ErrorCode> {
        match self {
            ChunkError::TooLarge { .. } | ChunkError::ChunkTooLarge { .. } => {
                Some(ErrorCode::TooLarge)
            }
            ChunkError::BadName { .. } | ChunkError::Mismatch { .. } => {
                Some(ErrorCode::ChunkMismatch)
            }
            ChunkError::Missing { .. } => Some(ErrorCode::SnapshotIncomplete),
            ChunkError::Unexpected | ChunkError::Version { .. } => None,
        }
    }
}

impl fmt::Display for ChunkError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChunkError::TooLarge { bytes, max } => {
                write!(f, "the snapshot is {bytes} bytes, past the {max} a chat keeps")
            }
            ChunkError::BadName { name } => {
                write!(f, "not a chunk name (64 lowercase hex): {name:?}")
            }
            ChunkError::ChunkTooLarge { name, bytes } => {
                write!(f, "chunk {name} is {bytes} bytes, past {CHUNK_MAX_BYTES}")
            }
            ChunkError::Mismatch { name, got } => {
                write!(f, "chunk {name} holds bytes that hash to {got}")
            }
            ChunkError::Missing { name } => write!(f, "chunk {name} is missing"),
            ChunkError::Unexpected => f.write_str("more chunks than the list names"),
            ChunkError::Version { v } => write!(f, "manifest version {v} is not read here"),
        }
    }
}

impl std::error::Error for ChunkError {}

/// A chunk's name: the lowercase hex SHA-256 of its bytes.
pub fn name_of(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}

/// `name` is 64 lowercase hex characters.
pub fn is_name(name: &str) -> bool {
    name.len() == 64 && name.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// One chunk: its name and its bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Chunk<'a> {
    pub name: &'a str,
    pub bytes: &'a [u8],
}

/// `bytes` cut into chunks of at most [`CHUNK_MAX_BYTES`], in order. No bytes, no chunks.
pub fn split(bytes: &[u8]) -> impl Iterator<Item = &[u8]> {
    bytes.chunks(CHUNK_MAX_BYTES)
}

/// A snapshot being built: the chunks to upload, each once, under the cap.
#[derive(Debug)]
pub struct Pack<'a> {
    max: u64,
    bytes: u64,
    chunks: BTreeMap<String, &'a [u8]>,
}

impl Default for Pack<'_> {
    fn default() -> Self {
        Pack::new()
    }
}

impl<'a> Pack<'a> {
    /// A pack under the cap a chat keeps ([`SNAPSHOT_MAX_BYTES`]).
    pub fn new() -> Pack<'a> {
        Pack::with_max(SNAPSHOT_MAX_BYTES)
    }

    /// A pack under another cap.
    pub fn with_max(max: u64) -> Pack<'a> {
        Pack { max, bytes: 0, chunks: BTreeMap::new() }
    }

    /// Adds one part (a bundle, a patch, a tar) and answers its chunk list for the manifest.
    /// Past the cap it is [`ChunkError::TooLarge`] and the pack is as it was.
    pub fn add(&mut self, part: &'a [u8]) -> Result<Vec<String>, ChunkError> {
        let size = u64::try_from(part.len()).unwrap_or(u64::MAX);
        let bytes = self.bytes.saturating_add(size);
        if bytes > self.max {
            return Err(ChunkError::TooLarge { bytes, max: self.max });
        }
        self.bytes = bytes;
        let mut names = Vec::new();
        for chunk in split(part) {
            let name = name_of(chunk);
            self.chunks.entry(name.clone()).or_insert(chunk);
            names.push(name);
        }
        Ok(names)
    }

    /// The bytes of every part added, which is what a holder downloads.
    pub fn bytes(&self) -> u64 {
        self.bytes
    }

    /// The chunks to upload, each name once.
    pub fn chunks(&self) -> impl Iterator<Item = Chunk<'_>> {
        self.chunks.iter().map(|(name, &bytes)| Chunk { name: name.as_str(), bytes })
    }
}

/// A chunk is what its name says: at most [`CHUNK_MAX_BYTES`], hashing to `name`.
pub fn check(name: &str, bytes: &[u8]) -> Result<(), ChunkError> {
    if !is_name(name) {
        return Err(ChunkError::BadName { name: name.to_owned() });
    }
    if bytes.len() > CHUNK_MAX_BYTES {
        return Err(ChunkError::ChunkTooLarge { name: name.to_owned(), bytes: bytes.len() });
    }
    let got = name_of(bytes);
    if got != name {
        return Err(ChunkError::Mismatch { name: name.to_owned(), got });
    }
    Ok(())
}

/// A manifest this build can read: its version, and every chunk name well formed.
pub fn validate(manifest: &Manifest) -> Result<(), ChunkError> {
    if manifest.v != MANIFEST_VERSION {
        return Err(ChunkError::Version { v: manifest.v });
    }
    match manifest.chunks().find(|name| !is_name(name)) {
        Some(name) => Err(ChunkError::BadName { name: name.to_owned() }),
        None => Ok(()),
    }
}

/// The chunks a manifest names that `stored` does not have, each once, in the manifest's order.
pub fn missing(manifest: &Manifest, stored: impl Fn(&str) -> bool) -> Vec<String> {
    let mut missing: Vec<String> = Vec::new();
    for name in manifest.chunks() {
        if !stored(name) && !missing.iter().any(|seen| seen == name) {
            missing.push(name.to_owned());
        }
    }
    missing
}

/// One part being put back together: it takes the list's chunks in order and checks each.
#[derive(Debug)]
pub struct Assembler<'a> {
    names: &'a [String],
    at: usize,
    bytes: u64,
    max: u64,
}

impl<'a> Assembler<'a> {
    /// An assembler for one chunk list, under the cap a chat keeps.
    pub fn new(names: &'a [String]) -> Result<Assembler<'a>, ChunkError> {
        Assembler::with_max(names, SNAPSHOT_MAX_BYTES)
    }

    /// An assembler under another cap, for a part that shares the cap with others.
    pub fn with_max(names: &'a [String], max: u64) -> Result<Assembler<'a>, ChunkError> {
        match names.iter().find(|name| !is_name(name)) {
            Some(name) => Err(ChunkError::BadName { name: name.clone() }),
            None => Ok(Assembler { names, at: 0, bytes: 0, max }),
        }
    }

    /// The chunk to give next; None when the part is whole.
    pub fn wanted(&self) -> Option<&'a str> {
        self.names.get(self.at).map(String::as_str)
    }

    /// Takes the wanted chunk's bytes. A refused chunk leaves the assembler as it was.
    pub fn accept(&mut self, chunk: &[u8]) -> Result<(), ChunkError> {
        let name = self.wanted().ok_or(ChunkError::Unexpected)?;
        check(name, chunk)?;
        let size = u64::try_from(chunk.len()).unwrap_or(u64::MAX);
        let bytes = self.bytes.saturating_add(size);
        if bytes > self.max {
            return Err(ChunkError::TooLarge { bytes, max: self.max });
        }
        self.bytes = bytes;
        self.at = self.at.saturating_add(1);
        Ok(())
    }

    /// The bytes accepted so far.
    pub fn bytes(&self) -> u64 {
        self.bytes
    }

    /// Every chunk the list names was accepted.
    pub fn whole(&self) -> bool {
        self.at == self.names.len()
    }
}

/// One part put back together from its chunk list. `fetch` answers a chunk's bytes by name, or
/// None when it does not have it.
pub fn assemble<B: AsRef<[u8]>>(
    names: &[String],
    mut fetch: impl FnMut(&str) -> Option<B>,
) -> Result<Vec<u8>, ChunkError> {
    let mut assembler = Assembler::new(names)?;
    let mut part = Vec::new();
    while let Some(name) = assembler.wanted() {
        let chunk = fetch(name).ok_or_else(|| ChunkError::Missing { name: name.to_owned() })?;
        assembler.accept(chunk.as_ref())?;
        part.extend_from_slice(chunk.as_ref());
    }
    Ok(part)
}

#[cfg(test)]
mod tests;
