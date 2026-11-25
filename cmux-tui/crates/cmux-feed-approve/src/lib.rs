//! The check of a phone's signed approve answer (cx-aocz, the chief-approved
//! App-Attested presence key design), moved from the Mac's Swift
//! (`FeedApproveProofCheck`, `CmuxFeedPushCore`'s `FeedApproveShownText` and
//! `FeedApproveProofMessage`). The Mac asks it over the app FFI
//! (`feed_approve_*` ops of `cmux_layout_reducer_json`); the phone and Android
//! can bind the same rules, so there is one definition of what is signed.
//!
//! The Mac answers an agent's permission prompt with an allow from the phone
//! only when [`check`] passes:
//!
//! - the proof names the install the owner authenticated as the answerer;
//! - that install has a presence key from an iPhone, attested by App Attest
//!   at registration, not revoked, its install active, past its cooldown
//!   (`usable_from`);
//! - the proof is at most [`MAX_AGE_MS`] old and at most [`MAX_SKEW_MS`] ahead;
//! - the key's P-256 signature covers [`ProofMessage::bytes`].
//!
//! Every parse fails closed: a malformed entry, flag or proof is a refusal.

use std::collections::{BTreeMap, HashMap};

use base64::Engine as _;
use base64::alphabet;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};
use p256::ecdsa::signature::Verifier as _;
use p256::ecdsa::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest as _, Sha256};

/// The oldest proof accepted, in milliseconds.
pub const MAX_AGE_MS: f64 = 300_000.0;
/// How far ahead of this clock a proof may be signed, in milliseconds.
pub const MAX_SKEW_MS: f64 = 60_000.0;

/// What the person saw on an agent's permission request: the tool, the
/// summary, the exact command, the input summary of a tool without a command,
/// and whether the Mac shortened any of it, as the phone renders them from the
/// feed item's `prompt.action`. The phone signs the sha256 of
/// [`ShownText::canonical`]; the Mac that posted the item computes it over the
/// text it posted and refuses a mismatch, so a changed item text cannot turn a
/// seen `ls` into an approved `rm`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ShownText {
    pub tool: String,
    pub summary: String,
    pub command: String,
    /// A tool input without a command: field name to its shown value.
    pub input: BTreeMap<String, String>,
    /// The Mac cut the command, an input value, a field name, or dropped fields.
    pub truncated: bool,
}

impl ShownText {
    /// `prompt.action` of a feed item (`tool`, `summary`, `command`, `input`,
    /// `truncated`). A field that is not a string reads as empty, an input
    /// value that is not a string is dropped, and `truncated` counts only as
    /// the JSON boolean true.
    #[must_use]
    pub fn from_action(action: &Value) -> Self {
        let text =
            |name: &str| action.get(name).and_then(Value::as_str).unwrap_or_default().to_owned();
        let input = action
            .get("input")
            .and_then(Value::as_object)
            .map(|fields| {
                fields
                    .iter()
                    .filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_owned())))
                    .collect()
            })
            .unwrap_or_default();
        Self {
            tool: text("tool"),
            summary: text("summary"),
            command: text("command"),
            input,
            truncated: json_true(action.get("truncated")),
        }
    }

    /// Unambiguous: a version line, then each field as
    /// `<name>:<UTF-8 byte count>:<value>` on its own line (a value may hold
    /// newlines), the input fields by name, then `truncated:0|1`.
    #[must_use]
    pub fn canonical(&self) -> String {
        let mut text = String::from("cmux-feed-shown-v2\n");
        for (name, value) in
            [("tool", &self.tool), ("summary", &self.summary), ("command", &self.command)]
        {
            text.push_str(&format!("{name}:{}:{value}\n", value.len()));
        }
        for (key, value) in &self.input {
            text.push_str(&format!("input:{}:{key}:{}:{value}\n", key.len(), value.len()));
        }
        text.push_str(if self.truncated { "truncated:1\n" } else { "truncated:0\n" });
        text
    }

    /// Lowercase hex sha256 of [`ShownText::canonical`].
    #[must_use]
    pub fn sha256(&self) -> String {
        hex_lower(&Sha256::digest(self.canonical().as_bytes()))
    }
}

