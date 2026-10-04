//! The install identity of this server (server.md 6.1): an ES256 (P-256)
//! install key and a WireGuard (X25519) key, generated once on this machine
//! and kept in `<state>/pairing/` (0700) as 0600 files. Neither key is ever
//! printed, logged or passed on argv; only the public halves leave.

use std::path::Path;

use base64::Engine;
use base64::engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD};
use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::error::{Error, Result};
use crate::fsx;

/// The install key, PKCS#8 DER (0600).
pub const INSTALL_KEY_FILE: &str = "install-key.p8";
/// The WireGuard private key, standard base64 like `wg genkey` (0600).
pub const WG_KEY_FILE: &str = "wg-key";

/// The public install key as the backend's `PublicJwk`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct PublicJwk {
    pub kty: &'static str,
    pub crv: &'static str,
    pub x: String,
    pub y: String,
}

/// RFC 7638 SHA-256 thumbprint of a P-256 JWK: the hash of
/// `{"crv":"P-256","kty":"EC","x":…,"y":…}` (members in lexical order, no
/// spaces), the same bytes as the backend's `jwkThumbprint`.
pub fn jwk_thumbprint(x: &str, y: &str) -> [u8; 32] {
    let canonical = format!(r#"{{"crv":"P-256","kty":"EC","x":"{x}","y":"{y}"}}"#);
    Sha256::digest(canonical.as_bytes()).into()
}

/// The message `POST /v1/pair/begin` signs (backend `beginProofMessage`).
pub fn begin_proof_message(
    environment: &str,
    thumbprint_b64u: &str,
    wg_public_key: &str,
    issued_at: u64,
) -> String {
    format!("cmux-pair-begin\n{environment}\n{thumbprint_b64u}\n{wg_public_key}\n{issued_at}")
}

pub fn b64u(bytes: &[u8]) -> String {
    URL_SAFE_NO_PAD.encode(bytes)
}

/// This server's keys.
pub struct InstallIdentity {
    key: EcdsaKeyPair,
    wg_public: [u8; 32],
}

impl std::fmt::Debug for InstallIdentity {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("InstallIdentity")
            .field("thumbprint", &self.thumbprint_b64u())
            .finish_non_exhaustive()
    }
}

impl InstallIdentity {
    /// Builds the identity from stored key material.
    pub fn from_parts(pkcs8: &[u8], wg_secret: [u8; 32]) -> Result<InstallIdentity> {
        let key =
            EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8, &SystemRandom::new())
                .map_err(|_| Error::internal("the install key is not a P-256 PKCS#8 key"))?;
        let secret = x25519_dalek::StaticSecret::from(wg_secret);
        let wg_public = x25519_dalek::PublicKey::from(&secret).to_bytes();
        Ok(InstallIdentity { key, wg_public })
    }

    /// Loads the keys from `dir`, or makes them once. `dir` must exist with
    /// mode 0700; the caller holds the pairing lock, so two runs never make
    /// two keys.
    pub fn load_or_create(dir: &Path) -> Result<InstallIdentity> {
        let key_path = dir.join(INSTALL_KEY_FILE);
        let wg_path = dir.join(WG_KEY_FILE);
        let pkcs8 = match read_secret(&key_path)? {
            Some(bytes) => bytes,
            None => {
                let doc = EcdsaKeyPair::generate_pkcs8(
                    &ECDSA_P256_SHA256_FIXED_SIGNING,
                    &SystemRandom::new(),
                )
                .map_err(|_| Error::internal("could not make an install key"))?;
                fsx::atomic_write(&key_path, doc.as_ref(), 0o600)?;
                doc.as_ref().to_vec()
            }
        };
        let wg_secret = match read_secret(&wg_path)? {
            Some(text) => decode_wg(&text).ok_or_else(|| {
                Error::internal(format!("{}: not a base64 X25519 key", wg_path.display()))
            })?,
            None => {
                let secret = crate::host::random::<32>()?;
                let mut text = STANDARD.encode(secret);
                text.push('\n');
                fsx::atomic_write(&wg_path, text.as_bytes(), 0o600)?;
                secret
            }
        };
        InstallIdentity::from_parts(&pkcs8, wg_secret)
    }

    /// The public key as a JWK (x and y: 32 bytes each, base64url).
    pub fn public_jwk(&self) -> PublicJwk {
        let point = self.key.public_key().as_ref();
        // Uncompressed SEC1: 0x04 || x || y.
        PublicJwk { kty: "EC", crv: "P-256", x: b64u(&point[1..33]), y: b64u(&point[33..65]) }
    }

    /// The uncompressed SEC1 public point (65 bytes).
    pub fn public_point(&self) -> &[u8] {
        self.key.public_key().as_ref()
    }

    pub fn thumbprint(&self) -> [u8; 32] {
        let jwk = self.public_jwk();
        jwk_thumbprint(&jwk.x, &jwk.y)
    }

    pub fn thumbprint_b64u(&self) -> String {
        b64u(&self.thumbprint())
    }

    /// The WireGuard public key, standard base64 with padding (44 chars).
    pub fn wg_public_key(&self) -> String {
        STANDARD.encode(self.wg_public)
    }

    /// ES256 over `message`: raw `r || s` (64 bytes), base64url.
    pub fn sign_b64u(&self, message: &[u8]) -> Result<String> {
        let sig = self
            .key
            .sign(&SystemRandom::new(), message)
            .map_err(|_| Error::internal("could not sign with the install key"))?;
        Ok(b64u(sig.as_ref()))
    }
}

fn decode_wg(text: &[u8]) -> Option<[u8; 32]> {
    let text = std::str::from_utf8(text).ok()?.trim();
    STANDARD.decode(text).ok()?.try_into().ok()
}

/// Reads a key file; `None` when it is missing. A symlink, another
/// owner or a key readable by others is refused, never silently narrowed.
fn read_secret(path: &Path) -> Result<Option<Vec<u8>>> {
    super::private::read(path)
}
