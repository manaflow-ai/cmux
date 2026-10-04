//! [`TransferKey`]: one Ed25519 key pair per transfer, made in memory.
//!
//! The private half never leaves this type except as the OpenSSH private
//! key text that [`super::openssh`] writes to `ssh-add`'s stdin. It is never
//! written to disk, put on argv, logged, or placed in an error: `Debug`
//! shows the public key only, and the seed is zeroed on drop.

use crate::api::{CloudError, codes};
use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use ed25519_dalek::SigningKey;
use zeroize::Zeroizing;

pub struct TransferKey {
    seed: Zeroizing<[u8; 32]>,
    public: [u8; 32],
}

const KEY_TYPE: &[u8] = b"ssh-ed25519";
const COMMENT: &[u8] = b"cmux-transfer";

fn put_string(out: &mut Vec<u8>, value: &[u8]) {
    out.extend_from_slice(&u32::try_from(value.len()).unwrap_or(u32::MAX).to_be_bytes());
    out.extend_from_slice(value);
}

impl TransferKey {
    /// A fresh key from the system random source.
    pub fn generate() -> Result<Self, CloudError> {
        let mut seed = Zeroizing::new([0u8; 32]);
        getrandom::fill(seed.as_mut()).map_err(|e| {
            CloudError::new(codes::UNSUPPORTED, format!("no system random source: {e}"))
        })?;
        let signing = SigningKey::from_bytes(&seed);
        let public = signing.verifying_key().to_bytes();
        Ok(Self { seed, public })
    }

    fn public_blob(&self) -> Vec<u8> {
        let mut blob = Vec::with_capacity(51);
        put_string(&mut blob, KEY_TYPE);
        put_string(&mut blob, &self.public);
        blob
    }

    /// `ssh-ed25519 <base64>`: the only key text sent to the Cloud API.
    pub fn public_openssh(&self) -> String {
        format!("ssh-ed25519 {}", STANDARD.encode(self.public_blob()))
    }

    /// The private key in the OpenSSH format (`openssh-key-v1`, no cipher),
    /// for `ssh-add -` on stdin. Zeroed when dropped.
    pub fn private_openssh(&self) -> Zeroizing<String> {
        let mut private = Zeroizing::new(Vec::with_capacity(160));
        // Two equal check words; their value only needs to match.
        let check = u32::from_be_bytes([self.public[0], self.public[1], self.public[2], 7]);
        private.extend_from_slice(&check.to_be_bytes());
        private.extend_from_slice(&check.to_be_bytes());
        put_string(&mut private, KEY_TYPE);
        put_string(&mut private, &self.public);
        let mut pair = Zeroizing::new([0u8; 64]);
        pair[..32].copy_from_slice(self.seed.as_ref());
        pair[32..].copy_from_slice(&self.public);
        put_string(&mut private, pair.as_ref());
        put_string(&mut private, COMMENT);
        let mut pad = 1u8;
        while private.len() % 8 != 0 {
            private.push(pad);
            pad += 1;
        }
        // Capacities fit the whole text, so no reallocation leaves a copy.
        let mut body = Zeroizing::new(Vec::with_capacity(320));
        body.extend_from_slice(b"openssh-key-v1\0");
        put_string(&mut body, b"none");
        put_string(&mut body, b"none");
        put_string(&mut body, b"");
        body.extend_from_slice(&1u32.to_be_bytes());
        put_string(&mut body, &self.public_blob());
        put_string(&mut body, &private);
        let encoded = Zeroizing::new(STANDARD.encode(body.as_slice()));
        let mut text = Zeroizing::new(String::with_capacity(encoded.len() + 128));
        text.push_str("-----BEGIN OPENSSH PRIVATE KEY-----\n");
        for line in encoded.as_bytes().chunks(70) {
            text.push_str(std::str::from_utf8(line).unwrap_or_default());
            text.push('\n');
        }
        text.push_str("-----END OPENSSH PRIVATE KEY-----\n");
        text
    }
}

impl std::fmt::Debug for TransferKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TransferKey")
            .field("public", &self.public_openssh())
            .field("private", &"<redacted>")
            .finish()
    }
}
