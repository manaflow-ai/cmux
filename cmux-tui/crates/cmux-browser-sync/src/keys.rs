//! Keys for end-to-end encrypted browser sync (RFD 0125 D8, "Keys"): each device holds its own X25519 key pair; a
//! profile's 32-byte key is wrapped to each device; a recovery key is shown once and can unwrap it too.
//!
//! A wrap to a device is an ECIES-style seal: a fresh ephemeral X25519 key, the shared secret through HKDF-SHA256
//! (salt: both public keys; info: the label, profile id and key version), and ChaCha20-Poly1305 over the profile key
//! with the same fields as associated data. So a wrap made for one profile or version never opens as another.
//!
//! Server escrow is Leo's decision ([irreversible] 2) and is a switch here: [`EscrowPolicy::None`] (the default)
//! refuses to wrap to an escrow key at all; [`EscrowPolicy::Server`] adds one more wrap to the server's public key.

use anyhow::{Context as _, anyhow, bail, ensure};
use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD as B64;
use ring::aead::{Aad, CHACHA20_POLY1305, LessSafeKey, Nonce, UnboundKey};
use ring::hkdf;
use serde::{Deserialize, Serialize};
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, Zeroizing};

const WRAP_LABEL: &str = "cmux-browser-sync/wrap/v1";
const RECOVERY_LABEL: &str = "cmux-browser-sync/recovery/v1";

/// Fills a fresh array from the OS's random source.
pub(crate) fn random<const N: usize>() -> anyhow::Result<[u8; N]> {
    let mut bytes = [0u8; N];
    getrandom::fill(&mut bytes).map_err(|error| anyhow!("no randomness: {error}"))?;
    Ok(bytes)
}

/// Whether the server may hold an escrowed copy of each profile key. Leo rules on it (RFD 0125 [irreversible] 2);
/// until then it is `None`.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum EscrowPolicy {
    /// No escrow: losing every device and the recovery key loses the synced data.
    #[default]
    None,
    /// The server holds one more wrap, to its escrow public key.
    Server { escrow_public: [u8; 32] },
}

/// A profile's symmetric key. Zeroed on drop; never serialized bare.
pub struct ProfileKey(Zeroizing<[u8; 32]>);

impl ProfileKey {
    pub fn generate() -> anyhow::Result<Self> {
        Ok(Self(Zeroizing::new(random()?)))
    }
    pub(crate) fn bytes(&self) -> &[u8; 32] {
        &self.0
    }
}

impl std::fmt::Debug for ProfileKey {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("ProfileKey(..)")
    }
}

/// One device's key pair. The secret stays on the device (the caller keeps it in the Keychain or the daemon's
/// key file); only [`DeviceKey::public`] is shared.
pub struct DeviceKey {
    pub id: String,
    secret: StaticSecret,
}

impl DeviceKey {
    pub fn generate(id: &str) -> anyhow::Result<Self> {
        Ok(Self { id: id.to_owned(), secret: StaticSecret::from(random::<32>()?) })
    }
    pub fn from_secret(id: &str, mut secret: [u8; 32]) -> Self {
        let key = Self { id: id.to_owned(), secret: StaticSecret::from(secret) };
        secret.zeroize();
        key
    }
    pub fn secret_bytes(&self) -> Zeroizing<[u8; 32]> {
        Zeroizing::new(self.secret.to_bytes())
    }
    pub fn public(&self) -> [u8; 32] {
        PublicKey::from(&self.secret).to_bytes()
    }
}

/// A recovery key: 32 random bytes shown to the person once, as groups of base32-free hex.
pub struct RecoveryKey(Zeroizing<[u8; 32]>);

