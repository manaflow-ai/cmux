//! The approval behind Share This Mac for a Mac already the owner's, confirmed
//! on the device the owner is at (Leo, 2026-11-14: "Let the owner confirm from
//! the device they are at (the same-account device asking, one click there,
//! recorded in the audit log)").
//!
//! The asker's cmux app signs a [`ShareApproval`] with its device key (the
//! Secure Enclave key the device hub knows it by) only after the person clicks
//! Allow (cmux-tui `remote_host/share_approval.rs` is the asker's flow). The
//! target Mac admits it ([`admit`]) only from a same-account machine its owner
//! granted ([`SameAccountGrant`]: hq#11046 cut 1's `signedInMachines` consent),
//! with the asker's signature, naming this Mac, fresh, and with a nonce not seen
//! before. The target then turns Share This Mac on itself (its own
//! `PUT /v1/devices/:id/mac-screen`), and its audit line is [`target_entry`].
//! It lives in acpmux, beside the hub carrier that brings the approval in.

use std::collections::HashSet;

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The approval format; the first line of [`ShareApproval::canonical`].
pub const VERSION: &str = "cmux.share-approval.v1";
/// How old an approval may be when the target reads it (the app stamps it at the
/// Allow click, however long the dialog waited; delivery takes seconds).
pub const MAX_AGE_SECS: u64 = 300;
/// How far ahead of the target's clock an approval may be.
pub const MAX_SKEW_SECS: u64 = 60;

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
    /// When the person clicked, Unix seconds (a JSON number or decimal string:
    /// the app sends a string, so no float rounding touches it).
    #[serde(deserialize_with = "unix_seconds")]
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

impl ShareApproval {
    /// The signed bytes, one field per line. The app builds the same string
    /// (`CmuxRemoteShareApproval.canonical`); `share_approval_vectors.json`
    /// holds both sides to it.
    pub fn canonical(&self) -> String {
        format!(
            "{}\ntarget={}\nasker={}\nconfirmed_by={}\nconfirmed_at={}\nnonce={}",
            self.v, self.target, self.asker, self.confirmed_by, self.confirmed_at, self.nonce
        )
    }

    pub fn display_target(&self) -> &str {
        if self.target_name.is_empty() { &self.target } else { &self.target_name }
    }

    pub fn display_asker(&self) -> &str {
        if self.asker_name.is_empty() { &self.asker } else { &self.asker_name }
    }
}

/// A machine asking the target, as the target sees it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Asker<'a> {
    /// Its device hub id.
    pub device: &'a str,
    /// The account it is signed in to (device hub user id).
    pub account: &'a str,
}

/// The target's owner consent for its other signed-in machines. hq#11046 cut
/// 1's grant ("control for my other signed-in machines", off by default, one
/// click on the target Mac) implements it: [`SignedInMachinesConsent`].
pub trait SameAccountGrant {
    /// Whether the target's owner granted `asker` (a machine signed in to the
    /// target's own account) control of this Mac.
    fn covers(&self, asker: &Asker<'_>) -> bool;
}

/// [`SameAccountGrant`] as this Mac's owner set it: the `signedInMachines`
/// consent (`cli/machine_consent.rs`, granted only by the person's own app on
/// this Mac), read the way the workspace circuit's gate reads it
/// ([`crate::machine_record::signed_in_machines_granted`]). The consent is for
/// the account's machines as a whole, so it covers an asker only when the grant
/// holds for the account this Mac is joined as and the asker is signed in to
/// that same account; off, unanswered, unreadable or another account's grant
/// covers nobody.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SignedInMachinesConsent {
    granted: bool,
    account: Option<String>,
}

impl SignedInMachinesConsent {
    /// From a `_acpmux/machine_consent_get` answer and the account this Mac is joined as.
    pub fn from_status(consent: &Value, account: Option<&str>) -> Self {
        Self {
            granted: crate::machine_record::signed_in_machines_granted(consent, account),
            account: account.map(str::to_owned),
        }
    }

    /// This Mac's consent, read now (blocking file reads; call off any async runtime thread).
    pub fn read() -> Self {
        let (granted, account) = crate::cli::cloud_join::signed_in_machines_granted_here();
        Self { granted, account }
    }
}

impl SameAccountGrant for SignedInMachinesConsent {
    fn covers(&self, asker: &Asker<'_>) -> bool {
        self.granted && !asker.account.is_empty() && self.account.as_deref() == Some(asker.account)
    }
}