/// The bytes a phone's presence key signs to answer an approve request:
/// `cmux-feed-approve-v1\n<environment>\n<user>\n<phone install>\n<Mac install>
/// \n<item id>\n<shown-text sha256>\n<decision>\n<scope>\n<ts ms>`.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ProofMessage {
    pub environment: String,
    pub user: String,
    pub phone_install: String,
    pub mac_install: String,
    pub item: String,
    pub shown_sha256: String,
    /// `allow` or `deny`.
    pub decision: String,
    /// `once`, `session` or `always`.
    pub scope: String,
    pub timestamp_ms: i64,
}

impl ProofMessage {
    #[must_use]
    pub fn bytes(&self) -> Vec<u8> {
        [
            "cmux-feed-approve-v1",
            &self.environment,
            &self.user,
            &self.phone_install,
            &self.mac_install,
            &self.item,
            &self.shown_sha256,
            &self.decision,
            &self.scope,
            &self.timestamp_ms.to_string(),
        ]
        .join("\n")
        .into_bytes()
    }
}

/// One entry of `user.presence_key.list`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Key {
    pub platform: String,
    /// The uncompressed SEC1 point (`04 || x || y`), base64url without padding.
    pub public_key: String,
    pub attested: bool,
    /// Milliseconds since 1970 from which the key may sign.
    pub usable_from_ms: Option<f64>,
    pub revoked: bool,
    pub install_active: bool,
}

/// Who this Mac is, from its own install token (`iss`, `sub`, `inst`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Context {
    pub environment: String,
    pub user: String,
    pub mac_install: String,
}

/// The proof an approve answer carries (`answer.proof`): the signing install,
/// the time it signed and the base64url raw P-256 signature.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Proof {
    pub install: String,
    pub timestamp_ms: i64,
    pub signature: String,
}

/// The phone's answer as the Mac read it from the feed item.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decision {
    /// `allow` or `deny`.
    pub outcome: String,
    /// `once`, `session`, `always`; none signs as `once`.
    #[serde(default)]
    pub scope: Option<String>,
    #[serde(default)]
    pub proof: Option<Proof>,
}

/// Why a proof was refused. The names are the ones the Mac logs.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Failure {
    NoProof,
    OtherInstall,
    NoKey,
    NotPhone,
    NotAttested,
    Revoked,
    CoolingDown,
    Stale,
    BadKey,
    BadSignature,
}

/// The keys of a `user.presence_key.list` value, by install. Fail closed: an
/// entry without an install, a P-256 JWK of 32-byte coordinates or a numeric
/// `usable_from` is dropped; a missing `revoked_at` counts as revoked; the
/// flags count only as JSON booleans.
#[must_use]
pub fn keys(value: &Value) -> HashMap<String, Key> {
    let mut out = HashMap::new();
    let Some(entries) = value.get("keys").and_then(Value::as_array) else {
        return out;
    };
    for entry in entries {
        let Some(install) = entry.get("install").and_then(Value::as_str) else {
            continue;
        };
        let Some(jwk) = entry.get("jwk").filter(|jwk| jwk.is_object()) else {
            continue;
        };
        let coordinate = |name: &str| {
            jwk.get(name)
                .and_then(Value::as_str)
                .and_then(base64url)
                .filter(|bytes| bytes.len() == 32)
        };
        let (Some(x), Some(y)) = (coordinate("x"), coordinate("y")) else {
            continue;
        };
        let Some(usable_from) = entry.get("usable_from").and_then(Value::as_f64) else {
            continue;
        };
        let mut point = Vec::with_capacity(65);
        point.push(0x04);
        point.extend_from_slice(&x);
        point.extend_from_slice(&y);
        out.insert(
            install.to_owned(),
            Key {
                platform: entry
                    .get("platform")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_owned(),
                public_key: base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(point),
                attested: json_true(entry.get("attested")),
                usable_from_ms: Some(usable_from),
                revoked: !entry.get("revoked_at").is_some_and(Value::is_null),
                install_active: json_true(entry.get("install_active")),
            },
        );
    }
    out
}

