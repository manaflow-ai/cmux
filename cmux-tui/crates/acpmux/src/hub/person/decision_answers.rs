//! The person's decision proof for an answer to a question (an agent's AskUserQuestion) relayed
//! from another machine's app: the allow's proof ([`super::decision_proof`]) also covers the
//! answers, so a relay cannot swap them. The app's pane on the Mac signs it for a chat on an ssh
//! peer (`AgentPaneTransport+RelayedAllow.swift`); before it, every such answer was refused as
//! not the person's (Leo, 2026-10-21).

use serde_json::Value;

/// Lowercase hex HMAC-SHA256(key, "acpmux-person-decision-answers-v1" 0 instance 0 session 0
/// permission 0 option 0 nonce 0 answers digest), the digest being the sha256 of the canonical
/// answers JSON as a phone's signed answer has it (`approvers::answers_digest`). None when `key`
/// is not a person key.
pub fn decision_answers_proof(
    key: &str,
    instance: &str,
    session: &str,
    permission: &str,
    option: &str,
    nonce: &str,
    answers: &Value,
) -> Option<String> {
    use cmux_local_auth::frontend_proof::{hex, hmac_sha256, unhex};
    let key = unhex::<32>(key).filter(|_| super::valid_key(key))?;
    let digest = crate::hub::approvers::answers_digest(Some(answers));
    let mut message = b"acpmux-person-decision-answers-v1".to_vec();
    for part in [instance, session, permission, option, nonce, digest.as_str()] {
        message.push(0);
        message.extend_from_slice(part.as_bytes());
    }
    Some(hex(&hmac_sha256(&key, &message)))
}
