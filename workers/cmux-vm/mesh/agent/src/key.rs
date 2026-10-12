//! The device's X25519 private key.
//!
//! The key is made here, written once to a 0600 file, and read back only by
//! this process. It is never printed, logged, or sent: `Debug` is redacted and
//! the only text this module returns is the public key.

use std::fmt;
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

pub struct PrivateKey(Zeroizing<[u8; 32]>);

impl fmt::Debug for PrivateKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PrivateKey(<redacted>)")
    }
}

impl PrivateKey {
    pub fn generate() -> io::Result<Self> {
        let mut bytes = Zeroizing::new([0u8; 32]);
        getrandom::fill(&mut bytes[..]).map_err(|error| io::Error::other(error.to_string()))?;
        // Clamp now so the file holds exactly the scalar WireGuard uses.
        let clamped = StaticSecret::from(*bytes).to_bytes();
        Ok(Self(Zeroizing::new(clamped)))
    }

    pub fn secret(&self) -> StaticSecret {
        StaticSecret::from(*self.0)
    }

    pub fn public_key(&self) -> [u8; 32] {
        PublicKey::from(&self.secret()).to_bytes()
    }

    pub fn public_key_base64(&self) -> String {
        STANDARD.encode(self.public_key())
    }
}

/// Write `key` to a new file with mode 0600. An existing file is never
/// overwritten.
pub fn write_new_key_file(path: &Path, key: &PrivateKey) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    let mut text = Zeroizing::new(STANDARD.encode(&key.0[..]));
    text.push('\n');
    file.write_all(text.as_bytes())?;
    file.sync_all()
}

pub fn read_key_file(path: &Path) -> io::Result<PrivateKey> {
    let text = Zeroizing::new(std::fs::read_to_string(path)?);
    let bytes = Zeroizing::new(
        STANDARD
            .decode(text.trim())
            .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "key file is not base64"))?,
    );
    let array: [u8; 32] = bytes
        .as_slice()
        .try_into()
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "key file is not 32 bytes"))?;
    Ok(PrivateKey(Zeroizing::new(array)))
}

/// `keygen`: make a key in a new 0600 file and return its public key (base64).
pub fn keygen(path: &Path) -> io::Result<String> {
    let key = PrivateKey::generate()?;
    write_new_key_file(path, &key)?;
    Ok(key.public_key_base64())
}
