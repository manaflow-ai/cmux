//! The signed Cloud machine channel (pure): what CI publishes at
//! [`CHANNEL_URL`] after every feat-cmux-next push whose cmux-tui build is
//! published (`point-machine-channel` in .github/workflows/cmux-tui-artifacts.yml,
//! payload by scripts/ci/cmux-machine-channel.py).
//!
//! The file is the web update pointer's envelope (scripts/cmux-next/web-ota-pointer.py
//! signs and verifies both), around exact payload bytes:
//!
//! ```json
//! {"schema": 1, "payload": "<base64 payload JSON>", "signatures": [{"key_id": "…", "sig": "<base64>"}]}
//! ```
//!
//! [`verify`] checks an ed25519 signature by a [`KEYS`] key over those bytes
//! before it reads any payload field. The key is the web update channel's
//! (CMUX_WEB_OTA_SIGNING_KEY of the `artifacts` environment; its private half
//! never leaves CI); the two kinds of file cannot stand in for each other:
//! this payload must say [`PURPOSE`] and the channel [`CHANNEL`], and the
//! app's web updater refuses a pointer for any channel but its own.

use std::collections::BTreeMap;

use base64::Engine as _;
use ring::signature::{ED25519, UnparsedPublicKey};
use serde::Deserialize;

/// Public, no credentials; the CDN caches it for a minute.
pub const CHANNEL_URL: &str = "https://files.cmux.com/cmux-tui/channels/cloud-machine.json";
/// The payload's `channel`.
pub const CHANNEL: &str = "cloud-machine";
/// The payload's `purpose`: no web update payload carries it.
pub const PURPOSE: &str = "cmux-cloud-machine-update";
pub const SCHEMA: u64 = 1;
/// Every binary comes from the immutable commit-addressed publication.
pub const FILES_PREFIX: &str = "https://files.cmux.com/cmux-tui/";
/// A channel file is a few kilobytes.
pub const CHANNEL_MAX_BYTES: usize = 64 * 1024;
/// A cmux-tui build is about 160 MB.
pub const BINARY_MAX_BYTES: u64 = 512 * 1024 * 1024;
/// The binaries an update replaces, by their store file names.
pub const CMUX_TUI: &str = "cmux-tui";
pub const CMUX_TUI_HOOK: &str = "cmux-tui-hook";

/// The keys a channel file may be signed with: `(id, raw ed25519 key, base64)`.
/// The same key as Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json
/// (the test `keys_match_the_web_update_keys` keeps them equal). To rotate,
/// add the next key here and ship it in machines before CI signs with it.
pub const KEYS: &[(&str, &str)] =
    &[("e5d7bbcacc70703d", "uroy2ajE6JWnMjkx3FNdn88SJN4DCMfLpqZjkwx45WY=")];

#[derive(Deserialize)]
struct Envelope {
    schema: u64,
    payload: String,
    signatures: Vec<Signature>,
}

#[derive(Deserialize)]
struct Signature {
    key_id: String,
    sig: String,
}

/// One binary of a build.
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Binary {
    pub url: String,
    pub sha256: String,
    pub size: u64,
}

/// The channel's build: the commit, when it was committed (the order a
/// machine never goes back on) and, per Rust target, its binaries by
/// store file name ([`CMUX_TUI`], [`CMUX_TUI_HOOK`]).
#[derive(Clone, Debug, PartialEq, Eq, Deserialize)]
pub struct Payload {
    pub schema: u64,
    pub purpose: String,
    pub channel: String,
    pub commit: String,
    pub committed_at: u64,
    pub published_at: u64,
    pub expires_at: u64,
    pub targets: BTreeMap<String, BTreeMap<String, Binary>>,
}

impl Payload {
    /// The binaries for `target`, both of them, checked.
    pub fn binaries_for(&self, target: &str) -> Result<(&Binary, &Binary), String> {
        let set = self
            .targets
            .get(target)
            .ok_or_else(|| format!("the channel has no build for {target}"))?;
        let get = |name: &str| {
            let binary =
                set.get(name).ok_or_else(|| format!("the channel has no {name} for {target}"))?;
            check_binary(binary, &self.commit, &format!("{name}-{target}"))?;
            Ok::<_, String>(binary)
        };
        Ok((get(CMUX_TUI)?, get(CMUX_TUI_HOOK)?))
    }
}

pub fn lower_hex(text: &str, len: usize) -> bool {
    text.len() == len && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn check_binary(binary: &Binary, commit: &str, published_name: &str) -> Result<(), String> {
    let url = format!("{FILES_PREFIX}{commit}/{published_name}");
    if binary.url != url {
        return Err(format!("{published_name}: the url is not {url}"));
    }
    if !lower_hex(&binary.sha256, 64) {
        return Err(format!("{published_name}: the sha256 is not a sha256"));
    }
    if binary.size == 0 || binary.size > BINARY_MAX_BYTES {
        return Err(format!("{published_name}: size {} is out of range", binary.size));
    }
    Ok(())
}

/// The trusted keys of [`KEYS`], decoded.
pub fn trusted_keys() -> Vec<(String, [u8; 32])> {
    KEYS.iter()
        .filter_map(|(id, b64)| {
            let raw = base64::engine::general_purpose::STANDARD.decode(b64).ok()?;
            let raw: [u8; 32] = raw.try_into().ok()?;
            Some(((*id).to_owned(), raw))
        })
        .collect()
}

/// The payload of `body` when a `keys` signature covers it and it is this
/// channel's, unexpired at `now` (unix seconds); else why not.
pub fn verify(body: &[u8], keys: &[(String, [u8; 32])], now: u64) -> Result<Payload, String> {
    let envelope: Envelope =
        serde_json::from_slice(body).map_err(|_| "the channel file is not an envelope")?;
    if envelope.schema != SCHEMA {
        return Err(format!("unknown envelope schema {}", envelope.schema));
    }
    let b64 = base64::engine::general_purpose::STANDARD;
    let payload = b64.decode(&envelope.payload).map_err(|_| "the payload is not base64")?;
    let signed = envelope.signatures.iter().any(|signature| {
        let Some((_, key)) = keys.iter().find(|(id, _)| *id == signature.key_id) else {
            return false;
        };
        let Ok(sig) = b64.decode(&signature.sig) else { return false };
        UnparsedPublicKey::new(&ED25519, key).verify(&payload, &sig).is_ok()
    });
    if !signed {
        return Err("no valid signature by a trusted key".to_owned());
    }
    let payload: Payload =
        serde_json::from_slice(&payload).map_err(|e| format!("the payload does not parse: {e}"))?;
    if payload.schema != SCHEMA {
        return Err(format!("unknown payload schema {}", payload.schema));
    }
    if payload.purpose != PURPOSE || payload.channel != CHANNEL {
        return Err(format!(
            "the payload is for {} channel {}, not a Cloud machine update",
            payload.purpose, payload.channel
        ));
    }
    if !lower_hex(&payload.commit, 40) {
        return Err("the payload names no commit".to_owned());
    }
    if payload.expires_at <= now {
        return Err(format!("the channel file expired at {} (now {now})", payload.expires_at));
    }
    Ok(payload)
}

/// This machine's Rust target, as the published binaries name it.
pub fn local_target() -> Option<&'static str> {
    match std::env::consts::ARCH {
        "x86_64" => Some("x86_64-unknown-linux-musl"),
        "aarch64" => Some("aarch64-unknown-linux-musl"),
        _ => None,
    }
}