/// The device keys the target trusts: the device hub's list for its own
/// account (each device's `signingKey`, base64 X9.63 P-256).
pub trait AskerKeys {
    fn signing_key(&self, device: &str) -> Option<String>;
}

/// This Mac, reading an approval.
#[derive(Clone, Copy, Debug)]
pub struct Target<'a> {
    /// Its device hub id.
    pub device: &'a str,
    /// The account it is signed in to.
    pub account: &'a str,
    /// Now, Unix seconds.
    pub now: u64,
}

/// Why the target refused an approval: a stable code and the person's words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub code: &'static str,
    pub message: String,
}

impl Refused {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    pub fn json(&self) -> Value {
        json!({"code": self.code, "message": self.message})
    }
}

/// Whether this Mac takes `approval`: every check passes, in this order, or
/// the first that fails says why. A taken nonce goes into `seen`.
pub fn admit(
    approval: &ShareApproval,
    target: &Target<'_>,
    grant: &impl SameAccountGrant,
    keys: &impl AskerKeys,
    seen: &mut HashSet<String>,
) -> Result<(), Refused> {
    if approval.v != VERSION {
        return Err(Refused::new(
            "share.bad_version",
            format!("unknown approval format {:?}", approval.v),
        ));
    }
    if approval.target != target.device {
        return Err(Refused::new(
            "share.wrong_target",
            format!("the approval is for {}, not this Mac", approval.display_target()),
        ));
    }
    if approval.confirmed_at > target.now.saturating_add(MAX_SKEW_SECS)
        || target.now.saturating_sub(approval.confirmed_at) > MAX_AGE_SECS
    {
        return Err(Refused::new(
            "share.stale",
            "the approval is too old (or from the future); confirm again on your device",
        ));
    }
    if approval.confirmed_by != target.account {
        return Err(Refused::new(
            "share.other_account",
            "the approval comes from another account; only this Mac's own account may share it",
        ));
    }
    let asker = Asker { device: &approval.asker, account: &approval.confirmed_by };
    if !grant.covers(&asker) {
        return Err(Refused::new(
            "share.not_granted",
            format!(
                "{} may not control this Mac: its owner has not turned on control for their other signed-in machines here",
                approval.display_asker()
            ),
        ));
    }
    let Some(key) = keys.signing_key(&approval.asker) else {
        return Err(Refused::new(
            "share.unknown_device",
            format!("{} is not one of this account's devices", approval.display_asker()),
        ));
    };
    if !signature_valid(approval, &key) {
        return Err(Refused::new(
            "share.bad_signature",
            "the approval is not signed by the device it names; nobody clicked Allow there",
        ));
    }
    if !seen.insert(approval.nonce.clone()) {
        return Err(Refused::new("share.replayed", "this approval was already used"));
    }
    Ok(())
}

/// Whether `approval.signature` is `signing_key`'s signature of its canonical bytes.
fn signature_valid(approval: &ShareApproval, signing_key: &str) -> bool {
    let engine = base64::engine::general_purpose::STANDARD;
    let (Ok(key), Ok(signature)) = (engine.decode(signing_key), engine.decode(&approval.signature))
    else {
        return false;
    };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
        .verify(approval.canonical().as_bytes(), &signature)
        .is_ok()
}

/// The target's audit line for one decision: who confirmed, on which device,
/// and when.
pub fn target_entry(approval: &ShareApproval, decision: &Result<(), Refused>) -> Value {
    let mut entry = json!({
        "event": if decision.is_ok() { "remote_host.share_admitted" } else { "remote_host.share_refused" },
        "via": "same-account",
        "asker": approval.asker,
        "asker_name": approval.display_asker(),
        "confirmed_by": approval.confirmed_by,
        "confirmed_on": approval.asker,
        "confirmed_at": rfc3339(approval.confirmed_at),
        "nonce": approval.nonce,
    });
    if let (Err(refused), Some(map)) = (decision, entry.as_object_mut()) {
        map.insert("code".into(), json!(refused.code));
        map.insert("reason".into(), json!(refused.message));
    }
    entry
}

/// Unix seconds as RFC 3339 UTC (`2026-11-14T09:00:00Z`).
fn rfc3339(secs: u64) -> String {
    i64::try_from(secs)
        .ok()
        .and_then(|secs| chrono::DateTime::from_timestamp(secs, 0))
        .map(|at| at.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
        .unwrap_or_default()
}

#[cfg(test)]
#[path = "share_approval_tests.rs"]
mod tests;
