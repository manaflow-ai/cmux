//! Computer Use approvals (PROTOCOL.md, "Computer Use approvals"): the
//! worker's request, its digest, the decision message and the asking
//! machine's own check of a decision before it applies it.

use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::canonical::{CanonicalError, canonical_sha256};
use crate::identity::Platform;
use crate::signing;

/// The domain separator of a decision signature.
pub const DECISION_CONTEXT: &str = "cmux-cu-approval-v1";

/// The app the call targets, as the worker resolved it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalTarget {
    pub bundle_id: Option<String>,
    pub executable: Option<String>,
    pub name: String,
}

/// The worker's approval request (`docs/computer-use-approvals.md`, "The
/// approval question"), unchanged on the way to the hub.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ApprovalRequest {
    pub v: u32,
    pub nonce: String,
    pub client: String,
    pub machine: String,
    pub session: String,
    pub agent: String,
    pub workspace: String,
    pub target: ApprovalTarget,
    pub tool: String,
    pub risk: String,
    pub created_ms: i64,
    pub wait_until_ms: i64,
    pub answerable_until_ms: i64,
    /// Lowercase hex SHA-256 of the canonical JSON of the object without `digest`.
    pub digest: String,
}

impl ApprovalRequest {
    /// The digest of this request's fields (its `digest` field excluded).
    pub fn compute_digest(&self) -> Result<String, CanonicalError> {
        let mut value =
            serde_json::to_value(self).map_err(|error| CanonicalError(error.to_string()))?;
        if let Value::Object(map) = &mut value {
            map.remove("digest");
        }
        canonical_sha256(&value)
    }

    /// This request with `digest` set from its fields.
    pub fn sealed(mut self) -> Result<ApprovalRequest, CanonicalError> {
        self.digest = self.compute_digest()?;
        Ok(self)
    }

    /// Whether `digest` matches the fields.
    pub fn digest_is_valid(&self) -> bool {
        self.compute_digest().is_ok_and(|digest| digest == self.digest)
    }
}

/// A person's answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Decision {
    /// This call only.
    Once,
    /// The app joins this agent session's manifest.
    Session,
    /// The app joins the client's saved list.
    Always,
    Deny,
}

impl Decision {
    pub fn as_str(self) -> &'static str {
        match self {
            Decision::Once => "once",
            Decision::Session => "session",
            Decision::Always => "always",
            Decision::Deny => "deny",
        }
    }

    pub fn parse(raw: &str) -> Option<Decision> {
        match raw {
            "once" => Some(Decision::Once),
            "session" => Some(Decision::Session),
            "always" => Some(Decision::Always),
            "deny" => Some(Decision::Deny),
            _ => None,
        }
    }
}

impl fmt::Display for Decision {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The string a deciding device signs: `"cmux-cu-approval-v1\n<digest>\n<decision>"`.
pub fn decision_message(digest: &str, decision: Decision) -> String {
    format!("{DECISION_CONTEXT}\n{digest}\n{}", decision.as_str())
}

/// An approval's state on the hub.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ApprovalState {
    Pending,
    Decided,
    Expired,
    Cancelled,
    #[serde(other)]
    Unknown,
}

/// An approval as the hub returns it. `request` is kept as JSON so its digest
/// can be recomputed from exactly what the hub holds.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HubApproval {
    pub id: String,
    pub device_id: String,
    #[serde(default)]
    pub device_name: Option<String>,
    pub request: Value,
    #[serde(default)]
    pub allow_always: bool,
    pub state: ApprovalState,
    #[serde(default)]
    pub decision: Option<String>,
    #[serde(default)]
    pub decider_id: Option<String>,
    #[serde(default)]
    pub sig: Option<String>,
    #[serde(default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub answerable_until: Option<i64>,
    #[serde(default)]
    pub decided_at: Option<i64>,
}

impl HubApproval {
    /// The decision this record carries, when it is `decided`. `digest` is the
    /// stored request's `digest` field.
    pub fn evidence(&self) -> Option<DecisionEvidence> {
        if self.state != ApprovalState::Decided {
            return None;
        }
        Some(DecisionEvidence {
            approval_id: self.id.clone(),
            decision: self.decision.clone()?,
            digest: self.request.get("digest")?.as_str()?.to_owned(),
            decider_id: self.decider_id.clone()?,
            sig: self.sig.clone()?,
        })
    }
}

