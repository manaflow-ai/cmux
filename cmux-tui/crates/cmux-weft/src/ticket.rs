//! Relay tickets: the coordinator's signed statement "this WireGuard key
//! belongs to tailnet T until time E". A relay admits a connection only with
//! a valid ticket and forwards only between keys of the same tailnet.
//!
//! Format: `base64url(payload json) "." base64url(ed25519 signature)`, where
//! the signature covers `weft-ticket-v1.` followed by the payload text.

use serde::{Deserialize, Serialize};

use crate::keys::SigningKey;

const DOMAIN: &[u8] = b"weft-ticket-v1.";
const MAX_TICKET: usize = 1024;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ticket {
    pub tailnet: String,
    pub node_key: [u8; 32],
    pub expires_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TicketError {
    Malformed,
    BadSignature,
    Expired,
}

impl std::fmt::Display for TicketError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(match self {
            Self::Malformed => "malformed ticket",
            Self::BadSignature => "bad ticket signature",
            Self::Expired => "ticket expired",
        })
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Payload {
    t: String,
    k: String,
    e: u64,
}

fn signed_bytes(payload: &[u8]) -> Vec<u8> {
    let mut bytes = DOMAIN.to_vec();
    bytes.extend_from_slice(payload);
    bytes
}

pub fn issue(
    authority: &SigningKey,
    tailnet: &str,
    node_key: &[u8; 32],
    expires_ms: u64,
) -> String {
    let payload =
        Payload { t: tailnet.to_owned(), k: crate::b64::encode_key(node_key), e: expires_ms };
    let text = serde_json::to_vec(&payload).unwrap_or_default();
    let signature = authority.sign(&signed_bytes(&text));
    format!("{}.{}", crate::b64::encode_url(&text), crate::b64::encode_url(&signature))
}

pub fn verify_ticket(authority: &[u8; 32], text: &str, now_ms: u64) -> Result<Ticket, TicketError> {
    if text.len() > MAX_TICKET {
        return Err(TicketError::Malformed);
    }
    let (payload, signature) = text.split_once('.').ok_or(TicketError::Malformed)?;
    let payload = crate::b64::decode_url(payload).ok_or(TicketError::Malformed)?;
    let signature = crate::b64::decode_url(signature).ok_or(TicketError::Malformed)?;
    if signature.len() != 64 {
        return Err(TicketError::Malformed);
    }
    if !crate::keys::verify(authority, &signed_bytes(&payload), &signature) {
        return Err(TicketError::BadSignature);
    }
    let parsed: Payload = serde_json::from_slice(&payload).map_err(|_| TicketError::Malformed)?;
    let node_key = crate::b64::decode_key(&parsed.k).ok_or(TicketError::Malformed)?;
    if now_ms > parsed.e {
        return Err(TicketError::Expired);
    }
    Ok(Ticket { tailnet: parsed.t, node_key, expires_ms: parsed.e })
}

/// Same as [`verify_ticket`]; the short name reads well at call sites
/// (`ticket::verify`).
pub fn verify(authority: &[u8; 32], text: &str, now_ms: u64) -> Result<Ticket, TicketError> {
    verify_ticket(authority, text, now_ms)
}
