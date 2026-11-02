//! Keys held in process memory: the raw P-256 private scalars and their
//! public points, as the Secret Service and key file stores keep them.

use ring::rand::SystemRandom;
use ring::signature::{ECDSA_P256_SHA256_FIXED_SIGNING, EcdsaKeyPair, KeyPair as _};
use serde::{Deserialize, Serialize};
use zeroize::Zeroizing;

use super::{Assurance, DeviceIdentity, DeviceKeys, IdentityError, Platform, is_device_id};

/// The stored form of a software identity (JSON in the Secret Service item or
/// the key file). Private scalars are lowercase hex, public points base64 X9.63.
#[derive(Clone, Serialize, Deserialize)]
pub struct StoredSoftwareIdentity {
    pub v: u32,
    pub id: String,
    #[serde(rename = "signingPrivate")]
    pub signing_private: String,
    #[serde(rename = "signingPublic")]
    pub signing_public: String,
    #[serde(rename = "agreementPrivate")]
    pub agreement_private: String,
    #[serde(rename = "agreementPublic")]
    pub agreement_public: String,
}

impl Drop for StoredSoftwareIdentity {
    fn drop(&mut self) {
        use zeroize::Zeroize as _;
        self.signing_private.zeroize();
        self.agreement_private.zeroize();
    }
}

/// A P-256 key pair in memory.
struct SoftwarePair {
    signer: EcdsaKeyPair,
    private: Zeroizing<[u8; 32]>,
    public: [u8; 65],
}

impl SoftwarePair {
    fn generate(rng: &SystemRandom) -> Result<SoftwarePair, IdentityError> {
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, rng)
            .map_err(|_| IdentityError::Crypto("could not generate a P-256 key".into()))?;
        let (private, public) = parse_ring_pkcs8(pkcs8.as_ref())?;
        SoftwarePair::from_parts(&private, &public)
    }

    fn from_parts(private: &[u8], public: &[u8]) -> Result<SoftwarePair, IdentityError> {
        let rng = SystemRandom::new();
        let signer = EcdsaKeyPair::from_private_key_and_public_key(
            &ECDSA_P256_SHA256_FIXED_SIGNING,
            private,
            public,
            &rng,
        )
        .map_err(|_| {
            IdentityError::Corrupt("the private key does not match its public key".into())
        })?;
        let private: [u8; 32] = private
            .try_into()
            .map_err(|_| IdentityError::Corrupt("a private key is not 32 bytes".into()))?;
        let mut public_out = [0u8; 65];
        public_out.copy_from_slice(signer.public_key().as_ref());
        Ok(SoftwarePair { signer, private: Zeroizing::new(private), public: public_out })
    }
}

/// A signing and an agreement key in memory. `assurance` is the store's.
pub struct SoftwareKeys {
    signing: SoftwarePair,
    agreement: SoftwarePair,
    assurance: Assurance,
    rng: SystemRandom,
}

impl SoftwareKeys {
    /// Two fresh keys.
    pub fn generate(assurance: Assurance) -> Result<SoftwareKeys, IdentityError> {
        let rng = SystemRandom::new();
        Ok(SoftwareKeys {
            signing: SoftwarePair::generate(&rng)?,
            agreement: SoftwarePair::generate(&rng)?,
            assurance,
            rng,
        })
    }

    /// Keys from raw private scalars and their X9.63 public points; each pair
    /// is checked to match.
    pub fn from_raw(
        signing_private: &[u8],
        signing_public: &[u8],
        agreement_private: &[u8],
        agreement_public: &[u8],
        assurance: Assurance,
    ) -> Result<SoftwareKeys, IdentityError> {
        Ok(SoftwareKeys {
            signing: SoftwarePair::from_parts(signing_private, signing_public)?,
            agreement: SoftwarePair::from_parts(agreement_private, agreement_public)?,
            assurance,
            rng: SystemRandom::new(),
        })
    }

    /// The stored form, with `id`.
    pub fn to_stored(&self, id: &str) -> StoredSoftwareIdentity {
        use base64::Engine as _;
        let engine = base64::engine::general_purpose::STANDARD;
        StoredSoftwareIdentity {
            v: 1,
            id: id.to_owned(),
            signing_private: hex::encode(*self.signing.private),
            signing_public: engine.encode(self.signing.public),
            agreement_private: hex::encode(*self.agreement.private),
            agreement_public: engine.encode(self.agreement.public),
        }
    }

    /// An identity from its stored form.
    pub fn identity_from_stored(
        stored: &StoredSoftwareIdentity,
        platform: Platform,
        assurance: Assurance,
    ) -> Result<DeviceIdentity, IdentityError> {
        use base64::Engine as _;
        let engine = base64::engine::general_purpose::STANDARD;
        if stored.v != 1 {
            return Err(IdentityError::Corrupt(format!("unknown version {}", stored.v)));
        }
        if !is_device_id(&stored.id) {
            return Err(IdentityError::Corrupt("the device id is not a lowercase UUID".into()));
        }
        let hex_key = |text: &str| {
            hex::decode(text)
                .map(Zeroizing::new)
                .map_err(|_| IdentityError::Corrupt("a private key is not hex".into()))
        };
        let b64_key = |text: &str| {
            engine
                .decode(text)
                .map_err(|_| IdentityError::Corrupt("a public key is not base64".into()))
        };
        let keys = SoftwareKeys::from_raw(
            &hex_key(&stored.signing_private)?,
            &b64_key(&stored.signing_public)?,
            &hex_key(&stored.agreement_private)?,
            &b64_key(&stored.agreement_public)?,
            assurance,
        )?;
        Ok(DeviceIdentity::new(stored.id.clone(), platform, std::sync::Arc::new(keys)))
    }
}

