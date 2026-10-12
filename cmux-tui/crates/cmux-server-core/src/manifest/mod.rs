//! Signed channel manifest (server.md 4.2 step 4; lane 1 vm-image.md 4.5).
//!
//! The signature is a detached Ed25519 signature over the exact manifest
//! bytes. [`verify`] checks it against the baked public keys (current and
//! next) before it parses anything, then refuses an invalid or expired
//! manifest and a sequence lower than the last applied one. The same
//! sequence is accepted as an idempotent re-apply.
//!
//! JSON shape (schema 1):
//! ```json
//! {"schema": 1, "channel": "stable", "sequence": 42,
//!  "expires_at": "2026-11-01T00:00:00Z", "min_cmux_version": "0.70.0",
//!  "packages": [{"name": "cmux", "version": "0.70.1",
//!    "url": "https://files.cmux.com/…", "sha256": "<64 hex>", "size": 123,
//!    "roles": ["all"]}]}
//! ```
//! Unknown fields are ignored so a newer manifest stays readable; anything a
//! machine must understand raises `min_cmux_version` instead.

mod format;
mod semver;
mod time;
mod validate;

pub use format::{FORMAT_SNIFF_LEN, PackageFormat};
pub use semver::SemVer;
pub use time::parse_rfc3339_utc_ms;
pub use validate::{Version, parse_version, valid_sha256};

use ring::signature::{ED25519, UnparsedPublicKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::layout::Layout;
use crate::platform::HostPath;

pub const SCHEMA: u32 = 1;

/// The version scale of `min_cmux_version`: the release version of the
/// `cmux` binary, which is the cmux-tui crate's version (the binary built
/// as `cmux` for the app bundle and as a store package's `bin/cmux`). The
/// `cmux server` mount passes that crate's `CARGO_PKG_VERSION`; the
/// standalone `cmux-server` binary reports this constant, and a cmux-tui
/// test keeps the two equal. Nothing stamps a version at build time.
pub const CMUX_VERSION: &str = "0.1.0";
pub const SIGNATURE_LEN: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Package {
    pub name: String,
    pub version: String,
    pub url: String,
    /// Lowercase hex SHA-256 of the archive; also its store directory name.
    pub sha256: String,
    pub size: u64,
    pub roles: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChannelManifest {
    pub schema: u32,
    pub channel: String,
    pub sequence: u64,
    pub expires_at: String,
    pub min_cmux_version: String,
    pub packages: Vec<Package>,
}

impl ChannelManifest {
    /// Packages for a machine with `roles` (a package with role `all` is
    /// for every machine).
    pub fn packages_for<'a>(&'a self, roles: &'a [&str]) -> impl Iterator<Item = &'a Package> {
        self.packages
            .iter()
            .filter(move |p| p.roles.iter().any(|r| r == "all" || roles.contains(&r.as_str())))
    }
}

/// A baked release public key.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrustedKey {
    pub id: String,
    pub public_key: [u8; 32],
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    pub manifest: ChannelManifest,
    pub expires_at_ms: u64,
    /// The key that signed it.
    pub key_id: String,
    /// SHA-256 of the exact manifest bytes; stored with the sequence as
    /// [`Applied`] after a successful apply.
    pub sha256: [u8; 32],
    /// The same bytes as the last applied manifest: applying it again is a
    /// no-op that only re-checks the store.
    pub reapply: bool,
    /// The running `cmux` is older than `min_cmux_version`: install the new
    /// `cmux` package first and let it apply the rest.
    pub needs_newer_cmux: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ManifestError {
    /// No trusted key verifies the signature (or it is not 64 bytes).
    BadSignature,
    /// Signed, but not valid JSON of this shape.
    Parse(String),
    /// Signed and parsed, but a field breaks a rule.
    Invalid(String),
    Expired {
        expires_at_ms: u64,
        now_ms: u64,
    },
    /// A sequence lower than the last applied one (a replay or downgrade).
    Rollback {
        sequence: u64,
        last_applied: u64,
    },
    /// The last applied sequence with different bytes: CI never signs two
    /// manifests with one sequence, so this is a key misuse or an attack.
    SequenceReused {
        sequence: u64,
    },
    /// Signed for another channel (a `beta` manifest offered to `stable`).
    ChannelMismatch {
        expected: String,
        got: String,
    },
}

/// What the updater recorded after its last successful apply.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Applied {
    pub sequence: u64,
    pub sha256: [u8; 32],
}

impl Verified {
    pub fn applied(&self) -> Applied {
        Applied { sequence: self.manifest.sequence, sha256: self.sha256 }
    }
}

/// The machine's side of a verification.
#[derive(Clone, Copy, Debug)]
pub struct VerifyContext<'a> {
    /// The baked release keys (current and next).
    pub keys: &'a [TrustedKey],
    pub now_ms: u64,
    /// The machine's `server.channel` (`stable`, `beta`).
    pub expected_channel: &'a str,
    pub last_applied: Option<Applied>,
    /// The running `cmux` version; a prerelease suffix is allowed.
    pub running_cmux: &'a str,
}

/// Verifies `bytes` with `signature`, then parses and checks the manifest:
/// signature, fields, channel, expiry, then sequence and bytes against the
/// last applied manifest.
pub fn verify(
    bytes: &[u8],
    signature: &[u8],
    ctx: &VerifyContext<'_>,
) -> Result<Verified, ManifestError> {
    if signature.len() != SIGNATURE_LEN {
        return Err(ManifestError::BadSignature);
    }
    let key_id = ctx
        .keys
        .iter()
        .find(|k| UnparsedPublicKey::new(&ED25519, &k.public_key).verify(bytes, signature).is_ok())
        .map(|k| k.id.clone())
        .ok_or(ManifestError::BadSignature)?;
    let manifest: ChannelManifest =
        serde_json::from_slice(bytes).map_err(|e| ManifestError::Parse(e.to_string()))?;
    let expires_at_ms = validate::check(&manifest)?;
    if manifest.channel != ctx.expected_channel {
        return Err(ManifestError::ChannelMismatch {
            expected: ctx.expected_channel.to_owned(),
            got: manifest.channel,
        });
    }
    if expires_at_ms <= ctx.now_ms {
        return Err(ManifestError::Expired { expires_at_ms, now_ms: ctx.now_ms });
    }
    let sha256: [u8; 32] = Sha256::digest(bytes).into();
    let reapply = match ctx.last_applied {
        Some(last) if manifest.sequence < last.sequence => {
            return Err(ManifestError::Rollback {
                sequence: manifest.sequence,
                last_applied: last.sequence,
            });
        }
        Some(last) if manifest.sequence == last.sequence && last.sha256 != sha256 => {
            return Err(ManifestError::SequenceReused { sequence: manifest.sequence });
        }
        Some(last) => manifest.sequence == last.sequence,
        None => false,
    };
    // Checked by validation above; a failure here is still an invalid manifest.
    let min = SemVer::release(parse_version(&manifest.min_cmux_version).ok_or_else(|| {
        ManifestError::Invalid(format!("min cmux version {:?}", manifest.min_cmux_version))
    })?);
    let running = SemVer::parse(ctx.running_cmux).ok_or_else(|| {
        ManifestError::Invalid(format!("running cmux version {:?}", ctx.running_cmux))
    })?;
    Ok(Verified {
        needs_newer_cmux: running < min,
        manifest,
        expires_at_ms,
        key_id,
        sha256,
        reapply,
    })
}

/// `<store>/<sha256>`: where a package unpacks (lane 1 store layout).
pub fn store_path(layout: &Layout, package: &Package) -> Option<HostPath> {
    layout.store_package(&package.sha256)
}
