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
        todo!("C5 red: not built yet")
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
        todo!("C5 red: not built yet")
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
