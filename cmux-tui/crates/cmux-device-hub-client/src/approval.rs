//! Computer Use approvals (PROTOCOL.md, "Computer Use approvals"): the
//! worker's request, its digest, the decision message and the asking
//! machine's own check of a decision before it applies it.

use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use base64::Engine as _;
use sha2::{Digest as _, Sha256};

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

/// An approver the asking machine's owner pinned at setup
/// (`cmux computer-use setup --approver`): the device and the fingerprint of
/// its **approval key** (the Secure Enclave key that needs Face ID or the
/// passcode for each Allow) the owner confirmed. The hub's device list only
/// supplies the key, which must match this pin: the hub's word alone never
/// grants.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct PinnedApprover {
    pub device_id: String,
    /// [`key_fingerprint`] of the device's `approvalKey`.
    pub approval_key_fingerprint: String,
}

/// SHA-256 of a base64 X9.63 P-256 public key (65 bytes), as 64 lowercase
/// hex digits; None when the text is not one.
pub fn key_fingerprint(key_base64: &str) -> Option<String> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(key_base64.trim()).ok()?;
    (bytes.len() == 65 && bytes[0] == 0x04).then(|| hex::encode(Sha256::digest(&bytes)))
}

/// A fingerprint as people compare it, the same as the iPhone and Mac show it
/// (Swift `DeviceIdentity.displayFingerprint`): its first 32 hex digits,
/// uppercase, in eight groups of four.
pub fn display_fingerprint(fingerprint: &str) -> String {
    let characters: Vec<char> = fingerprint.chars().take(32).map(|c| c.to_ascii_uppercase()).collect();
    characters.chunks(4).map(|chunk| chunk.iter().collect::<String>()).collect::<Vec<_>>().join(" ")
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
    /// The decider is not an approver this machine's owner pinned.
    NotPinned,
    /// An Allow from a device the hub lists without an approval key.
    NoApprovalKey,
    /// The hub's approval key for the decider is not the key the owner pinned.
    PinnedKeyMismatch,
    /// The decider is not a `macos` or `ios` device.
    NotApprover(Platform),
    /// Not this request's digest.
    DigestMismatch,
    UnknownDecision(String),
    /// `always` without this machine's `phoneAlwaysAllow`.
    AlwaysNotAllowed,
    /// `sig` does not verify with the decider's key for this decision
    /// (its approval key for an Allow, its signing key for a deny).
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
            Rejection::NotPinned => f.write_str("the decider is not a pinned approver of this machine"),
            Rejection::NoApprovalKey => f.write_str("the decider has no approval key"),
            Rejection::PinnedKeyMismatch => {
                f.write_str("the decider's approval key is not the key pinned on this machine")
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
    /// Base64 X9.63; signs a deny.
    pub signing_key: String,
    /// Base64 X9.63 approval key (`macos`/`ios`, Secure Enclave with user
    /// presence); signs an Allow. None when the device has none.
    pub approval_key: Option<String>,
}

/// What the asking machine expects of a decision.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Expectation<'a> {
    pub approval_id: &'a str,
    pub own_device_id: &'a str,
    pub request_digest: &'a str,
    pub allow_always: bool,
    /// The approvers the owner pinned; no other device's decision applies.
    pub pinned: &'a [PinnedApprover],
}

/// The approval key of `device` when it is one of `pinned` and the key the
/// hub lists has the pinned fingerprint.
pub fn pin_of<'d>(device: &'d KnownDevice, pinned: &[PinnedApprover]) -> Result<&'d str, Rejection> {
    let pin = pinned
        .iter()
        .find(|pin| pin.device_id.eq_ignore_ascii_case(&device.id))
        .ok_or(Rejection::NotPinned)?;
    let key = device.approval_key.as_deref().ok_or(Rejection::NoApprovalKey)?;
    let fingerprint = key_fingerprint(key).ok_or(Rejection::PinnedKeyMismatch)?;
    if !fingerprint.eq_ignore_ascii_case(&pin.approval_key_fingerprint) {
        return Err(Rejection::PinnedKeyMismatch);
    }
    Ok(key)
}