/// A decision as it reached the asking machine (`approval.decided`, or a
/// `decided` approval it read), not yet trusted.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DecisionEvidence {
    pub approval_id: String,
    pub decision: String,
    pub digest: String,
    pub decider_id: String,
    pub sig: String,
}

/// A decision the asking machine checked itself.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedDecision {
    pub approval_id: String,
    pub decision: Decision,
    pub digest: String,
    pub decider_id: String,
    pub decider_platform: Platform,
}

/// Why a decision was not applied.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Rejection {
    /// It is about another approval.
    OtherApproval,
    /// The decider is this machine.
    SelfDecider,
    /// The decider is not one of the user's devices.
    UnknownDecider,
    /// The decider is not a `macos` or `ios` device.
    NotApprover(Platform),
    /// Not this request's digest.
    DigestMismatch,
    UnknownDecision(String),
    /// `always` without this machine's `phoneAlwaysAllow`.
    AlwaysNotAllowed,
    /// `sig` does not verify with the decider's signing key.
    BadSignature,
}

impl fmt::Display for Rejection {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Rejection::OtherApproval => f.write_str("the decision is about another approval"),
            Rejection::SelfDecider => f.write_str("the decider is this device"),
            Rejection::UnknownDecider => {
                f.write_str("the decider is not one of the account's devices")
            }
            Rejection::NotApprover(platform) => {
                write!(f, "a {} device cannot approve", platform.as_str())
            }
            Rejection::DigestMismatch => f.write_str("the digest is not this request's"),
            Rejection::UnknownDecision(raw) => write!(f, "unknown decision {raw:?}"),
            Rejection::AlwaysNotAllowed => f.write_str("always is not allowed on this machine"),
            Rejection::BadSignature => f.write_str("the decision signature does not verify"),
        }
    }
}

/// The part of a device the check needs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KnownDevice {
    pub id: String,
    pub platform: Platform,
    /// Base64 X9.63.
    pub signing_key: String,
}

/// What the asking machine expects of a decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Expectation<'a> {
    pub approval_id: &'a str,
    pub own_device_id: &'a str,
    pub request_digest: &'a str,
    pub allow_always: bool,
}

/// The asking machine's check, fail closed (PROTOCOL.md): the decider is not
/// this machine, is a `macos` or `ios` device of the account, the digest is
/// this request's, `always` only with `allow_always`, and `sig` verifies with
/// the decider's signing key.
pub fn verify_decision(
    evidence: &DecisionEvidence,
    expected: &Expectation<'_>,
    devices: &[KnownDevice],
) -> Result<VerifiedDecision, Rejection> {
    if evidence.approval_id != expected.approval_id {
        return Err(Rejection::OtherApproval);
    }
    if evidence.decider_id.eq_ignore_ascii_case(expected.own_device_id) {
        return Err(Rejection::SelfDecider);
    }
    let decider = devices
        .iter()
        .find(|device| device.id == evidence.decider_id)
        .ok_or(Rejection::UnknownDecider)?;
    if !decider.platform.is_approver() {
        return Err(Rejection::NotApprover(decider.platform));
    }
    if evidence.digest != expected.request_digest {
        return Err(Rejection::DigestMismatch);
    }
    let decision = Decision::parse(&evidence.decision)
        .ok_or_else(|| Rejection::UnknownDecision(evidence.decision.clone()))?;
    if decision == Decision::Always && !expected.allow_always {
        return Err(Rejection::AlwaysNotAllowed);
    }
    let message = decision_message(expected.request_digest, decision);
    if !signing::verify_base64(&decider.signing_key, message.as_bytes(), &evidence.sig) {
        return Err(Rejection::BadSignature);
    }
    Ok(VerifiedDecision {
        approval_id: evidence.approval_id.clone(),
        decision,
        digest: evidence.digest.clone(),
        decider_id: decider.id.clone(),
        decider_platform: decider.platform,
    })
}
