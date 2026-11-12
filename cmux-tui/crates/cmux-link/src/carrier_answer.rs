//! The relay fields of a carrier answer (cmux-platform `CarrierRoute.ts`,
//! `POST /v1/cloud/machines/{id}/carrier`): `{ok, value: {relay, slot, ticket,
//! expires_at, grant?, daemon_key?}}`, checked the same way by every client
//! that dials a Cloud machine's relay slot: the `cmux carrier` CLI (which reads
//! its ssh and desktop extras beside these) and the iOS app's own carrier.
//!
//! Tickets and grants are secrets: they are kept in [`Zeroizing`] strings and
//! never appear in a `Debug` or an error.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use serde_json::Value;
use url::Url;
use zeroize::Zeroizing;

/// The longest ticket accepted (cmux-remote's relay credential bound).
pub const MAX_TICKET_BYTES: usize = 4096;

/// The relay part of one checked carrier answer.
#[derive(Clone)]
pub struct RelayAnswer {
    /// `relay+do://<host>` (or `relay+ws://` to this machine, for a local relay).
    pub relay: Url,
    pub slot: String,
    pub ticket: Zeroizing<String>,
    /// Unix seconds.
    pub expires_at: u64,
    /// The carrier grant naming the caller's Noise key, when it sent one.
    pub grant: Option<Zeroizing<String>>,
    /// The machine daemon's Noise static key: 32 canonical base64url bytes,
    /// else None (missing or malformed). A dial never handshakes without it.
    pub daemon_key: Option<[u8; 32]>,
}

impl std::fmt::Debug for RelayAnswer {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("RelayAnswer")
            .field("relay", &self.relay.as_str())
            .field("expires_at", &self.expires_at)
            .field("grant", &self.grant.is_some())
            .field("daemon_key", &self.daemon_key.is_some())
            .finish_non_exhaustive()
    }
}

/// A refused carrier ask: the platform's status and error code, and whether
/// asking again may pass (408, 429, 5xx and `owner.unreachable`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refusal {
    pub status: u16,
    pub code: String,
    pub message: String,
    pub retryable: bool,
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "cmux-platform answered {} {}: {}", self.status, self.code, self.message)
    }
}

/// base64url (no padding) of a 32-byte key, as the platform spells it.
pub fn key_text(key: &[u8; 32]) -> String {
    URL_SAFE_NO_PAD.encode(key)
}

/// A 32-byte key from its canonical base64url text, else None.
pub fn key_bytes(text: &str) -> Option<[u8; 32]> {
    let bytes = URL_SAFE_NO_PAD.decode(text).ok()?;
    let key: [u8; 32] = bytes.try_into().ok()?;
    (key_text(&key) == text).then_some(key)
}

/// The answer's `value` on success (`{ok: true, value}` with a 2xx status),
/// else the refusal.
pub fn reply_value(status: u16, body: &Value) -> Result<&Value, Refusal> {
    if (200..300).contains(&status) && body.get("ok").and_then(Value::as_bool) == Some(true) {
        return Ok(body.get("value").unwrap_or(&Value::Null));
    }
    let error = body.get("error");
    let code = error.and_then(|e| e.get("code")).and_then(Value::as_str).unwrap_or("http");
    let message = error.and_then(|e| e.get("message")).and_then(Value::as_str).unwrap_or("");
    let retryable = matches!(status, 408 | 429 | 500..=599) || code == "owner.unreachable";
    Err(Refusal { status, code: code.to_owned(), message: message.to_owned(), retryable })
}

/// Checks the relay fields of an answer's `value`.
pub fn parse_relay(value: &Value) -> Result<RelayAnswer, String> {
    let relay = relay_route(value.get("relay").and_then(Value::as_str).ok_or("relay is missing")?)?;
    let slot = value.get("slot").and_then(Value::as_str).ok_or("slot is missing")?;
    if slot.is_empty()
        || slot.len() > 128
        || !slot.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-')
    {
        return Err("slot is not 1 to 128 base64url characters".into());
    }
    let ticket = secret(value, "ticket", MAX_TICKET_BYTES)?;
    let expires_at =
        value.get("expires_at").and_then(Value::as_u64).ok_or("expires_at is missing")?;
    let grant = match value.get("grant") {
        None | Some(Value::Null) => None,
        Some(_) => Some(secret(value, "grant", crate::carrier_grant::MAX_GRANT_BYTES)?),
    };
    let daemon_key = value.get("daemon_key").and_then(Value::as_str).and_then(key_bytes);
    Ok(RelayAnswer { relay, slot: slot.to_owned(), ticket, expires_at, grant, daemon_key })
}

