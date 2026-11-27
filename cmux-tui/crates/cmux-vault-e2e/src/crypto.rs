//! vault-v1's crypto (cmuxterm-hq docs/design/e2e-vault.md, "Wire").
//!
//! - An item is XChaCha20-Poly1305 under the vault key, its AAD naming the vault, item id, name, scope, revision
//!   and epoch, so a ciphertext the server moves anywhere else does not open.
//! - A wrap is the vault key HPKE-sealed to one device's X25519 key; a delivery is one value HPKE-sealed to a
//!   machine daemon's Noise static key. HPKE is RFC 9180 base mode, DHKEM(X25519, HKDF-SHA256), HKDF-SHA256,
//!   ChaCha20Poly1305: the `secrets-v1` suite (cmux-remote `secrets/seal.rs`), with its own `info` labels.
//!
//! No error here carries a value or key byte.

use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use hpke::aead::ChaCha20Poly1305;
use hpke::kdf::HkdfSha256;
use hpke::kem::X25519HkdfSha256;
use hpke::{Deserializable, Kem as _, OpModeR, OpModeS, Serializable};
use sha2::{Digest as _, Sha256};
use zeroize::Zeroizing;

type Kem = X25519HkdfSha256;

const ITEM_LABEL: &[u8] = b"cmux vault-v1 item";
const WRAP_LABEL: &[u8] = b"cmux vault-v1 wrap";
const DELIVER_LABEL: &[u8] = b"cmux vault-v1 deliver";
const CODE_LABEL: &[u8] = b"cmux vault-v1 code";
const ID_LABEL: &[u8] = b"cmux vault-v1 id";

/// Why a seal or open failed. Never a value.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CryptoError {
    /// The system random source failed.
    Random,
    /// A key is not 32 bytes, or not a usable X25519 key.
    BadKey,
    /// A wrong key, a moved ciphertext or a changed byte.
    OpenFailed,
    /// The AEAD refused to seal.
    SealFailed,
}

impl CryptoError {
    pub fn code(self) -> &'static str {
        match self {
            Self::Random => "vault.random",
            Self::BadKey => "vault.bad_key",
            Self::OpenFailed => "vault.open_failed",
            Self::SealFailed => "vault.seal_failed",
        }
    }
}

impl std::fmt::Display for CryptoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.code())
    }
}

impl std::error::Error for CryptoError {}

fn push_lp(out: &mut Vec<u8>, field: &[u8]) {
    let length = u16::try_from(field.len()).unwrap_or(u16::MAX);
    out.extend_from_slice(&length.to_be_bytes());
    out.extend_from_slice(field.get(..usize::from(length)).unwrap_or_default());
}

fn random<const N: usize>() -> Result<Zeroizing<[u8; N]>, CryptoError> {
    let mut bytes = Zeroizing::new([0_u8; N]);
    getrandom::fill(bytes.as_mut_slice()).map_err(|_| CryptoError::Random)?;
    Ok(bytes)
}

/// A vault key: 32 random bytes, wiped when dropped. No `Debug` of its bytes.
#[derive(Clone)]
pub struct VaultKey(Zeroizing<[u8; 32]>);

impl std::fmt::Debug for VaultKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("VaultKey(..)")
    }
}

impl VaultKey {
    pub fn generate() -> Result<Self, CryptoError> {
        random::<32>().map(Self)
    }

    pub fn from_bytes(bytes: &[u8]) -> Result<Self, CryptoError> {
        let array: [u8; 32] = bytes.try_into().map_err(|_| CryptoError::BadKey)?;
        Ok(Self(Zeroizing::new(array)))
    }

    pub fn as_bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

/// A device's X25519 key pair; the private half is wiped when dropped.
pub struct DeviceKey {
    private: Zeroizing<[u8; 32]>,
    public: [u8; 32],
}

impl std::fmt::Debug for DeviceKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "DeviceKey(code {})", safety_code(&self.public))
    }
}

impl DeviceKey {
    pub fn generate() -> Result<Self, CryptoError> {
        let seed = random::<32>()?;
        let (private, public) = Kem::derive_keypair(seed.as_slice());
        Self::from_parts(&private.to_bytes(), &public.to_bytes())
    }

