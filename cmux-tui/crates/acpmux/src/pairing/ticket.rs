//! The ticket a person pastes: `cmxt1.` and the URL-safe base64 of a small
//! JSON object, so it survives a shell, a chat message and a QR code.
//!
//! `{"v":1,"u":URL,"m":MINTER,"r":ROLE,"x":EXPIRES_MS,"s":SECRET}`: where to
//! redeem it, the minting machine's name (the peer name the joiner uses),
//! the role, when it expires and the secret. Only the secret proves
//! anything; the minter answers with the role it stored, whatever `r` says.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde::{Deserialize, Serialize};

use super::Role;

pub const TICKET_PREFIX: &str = "cmxt1.";
/// A ticket longer than this is not one (the payload is ~200 bytes).
const MAX_TICKET_BYTES: usize = 2048;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Ticket {
    #[serde(rename = "u")]
    pub url: String,
    #[serde(rename = "m")]
    pub minter: String,
    #[serde(rename = "r")]
    pub role: Role,
    #[serde(rename = "x")]
    pub expires_ms: u64,
    #[serde(rename = "s")]
    pub secret: String,
}

#[derive(Serialize, Deserialize)]
struct Wire {
    v: u32,
    #[serde(flatten)]
    ticket: Ticket,
}

impl Ticket {
    pub fn encode(&self) -> String {
        let wire = Wire { v: 1, ticket: self.clone() };
        let json = serde_json::to_vec(&wire).unwrap_or_default();
        format!("{TICKET_PREFIX}{}", URL_SAFE_NO_PAD.encode(json))
    }

    /// A short, non-secret identifier suitable for setup receipts and logs.
    /// It hashes the complete bearer ticket and never includes ticket payload.
    pub fn hint(text: &str) -> String {
        let trimmed = text.trim().trim_matches(|c| c == '\'' || c == '"');
        if !trimmed.starts_with(TICKET_PREFIX) {
            return "invalid".into();
        }
        let digest = crate::sha256::sha256_hex(trimmed.as_bytes());
        format!("{TICKET_PREFIX}{}…", &digest[..12])
    }

    /// Parse a pasted ticket (surrounding whitespace and quotes ignored).
    pub fn decode(text: &str) -> Result<Self, String> {
        let text = text.trim().trim_matches(|c| c == '\'' || c == '"');
        if text.len() > MAX_TICKET_BYTES {
            return Err("that is not a cmux pairing ticket (too long)".into());
        }
        let body = text.strip_prefix(TICKET_PREFIX).ok_or_else(|| {
            format!("that is not a cmux pairing ticket (it starts with {TICKET_PREFIX})")
        })?;
        let bytes = URL_SAFE_NO_PAD
            .decode(body)
            .map_err(|_| "the ticket is damaged (not base64); copy it again".to_owned())?;
        let wire: Wire = serde_json::from_slice(&bytes)
            .map_err(|_| "the ticket is damaged; copy it again".to_owned())?;
        if wire.v != 1 {
            return Err(format!(
                "this cmux reads version 1 tickets, not version {}: paste the whole install line the other machine printed (`cmux host ticket new`), which installs a cmux that reads it",
                wire.v
            ));
        }
        let t = wire.ticket;
        if t.secret.len() != 64 || !t.secret.bytes().all(|b| b.is_ascii_hexdigit()) {
            return Err("the ticket is damaged (its secret); copy it again".into());
        }
        Ok(t)
    }
}