/// A secret field: 1 to `max` visible ASCII bytes.
fn secret(value: &Value, name: &str, max: usize) -> Result<Zeroizing<String>, String> {
    let text = value.get(name).and_then(Value::as_str).ok_or(format!("{name} is missing"))?;
    if text.is_empty() || text.len() > max || !text.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
        return Err(format!("{name} is not 1 to {max} visible ASCII bytes"));
    }
    Ok(Zeroizing::new(text.to_owned()))
}

/// The relay route a carrier dials: `relay+do://<host>`, or `relay+ws://`
/// only to this machine (a local relay in development and tests).
fn relay_route(text: &str) -> Result<Url, String> {
    let url = Url::parse(text).map_err(|_| "relay is not a URL".to_owned())?;
    let local = matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]"));
    let bare = url.username().is_empty()
        && url.password().is_none()
        && url.query().is_none()
        && url.fragment().is_none()
        && matches!(url.path(), "" | "/");
    match url.scheme() {
        "relay+do" if bare && url.host_str().is_some() => Ok(url),
        "relay+ws" if bare && local => Ok(url),
        _ => Err("relay is not a relay+do:// origin".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn key() -> String {
        key_text(&[7; 32])
    }

    fn answer() -> Value {
        json!({
            "relay": "relay+do://relay.cmux.dev",
            "slot": "slot_abc-1",
            "ticket": "tkt.secret",
            "expires_at": 1_800_000_000_u64,
            "grant": "h.c.s",
            "daemon_key": key(),
        })
    }

    #[test]
    fn a_whole_answer_parses() {
        let parsed = parse_relay(&answer()).expect("valid answer");
        assert_eq!(parsed.relay.as_str(), "relay+do://relay.cmux.dev");
        assert_eq!(parsed.slot, "slot_abc-1");
        assert_eq!(parsed.ticket.as_str(), "tkt.secret");
        assert_eq!(parsed.expires_at, 1_800_000_000);
        assert_eq!(parsed.grant.as_deref().map(String::as_str), Some("h.c.s"));
        assert_eq!(parsed.daemon_key, Some([7; 32]));
    }

    #[test]
    fn the_debug_form_names_no_secret() {
        let text = format!("{:?}", parse_relay(&answer()).expect("valid answer"));
        assert!(!text.contains("tkt.secret") && !text.contains("h.c.s"), "{text}");
    }

    #[test]
    fn a_relay_that_is_not_a_bare_relay_do_origin_is_refused() {
        for relay in [
            "wss://relay.cmux.dev",
            "relay+do://relay.cmux.dev/path",
            "relay+do://user@relay.cmux.dev",
            "relay+do://relay.cmux.dev?x=1",
            "relay+ws://relay.cmux.dev",
        ] {
            let mut value = answer();
            value["relay"] = json!(relay);
            assert!(parse_relay(&value).is_err(), "{relay}");
        }
        let mut value = answer();
        value["relay"] = json!("relay+ws://127.0.0.1:8787");
        assert!(parse_relay(&value).is_ok());
    }

    #[test]
    fn a_malformed_daemon_key_is_absent_not_an_error() {
        for key in [json!("short"), json!(format!("{}=", key())), json!(12)] {
            let mut value = answer();
            value["daemon_key"] = key;
            assert_eq!(parse_relay(&value).expect("valid answer").daemon_key, None);
        }
    }

    #[test]
    fn a_secret_with_spaces_or_no_bytes_is_refused() {
        for (name, bad) in [("ticket", ""), ("ticket", "a b"), ("grant", "a\nb"), ("slot", "a/b")] {
            let mut value = answer();
            value[name] = json!(bad);
            assert!(parse_relay(&value).is_err(), "{name}={bad:?}");
        }
    }

    #[test]
    fn a_refusal_says_whether_asking_again_may_pass() {
        let body = json!({"ok": false, "error": {"code": "cloud.machine.paused", "message": "paused"}});
        let refusal = reply_value(409, &body).expect_err("refused");
        assert_eq!((refusal.code.as_str(), refusal.retryable), ("cloud.machine.paused", false));
        let busy = json!({"ok": false, "error": {"code": "owner.unreachable"}});
        assert!(reply_value(503, &busy).expect_err("refused").retryable);
        assert!(reply_value(200, &json!({"ok": false})).is_err());
        assert!(reply_value(200, &json!({"ok": true, "value": answer()})).is_ok());
    }
}