impl RecoveryKey {
    pub fn generate() -> anyhow::Result<Self> {
        Ok(Self(Zeroizing::new(random()?)))
    }
    /// The text shown once: 64 hex digits in groups of 8, dash separated.
    pub fn display(&self) -> Zeroizing<String> {
        let groups: Vec<String> = self
            .0
            .chunks(4)
            .map(|group| group.iter().map(|byte| format!("{byte:02x}")).collect())
            .collect();
        Zeroizing::new(groups.join("-"))
    }
    /// Reads what the person typed back: hex digits, any dashes or spaces, any case.
    pub fn parse(text: &str) -> anyhow::Result<Self> {
        let digits: Zeroizing<String> = Zeroizing::new(
            text.chars().filter(|c| !matches!(c, '-' | ' ')).collect::<String>().to_lowercase(),
        );
        ensure!(digits.len() == 64, "a recovery key is 64 hex digits");
        let nibbles: Zeroizing<Vec<u8>> = Zeroizing::new(
            digits
                .chars()
                .map(|c| c.to_digit(16).and_then(|d| u8::try_from(d).ok()))
                .collect::<Option<Vec<u8>>>()
                .ok_or_else(|| anyhow!("a recovery key is hex digits"))?,
        );
        let mut bytes = Zeroizing::new([0u8; 32]);
        for (byte, pair) in bytes.iter_mut().zip(nibbles.chunks_exact(2)) {
            if let [high, low] = pair {
                *byte = (high << 4) | low;
            }
        }
        Ok(Self(bytes))
    }
}

/// Who a wrap opens for.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Recipient {
    Device { device: String },
    Recovery,
    Escrow,
}

/// A profile key sealed to one recipient. Safe to store anywhere, the server included.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WrappedKey {
    pub recipient: Recipient,
    pub profile: String,
    pub key_version: u32,
    /// The sender's ephemeral X25519 public key (base64url); absent for a recovery wrap.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ephemeral: Option<String>,
    pub nonce: String,
    pub ciphertext: String,
}

struct OkmLen;
impl hkdf::KeyType for OkmLen {
    fn len(&self) -> usize {
        32
    }
}

fn derive(secret: &[u8], salt: &[u8], info: &[&[u8]]) -> anyhow::Result<Zeroizing<[u8; 32]>> {
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, salt).extract(secret);
    let okm = prk.expand(info, OkmLen).map_err(|_| anyhow!("hkdf expand"))?;
    let mut out = Zeroizing::new([0u8; 32]);
    okm.fill(out.as_mut()).map_err(|_| anyhow!("hkdf fill"))?;
    Ok(out)
}

pub(crate) fn seal(
    key: &[u8; 32],
    aad: &[u8],
    plaintext: &[u8],
) -> anyhow::Result<([u8; 12], Vec<u8>)> {
    let nonce_bytes = random::<12>()?;
    let key = LessSafeKey::new(
        UnboundKey::new(&CHACHA20_POLY1305, key).map_err(|_| anyhow!("aead key"))?,
    );
    let mut buffer = plaintext.to_vec();
    key.seal_in_place_append_tag(
        Nonce::assume_unique_for_key(nonce_bytes),
        Aad::from(aad),
        &mut buffer,
    )
    .map_err(|_| anyhow!("seal"))?;
    Ok((nonce_bytes, buffer))
}

pub(crate) fn open(
    key: &[u8; 32],
    aad: &[u8],
    nonce: &[u8],
    ciphertext: &[u8],
) -> anyhow::Result<Vec<u8>> {
    let nonce: [u8; 12] = nonce.try_into().map_err(|_| anyhow!("bad nonce"))?;
    let key = LessSafeKey::new(
        UnboundKey::new(&CHACHA20_POLY1305, key).map_err(|_| anyhow!("aead key"))?,
    );
    let mut buffer = ciphertext.to_vec();
    let plain = key
        .open_in_place(Nonce::assume_unique_for_key(nonce), Aad::from(aad), &mut buffer)
        .map_err(|_| anyhow!("does not open: wrong key, or the data was changed"))?;
    Ok(plain.to_vec())
}

pub(crate) fn b64(bytes: &[u8]) -> String {
    B64.encode(bytes)
}

pub(crate) fn unb64(text: &str) -> anyhow::Result<Vec<u8>> {
    B64.decode(text).context("bad base64")
}

