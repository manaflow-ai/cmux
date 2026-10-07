//! The install key and the signed mesh message (`cmux-mesh-v1`).
//!
//! The install key is an ECDSA P-256 key that proves a request comes from
//! this installation. It signs every enrollment and key rotation, and a
//! device's own peer-map and tunnel reads, which need no other credential. The file
//! holds the base64 of the 32-byte secret scalar, mode 0600, and is never
//! overwritten. Like the WireGuard key it is never printed, logged, or sent:
//! `Debug` is redacted and only the public point leaves this module.
//!
//! Wire format (the Worker verifies the same bytes):
//! - public key: base64 (standard, padded) of the 65-byte uncompressed SEC1
//!   point `0x04 || X || Y`;
//! - message: eight UTF-8 lines joined by `\n`, no trailing newline:
//!   `cmux-mesh-v1`, purpose, target, WireGuard public key, install public
//!   key, device name (empty except for enroll), signedAt (unix ms), nonce;
//!   purposes `enroll`, `rotate-key`, `peers`, `tunnel` (the last two have
//!   an empty WireGuard key line);
//! - nonce: 16 random bytes, base64url without padding (22 characters);
//! - signature: base64 (standard, padded) of the 64-byte `r || s` ECDSA
//!   P-256 SHA-256 signature (RFC 6979 deterministic k).

use std::fmt;
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::Path;

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use p256::ecdsa::signature::Signer;
use p256::ecdsa::{Signature, SigningKey};
use zeroize::Zeroizing;

/// The first line of every signed message.
pub const MESSAGE_VERSION: &str = "cmux-mesh-v1";

pub struct InstallKey(SigningKey);

impl fmt::Debug for InstallKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("InstallKey(<redacted>)")
    }
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message.to_string())
}

impl InstallKey {
    pub fn generate() -> io::Result<Self> {
        // A random 32-byte string is a valid scalar unless it is 0 or at
        // least the group order (probability about 2^-32); draw again then.
        loop {
            let mut bytes = Zeroizing::new([0u8; 32]);
            getrandom::fill(&mut bytes[..]).map_err(|error| io::Error::other(error.to_string()))?;
            if let Ok(key) = Self::from_scalar(&bytes) {
                return Ok(key);
            }
        }
    }

    /// The key with this secret scalar (big-endian). Fails for 0 and for
    /// values at or above the group order.
    pub fn from_scalar(bytes: &[u8; 32]) -> io::Result<Self> {
        SigningKey::from_slice(bytes)
            .map(Self)
            .map_err(|_| invalid("install key is not a valid P-256 scalar"))
    }

    /// The uncompressed SEC1 public point, `0x04 || X || Y`.
    pub fn public_key_bytes(&self) -> [u8; 65] {
        let point = self.0.verifying_key().to_encoded_point(false);
        point.as_bytes().try_into().expect("an uncompressed P-256 point is 65 bytes")
    }

    pub fn public_key_base64(&self) -> String {
        STANDARD.encode(self.public_key_bytes())
    }

    /// ECDSA P-256 SHA-256 over `message`: `r || s`, 64 bytes.
    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        let signature: Signature = self.0.sign(message);
        let mut bytes = [0u8; 64];
        bytes.copy_from_slice(&signature.to_bytes());
        bytes
    }

    pub fn sign_base64(&self, message: &[u8]) -> String {
        STANDARD.encode(self.sign(message))
    }
}

/// Write `key` to a new file with mode 0600. An existing file is never
/// overwritten.
pub fn write_new_install_key_file(path: &Path, key: &InstallKey) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)?;
    let mut scalar = Zeroizing::new([0u8; 32]);
    scalar.copy_from_slice(&key.0.to_bytes());
    let mut text = Zeroizing::new(STANDARD.encode(&scalar[..]));
    text.push('\n');
    file.write_all(text.as_bytes())?;
    file.sync_all()
}

pub fn read_install_key_file(path: &Path) -> io::Result<InstallKey> {
    let text = Zeroizing::new(std::fs::read_to_string(path)?);
    let bytes = Zeroizing::new(
        STANDARD.decode(text.trim()).map_err(|_| invalid("install key file is not base64"))?,
    );
    let scalar: Zeroizing<[u8; 32]> = Zeroizing::new(
        bytes.as_slice().try_into().map_err(|_| invalid("install key file is not 32 bytes"))?,
    );
    InstallKey::from_scalar(&scalar)
}

/// `install-keygen`: make an install key in a new 0600 file and return its
/// public key (base64).
pub fn install_keygen(path: &Path) -> io::Result<String> {
    let key = InstallKey::generate()?;
    write_new_install_key_file(path, &key)?;
    Ok(key.public_key_base64())
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Enroll,
    RotateKey,
    /// The device reads its own peer map (M3); no credential but this signature.
    Peers,
    /// The device reads its own tunnel config (M3); no credential but this signature.
    Tunnel,
}

impl Purpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Enroll => "enroll",
            Self::RotateKey => "rotate-key",
            Self::Peers => "peers",
            Self::Tunnel => "tunnel",
        }
    }
}

/// The exact bytes that are signed. `target` is the mesh id for enroll and
/// the device id otherwise; `wg_public_key` is the key being registered
/// (empty for peers and tunnel); `name` is empty except for enroll. No field may contain a newline (the
/// callers check ids, keys, and names before they get here).
pub fn message(
    purpose: Purpose,
    target: &str,
    wg_public_key: &str,
    install_public_key: &str,
    name: &str,
    signed_at_ms: u64,
    nonce: &str,
) -> String {
    [
        MESSAGE_VERSION,
        purpose.as_str(),
        target,
        wg_public_key,
        install_public_key,
        name,
        &signed_at_ms.to_string(),
        nonce,
    ]
    .join("\n")
}

/// 16 random bytes, base64url without padding.
pub fn new_nonce() -> io::Result<String> {
    let mut bytes = [0u8; 16];
    getrandom::fill(&mut bytes).map_err(|error| io::Error::other(error.to_string()))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

/// The signed fields a request carries next to its payload.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Proof {
    pub signed_at: u64,
    pub nonce: String,
    pub signature: String,
}

/// Sign at a given time with a given nonce.
pub fn prove_at(
    key: &InstallKey,
    purpose: Purpose,
    target: &str,
    wg_public_key: &str,
    name: &str,
    signed_at: u64,
    nonce: String,
) -> Proof {
    let text =
        message(purpose, target, wg_public_key, &key.public_key_base64(), name, signed_at, &nonce);
    Proof { signed_at, signature: key.sign_base64(text.as_bytes()), nonce }
}

/// Sign now (wall clock) with a fresh nonce.
pub fn prove(
    key: &InstallKey,
    purpose: Purpose,
    target: &str,
    wg_public_key: &str,
    name: &str,
) -> io::Result<Proof> {
    let nonce = new_nonce()?;
    Ok(prove_at(key, purpose, target, wg_public_key, name, crate::ops::wall_ms(), nonce))
}
