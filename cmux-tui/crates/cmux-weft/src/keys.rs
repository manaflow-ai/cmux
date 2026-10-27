//! Device keys. Both halves are generated on the device and the private
//! halves never leave it.
//!
//! - [`SigningKey`] (Ed25519): the machine key that signs control requests,
//!   and the coordinator's relay-ticket authority.
//! - [`NodeKey`] (X25519): the WireGuard static key.

use std::fmt;

use ring::signature::{ED25519, Ed25519KeyPair, KeyPair, UnparsedPublicKey};
use zeroize::Zeroizing;

/// An Ed25519 key pair kept as its 32-byte seed.
pub struct SigningKey {
    seed: Zeroizing<[u8; 32]>,
    pair: Ed25519KeyPair,
}

impl SigningKey {
    pub fn generate() -> Self {
        let mut seed = Zeroizing::new([0u8; 32]);
        let _ = getrandom::fill(seed.as_mut());
        Self::from_seed(*seed)
    }

    pub fn from_seed(seed: [u8; 32]) -> Self {
        // `from_seed_unchecked` only fails on a wrong length, which the
        // array type already rules out.
        let pair = match Ed25519KeyPair::from_seed_unchecked(&seed) {
            Ok(pair) => pair,
            Err(_) => return Self::generate(),
        };
        Self { seed: Zeroizing::new(seed), pair }
    }

    pub fn seed(&self) -> &[u8; 32] {
        &self.seed
    }

    pub fn public(&self) -> [u8; 32] {
        let mut public = [0u8; 32];
        public.copy_from_slice(self.pair.public_key().as_ref());
        public
    }

    pub fn sign(&self, message: &[u8]) -> [u8; 64] {
        let mut signature = [0u8; 64];
        signature.copy_from_slice(self.pair.sign(message).as_ref());
        signature
    }
}

impl fmt::Debug for SigningKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SigningKey")
            .field("public", &crate::b64::encode_key(&self.public()))
            .finish_non_exhaustive()
    }
}

/// Whether `signature` is `public`'s Ed25519 signature over `message`.
pub fn verify(public: &[u8; 32], message: &[u8], signature: &[u8]) -> bool {
    UnparsedPublicKey::new(&ED25519, public).verify(message, signature).is_ok()
}

/// A WireGuard (X25519) static key.
#[derive(Clone)]
pub struct NodeKey {
    private: Zeroizing<[u8; 32]>,
    public: [u8; 32],
}

impl NodeKey {
    pub fn generate() -> Self {
        let mut private = [0u8; 32];
        let _ = getrandom::fill(&mut private);
        let key = Self::from_private(private);
        zeroize::Zeroize::zeroize(&mut private);
        key
    }

    pub fn from_private(private: [u8; 32]) -> Self {
        let secret = x25519_dalek::StaticSecret::from(private);
        let public = x25519_dalek::PublicKey::from(&secret).to_bytes();
        Self { private: Zeroizing::new(secret.to_bytes()), public }
    }

    pub fn private(&self) -> &[u8; 32] {
        &self.private
    }

    pub fn public(&self) -> [u8; 32] {
        self.public
    }
}

impl fmt::Debug for NodeKey {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("NodeKey")
            .field("public", &crate::b64::encode_key(&self.public))
            .finish_non_exhaustive()
    }
}