/// The asking machine's check, fail closed (PROTOCOL.md,
/// docs/computer-use-approvals.md "Device hub approvals"): the decider is not
/// this machine and is a `macos` or `ios` device of the account; the digest is
/// this request's; `always` only with `allow_always`. An Allow (`once`,
/// `session`, `always`) applies only from a device the owner pinned, signed
/// with its approval key whose fingerprint is the pinned one. A `deny` (it
/// only refuses) applies when signed with the decider's signing key.
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
    let key = match decision {
        Decision::Deny => decider.signing_key.as_str(),
        Decision::Once | Decision::Session | Decision::Always => pin_of(decider, expected.pinned)?,
    };
    let message = decision_message(expected.request_digest, decision);
    if !signing::verify_base64(key, message.as_bytes(), &evidence.sig) {
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::identity::{Assurance, DeviceKeys as _, SoftwareKeys};

    struct Approver {
        signing: SoftwareKeys,
        approval: SoftwareKeys,
        device: KnownDevice,
    }

    fn encode(keys: &SoftwareKeys) -> String {
        base64::engine::general_purpose::STANDARD.encode(keys.signing_public_key())
    }

    fn approver(id: &str, platform: Platform) -> Approver {
        let signing = SoftwareKeys::generate(Assurance::Hardware).unwrap();
        let approval = SoftwareKeys::generate(Assurance::Hardware).unwrap();
        let device = KnownDevice {
            id: id.into(),
            platform,
            signing_key: encode(&signing),
            approval_key: Some(encode(&approval)),
        };
        Approver { signing, approval, device }
    }

    fn pin(approver: &Approver) -> PinnedApprover {
        PinnedApprover {
            device_id: approver.device.id.clone(),
            approval_key_fingerprint: key_fingerprint(approver.device.approval_key.as_deref().unwrap())
                .unwrap(),
        }
    }

    fn signed(id: &str, keys: &SoftwareKeys, digest: &str, decision: Decision) -> DecisionEvidence {
        let sig = keys.sign(decision_message(digest, decision).as_bytes()).unwrap();
        DecisionEvidence {
            approval_id: "a1".into(),
            decision: decision.as_str().into(),
            digest: digest.into(),
            decider_id: id.into(),
            sig: base64::engine::general_purpose::STANDARD.encode(sig),
        }
    }

    /// The right key for the decision: the approval key for an Allow, the signing key for a deny.
    fn evidence(approver: &Approver, digest: &str, decision: Decision) -> DecisionEvidence {
        let keys = if decision == Decision::Deny { &approver.signing } else { &approver.approval };
        signed(&approver.device.id, keys, digest, decision)
    }

    fn expected<'a>(digest: &'a str, pinned: &'a [PinnedApprover]) -> Expectation<'a> {
        Expectation {
            approval_id: "a1",
            own_device_id: "box",
            request_digest: digest,
            allow_always: true,
            pinned,
        }
    }

    #[test]
    fn a_pinned_approval_key_allows() {
        let digest = "d".repeat(64);
        let phone = approver("phone", Platform::Ios);
        let pinned = vec![pin(&phone)];
        for decision in [Decision::Once, Decision::Session, Decision::Always] {
            let verified = verify_decision(
                &evidence(&phone, &digest, decision),
                &expected(&digest, &pinned),
                std::slice::from_ref(&phone.device),
            )
            .unwrap();
            assert_eq!(verified.decision, decision);
        }
    }

    #[test]
    fn an_allow_signed_with_the_signing_key_is_refused() {
        let digest = "d".repeat(64);
        let phone = approver("phone", Platform::Ios);
        let pinned = vec![pin(&phone)];
        let with_signing_key = signed("phone", &phone.signing, &digest, Decision::Session);
        assert_eq!(
            verify_decision(&with_signing_key, &expected(&digest, &pinned), std::slice::from_ref(&phone.device)),
            Err(Rejection::BadSignature)
        );
    }

    #[test]
    fn an_allow_whose_approval_key_is_not_pinned_is_refused() {
        let digest = "d".repeat(64);
        let phone = approver("phone", Platform::Ios);
        let forged = approver("forged", Platform::Ios);
        let devices = vec![phone.device.clone(), forged.device.clone()];
        let pinned = vec![pin(&phone)];
        let expect = expected(&digest, &pinned);
        // Registered on the hub as an iPhone with an approval key, signature valid, never pinned.
        assert_eq!(
            verify_decision(&evidence(&forged, &digest, Decision::Always), &expect, &devices),
            Err(Rejection::NotPinned)
        );
        // The pinned device, but the hub lists another approval key for it.
        let swapped = vec![KnownDevice { approval_key: forged.device.approval_key.clone(), ..phone.device.clone() }];
        let forged_as_phone = signed("phone", &forged.approval, &digest, Decision::Once);
        assert_eq!(verify_decision(&forged_as_phone, &expect, &swapped), Err(Rejection::PinnedKeyMismatch));
        // The pinned device with no approval key on the hub.
        let keyless = vec![KnownDevice { approval_key: None, ..phone.device.clone() }];
        assert_eq!(
            verify_decision(&evidence(&phone, &digest, Decision::Once), &expect, &keyless),
            Err(Rejection::NoApprovalKey)
        );
        // No pins: no Allow applies.
        assert_eq!(
            verify_decision(&evidence(&phone, &digest, Decision::Once), &expected(&digest, &[]), &devices),
            Err(Rejection::NotPinned)
        );
    }

    #[test]
    fn a_deny_needs_only_the_deciders_signing_key() {
        let digest = "d".repeat(64);
        let mac = approver("mac", Platform::Macos);
        let devices = vec![KnownDevice { approval_key: None, ..mac.device.clone() }];
        let verified = verify_decision(&evidence(&mac, &digest, Decision::Deny), &expected(&digest, &[]), &devices)
            .unwrap();
        assert_eq!(verified.decision, Decision::Deny);
        let with_approval_key = signed("mac", &mac.approval, &digest, Decision::Deny);
        assert_eq!(
            verify_decision(&with_approval_key, &expected(&digest, &[]), std::slice::from_ref(&mac.device)),
            Err(Rejection::BadSignature)
        );
    }

    #[test]
    fn this_machine_never_decides_even_when_pinned() {
        let digest = "d".repeat(64);
        let own = approver("box", Platform::Ios);
        let pinned = vec![pin(&own)];
        for decision in [Decision::Once, Decision::Deny] {
            assert_eq!(
                verify_decision(
                    &evidence(&own, &digest, decision),
                    &expected(&digest, &pinned),
                    std::slice::from_ref(&own.device)
                ),
                Err(Rejection::SelfDecider)
            );
        }
    }

    #[test]
    fn fingerprints_are_sha256_of_the_key_and_group_for_people() {
        let phone = approver("phone", Platform::Ios);
        let fingerprint = key_fingerprint(phone.device.approval_key.as_deref().unwrap()).unwrap();
        assert_eq!(fingerprint.len(), 64);
        let raw = base64::engine::general_purpose::STANDARD.decode(phone.device.approval_key.as_deref().unwrap()).unwrap();
        assert_eq!(fingerprint, hex::encode(Sha256::digest(&raw)));
        assert_eq!(
            display_fingerprint(&"0123456789abcdef".repeat(4)),
            "0123 4567 89AB CDEF 0123 4567 89AB CDEF"
        );
        assert_eq!(key_fingerprint("not base64"), None);
        assert_eq!(key_fingerprint("AAAA"), None);
    }
}
