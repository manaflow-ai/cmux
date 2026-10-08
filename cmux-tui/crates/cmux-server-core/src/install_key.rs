//! The ES256 (P-256) install key of a cmux Cloud machine (plans/cmux-next
//! cloud-client-contract.md 1.7 "bind"; vm-image.md 6.3).
//!
//! The machine registers the public half as a JWK at bind and signs the
//! server's auth challenge (prefix + nonce) with the private half. A
//! signature is the fixed 64-byte `r || s` form, base64url without padding,
//! the same bytes WebCrypto's `ECDSA` with `SHA-256` returns.
//!
//! Pure except for the random source, which the caller passes in (ring's
//! ECDSA mixes randomness into every nonce).

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use ring::rand::SecureRandom;
use ring::signature::{
    ECDSA_P256_SHA256_FIXED, ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair,
    UnparsedPublicKey,
};
use serde_json::{Value, json};

pub use ring::rand::SystemRandom;

/// One ES256 key pair and its PKCS#8 encoding (what the machine stores).
pub struct InstallKey {
    pkcs8: Vec<u8>,
    pair: EcdsaKeyPair,
}

impl std::fmt::Debug for InstallKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Never print the private key.
        f.debug_struct("InstallKey").field("public_jwk", &self.public_jwk()).finish()
    }
}

impl InstallKey {
    /// A new random key.
    pub fn generate(rng: &dyn SecureRandom) -> Result<InstallKey, String> {
        let doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, rng)
            .map_err(|_| "install key: generation failed".to_owned())?;
        InstallKey::from_pkcs8(doc.as_ref(), rng)
    }

    /// The key stored as PKCS#8 bytes.
    pub fn from_pkcs8(pkcs8: &[u8], rng: &dyn SecureRandom) -> Result<InstallKey, String> {
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8, rng)
            .map_err(|e| format!("install key: unreadable PKCS#8 ({e})"))?;
        Ok(InstallKey { pkcs8: pkcs8.to_vec(), pair })
    }

    pub fn pkcs8(&self) -> &[u8] {
        &self.pkcs8
    }

    /// The stored form: PKCS#8, base64url.
    pub fn pkcs8_base64url(&self) -> String {
        URL_SAFE_NO_PAD.encode(&self.pkcs8)
    }

    pub fn from_pkcs8_base64url(text: &str, rng: &dyn SecureRandom) -> Result<InstallKey, String> {
        let bytes = URL_SAFE_NO_PAD.decode(text).map_err(|_| "install key: not base64url")?;
        InstallKey::from_pkcs8(&bytes, rng)
    }

    /// `{"kty":"EC","crv":"P-256","x":…,"y":…}`: the public half only.
    pub fn public_jwk(&self) -> Value {
        let point = self.pair.public_key().as_ref();
        // An uncompressed SEC1 point: 0x04 || x (32) || y (32).
        let (x, y) = point[1..].split_at(32);
        json!({
            "kty": "EC",
            "crv": "P-256",
            "x": URL_SAFE_NO_PAD.encode(x),
            "y": URL_SAFE_NO_PAD.encode(y),
        })
    }

    /// ES256 over `message`: 64 bytes `r || s`, base64url.
    pub fn sign(&self, message: &[u8], rng: &dyn SecureRandom) -> Result<String, String> {
        let sig = self.pair.sign(rng, message).map_err(|_| "install key: signing failed")?;
        Ok(URL_SAFE_NO_PAD.encode(sig.as_ref()))
    }
}

/// Whether `signature` (base64url `r || s`) is an ES256 signature of
/// `message` by the public JWK `jwk` (what the server checks).
pub fn verify(jwk: &Value, message: &[u8], signature: &str) -> bool {
    let coord = |name: &str| jwk[name].as_str().and_then(|s| URL_SAFE_NO_PAD.decode(s).ok());
    let (Some(x), Some(y)) = (coord("x"), coord("y")) else { return false };
    if jwk["kty"] != "EC" || jwk["crv"] != "P-256" || x.len() != 32 || y.len() != 32 {
        return false;
    }
    let Ok(sig) = URL_SAFE_NO_PAD.decode(signature) else { return false };
    let mut point = Vec::with_capacity(65);
    point.push(4);
    point.extend_from_slice(&x);
    point.extend_from_slice(&y);
    UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, point).verify(message, &sig).is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signs_and_round_trips_through_pkcs8() {
        let rng = SystemRandom::new();
        let key = InstallKey::generate(&rng).unwrap();
        let jwk = key.public_jwk();
        assert_eq!(jwk.as_object().unwrap().len(), 4, "public part only: {jwk}");
        let sig = key.sign(b"cmux-auth-v1\ndevelopment\ninst\nnonce", &rng).unwrap();
        assert_eq!(URL_SAFE_NO_PAD.decode(&sig).unwrap().len(), 64);
        assert!(verify(&jwk, b"cmux-auth-v1\ndevelopment\ninst\nnonce", &sig));
        assert!(!verify(&jwk, b"cmux-auth-v1\nproduction\ninst\nnonce", &sig));
        let again = InstallKey::from_pkcs8_base64url(&key.pkcs8_base64url(), &rng).unwrap();
        assert_eq!(again.public_jwk(), jwk);
        assert!(!format!("{key:?}").contains("d\""), "debug output never shows a private part");
    }
}