    /// From a stored private key.
    pub fn from_private(private: &[u8]) -> Result<Self, CryptoError> {
        let key =
            <Kem as hpke::Kem>::PrivateKey::from_bytes(private).map_err(|_| CryptoError::BadKey)?;
        let public = Kem::sk_to_pk(&key).to_bytes();
        Self::from_parts(private, &public)
    }

    fn from_parts(private: &[u8], public: &[u8]) -> Result<Self, CryptoError> {
        let private: [u8; 32] = private.try_into().map_err(|_| CryptoError::BadKey)?;
        let public: [u8; 32] = public.try_into().map_err(|_| CryptoError::BadKey)?;
        Ok(Self { private: Zeroizing::new(private), public })
    }

    pub fn private_bytes(&self) -> &[u8; 32] {
        &self.private
    }

    pub fn public_bytes(&self) -> &[u8; 32] {
        &self.public
    }
}

/// An HPKE-sealed message: the encapsulated key and the ciphertext.
#[derive(Clone, PartialEq, Eq)]
pub struct Sealed {
    pub enc: Vec<u8>,
    pub ct: Vec<u8>,
}

impl std::fmt::Debug for Sealed {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Sealed({} bytes)", self.ct.len())
    }
}

/// System random bytes read up front for one HPKE seal (`hpke` takes a `rand_core` RNG, which cannot fail).
struct Prefilled {
    bytes: Zeroizing<[u8; 64]>,
    used: usize,
    short: bool,
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

fn hpke_seal(recipient: &[u8], info: &[u8], plaintext: &[u8]) -> Result<Sealed, CryptoError> {
    let recipient =
        <Kem as hpke::Kem>::PublicKey::from_bytes(recipient).map_err(|_| CryptoError::BadKey)?;
    let mut rng = Prefilled { bytes: random::<64>()?, used: 0, short: false };
    let (enc, ct) = hpke::single_shot_seal::<ChaCha20Poly1305, HkdfSha256, Kem, _>(
        &OpModeS::Base,
        &recipient,
        info,
        plaintext,
        &[],
        &mut rng,
    )
    .map_err(|_| CryptoError::SealFailed)?;
    if rng.short {
        return Err(CryptoError::Random);
    }
    Ok(Sealed { enc: enc.to_bytes().to_vec(), ct })
}

fn hpke_open(
    private: &[u8; 32],
    info: &[u8],
    sealed: &Sealed,
) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
    let enc = <Kem as hpke::Kem>::EncappedKey::from_bytes(&sealed.enc)
        .map_err(|_| CryptoError::OpenFailed)?;
    let private =
        <Kem as hpke::Kem>::PrivateKey::from_bytes(private).map_err(|_| CryptoError::BadKey)?;
    hpke::single_shot_open::<ChaCha20Poly1305, HkdfSha256, Kem>(
        &OpModeR::Base,
        &private,
        &enc,
        info,
        &sealed.ct,
        &[],
    )
    .map(Zeroizing::new)
    .map_err(|_| CryptoError::OpenFailed)
}

/// Where an item belongs: what its AAD binds.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ItemPlace<'a> {
    pub vault: &'a str,
    pub item_id: &'a str,
    pub name: &'a str,
    pub scope: &'a str,
    pub revision: u64,
    pub epoch: u64,
}

impl ItemPlace<'_> {
    fn aad(&self) -> Vec<u8> {
        let mut out = ITEM_LABEL.to_vec();
        for field in [self.vault, self.item_id, self.name, self.scope] {
            push_lp(&mut out, field.as_bytes());
        }
        out.extend_from_slice(&self.revision.to_be_bytes());
        out.extend_from_slice(&self.epoch.to_be_bytes());
        out
    }
}

/// A sealed item: its 24-byte nonce and ciphertext.
#[derive(Clone, PartialEq, Eq)]
pub struct SealedItem {
    pub nonce: [u8; 24],
    pub ciphertext: Vec<u8>,
}

impl std::fmt::Debug for SealedItem {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "SealedItem({} bytes)", self.ciphertext.len())
    }
}

pub fn seal_item(
    key: &VaultKey,
    place: &ItemPlace<'_>,
    value: &[u8],
) -> Result<SealedItem, CryptoError> {
    let nonce = random::<24>()?;
    let cipher =
        XChaCha20Poly1305::new_from_slice(key.as_bytes()).map_err(|_| CryptoError::BadKey)?;
    let aad = place.aad();
    let ciphertext = cipher
        .encrypt(XNonce::from_slice(nonce.as_slice()), Payload { msg: value, aad: &aad })
        .map_err(|_| CryptoError::SealFailed)?;
    Ok(SealedItem { nonce: *nonce, ciphertext })
}

