//! The phone's presence-key approve proof (`FeedApproveProofCheck`): an allow answered on a phone
//! reaches the agent only with an ECDSA P-256 signature, by an attested, active, cooled-down iOS
//! key of the answering install, over exactly what the phone showed (`FeedApproveShownText`) and
//! the decision (`FeedApproveProofMessage`).

use crate::json::{is_true, obj_at, sha256_hex, str_at};
use base64::Engine;
use base64::engine::{GeneralPurpose, GeneralPurposeConfig};
use p256::ecdsa::signature::Verifier;
use p256::ecdsa::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// How old a proof may be (ms).
pub const MAX_AGE_MS: f64 = 300_000.0;
/// How far ahead of this Mac's clock a proof may be signed (ms).
pub const MAX_SKEW_MS: f64 = 60_000.0;

/// One install's presence key, as `user.presence_key.list` returns it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Key {
    pub platform: String,
    /// X9.63 `0x04‖x‖y`, lowercase hex.
    pub public_key: String,
    pub attested: bool,
    /// When the key may sign (ms since 1970).
    pub usable_from: Option<f64>,
    pub revoked: bool,
    pub install_active: bool,
}

/// Who this Mac is signed in as, from its install token.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Context {
    pub environment: String,
    pub user: String,
    pub mac_install: String,
}

/// Why a proof does not hold.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
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

/// An approve answer: allow or deny, its scope, and the phone's proof.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decision {
    pub outcome: Outcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub scope: Option<Scope>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub proof: Option<Proof>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Allow,
    Deny,
}

impl Outcome {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Allow => "allow",
            Self::Deny => "deny",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Scope {
    Once,
    Session,
    Always,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Once => "once",
            Self::Session => "session",
            Self::Always => "always",
        }
    }

    fn parse(text: &str) -> Option<Self> {
        match text {
            "once" => Some(Self::Once),
            "session" => Some(Self::Session),
            "always" => Some(Self::Always),
            _ => None,
        }
    }
}

/// The signing install, when it signed (ms) and the base64url raw `r‖s` signature.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Proof {
    pub install: String,
    #[serde(rename = "ts")]
    pub timestamp_ms: i64,
    #[serde(rename = "sig")]
    pub signature: String,
}

/// A closed approve item's decision (`FeedDaemonItem.approveDecision`): `None` unless the item is
/// an approve with an answer value. An unknown decision is a deny.
pub fn approve_decision(item: &Value) -> Option<Decision> {
    if str_at(item, "kind") != Some("approve") {
        return None;
    }
    let value = item.get("answer")?.get("value")?;
    if !value.is_object() {
        return None;
    }
    let proof = value.get("proof").and_then(|proof| {
        Some(Proof {
            install: str_at(proof, "install")?.to_owned(),
            timestamp_ms: proof.get("ts")?.as_i64()?,
            signature: str_at(proof, "sig")?.to_owned(),
        })
    });
    Some(Decision {
        outcome: if str_at(value, "decision") == Some("allow") {
            Outcome::Allow
        } else {
            Outcome::Deny
        },
        scope: str_at(value, "scope").and_then(Scope::parse),
        reason: str_at(value, "reason").map(str::to_owned),
        proof,
    })
}

const LENIENT: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_allow_trailing_bits(true),
);

/// Base64url (unpadded or padded) decoded as Foundation's `Data(base64Encoded:)` would after the
/// alphabet swap and padding.
pub fn base64_url(text: &str) -> Option<Vec<u8>> {
    let mut base = text.replace('-', "+").replace('_', "/");
    let pad = (4 - base.chars().count() % 4) % 4;
    base.push_str(&"=".repeat(pad));
    LENIENT.decode(base).ok()
}

/// The presence keys of `user.presence_key.list`'s value, by install. An entry without a 32-byte
/// `x` and `y` or a numeric `usable_from` is left out; a missing `revoked_at` counts as revoked.
pub fn keys(value: &Value) -> BTreeMap<String, Key> {
    let mut out = BTreeMap::new();
    for entry in value.get("keys").and_then(Value::as_array).into_iter().flatten() {
        let Some(install) = str_at(entry, "install") else { continue };
        let Some(jwk) = entry.get("jwk").filter(|jwk| jwk.is_object()) else { continue };
        let coordinate =
            |name: &str| str_at(jwk, name).and_then(base64_url).filter(|bytes| bytes.len() == 32);
        let (Some(x), Some(y)) = (coordinate("x"), coordinate("y")) else { continue };
        let Some(usable_from) = entry.get("usable_from").and_then(Value::as_f64) else { continue };
        let mut public_key = vec![0x04];
        public_key.extend(x);
        public_key.extend(y);
        out.insert(
            install.to_owned(),
            Key {
                platform: str_at(entry, "platform").unwrap_or_default().to_owned(),
                public_key: public_key.iter().map(|byte| format!("{byte:02x}")).collect(),
                attested: is_true(entry, "attested"),
                usable_from: Some(usable_from),
                revoked: entry.get("revoked_at") != Some(&Value::Null),
                install_active: is_true(entry, "install_active"),
            },
        );
    }
    out
}

/// A JWT's claims (the middle of three non-empty dot-separated parts), as `split(".")` reads it.
fn claims(token: &str) -> Option<Value> {
    let parts: Vec<&str> = token.split('.').filter(|part| !part.is_empty()).collect();
    let [_, payload, _] = parts.as_slice() else { return None };
    let claims: Value = serde_json::from_slice(&base64_url(payload)?).ok()?;
    claims.is_object().then_some(claims)
}

