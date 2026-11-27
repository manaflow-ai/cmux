//! BIND tickets: `hop1.<session>.<expires_unix>.<base64url hmac>`.
//!
//! The same authority shape as cmux-relay's `TicketAuthority`: an HMAC-SHA256
//! secret shared with the minter (`/v1/ice` mints one per session, as it mints
//! TURN credentials), or open mode for netlab, where any non-empty ticket is
//! its own session key. The session names the allocation: a BIND with the same
//! ticket from a new address moves it (roam keeps the relayed port).

use std::time::{SystemTime, UNIX_EPOCH};

use base64::{Engine as _, engine::general_purpose::URL_SAFE_NO_PAD};
use hmac::{Hmac, Mac};
use sha2::Sha256;

const PREFIX: &str = "hop1";
pub const MINIMUM_SECRET_BYTES: usize = 32;
pub const MAXIMUM_TICKET_BYTES: usize = 512;
const MAXIMUM_SESSION_BYTES: usize = 128;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TicketError {
    ShortSecret,
    TooLong,
    Malformed,
    BadSignature,
    Expired,
    Clock,
}

impl std::fmt::Display for TicketError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            Self::ShortSecret => "the ticket secret is shorter than 32 bytes",
            Self::TooLong => "ticket too long",
            Self::Malformed => "malformed ticket",
            Self::BadSignature => "ticket signature mismatch",
            Self::Expired => "ticket expired",
            Self::Clock => "system clock is before the Unix epoch",
        })
    }
}

impl std::error::Error for TicketError {}

#[derive(Clone)]
pub struct TicketAuthority {
    secret: Option<Vec<u8>>,
}

impl TicketAuthority {
    /// Development mode: any non-empty ticket binds, and is its own session.
    pub const fn open() -> Self {
        Self { secret: None }
    }

    pub fn hmac(secret: Vec<u8>) -> Result<Self, TicketError> {
        if secret.len() < MINIMUM_SECRET_BYTES {
            return Err(TicketError::ShortSecret);
        }
        Ok(Self { secret: Some(secret) })
    }

    pub const fn is_open(&self) -> bool {
        self.secret.is_none()
    }

    pub fn issue(&self, session: &str, expires_unix: u64) -> Result<String, TicketError> {
        valid_session(session)?;
        let body = format!("{PREFIX}.{session}.{expires_unix}");
        let Some(secret) = &self.secret else {
            return Ok(body);
        };
        let signature = URL_SAFE_NO_PAD.encode(sign(secret, body.as_bytes())?);
        Ok(format!("{body}.{signature}"))
    }

    /// The session key the ticket binds, if it is valid now.
    pub fn verify(&self, ticket: &[u8]) -> Result<Vec<u8>, TicketError> {
        if ticket.is_empty() {
            return Err(TicketError::Malformed);
        }
        if ticket.len() > MAXIMUM_TICKET_BYTES {
            return Err(TicketError::TooLong);
        }
        let Some(secret) = &self.secret else {
            return Ok(ticket.to_vec());
        };
        let text = std::str::from_utf8(ticket).map_err(|_| TicketError::Malformed)?;
        let (body, signature) = text.rsplit_once('.').ok_or(TicketError::Malformed)?;
        let mut parts = body.split('.');
        let (Some(PREFIX), Some(session), Some(expires), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return Err(TicketError::Malformed);
        };
        valid_session(session)?;
        let expires: u64 = expires.parse().map_err(|_| TicketError::Malformed)?;
        let signature = URL_SAFE_NO_PAD.decode(signature).map_err(|_| TicketError::Malformed)?;
        let mut mac = HmacSha256::new_from_slice(secret).map_err(|_| TicketError::ShortSecret)?;
        mac.update(body.as_bytes());
        mac.verify_slice(&signature).map_err(|_| TicketError::BadSignature)?;
        if expires < unix_now()? {
            return Err(TicketError::Expired);
        }
        Ok(session.as_bytes().to_vec())
    }
}

fn sign(secret: &[u8], body: &[u8]) -> Result<Vec<u8>, TicketError> {
    let mut mac = HmacSha256::new_from_slice(secret).map_err(|_| TicketError::ShortSecret)?;
    mac.update(body);
    Ok(mac.finalize().into_bytes().to_vec())
}

fn valid_session(session: &str) -> Result<(), TicketError> {
    let ok = !session.is_empty()
        && session.len() <= MAXIMUM_SESSION_BYTES
        && session.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    if ok { Ok(()) } else { Err(TicketError::Malformed) }
}

pub fn unix_now() -> Result<u64, TicketError> {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .map_err(|_| TicketError::Clock)
}

#[cfg(test)]
#[path = "ticket_tests.rs"]
mod tests;