pub fn open_item(
    key: &VaultKey,
    place: &ItemPlace<'_>,
    item: &SealedItem,
) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
    let cipher =
        XChaCha20Poly1305::new_from_slice(key.as_bytes()).map_err(|_| CryptoError::BadKey)?;
    let aad = place.aad();
    cipher
        .decrypt(XNonce::from_slice(&item.nonce), Payload { msg: &item.ciphertext, aad: &aad })
        .map(Zeroizing::new)
        .map_err(|_| CryptoError::OpenFailed)
}

fn wrap_info(vault: &str, device_id: &str, epoch: u64) -> Vec<u8> {
    let mut out = WRAP_LABEL.to_vec();
    push_lp(&mut out, vault.as_bytes());
    push_lp(&mut out, device_id.as_bytes());
    out.extend_from_slice(&epoch.to_be_bytes());
    out
}

/// The vault key sealed to `device_public` for `device_id` at `epoch`.
pub fn wrap_key(
    key: &VaultKey,
    vault: &str,
    device_id: &str,
    device_public: &[u8],
    epoch: u64,
) -> Result<Sealed, CryptoError> {
    hpke_seal(device_public, &wrap_info(vault, device_id, epoch), key.as_bytes())
}

pub fn unwrap_key(
    device: &DeviceKey,
    vault: &str,
    device_id: &str,
    epoch: u64,
    wrap: &Sealed,
) -> Result<VaultKey, CryptoError> {
    let bytes = hpke_open(device.private_bytes(), &wrap_info(vault, device_id, epoch), wrap)?;
    VaultKey::from_bytes(&bytes)
}

fn deliver_info(machine_id: &str, name: &str, revision: u64) -> Vec<u8> {
    let mut out = DELIVER_LABEL.to_vec();
    push_lp(&mut out, machine_id.as_bytes());
    push_lp(&mut out, name.as_bytes());
    out.extend_from_slice(&revision.to_be_bytes());
    out
}

/// One value sealed to a machine's daemon key, for that machine, name and revision.
pub fn seal_delivery(
    machine_key: &[u8],
    machine_id: &str,
    name: &str,
    revision: u64,
    value: &[u8],
) -> Result<Sealed, CryptoError> {
    hpke_seal(machine_key, &deliver_info(machine_id, name, revision), value)
}

/// The machine's side: open one delivered value with the daemon's private key.
pub fn open_delivery(
    daemon_private: &[u8; 32],
    machine_id: &str,
    name: &str,
    revision: u64,
    sealed: &Sealed,
) -> Result<Zeroizing<Vec<u8>>, CryptoError> {
    hpke_open(daemon_private, &deliver_info(machine_id, name, revision), sealed)
}

/// The 8 digits both devices show before an approve: the first 40 bits of SHA-256 over the label and the new
/// device's public key, as `1234 5678`.
pub fn safety_code(public_key: &[u8]) -> String {
    let mut hash = Sha256::new();
    hash.update(CODE_LABEL);
    hash.update(public_key);
    let digest = hash.finalize();
    let mut n: u64 = 0;
    for byte in digest.iter().take(5) {
        n = (n << 8) | u64::from(*byte);
    }
    let digits = n % 100_000_000;
    format!("{:04} {:04}", digits / 10_000, digits % 10_000)
}

/// Whether `typed` is `code` with its spaces and dashes left out or in.
pub fn same_code(code: &str, typed: &str) -> bool {
    let digits = |s: &str| s.chars().filter(char::is_ascii_digit).collect::<String>();
    let typed_digits = digits(typed);
    typed_digits.len() == 8 && typed_digits == digits(code)
}

/// The item id of a name in a scope: the same on every device, so two devices that keep one name never make two
/// items. 22 base64url characters (128 bits of SHA-256).
pub fn item_id(vault: &str, name: &str, scope: &str) -> String {
    let mut buf = ID_LABEL.to_vec();
    for field in [vault, name, scope] {
        push_lp(&mut buf, field.as_bytes());
    }
    let digest = Sha256::digest(&buf);
    crate::b64::encode(digest.get(..16).unwrap_or_default())
}
