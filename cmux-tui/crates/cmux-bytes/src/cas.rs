//! What the receiver already holds, by chunk hash: the VM's store, a cache,
//! or chunks sent earlier in this same transfer (so two equal files cost one).

use std::collections::HashSet;

pub type Hash = [u8; 32];

pub fn hash(bytes: &[u8]) -> Hash {
    *blake3::hash(bytes).as_bytes()
}

/// The set of chunk hashes the receiver has. A transfer adds each chunk it sends.
#[derive(Default, Clone)]
pub struct Have {
    set: HashSet<Hash>,
}

impl Have {
    pub fn contains(&self, h: &Hash) -> bool {
        self.set.contains(h)
    }
    pub fn insert(&mut self, h: Hash) -> bool {
        self.set.insert(h)
    }
    pub fn len(&self) -> usize {
        self.set.len()
    }
    pub fn is_empty(&self) -> bool {
        self.set.is_empty()
    }
}

/// Chunks under this size go as bytes: a reference frame costs 36 bytes, and a
/// lookup round trip is not worth saving less.
pub const MIN_REF_BYTES: usize = 256;
