//! The sealed blob format: `CSH1`, a 24-byte random nonce, then XChaCha20-Poly1305 over the zstd-compressed
//! plaintext, with `CSH1` as associated data. The blob's address is the SHA-256 of these bytes, so the store
//! learns only sizes and counts. A random nonce means two machines never produce the same blob for the same
//! segment; that costs nothing here, since a sealed segment is written by one machine once.

use anyhow::{Context, anyhow, bail};
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use std::path::Path;

pub const MAGIC: &[u8; 4] = b"CSH1";
const NONCE: usize = 24;
const ZSTD_LEVEL: i32 = 3;

/// The person's 256-bit history key. It never leaves their machines in the clear.
#[derive(Clone)]
pub struct Key([u8; 32]);

impl std::fmt::Debug for Key {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Key(..)")
    }
}

impl Key {
    pub fn from_bytes(bytes: [u8; 32]) -> Self {
        Self(bytes)
    }

    /// Bytes to derive a public, stable id from (hashed with a label first, never sent as is).
    pub(crate) fn id_material(&self) -> &[u8] {
        &self.0
    }

    pub fn generate() -> anyhow::Result<Self> {
        let mut bytes = [0u8; 32];
        getrandom::fill(&mut bytes).map_err(|e| anyhow!("no randomness: {e}"))?;
        Ok(Self(bytes))
    }

    /// Reads the key at `path` (64 hex characters), or makes one there (mode 0600) when none exists.
    pub fn load_or_create(path: &Path) -> anyhow::Result<Self> {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let raw = hex::decode(text.trim()).context("the history key is not hex")?;
                let bytes: [u8; 32] =
                    raw.try_into().map_err(|_| anyhow!("the history key is not 32 bytes"))?;
                Ok(Self(bytes))
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let key = Self::generate()?;
                if let Some(parent) = path.parent() {
                    std::fs::create_dir_all(parent)?;
                }
                write_private(path, hex::encode(key.0).as_bytes())?;
                Ok(key)
            }
            Err(error) => Err(error).with_context(|| format!("cannot read {}", path.display())),
        }
    }

    fn cipher(&self) -> XChaCha20Poly1305 {
        XChaCha20Poly1305::new((&self.0).into())
    }
}

#[cfg(unix)]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let mut file =
        std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    file.write_all(bytes)?;
    file.sync_all()
}

#[cfg(not(unix))]
fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    std::fs::write(path, bytes)
}

/// Compresses and encrypts `plain`.
pub fn seal(key: &Key, plain: &[u8]) -> anyhow::Result<Vec<u8>> {
    let packed = zstd::bulk::compress(plain, ZSTD_LEVEL).context("cannot compress")?;
    let mut nonce = [0u8; NONCE];
    getrandom::fill(&mut nonce).map_err(|e| anyhow!("no randomness: {e}"))?;
    let body = key
        .cipher()
        .encrypt(XNonce::from_slice(&nonce), Payload { msg: &packed, aad: MAGIC })
        .map_err(|_| anyhow!("cannot encrypt"))?;
    let mut out = Vec::with_capacity(MAGIC.len() + NONCE + body.len());
    out.extend_from_slice(MAGIC);
    out.extend_from_slice(&nonce);
    out.extend_from_slice(&body);
    Ok(out)
}

/// Decrypts and decompresses a sealed blob; `plain_len` bounds the decompressed size.
pub fn open(key: &Key, sealed: &[u8], plain_len: usize) -> anyhow::Result<Vec<u8>> {
    if sealed.len() < MAGIC.len() + NONCE || sealed.get(..MAGIC.len()) != Some(MAGIC.as_slice()) {
        bail!("not a sealed history blob");
    }
    let nonce =
        sealed.get(MAGIC.len()..MAGIC.len() + NONCE).context("not a sealed history blob")?;
    let encrypted = sealed.get(MAGIC.len() + NONCE..).context("not a sealed history blob")?;
    let packed = key
        .cipher()
        .decrypt(XNonce::from_slice(nonce), Payload { msg: encrypted, aad: MAGIC })
        .map_err(|_| anyhow!("the blob does not open with this history key"))?;
    zstd::bulk::decompress(&packed, plain_len).context("cannot decompress")
}

#[cfg(test)]
#[path = "seal_tests.rs"]
mod tests;
