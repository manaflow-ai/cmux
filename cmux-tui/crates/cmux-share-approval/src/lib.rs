//! `cmux.share-approval.v1`: the signed yes behind Share This Mac for a Mac
//! already the owner's, made on the device the owner is at.
//!
//! The format, its canonical bytes and the asker's half live here, so the two
//! Rust sides share one definition: the target Mac's acpmux reads and admits
//! it (`acpmux::share_approval::admit`), and the iPhone builds the one it signs
//! after the person's tap (cmux-mobile-link-ffi `share_approval`). The Mac
//! app's Swift twin is `CmuxRemoteShareApproval`; `share_approval_vectors.json`
//! (in acpmux) holds every side to one canonical string.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The approval format; the first line of [`ShareApproval::canonical`].
pub const VERSION: &str = "cmux.share-approval.v1";

/// The same signed yes for a different grant: "control for my other signed-in machines" on the
/// target Mac (acpmux's `signedInMachines` consent), given from the device the owner is at
/// instead of by a click at that Mac. It is the first line of the signed bytes, so a tap that
/// shares a screen is never a control grant, nor the other way round.
pub const CONTROL_VERSION: &str = "cmux.control-approval.v1";

/// The asker app's answer to one Allow click: what the person allowed, where
/// and when, signed by the asker's device key. Ids are the device hub's; the
/// names are for people (the audit and the dialog) and are not signed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ShareApproval {
    pub v: String,
    /// The Mac to share (its device hub id).
    pub target: String,
    #[serde(default)]
    pub target_name: String,
    /// The device the person clicked Allow on (its device hub id).
    pub asker: String,
    #[serde(default)]
    pub asker_name: String,
    /// The signed-in account (device hub user id) that clicked.
    pub confirmed_by: String,
    /// When the person clicked, Unix seconds. Read from a JSON number or a
    /// decimal string; written as a decimal string, as the apps send it, so no
    /// float rounding touches it.
    #[serde(deserialize_with = "unix_seconds", serialize_with = "decimal")]
    pub confirmed_at: u64,
    /// Random per click; the target admits each once.
    pub nonce: String,
    /// base64 raw r||s ECDSA P-256 SHA-256 signature of [`Self::canonical`].
    pub signature: String,
}

fn unix_seconds<'de, D: serde::Deserializer<'de>>(deserializer: D) -> Result<u64, D::Error> {
    match Value::deserialize(deserializer)? {
        Value::Number(number) => number.as_u64(),
        Value::String(text) => text.parse().ok(),
        _ => None,
    }
    .ok_or_else(|| serde::de::Error::custom("confirmed_at must be whole Unix seconds"))
}

fn decimal<S: serde::Serializer>(secs: &u64, serializer: S) -> Result<S::Ok, S::Error> {
    serializer.collect_str(secs)
}

/// One device in an approval: its device hub id and the name people see.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Device<'a> {
    pub id: &'a str,
    pub name: &'a str,
}

/// Why the asker cannot make an approval: a stable code and the person's words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AskRefused {
    pub code: &'static str,
    pub message: String,
}

impl ShareApproval {
    /// The asker's unsigned approval for one tap: the person asked `asker`
    /// (this device) to share `target`, signed in as `account`, at
    /// `confirmed_at`, with a fresh `nonce`. Nothing is signed here: the
    /// device signs [`Self::canonical`] after the tap, and [`Self::signed`]
    /// takes its signature.
    pub fn asked(
        target: Device<'_>,
        asker: Device<'_>,
        account: &str,
        confirmed_at: u64,
        nonce: &str,
    ) -> Result<Self, AskRefused> {
        Self::asked_for(VERSION, target, asker, account, confirmed_at, nonce)
    }

    /// [`Self::asked`] for the grant `version` names: [`VERSION`] (share this Mac's screen) or
    /// [`CONTROL_VERSION`] (control for the person's other signed-in machines).
    pub fn asked_for(
        version: &str,
        target: Device<'_>,
        asker: Device<'_>,
        account: &str,
        confirmed_at: u64,
        nonce: &str,
    ) -> Result<Self, AskRefused> {
        let refuse = |code, message: &str| Err(AskRefused { code, message: message.into() });
        let (target_id, asker_id, account, nonce) =
            (target.id.trim(), asker.id.trim(), account.trim(), nonce.trim());
        if version != VERSION && version != CONTROL_VERSION {
            return refuse("share.bad_version", "unknown approval format");
        }
        if target_id.is_empty() {
            return refuse("share.no_target", "no Mac to share");
        }
        if asker_id.is_empty() {
            return refuse(
                "share.no_device",
                "this device is not registered with your devices yet; try again in a moment",
            );
        }
        if account.is_empty() {
            return refuse("share.signed_out", "sign in to share your Mac");
        }
        if target_id == asker_id {
            return refuse("share.self", "a device cannot ask itself to share");
        }
        if nonce.is_empty() {
            return refuse("share.no_nonce", "an approval needs a nonce");
        }
        // A field holding a line break would change what the canonical lines mean.
        if [target_id, asker_id, account, nonce].iter().any(|field| field.contains('\n')) {
            return refuse("share.bad_field", "an approval field holds a line break");
        }
        Ok(Self {
            v: version.into(),
            target: target_id.into(),
            target_name: target.name.trim().into(),
            asker: asker_id.into(),
            asker_name: asker.name.trim().into(),
            confirmed_by: account.into(),
            confirmed_at,
            nonce: nonce.into(),
            signature: String::new(),
        })
    }

    /// This approval with the device's signature of [`Self::canonical`].
    #[must_use]
    pub fn signed(self, signature: impl Into<String>) -> Self {
        Self { signature: signature.into(), ..self }
    }

    /// The signed bytes, one field per line. The app builds the same string
    /// (`CmuxRemoteShareApproval.canonical`); `share_approval_vectors.json`
    /// holds both sides to it.
    pub fn canonical(&self) -> String {
        format!(
            "{}\ntarget={}\nasker={}\nconfirmed_by={}\nconfirmed_at={}\nnonce={}",
            self.v, self.target, self.asker, self.confirmed_by, self.confirmed_at, self.nonce
        )
    }

    /// The approval as it travels: the JSON object the target reads back.
    pub fn wire(&self) -> Value {
        serde_json::to_value(self).unwrap_or(Value::Null)
    }

    pub fn display_target(&self) -> &str {
        if self.target_name.is_empty() { &self.target } else { &self.target_name }
    }

    pub fn display_asker(&self) -> &str {
        if self.asker_name.is_empty() { &self.asker } else { &self.asker_name }
    }
}

#[cfg(test)]
mod tests;