fn aad(label: &str, recipient: &Recipient, profile: &str, version: u32) -> Vec<u8> {
    let who = match recipient {
        Recipient::Device { device } => format!("device:{device}"),
        Recipient::Recovery => "recovery".to_owned(),
        Recipient::Escrow => "escrow".to_owned(),
    };
    format!("{label}\n{who}\n{profile}\n{version}").into_bytes()
}

fn wrap_to_public(
    key: &ProfileKey,
    recipient: Recipient,
    profile: &str,
    version: u32,
    public: &[u8; 32],
) -> anyhow::Result<WrappedKey> {
    let ephemeral = StaticSecret::from(random::<32>()?);
    let ephemeral_public = PublicKey::from(&ephemeral).to_bytes();
    let shared = ephemeral.diffie_hellman(&PublicKey::from(*public));
    ensure!(shared.was_contributory(), "the recipient key is not a usable X25519 key");
    let salt = [ephemeral_public.as_slice(), public.as_slice()].concat();
    let aad = aad(WRAP_LABEL, &recipient, profile, version);
    let wrap_key = derive(shared.as_bytes(), &salt, &[&aad])?;
    let (nonce, ciphertext) = seal(&wrap_key, &aad, key.bytes())?;
    Ok(WrappedKey {
        recipient,
        profile: profile.to_owned(),
        key_version: version,
        ephemeral: Some(b64(&ephemeral_public)),
        nonce: b64(&nonce),
        ciphertext: b64(&ciphertext),
    })
}

fn to_key(bytes: Vec<u8>) -> anyhow::Result<ProfileKey> {
    let bytes = Zeroizing::new(bytes);
    let array: [u8; 32] =
        bytes.as_slice().try_into().map_err(|_| anyhow!("a profile key is 32 bytes"))?;
    Ok(ProfileKey(Zeroizing::new(array)))
}

/// Wraps `key` to a device's public key.
pub fn wrap_to_device(
    key: &ProfileKey,
    profile: &str,
    version: u32,
    device: &str,
    device_public: &[u8; 32],
) -> anyhow::Result<WrappedKey> {
    wrap_to_public(
        key,
        Recipient::Device { device: device.to_owned() },
        profile,
        version,
        device_public,
    )
}

/// Opens a wrap made for this device.
pub fn unwrap_for_device(wrapped: &WrappedKey, device: &DeviceKey) -> anyhow::Result<ProfileKey> {
    match &wrapped.recipient {
        Recipient::Device { device: id } if *id == device.id => {}
        other => bail!("this wrap is for {other:?}, not device {}", device.id),
    }
    let ephemeral: [u8; 32] = unb64(wrapped.ephemeral.as_deref().unwrap_or_default())?
        .try_into()
        .map_err(|_| anyhow!("bad ephemeral key"))?;
    let shared = device.secret.diffie_hellman(&PublicKey::from(ephemeral));
    let salt = [ephemeral.as_slice(), device.public().as_slice()].concat();
    let aad = aad(WRAP_LABEL, &wrapped.recipient, &wrapped.profile, wrapped.key_version);
    let wrap_key = derive(shared.as_bytes(), &salt, &[&aad])?;
    to_key(open(&wrap_key, &aad, &unb64(&wrapped.nonce)?, &unb64(&wrapped.ciphertext)?)?)
}

/// Wraps `key` to the recovery key.
pub fn wrap_to_recovery(
    key: &ProfileKey,
    profile: &str,
    version: u32,
    recovery: &RecoveryKey,
) -> anyhow::Result<WrappedKey> {
    let recipient = Recipient::Recovery;
    let aad = aad(RECOVERY_LABEL, &recipient, profile, version);
    let wrap_key = derive(recovery.0.as_slice(), RECOVERY_LABEL.as_bytes(), &[&aad])?;
    let (nonce, ciphertext) = seal(&wrap_key, &aad, key.bytes())?;
    Ok(WrappedKey {
        recipient,
        profile: profile.to_owned(),
        key_version: version,
        ephemeral: None,
        nonce: b64(&nonce),
        ciphertext: b64(&ciphertext),
    })
}

