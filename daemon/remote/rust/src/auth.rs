use base64::Engine;
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use sha2::Sha256;

type HmacSha256 = Hmac<Sha256>;

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TicketClaims {
    #[serde(default)]
    pub server_id: String,
    #[serde(default)]
    pub team_id: String,
    #[serde(default)]
    pub session_id: String,
    #[serde(default)]
    pub attachment_id: String,
    #[serde(default)]
    pub capabilities: Vec<String>,
    #[serde(default)]
    pub exp: i64,
    #[serde(default)]
    pub nonce: String,
}

#[derive(Debug, Clone)]
pub enum TicketError {
    Malformed,
    InvalidSignature,
    Expired,
    WrongServer,
}

impl std::fmt::Display for TicketError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            TicketError::Malformed => write!(f, "malformed ticket"),
            TicketError::InvalidSignature => write!(f, "invalid ticket signature"),
            TicketError::Expired => write!(f, "ticket expired"),
            TicketError::WrongServer => write!(f, "ticket server mismatch"),
        }
    }
}

impl std::error::Error for TicketError {}

pub fn verify_ticket(
    token: &str,
    secret: &[u8],
    expected_server_id: &str,
) -> Result<TicketClaims, TicketError> {
    let mut parts = token.split('.');
    let encoded_payload = parts.next().ok_or(TicketError::Malformed)?;
    let encoded_signature = parts.next().ok_or(TicketError::Malformed)?;
    if parts.next().is_some() {
        return Err(TicketError::Malformed);
    }

    let signature = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded_signature)
        .map_err(|_| TicketError::Malformed)?;
    let mut mac = HmacSha256::new_from_slice(secret).expect("hmac key");
    mac.update(encoded_payload.as_bytes());
    if mac.verify_slice(&signature).is_err() {
        return Err(TicketError::InvalidSignature);
    }

    let payload = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(encoded_payload)
        .map_err(|_| TicketError::Malformed)?;
    let claims: TicketClaims =
        serde_json::from_slice(&payload).map_err(|_| TicketError::Malformed)?;
    if claims.exp <= now_unix() {
        return Err(TicketError::Expired);
    }
    if !expected_server_id.is_empty() && claims.server_id != expected_server_id {
        return Err(TicketError::WrongServer);
    }
    Ok(claims)
}

pub fn has_session_capability(capabilities: &[String]) -> bool {
    capabilities
        .iter()
        .any(|value| value == "session.attach" || value == "session.open")
}

#[cfg_attr(not(test), allow(dead_code))]
pub fn sign(payload: &[u8], secret: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(secret).expect("hmac key");
    mac.update(payload);
    mac.finalize().into_bytes().to_vec()
}

fn now_unix() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encode(value: &[u8]) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(value)
    }

    #[test]
    fn verify_ticket_accepts_valid_signature() {
        let payload = encode(br#"{"server_id":"srv","exp":4102444800,"nonce":"n"}"#);
        let signature = encode(&sign(payload.as_bytes(), b"secret"));
        let token = format!("{payload}.{signature}");
        assert!(verify_ticket(&token, b"secret", "srv").is_ok());
    }

    #[test]
    fn verify_ticket_rejects_invalid_signature() {
        let payload = encode(br#"{"server_id":"srv","exp":4102444800,"nonce":"n"}"#);
        let token = format!("{payload}.{}", encode(b"wrong"));
        assert!(matches!(
            verify_ticket(&token, b"secret", "srv"),
            Err(TicketError::InvalidSignature)
        ));
    }
}
