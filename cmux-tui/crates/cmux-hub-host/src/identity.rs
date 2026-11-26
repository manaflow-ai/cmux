//! A screen host's device hub identity and account, kept like the Mac's Keychain items but in
//! files only this user can read, with `device.json` (the device id, name and its two P-256
//! keys as PKCS#8) and `account.json` (the hub, the user id and when the anchor ends).
//!
//! Unix: `$XDG_CONFIG_HOME/cmux/screen-host/` (0700), each file 0600. Writes go through a
//! same-directory temp file created with `O_EXCL | O_NOFOLLOW` and a rename; reads refuse a
//! symlink, a file another user owns, or one any other user can read.
//!
//! Windows: `%APPDATA%\cmux\screen-host\`. A user profile's folders inherit an ACL that gives
//! only this user, SYSTEM and the Administrators group access, so the files carry no mode of
//! their own; writes still go through a new temp file and a rename, and reads refuse a symlink
//! or any other reparse point (a junction planted in place of the file).

use crate::b64;
use crate::Res;
use ring::rand::{SecureRandom, SystemRandom};
use ring::signature::{EcdsaKeyPair, KeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use serde::{Deserialize, Serialize};
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

/// A non-empty environment variable as a path.
fn env_dir(name: &str) -> Option<PathBuf> {
    std::env::var_os(name).filter(|v| !v.is_empty()).map(PathBuf::from)
}

/// cmux's folder under the config base: `cmux-next` on macOS, where `cmux`
/// is cmux Classic's; `cmux` elsewhere.
#[cfg(unix)]
const CONFIG_DIR_NAME: &str = if cfg!(target_os = "macos") { "cmux-next" } else { "cmux" };

/// `$XDG_CONFIG_HOME/cmux/screen-host`, else `~/.config/cmux/screen-host`
/// (`cmux-next` instead of `cmux` on macOS).
#[cfg(unix)]
pub fn config_dir() -> Res<PathBuf> {
    let base = match env_dir("XDG_CONFIG_HOME") {
        Some(dir) => dir,
        None => env_dir("HOME").ok_or("HOME is not set")?.join(".config"),
    };
    Ok(base.join(CONFIG_DIR_NAME).join("screen-host"))
}

/// `%APPDATA%\cmux\screen-host` (the roaming profile's application data).
#[cfg(windows)]
pub fn config_dir() -> Res<PathBuf> {
    let base = env_dir("APPDATA").ok_or("APPDATA is not set: run the host as the desktop user")?;
    Ok(base.join("cmux").join("screen-host"))
}

/// `$XDG_RUNTIME_DIR/cmux-screen-host`: the session's private runtime directory (pending
/// requests). No fallback: without the login session's runtime directory there is no
/// private place for them, and the host refuses to run.
#[cfg(unix)]
pub fn runtime_dir() -> Res<PathBuf> {
    let base = env_dir("XDG_RUNTIME_DIR")
        .ok_or("XDG_RUNTIME_DIR is not set: run the host in the desktop user's login session")?;
    Ok(base.join("cmux-screen-host"))
}

/// `%LOCALAPPDATA%\cmux\screen-host\run`: this machine's private state of the running host
/// (pending requests, the capture check). Local, never roamed to another PC.
#[cfg(windows)]
pub fn runtime_dir() -> Res<PathBuf> {
    let base = env_dir("LOCALAPPDATA")
        .ok_or("LOCALAPPDATA is not set: run the host as the desktop user")?;
    Ok(base.join("cmux").join("screen-host").join("run"))
}

/// Creates `dir` (and its parents) under this user's profile; refuses a symlink or junction.
#[cfg(windows)]
pub fn private_dir(dir: &Path) -> Res<()> {
    fs::create_dir_all(dir)?;
    let meta = fs::symlink_metadata(dir)?;
    if !meta.is_dir() || is_reparse_point(&meta) {
        return Err(format!("{} is not a plain directory", dir.display()).into());
    }
    Ok(())
}

/// Whether `meta` (from `symlink_metadata`) is a symlink, junction or other reparse point.
#[cfg(windows)]
fn is_reparse_point(meta: &fs::Metadata) -> bool {
    use std::os::windows::fs::MetadataExt;
    const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x400;
    meta.file_type().is_symlink() || meta.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
}

/// A new file at `path` that only this user may read (`O_EXCL`, 0600, no symlink followed).
#[cfg(unix)]
fn create_private(path: &Path) -> std::io::Result<fs::File> {
    OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

/// A new file at `path` (`CREATE_NEW`: never an existing file or a link's target), with the
/// profile folder's inherited ACL.
#[cfg(windows)]
fn create_private(path: &Path) -> std::io::Result<fs::File> {
    OpenOptions::new().write(true).create_new(true).open(path)
}

/// Creates `dir` (and its parents) and makes it this user's 0700 directory; refuses a symlink
/// or a directory another user owns.
#[cfg(unix)]
pub fn private_dir(dir: &Path) -> Res<()> {
    fs::create_dir_all(dir)?;
    let meta = fs::symlink_metadata(dir)?;
    if !meta.is_dir() {
        return Err(format!("{} is not a directory", dir.display()).into());
    }
    // SAFETY: geteuid has no preconditions.
    if meta.uid() != unsafe { libc::geteuid() } {
        return Err(format!("{} belongs to another user", dir.display()).into());
    }
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    Ok(())
}

/// Writes `bytes` to `path` as this user's private file, atomically.
pub fn write_private(path: &Path, bytes: &[u8]) -> Res<()> {
    let dir = path.parent().ok_or("no parent directory")?;
    private_dir(dir)?;
    let mut nonce = [0u8; 8];
    SystemRandom::new().fill(&mut nonce).map_err(|_| "no randomness")?;
    let tmp = dir.join(format!(
        ".{}.{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("file"),
        crate::hex(&nonce)
    ));
    let written = (|| -> std::io::Result<()> {
        let mut file = create_private(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        // Windows: MoveFileEx with MOVEFILE_REPLACE_EXISTING, so an older file is replaced.
        fs::rename(&tmp, path)
    })();
    if let Err(e) = written {
        let _ = fs::remove_file(&tmp);
        return Err(format!("{}: {e}", path.display()).into());
    }
    Ok(())
}

/// Reads this user's private file: None when it does not exist; an error for a symlink, a file
/// of another user, or one with group or other permissions.
#[cfg(unix)]
pub fn read_private(path: &Path) -> Res<Option<Vec<u8>>> {
    let mut file = match OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
    {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{}: {e}", path.display()).into()),
    };
    let meta = file.metadata()?;
    // SAFETY: geteuid has no preconditions.
    if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } || meta.mode() & 0o077 != 0 {
        return Err(format!(
            "{} must be this user's file with mode 0600 (chmod 600 it, or remove it)",
            path.display()
        )
        .into());
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(Some(bytes))
}

/// Reads this user's private file: None when it does not exist; an error for a symlink,
/// junction or anything but a plain file. The file is opened without following a reparse
/// point (`FILE_FLAG_OPEN_REPARSE_POINT`), and the opened handle is the one checked.
#[cfg(windows)]
pub fn read_private(path: &Path) -> Res<Option<Vec<u8>>> {
    use std::os::windows::fs::OpenOptionsExt;
    const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x0020_0000;
    let mut file =
        match OpenOptions::new().read(true).custom_flags(FILE_FLAG_OPEN_REPARSE_POINT).open(path) {
            Ok(f) => f,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(e) => return Err(format!("{}: {e}", path.display()).into()),
        };
    let meta = file.metadata()?;
    if !meta.is_file() || is_reparse_point(&meta) {
        return Err(format!("{} must be a plain file (remove it)", path.display()).into());
    }
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes)?;
    Ok(Some(bytes))
}

/// The device: its hub id, its name and its signing and key-agreement keys.
#[derive(Serialize, Deserialize, Clone)]
pub struct Device {
    pub id: String,
    pub name: String,
    /// PKCS#8 of the P-256 signing key (base64).
    pub signing_pkcs8: String,
    /// PKCS#8 of the P-256 key whose public point is the registered agreement key (base64).
    /// The relay secrets the person seals to it open with [`Device::open_sealed`].
    pub agreement_pkcs8: String,
}

impl Device {
    /// A new device with fresh keys.
    pub fn generate(name: &str) -> Res<Self> {
        let rng = SystemRandom::new();
        let key = |_: ()| -> Res<String> {
            let doc = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
                .map_err(|_| "key generation failed")?;
            Ok(b64::encode(doc.as_ref()))
        };
        Ok(Self {
            id: uuid_v4(&rng)?,
            name: name.to_owned(),
            signing_pkcs8: key(())?,
            agreement_pkcs8: key(())?,
        })
    }

    pub fn signer(&self) -> Res<Signer> {
        Signer::from_pkcs8(&self.signing_pkcs8)
    }

    /// The agreement key's public point (base64 X9.63, 65 bytes).
    pub fn agreement_key(&self) -> Res<String> {
        Ok(Signer::from_pkcs8(&self.agreement_pkcs8)?.public_key())
    }

    /// Opens what was sealed to the agreement key: HPKE base mode (RFC 9180) with
    /// DHKEM(P-256, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM, no associated data. A relay
    /// blob (PROTOCOL.md, Relays) is the 65-byte `encapsulated_key` then the `ciphertext`,
    /// with `info` `cmux-device-hub relay v1 <relay id>`.
    pub fn open_sealed(
        &self,
        ciphertext: &[u8],
        encapsulated_key: &[u8],
        info: &[u8],
    ) -> Res<Vec<u8>> {
        use hpke::Deserializable;
        use p256::pkcs8::DecodePrivateKey;
        type Kem = hpke::kem::DhP256HkdfSha256;
        let der = b64::decode(&self.agreement_pkcs8).ok_or("key is not base64")?;
        let secret = p256::SecretKey::from_pkcs8_der(&der)
            .map_err(|_| "the agreement key is not a P-256 PKCS#8 key")?;
        let private = <Kem as hpke::Kem>::PrivateKey::from_bytes(&secret.to_bytes())
            .map_err(|_| "the agreement key is not a P-256 private key")?;
        let encapsulated = <Kem as hpke::Kem>::EncappedKey::from_bytes(encapsulated_key)
            .map_err(|_| "the encapsulated key is not a P-256 point")?;
        hpke::single_shot_open::<hpke::aead::AesGcm256, hpke::kdf::HkdfSha256, Kem>(
            &hpke::OpModeR::Base,
            &private,
            &encapsulated,
            info,
            ciphertext,
            &[],
        )
        .map_err(|_| "the sealed secret does not open with this device's agreement key".into())
    }

    pub fn load(dir: &Path) -> Res<Option<Self>> {
        match read_private(&dir.join("device.json"))? {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn save(&self, dir: &Path) -> Res<()> {
        write_private(&dir.join("device.json"), &serde_json::to_vec_pretty(self)?)
    }
}

/// The account this device was enabled for.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Account {
    /// The device hub's origin, e.g. `https://cmux-device-hub.example`.
    pub hub: String,
    pub user_id: String,
    /// When the anchor (`POST /v1/auth/device/anchor`) ends, Unix ms.
    #[serde(default)]
    pub anchored_until: u64,
}

impl Account {
    pub fn load(dir: &Path) -> Res<Option<Self>> {
        match read_private(&dir.join("account.json"))? {
            Some(bytes) => Ok(Some(serde_json::from_slice(&bytes)?)),
            None => Ok(None),
        }
    }

    pub fn save(&self, dir: &Path) -> Res<()> {
        write_private(&dir.join("account.json"), &serde_json::to_vec_pretty(self)?)
    }
}

/// The device's signing key: raw r||s ECDSA-P256-SHA256 signatures.
pub struct Signer {
    pair: EcdsaKeyPair,
    rng: SystemRandom,
}

impl Signer {
    pub fn from_pkcs8(base64: &str) -> Res<Self> {
        let rng = SystemRandom::new();
        let der = b64::decode(base64).ok_or("key is not base64")?;
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &rng)
            .map_err(|_| "key is not a P-256 PKCS#8 key")?;
        Ok(Self { pair, rng })
    }

    /// base64 of the 65-byte uncompressed public point.
    pub fn public_key(&self) -> String {
        b64::encode(self.pair.public_key().as_ref())
    }

    /// 64 bytes, r||s.
    pub fn sign(&self, message: &[u8]) -> Res<Vec<u8>> {
        Ok(self.pair.sign(&self.rng, message).map_err(|_| "signing failed")?.as_ref().to_vec())
    }
}

#[allow(clippy::string_slice, reason = "the hex of 16 bytes is 32 ASCII characters")]
fn uuid_v4(rng: &SystemRandom) -> Res<String> {
    let mut b = [0u8; 16];
    rng.fill(&mut b).map_err(|_| "no randomness")?;
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = crate::hex(&b);
    Ok(format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32]))
}

/// This machine's name for a new device (the kernel host name).
#[cfg(unix)]
pub fn host_name() -> String {
    fs::read_to_string("/proc/sys/kernel/hostname")
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Linux".to_owned())
}

/// This machine's name for a new device (the computer name Windows shows in Settings > System).
#[cfg(windows)]
pub fn host_name() -> String {
    std::env::var("COMPUTERNAME")
        .ok()
        .map(|s| s.trim().to_owned())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Windows".to_owned())
}

#[cfg(test)]
#[path = "identity_tests.rs"]
mod tests;
