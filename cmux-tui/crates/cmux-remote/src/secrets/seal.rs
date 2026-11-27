//! `secrets-v1` sealing: HPKE (RFC 9180) base mode with DHKEM(X25519,
//! HKDF-SHA256), HKDF-SHA256 and ChaCha20Poly1305, from the `hpke` crate.
//!
//! A device seals each value to the daemon's static X25519 key (its Noise
//! static key from the cmux-remote identity). The `info` binds the machine id,
//! the purpose, the item's name and its nonce; the AAD is the name. Only the
//! daemon holding the private key can open an item, only for that machine,
//! purpose and name.
//!
//! The sealed plaintext is the time the device sealed it (Unix seconds, a
//! big-endian u64), then the value: the time is authenticated with the
//! value, so the daemon can refuse an item sealed long ago.

use cmux_remote_protocol::{ByteString, SealedSecret};
use hpke::aead::ChaCha20Poly1305;
use hpke::kdf::HkdfSha256;
use hpke::kem::X25519HkdfSha256;
use hpke::{Deserializable, Kem as _, OpModeR, OpModeS, Serializable};
use zeroize::Zeroizing;

type Kem = X25519HkdfSha256;

/// The first field of every `info`: the protocol and its version.
const INFO_LABEL: &[u8] = b"cmux secrets-v1";

/// What a sealed item is for; part of its `info`, so an item sealed for
/// another request kind can never open as a machine secret.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Purpose {
    Secret,
}

impl Purpose {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Secret => "secret",
        }
    }
}

/// Why an item could not be sealed or opened. Carries no value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SealError {
    /// The nonce is not 32 lowercase hex digits.
    BadNonce,
    /// The encapsulated key is not a 32-byte X25519 key.
    BadEncapsulation,
    /// Wrong key, wrong machine, wrong purpose, wrong name or a changed byte.
    OpenFailed,
    /// The system random source failed.
    Random,
    /// The `hpke` crate refused to seal.
    SealFailed,
}

impl SealError {
    /// The fixed wire code: never anything from the item.
    pub fn code(self) -> &'static str {
        match self {
            Self::BadNonce => "bad-nonce",
            Self::BadEncapsulation => "bad-encapsulation",
            Self::OpenFailed => "open-failed",
            Self::Random => "random",
            Self::SealFailed => "seal-failed",
        }
    }
}

/// The `info` of one item: the label, then machine id, purpose, name and
/// nonce, each as a big-endian u16 length and its bytes, so no two field
/// lists encode alike.
pub fn info(machine_id: &str, purpose: Purpose, name: &str, nonce: &str) -> Vec<u8> {
    let mut out = INFO_LABEL.to_vec();
    for field in [machine_id, purpose.as_str(), name, nonce] {
        // Every field is far shorter than 64 KiB (names are at most 128
        // bytes); a longer one is cut at the length it declares.
        let length = u16::try_from(field.len()).unwrap_or(u16::MAX);
        out.extend_from_slice(&length.to_be_bytes());
        out.extend_from_slice(field.as_bytes().get(..usize::from(length)).unwrap_or_default());
    }
    out
}

/// Whether `nonce` is 32 lowercase hex digits (128 bits).
pub fn is_nonce(nonce: &str) -> bool {
    nonce.len() == 32 && nonce.bytes().all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// A fresh nonce: 128 bits from the system random source, as lowercase hex.
pub fn fresh_nonce() -> Result<String, SealError> {
    let mut bytes = [0_u8; 16];
    getrandom::fill(&mut bytes).map_err(|_| SealError::Random)?;
    Ok(bytes.iter().map(|byte| format!("{byte:02x}")).collect())
}

/// Seconds since the Unix epoch, now (0 before it).
pub fn unix_now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs())
}

/// An opened item: when the device sealed it, and the value.
pub struct Opened {
    pub issued_at: u64,
    pub value: Zeroizing<Vec<u8>>,
}

/// Seal `value` for the daemon whose static public key is `recipient`,
/// stamped with the time now.
pub fn seal(
    recipient: &[u8; 32],
    machine_id: &str,
    purpose: Purpose,
    name: &str,
    value: &[u8],
) -> Result<SealedSecret, SealError> {
    seal_at(recipient, machine_id, purpose, name, value, unix_now())
}

/// [`seal`] stamped with `issued_at` (Unix seconds).
pub fn seal_at(
    recipient: &[u8; 32],
    machine_id: &str,
    purpose: Purpose,
    name: &str,
    value: &[u8],
    issued_at: u64,
) -> Result<SealedSecret, SealError> {
    let nonce = fresh_nonce()?;
    seal_with_nonce(recipient, machine_id, purpose, name, &nonce, value, issued_at)
}