const ISSUER: &str = "https://cmux-api/";

/// This Mac's context from its install token: `iss` `https://cmux-api/<env>`, `sub`, `inst`.
pub fn context_of_token(token: &str) -> Option<Context> {
    let claims = claims(token)?;
    let environment = str_at(&claims, "iss")?.strip_prefix(ISSUER)?;
    let user = str_at(&claims, "sub").filter(|user| !user.is_empty())?;
    let install = str_at(&claims, "inst").filter(|install| !install.is_empty())?;
    if environment.is_empty() {
        return None;
    }
    Some(Context {
        environment: environment.to_owned(),
        user: user.to_owned(),
        mac_install: install.to_owned(),
    })
}

/// The install an install token names (`FeedInstallPrincipal.install(ofToken:)`).
pub fn install_of_token(token: &str) -> Option<String> {
    str_at(&claims(token)?, "inst").filter(|install| !install.is_empty()).map(str::to_owned)
}

/// What the phone showed for an approve action, as the proof signs it.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ShownText {
    pub tool: String,
    pub summary: String,
    pub command: String,
    pub input: BTreeMap<String, String>,
    pub truncated: bool,
}

impl ShownText {
    /// The shown text of a posted `prompt.action`: string fields only, `truncated` only as the JSON
    /// boolean `true`.
    pub fn of_action(action: &Value) -> Self {
        let text = |name: &str| str_at(action, name).unwrap_or_default().to_owned();
        Self {
            tool: text("tool"),
            summary: text("summary"),
            command: text("command"),
            input: obj_at(action, "input")
                .map(|input| {
                    input
                        .iter()
                        .filter_map(|(key, value)| Some((key.clone(), value.as_str()?.to_owned())))
                        .collect()
                })
                .unwrap_or_default(),
            truncated: is_true(action, "truncated"),
        }
    }

    /// The length-prefixed canonical text (`cmux-feed-shown-v2`).
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
        text.push_str(&format!("truncated:{}\n", u8::from(self.truncated)));
        text
    }

    pub fn sha256(&self) -> String {
        sha256_hex(self.canonical().as_bytes())
    }
}

/// `FeedApproveProofCheck.shownSHA256(action:)`.
pub fn shown_sha256(action: &Value) -> String {
    ShownText::of_action(action).sha256()
}

/// The bytes a phone signs (`cmux-feed-approve-v1`).
pub fn message(
    context: &Context,
    phone_install: &str,
    item: &str,
    shown_sha256: &str,
    decision: &str,
    scope: &str,
    timestamp_ms: i64,
) -> String {
    [
        "cmux-feed-approve-v1",
        &context.environment,
        &context.user,
        phone_install,
        &context.mac_install,
        item,
        shown_sha256,
        decision,
        scope,
        &timestamp_ms.to_string(),
    ]
    .join("\n")
}

fn hex_bytes(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    (0..text.len())
        .step_by(2)
        .map(|index| u8::from_str_radix(text.get(index..index + 2)?, 16).ok())
        .collect()
}

/// Whether `decision`'s proof holds for the answer `by` gave to `item`, at `now_ms`.
pub fn check(
    decision: &Decision,
    by: &str,
    item: &str,
    shown_sha256: &str,
    context: &Context,
    keys: &BTreeMap<String, Key>,
    now_ms: f64,
) -> Result<(), Failure> {
    let proof = decision.proof.as_ref().ok_or(Failure::NoProof)?;
    if proof.install != by {
        return Err(Failure::OtherInstall);
    }
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
    if key.usable_from.is_some_and(|from| from > now_ms) {
        return Err(Failure::CoolingDown);
    }
    let public_key = hex_bytes(&key.public_key)
        .and_then(|bytes| VerifyingKey::from_sec1_bytes(&bytes).ok())
        .ok_or(Failure::BadKey)?;
    let scope = decision.scope.map_or("once", Scope::as_str);
    let bytes = message(
        context,
        &proof.install,
        item,
        shown_sha256,
        decision.outcome.as_str(),
        scope,
        proof.timestamp_ms,
    );
    let signature = base64_url(&proof.signature)
        .and_then(|raw| Signature::from_slice(&raw).ok())
        .ok_or(Failure::BadSignature)?;
    public_key.verify(bytes.as_bytes(), &signature).map_err(|_| Failure::BadSignature)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn shown_text_is_truncated_only_by_the_json_boolean_true() {
        for (value, truncated) in
            [(json!(true), true), (json!(1), false), (json!("true"), false), (json!(false), false)]
        {
            let action = json!({"tool": "execute", "summary": "Run", "truncated": value});
            assert_eq!(ShownText::of_action(&action).truncated, truncated, "{value}");
        }
        let action = json!({"tool": "execute"});
        assert!(!ShownText::of_action(&action).truncated);
    }

    #[test]
    fn shown_text_canonical_counts_utf8_bytes_and_sorts_inputs() {
        let action = json!({"tool": "t", "summary": "é", "command": "", "input": {"b": "2", "a": "1", "n": 3}});
        assert_eq!(
            ShownText::of_action(&action).canonical(),
            "cmux-feed-shown-v2\ntool:1:t\nsummary:2:é\ncommand:0:\ninput:1:a:1:1\ninput:1:b:1:2\ntruncated:0\n"
        );
    }

    #[test]
    fn base64_url_pads_and_swaps() {
        assert_eq!(base64_url("-_8").unwrap(), vec![0xfb, 0xff]);
        assert_eq!(base64_url("YQ").unwrap(), b"a");
        assert_eq!(base64_url("Y"), None);
    }
}
