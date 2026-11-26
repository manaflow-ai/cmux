//! A sealed chunk: `[u8 version = 1][ciphertext][16-byte tag]`, XChaCha20-Poly1305 under the pair's seal
//! key. The nonce is the chunk id's first 24 bytes: the id is a keyed hash of the plaintext, so a nonce
//! repeats only for the same plaintext under the same key, which seals to the same bytes (deterministic,
//! SIV-style; this is what lets two copies of a chunk dedupe as ciphertext). The associated data is the
//! version and the whole id, and opening recomputes the id from the plaintext: a store, cache or relay
//! that returns other bytes, or a chunk filed under another id, fails with [`Error::Seal`].
//!
//! The plaintext inside is `[u8 codec][body]`: codec 0 is the bytes as they are, codec 1 is zstd. The id
//! is over the chunk's content, never its encoding, so a sender that compresses and one that does not
//! still dedupe against each other.

use crate::{ChunkId, Error, PairKey, Result};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};

/// The sealed form's version byte.
pub const VERSION: u8 = 1;
/// Bytes a seal adds to a chunk's encoded body: version, codec and tag.
pub const OVERHEAD: usize = 1 + 1 + 16;
/// The largest sealed chunk (a [`crate::cdc::MAX`] chunk stored raw, plus the overhead).
pub const MAX_SEALED: usize = crate::cdc::MAX + OVERHEAD;

const CODEC_RAW: u8 = 0;
const CODEC_ZSTD: u8 = 1;
/// zstd level for chunks: fast enough for a phone, and most of the gain on text.
const ZSTD_LEVEL: i32 = 3;
/// Bytes zstd must save before a chunk is stored compressed (a PNG or a video gains nothing).
const ZSTD_MIN_GAIN: usize = 64;

fn cipher(key: &PairKey) -> XChaCha20Poly1305 {
    XChaCha20Poly1305::new(key.seal_key().into())
}

fn aad(id: &ChunkId) -> [u8; 33] {
    let mut out = [0u8; 33];
    out[0] = VERSION;
    out[1..].copy_from_slice(id);
    out
}

/// `content` sealed for the pair, and its id.
pub fn seal(key: &PairKey, content: &[u8]) -> (ChunkId, Vec<u8>) {
    let id = key.chunk_id(content);
    (id, seal_with_id(key, &id, content))
}

/// `content` sealed under the id the caller already computed (`key.chunk_id(content)`).
pub fn seal_with_id(key: &PairKey, id: &ChunkId, content: &[u8]) -> Vec<u8> {
    let mut plain = Vec::with_capacity(content.len() + 1);
    match zstd::bulk::compress(content, ZSTD_LEVEL) {
        Ok(z) if z.len() + ZSTD_MIN_GAIN < content.len() => {
            plain.push(CODEC_ZSTD);
            plain.extend_from_slice(&z);
        }
        _ => {
            plain.push(CODEC_RAW);
            plain.extend_from_slice(content);
        }
    }
    let ad = aad(id);
    let sealed = cipher(key)
        .encrypt(XNonce::from_slice(&id[..24]), Payload { msg: &plain, aad: &ad })
        // XChaCha20-Poly1305 encryption only fails past 256 GiB, far above a chunk.
        .unwrap_or_default();
    let mut out = Vec::with_capacity(sealed.len() + 1);
    out.push(VERSION);
    out.extend_from_slice(&sealed);
    out
}

/// The content of the sealed chunk `sealed` filed under `id`, checked against `id`.
pub fn open(key: &PairKey, id: &ChunkId, sealed: &[u8]) -> Result<Vec<u8>> {
    let (&version, body) = sealed.split_first().ok_or(Error::Malformed("sealed chunk"))?;
    if version != VERSION {
        return Err(Error::Version(version));
    }
    if sealed.len() > MAX_SEALED {
        return Err(Error::Malformed("sealed chunk size"));
    }
    let ad = aad(id);
    let plain = cipher(key)
        .decrypt(XNonce::from_slice(&id[..24]), Payload { msg: body, aad: &ad })
        .map_err(|_| Error::Seal)?;
    let (&codec, enc) = plain.split_first().ok_or(Error::Seal)?;
    let content = match codec {
        CODEC_RAW => enc.to_vec(),
        CODEC_ZSTD => zstd::bulk::decompress(enc, crate::cdc::MAX).map_err(|_| Error::Seal)?,
        _ => return Err(Error::Seal),
    };
    if key.chunk_id(&content) != *id {
        return Err(Error::Seal);
    }
    Ok(content)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn seals_open_and_dedupe() {
        let key = PairKey::derive(&[3; 32]);
        let text = b"hello hello hello hello ".repeat(400);
        let (id, sealed) = seal(&key, &text);
        assert!(sealed.len() < text.len() / 4, "text compresses: {}", sealed.len());
        assert_eq!(open(&key, &id, &sealed).unwrap(), text);
        // Deterministic: the same content seals to the same bytes (ciphertext dedupe in a cache).
        assert_eq!(seal(&key, &text).1, sealed);
    }

    #[test]
    fn a_wrong_key_id_or_byte_is_caught() {
        let key = PairKey::derive(&[3; 32]);
        let other = PairKey::derive(&[4; 32]);
        let (id, sealed) = seal(&key, b"attachment bytes");
        assert_eq!(open(&other, &id, &sealed), Err(Error::Seal));
        let (id2, _) = seal(&key, b"another chunk");
        assert_eq!(open(&key, &id2, &sealed), Err(Error::Seal));
        let mut flipped = sealed.clone();
        *flipped.last_mut().unwrap() ^= 1;
        assert_eq!(open(&key, &id, &flipped), Err(Error::Seal));
        let mut future = sealed;
        future[0] = 2;
        assert_eq!(open(&key, &id, &future), Err(Error::Version(2)));
    }

    #[test]
    fn incompressible_chunks_stay_raw() {
        let key = PairKey::derive(&[5; 32]);
        let noise: Vec<u8> =
            (0u32..70_000).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
        let (id, sealed) = seal(&key, &noise);
        assert!(sealed.len() <= noise.len() + OVERHEAD);
        assert_eq!(open(&key, &id, &sealed).unwrap(), noise);
    }
}