pub(crate) fn seal_with_nonce(
    recipient: &[u8; 32],
    machine_id: &str,
    purpose: Purpose,
    name: &str,
    nonce: &str,
    value: &[u8],
    issued_at: u64,
) -> Result<SealedSecret, SealError> {
    if !is_nonce(nonce) {
        return Err(SealError::BadNonce);
    }
    let mut plaintext = Zeroizing::new(Vec::with_capacity(8 + value.len()));
    plaintext.extend_from_slice(&issued_at.to_be_bytes());
    plaintext.extend_from_slice(value);
    let recipient = <Kem as hpke::Kem>::PublicKey::from_bytes(recipient)
        .map_err(|_| SealError::BadEncapsulation)?;
    let info = info(machine_id, purpose, name, nonce);
    let mut random = Prefilled::new()?;
    let (encapsulated, ciphertext) =
        hpke::single_shot_seal::<ChaCha20Poly1305, HkdfSha256, Kem, _>(
            &OpModeS::Base,
            &recipient,
            &info,
            &plaintext,
            name.as_bytes(),
            &mut random,
        )
        .map_err(|_| SealError::SealFailed)?;
    if random.short {
        // It ran out of system random bytes: the seal is not used.
        return Err(SealError::Random);
    }
    Ok(SealedSecret {
        name: name.to_owned(),
        nonce: nonce.to_owned(),
        enc: ByteString::from_bytes(&encapsulated.to_bytes()),
        ciphertext: ByteString::from_bytes(&ciphertext),
    })
}

/// Open `item` with the daemon's static private key, for this machine and
/// `purpose`. The value is wiped when dropped.
pub fn open(
    private_key: &[u8; 32],
    machine_id: &str,
    purpose: Purpose,
    item: &SealedSecret,
) -> Result<Opened, SealError> {
    if !is_nonce(&item.nonce) {
        return Err(SealError::BadNonce);
    }
    let encapsulated = item.enc.decode().map_err(|_| SealError::BadEncapsulation)?;
    let encapsulated = <Kem as hpke::Kem>::EncappedKey::from_bytes(&encapsulated)
        .map_err(|_| SealError::BadEncapsulation)?;
    let ciphertext = item.ciphertext.decode().map_err(|_| SealError::OpenFailed)?;
    let private = <Kem as hpke::Kem>::PrivateKey::from_bytes(private_key)
        .map_err(|_| SealError::OpenFailed)?;
    let info = info(machine_id, purpose, &item.name, &item.nonce);
    let plaintext = Zeroizing::new(
        hpke::single_shot_open::<ChaCha20Poly1305, HkdfSha256, Kem>(
            &OpModeR::Base,
            &private,
            &encapsulated,
            &info,
            &ciphertext,
            item.name.as_bytes(),
        )
        .map_err(|_| SealError::OpenFailed)?,
    );
    let (stamp, value) = plaintext.split_at_checked(8).ok_or(SealError::OpenFailed)?;
    let mut issued_at = [0_u8; 8];
    issued_at.copy_from_slice(stamp);
    Ok(Opened { issued_at: u64::from_be_bytes(issued_at), value: Zeroizing::new(value.to_vec()) })
}

/// The public key of a static private key, as the `hpke` crate derives it.
pub fn public_key(private_key: &[u8; 32]) -> Result<[u8; 32], SealError> {
    let private = <Kem as hpke::Kem>::PrivateKey::from_bytes(private_key)
        .map_err(|_| SealError::OpenFailed)?;
    let public = Kem::sk_to_pk(&private).to_bytes();
    let mut out = [0_u8; 32];
    out.copy_from_slice(&public);
    Ok(out)
}

/// System random bytes, read up front (the read can fail, and the
/// `rand_core` trait the `hpke` crate takes can't), served to the seal. A
/// seal takes 32 (its ephemeral X25519 key); asking for more than were read
/// gets zeros and marks the seal `short`, which the caller never uses.
struct Prefilled {
    bytes: Zeroizing<[u8; 64]>,
    used: usize,
    short: bool,
}

impl Prefilled {
    fn new() -> Result<Self, SealError> {
        let mut bytes = Zeroizing::new([0_u8; 64]);
        getrandom::fill(bytes.as_mut_slice()).map_err(|_| SealError::Random)?;
        Ok(Self { bytes, used: 0, short: false })
    }
}

impl rand_core::RngCore for Prefilled {
    fn next_u32(&mut self) -> u32 {
        let mut bytes = [0_u8; 4];
        self.fill_bytes(&mut bytes);
        u32::from_le_bytes(bytes)
    }

    fn next_u64(&mut self) -> u64 {
        let mut bytes = [0_u8; 8];
        self.fill_bytes(&mut bytes);
        u64::from_le_bytes(bytes)
    }

    fn fill_bytes(&mut self, destination: &mut [u8]) {
        let end = self.used.saturating_add(destination.len());
        match self.bytes.get(self.used..end) {
            Some(source) => {
                destination.copy_from_slice(source);
                self.used = end;
            }
            None => {
                destination.fill(0);
                self.short = true;
            }
        }
    }
}

impl rand_core::CryptoRng for Prefilled {}
