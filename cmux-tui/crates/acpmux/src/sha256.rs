//! SHA-256 for the preset system prompt files' recorded hashes (the `sha2`
//! crate, already in the workspace).

use sha2::{Digest, Sha256};

/// The lowercase hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests;