/// Opens the recovery wrap with the key the person typed back.
pub fn unwrap_with_recovery(
    wrapped: &WrappedKey,
    recovery: &RecoveryKey,
) -> anyhow::Result<ProfileKey> {
    ensure!(wrapped.recipient == Recipient::Recovery, "this wrap is not the recovery wrap");
    let aad = aad(RECOVERY_LABEL, &wrapped.recipient, &wrapped.profile, wrapped.key_version);
    let wrap_key = derive(recovery.0.as_slice(), RECOVERY_LABEL.as_bytes(), &[&aad])?;
    to_key(open(&wrap_key, &aad, &unb64(&wrapped.nonce)?, &unb64(&wrapped.ciphertext)?)?)
}

/// Every wrap of one profile key version.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Keyring {
    pub profile: String,
    pub key_version: u32,
    pub wraps: Vec<WrappedKey>,
}

impl Keyring {
    /// Wraps `key` to each device, the recovery key, and the escrow key only when `escrow` allows it.
    pub fn build(
        key: &ProfileKey,
        profile: &str,
        version: u32,
        devices: &[(String, [u8; 32])],
        recovery: &RecoveryKey,
        escrow: &EscrowPolicy,
    ) -> anyhow::Result<Self> {
        let mut wraps = Vec::with_capacity(devices.len() + 2);
        for (device, public) in devices {
            wraps.push(wrap_to_device(key, profile, version, device, public)?);
        }
        wraps.push(wrap_to_recovery(key, profile, version, recovery)?);
        if let EscrowPolicy::Server { escrow_public } = escrow {
            wraps.push(wrap_to_public(key, Recipient::Escrow, profile, version, escrow_public)?);
        }
        Ok(Self { profile: profile.to_owned(), key_version: version, wraps })
    }

    /// Approves a new device from one that already holds the key (RFD: "a new device is approved from one the
    /// person already has"): opens this device's wrap and adds one for the new device.
    pub fn approve_device(
        &mut self,
        approver: &DeviceKey,
        new_device: &str,
        new_public: &[u8; 32],
    ) -> anyhow::Result<()> {
        let key = self.open_for_device(approver)?;
        self.wraps
            .retain(|wrap| wrap.recipient != Recipient::Device { device: new_device.to_owned() });
        self.wraps.push(wrap_to_device(
            &key,
            &self.profile,
            self.key_version,
            new_device,
            new_public,
        )?);
        Ok(())
    }

    /// Removes a device's wrap. The caller rotates the key (a new version) so the removed device cannot read what
    /// is written next.
    pub fn remove_device(&mut self, device: &str) {
        self.wraps.retain(|wrap| wrap.recipient != Recipient::Device { device: device.to_owned() });
    }

    pub fn open_for_device(&self, device: &DeviceKey) -> anyhow::Result<ProfileKey> {
        let wrap = self
            .wraps
            .iter()
            .find(|wrap| wrap.recipient == Recipient::Device { device: device.id.clone() })
            .ok_or_else(|| anyhow!("device {} holds no wrap of this profile key", device.id))?;
        ensure!(
            wrap.profile == self.profile && wrap.key_version == self.key_version,
            "wrap does not match ring"
        );
        unwrap_for_device(wrap, device)
    }

    pub fn open_with_recovery(&self, recovery: &RecoveryKey) -> anyhow::Result<ProfileKey> {
        let wrap = self
            .wraps
            .iter()
            .find(|wrap| wrap.recipient == Recipient::Recovery)
            .ok_or_else(|| anyhow!("this ring has no recovery wrap"))?;
        unwrap_with_recovery(wrap, recovery)
    }

    pub fn has_escrow(&self) -> bool {
        self.wraps.iter().any(|wrap| wrap.recipient == Recipient::Escrow)
    }
}
