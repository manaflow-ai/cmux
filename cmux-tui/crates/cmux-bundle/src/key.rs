use crate::{Error, Result};

/// A chunk's id: BLAKE3 keyed by the pair's id key, over the chunk's plaintext.
pub type ChunkId = [u8; 32];

const ID_CONTEXT: &str = "cmux-bundle v1 2026-11-24 chunk id key";
const SEAL_CONTEXT: &str = "cmux-bundle v1 2026-11-24 chunk seal key";

/// A pair's two bundle keys, derived from a secret only the pair's two ends hold (for the phone
/// link, the WireGuard pair's shared secret or the pairing secret). Neither key ever reaches a relay.
#[derive(Clone)]
pub struct PairKey {
    id: [u8; 32],
    seal: [u8; 32],
}

impl PairKey {
    /// The keys for the pair holding `secret` (at least 32 bytes of key material).
    pub fn derive(secret: &[u8]) -> Self {
        Self {
            id: blake3::derive_key(ID_CONTEXT, secret),
            seal: blake3::derive_key(SEAL_CONTEXT, secret),
        }
    }

    /// The id of a chunk holding `bytes`.
    pub fn chunk_id(&self, bytes: &[u8]) -> ChunkId {
        *blake3::keyed_hash(&self.id, bytes).as_bytes()
    }

    pub(crate) fn id_hasher(&self) -> blake3::Hasher {
        blake3::Hasher::new_keyed(&self.id)
    }

    pub(crate) fn seal_key(&self) -> &[u8; 32] {
        &self.seal
    }
}

impl std::fmt::Debug for PairKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairKey(..)")
    }
}

/// An id as 64 lowercase hex digits (the relay cache's URL form).
pub fn hex(id: &ChunkId) -> String {
    use std::fmt::Write as _;
    let mut s = String::with_capacity(64);
    for b in id {
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// The id 64 hex digits name.
pub fn unhex(s: &str) -> Result<ChunkId> {
    let b = s.as_bytes();
    if b.len() != 64 {
        return Err(Error::Malformed("chunk id"));
    }
    let digit = |c: u8| match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        _ => Err(Error::Malformed("chunk id")),
    };
    let mut id = [0u8; 32];
    for (slot, pair) in id.iter_mut().zip(b.chunks_exact(2)) {
        let &[hi, lo] = pair else {
            return Err(Error::Malformed("chunk id"));
        };
        *slot = digit(hi)? << 4 | digit(lo)?;
    }
    Ok(id)
}

#[cfg(test)]
#[path = "key_tests.rs"]
mod tests;