/// This Mac's context from its install token's claims: `iss` must be
/// `https://cmux-api/<environment>` and `sub` and `inst` non-empty.
#[must_use]
pub fn context_of_token(token: &str) -> Option<Context> {
    let parts: Vec<&str> = token.split('.').filter(|part| !part.is_empty()).collect();
    let [_, claims, _] = parts.as_slice() else {
        return None;
    };
    let claims: Value = serde_json::from_slice(&base64url(claims)?).ok()?;
    let issuer = claims.get("iss")?.as_str()?;
    let environment = issuer.strip_prefix("https://cmux-api/")?;
    let user = claims.get("sub")?.as_str().filter(|user| !user.is_empty())?;
    let install = claims.get("inst")?.as_str().filter(|install| !install.is_empty())?;
    if environment.is_empty() {
        return None;
    }
    Some(Context {
        environment: environment.to_owned(),
        user: user.to_owned(),
        mac_install: install.to_owned(),
    })
}

/// Checks `decision`'s proof for `item`, answered by `by`, at `now_ms`
/// (milliseconds since 1970).
///
/// # Errors
///
/// The first rule the proof breaks, in the Mac's order: the time comes
/// before the key, so a stale proof is named as such.
pub fn check(
    decision: &Decision,
    by: &str,
    item: &str,
    shown_sha256: &str,
    context: &Context,
    keys: &HashMap<String, Key>,
    now_ms: f64,
) -> Result<(), Failure> {
    let proof = decision.proof.as_ref().ok_or(Failure::NoProof)?;
    if proof.install != by {
        return Err(Failure::OtherInstall);
    }
    #[expect(
        clippy::cast_precision_loss,
        reason = "a millisecond time fits an f64 exactly until the year 287396"
    )]
    let signed = proof.timestamp_ms as f64;
    if signed > now_ms + MAX_SKEW_MS || now_ms - signed > MAX_AGE_MS {
        return Err(Failure::Stale);
    }
    let key = keys.get(&proof.install).ok_or(Failure::NoKey)?;
    if key.platform != "ios" {
        return Err(Failure::NotPhone);
    }
    if !key.attested {
        return Err(Failure::NotAttested);
    }
    if key.revoked || !key.install_active {
        return Err(Failure::Revoked);
    }
    if key.usable_from_ms.is_some_and(|from| from > now_ms) {
        return Err(Failure::CoolingDown);
    }
    let public_key = base64url(&key.public_key)
        .and_then(|point| VerifyingKey::from_sec1_bytes(&point).ok())
        .ok_or(Failure::BadKey)?;
    let message = ProofMessage {
        environment: context.environment.clone(),
        user: context.user.clone(),
        phone_install: proof.install.clone(),
        mac_install: context.mac_install.clone(),
        item: item.to_owned(),
        shown_sha256: shown_sha256.to_owned(),
        decision: decision.outcome.clone(),
        scope: decision.scope.clone().unwrap_or_else(|| "once".to_owned()),
        timestamp_ms: proof.timestamp_ms,
    };
    let signature = base64url(&proof.signature)
        .and_then(|raw| Signature::from_slice(&raw).ok())
        .ok_or(Failure::BadSignature)?;
    public_key.verify(&message.bytes(), &signature).map_err(|_| Failure::BadSignature)
}

/// base64url with or without padding (standard `+` and `/` are read too), as
/// the Mac's Swift decoded it.
#[must_use]
pub fn base64url(text: &str) -> Option<Vec<u8>> {
    const LENIENT: GeneralPurpose = GeneralPurpose::new(
        &alphabet::STANDARD,
        GeneralPurposeConfig::new()
            .with_decode_padding_mode(DecodePaddingMode::RequireCanonical)
            .with_decode_allow_trailing_bits(true),
    );
    let mut base: String = text
        .chars()
        .map(|c| match c {
            '-' => '+',
            '_' => '/',
            other => other,
        })
        .collect();
    let pad = (4 - base.chars().count() % 4) % 4;
    base.extend(std::iter::repeat_n('=', pad));
    LENIENT.decode(base).ok()
}

/// `true` only for the JSON boolean true (not 1, not "true").
fn json_true(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Bool(true)))
}

fn hex_lower(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    bytes.iter().fold(String::new(), |mut out, byte| {
        let _ = write!(out, "{byte:02x}");
        out
    })
}

#[cfg(test)]
mod tests;