impl DeviceKeys for SoftwareKeys {
    fn signing_public_key(&self) -> [u8; 65] {
        self.signing.public
    }

    fn agreement_public_key(&self) -> [u8; 65] {
        self.agreement.public
    }

    fn sign(&self, message: &[u8]) -> Result<[u8; 64], IdentityError> {
        let signature = self
            .signing
            .signer
            .sign(&self.rng, message)
            .map_err(|_| IdentityError::Crypto("signing failed".into()))?;
        signature
            .as_ref()
            .try_into()
            .map_err(|_| IdentityError::Crypto("the signature is not 64 bytes".into()))
    }

    fn assurance(&self) -> Assurance {
        self.assurance
    }
}

/// One DER TLV: (tag, contents, rest).
fn der_next(input: &[u8]) -> Option<(u8, &[u8], &[u8])> {
    let (&tag, rest) = input.split_first()?;
    let (&first, mut rest) = rest.split_first()?;
    let length = if first < 0x80 {
        usize::from(first)
    } else {
        let count = usize::from(first & 0x7f);
        if count == 0 || count > 2 || rest.len() < count {
            return None;
        }
        let mut length = 0usize;
        for byte in &rest[..count] {
            length = (length << 8) | usize::from(*byte);
        }
        rest = &rest[count..];
        length
    };
    if rest.len() < length {
        return None;
    }
    Some((tag, &rest[..length], &rest[length..]))
}

/// The private scalar and public point of ring's P-256 PKCS#8 v1 document:
/// `SEQUENCE { INTEGER 0, AlgorithmIdentifier, OCTET STRING { ECPrivateKey } }`
/// with `ECPrivateKey = SEQUENCE { INTEGER 1, OCTET STRING d, [1] { BIT STRING Q } }`.
fn parse_ring_pkcs8(document: &[u8]) -> Result<(Zeroizing<Vec<u8>>, Vec<u8>), IdentityError> {
    let malformed = || IdentityError::Crypto("unexpected PKCS#8 layout".into());
    let (tag, outer, _) = der_next(document).ok_or_else(malformed)?;
    if tag != 0x30 {
        return Err(malformed());
    }
    let (tag, _version, rest) = der_next(outer).ok_or_else(malformed)?;
    if tag != 0x02 {
        return Err(malformed());
    }
    let (tag, _algorithm, rest) = der_next(rest).ok_or_else(malformed)?;
    if tag != 0x30 {
        return Err(malformed());
    }
    let (tag, wrapped, _) = der_next(rest).ok_or_else(malformed)?;
    if tag != 0x04 {
        return Err(malformed());
    }
    let (tag, ec_key, _) = der_next(wrapped).ok_or_else(malformed)?;
    if tag != 0x30 {
        return Err(malformed());
    }
    let (tag, _ec_version, mut rest) = der_next(ec_key).ok_or_else(malformed)?;
    if tag != 0x02 {
        return Err(malformed());
    }
    let (tag, scalar, after) = der_next(rest).ok_or_else(malformed)?;
    if tag != 0x04 || scalar.len() != 32 {
        return Err(malformed());
    }
    rest = after;
    while !rest.is_empty() {
        let (tag, contents, after) = der_next(rest).ok_or_else(malformed)?;
        if tag == 0xa1 {
            let (bit_tag, bits, _) = der_next(contents).ok_or_else(malformed)?;
            if bit_tag != 0x03 || bits.len() != 66 || bits[0] != 0 || bits[1] != 0x04 {
                return Err(malformed());
            }
            return Ok((Zeroizing::new(scalar.to_vec()), bits[1..].to_vec()));
        }
        rest = after;
    }
    Err(malformed())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_keys_round_trip_through_the_stored_form() {
        let keys = SoftwareKeys::generate(Assurance::File).unwrap();
        let stored = keys.to_stored("0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60");
        let identity =
            SoftwareKeys::identity_from_stored(&stored, Platform::Linux, Assurance::File).unwrap();
        assert_eq!(identity.keys().signing_public_key(), keys.signing_public_key());
        assert_eq!(identity.keys().agreement_public_key(), keys.agreement_public_key());
        assert_ne!(keys.signing_public_key(), keys.agreement_public_key());
        let signature = identity.keys().sign(b"hello").unwrap();
        assert!(crate::signing::verify(&keys.signing_public_key(), b"hello", &signature));
    }

    #[test]
    fn mismatched_public_key_is_refused() {
        let a = SoftwareKeys::generate(Assurance::File).unwrap();
        let b = SoftwareKeys::generate(Assurance::File).unwrap();
        let mut stored = a.to_stored("0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60");
        stored.signing_public =
            b.to_stored("0b9f4c1e-8d1a-4d7e-9a43-2f0c5e7b1a60").signing_public.clone();
        assert!(
            SoftwareKeys::identity_from_stored(&stored, Platform::Linux, Assurance::File).is_err()
        );
    }
}
