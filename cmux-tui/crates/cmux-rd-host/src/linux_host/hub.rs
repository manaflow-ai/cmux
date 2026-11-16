//! The device hub client of the Linux screen host (docs/device-hub/PROTOCOL.md): device-signed
//! requests, the account session (a Stack token exchanged once at `enable`, then device-key
//! renewal of a host-scoped session), and the hub's two WebSockets.

use super::b64;
use super::identity::{Device, Signer};
use super::net::{self, Url, WebSocket};
use crate::Res;
use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Renew the account session when less than this is left (ms).
const RENEW_BEFORE_MS: u64 = 5 * 60 * 1000;

/// A refusal from the hub: `{error:{code, message}}`.
#[derive(Debug, Clone, PartialEq)]
pub struct HubError {
    pub status: u16,
    pub code: String,
    pub message: String,
}

impl HubError {
    pub fn from_body(status: u16, body: &[u8]) -> Self {
        let value: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
        let field = |k: &str| value["error"][k].as_str().unwrap_or_default().to_owned();
        let mut message = field("message");
        if message.is_empty() {
            message = String::from_utf8_lossy(&body[..body.len().min(200)]).into_owned();
        }
        Self { status, code: field("code"), message }
    }
}

impl std::fmt::Display for HubError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The hub's own text, printed to the journal: no terminal control characters.
        write!(
            f,
            "device hub {} {}: {}",
            self.status,
            super::printable(&self.code),
            super::printable(&self.message)
        )
    }
}

impl std::error::Error for HubError {}

/// The string a device signs: `"<METHOD>\n<path+query>\n<ts>\n<hex sha256 of body or empty>"`.
/// The method is upper-cased and an empty body signs as no body, as the hub and the apps do
/// (schemas/device-hub/request-signing-vectors.json).
pub fn signing_string(method: &str, target: &str, ts: u64, body: Option<&[u8]>) -> String {
    let method = method.to_ascii_uppercase();
    let digest = body
        .filter(|b| !b.is_empty())
        .map(|b| crate::serve::hex(ring::digest::digest(&ring::digest::SHA256, b).as_ref()))
        .unwrap_or_default();
    format!("{method}\n{target}\n{ts}\n{digest}")
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |d| d.as_millis() as u64)
}

pub struct Hub {
    pub origin: String,
    pub device: Device,
    signer: Signer,
    user_id: Mutex<Option<String>>,
    /// The account session and when it ends (ms).
    session: Mutex<Option<(String, u64)>>,
}

impl Hub {
    pub fn new(origin: &str, device: Device, user_id: Option<String>) -> Res<Self> {
        Url::parse(origin)?;
        Ok(Self {
            origin: origin.trim_end_matches('/').to_owned(),
            signer: device.signer()?,
            device,
            user_id: Mutex::new(user_id),
            session: Mutex::new(None),
        })
    }

    pub fn user_id(&self) -> Option<String> {
        self.user_id.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    #[cfg(test)]
    pub fn signing_key(&self) -> String {
        self.signer.public_key()
    }

    pub fn sign(&self, message: &[u8]) -> Res<Vec<u8>> {
        self.signer.sign(message)
    }

    /// `X-Device-Id`, `X-Device-Ts`, `X-Device-Sig` for one request.
    pub fn device_headers(
        &self,
        method: &str,
        target: &str,
        body: Option<&[u8]>,
    ) -> Res<Vec<(String, String)>> {
        let ts = now_ms() / 1000;
        let sig = self.signer.sign(signing_string(method, target, ts, body).as_bytes())?;
        Ok(vec![
            ("X-Device-Id".into(), self.device.id.clone()),
            ("X-Device-Ts".into(), ts.to_string()),
            ("X-Device-Sig".into(), b64::encode(&sig)),
        ])
    }

    fn send(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        bearer: Option<&str>,
        signed: bool,
    ) -> Res<Value> {
        let url = Url::join(&self.origin, path)?;
        let bytes = body.map(serde_json::to_vec).transpose()?;
        let mut headers = if signed {
            self.device_headers(method, &url.target, bytes.as_deref())?
        } else {
            Vec::new()
        };
        if let Some(token) = bearer {
            headers.push(("Authorization".into(), format!("Bearer {token}")));
        }
        let response = net::request(method, &url, &headers, bytes.as_deref())?;
        if !(200..300).contains(&response.status) {
            return Err(HubError::from_body(response.status, &response.body).into());
        }
        if response.body.is_empty() {
            return Ok(Value::Null);
        }
        Ok(serde_json::from_slice(&response.body)?)
    }

    /// `POST /v1/auth/stack`: the account session for a Stack access token (`enable`).
    pub fn sign_in_with_stack(&self, token: &str) -> Res<String> {
        let answer =
            self.send("POST", "/v1/auth/stack", Some(&json!({ "token": token })), None, false)?;
        let session =
            answer["session"].as_str().ok_or("no session in the hub's answer")?.to_owned();
        let user = answer["userId"].as_str().ok_or("no userId in the hub's answer")?.to_owned();
        let expires = answer["expiresAt"].as_u64().unwrap_or(now_ms() + 30 * 60 * 1000);
        *self.user_id.lock().unwrap_or_else(|e| e.into_inner()) = Some(user.clone());
        *self.session.lock().unwrap_or_else(|e| e.into_inner()) = Some((session, expires));
        Ok(user)
    }

    /// `POST /v1/auth/device`: a host-scoped session from the device key alone (the anchor
    /// that `enable` recorded lets this device renew for 30 days).
    fn renew(&self) -> Res<(String, u64)> {
        let user = self.user_id().ok_or("not enabled: run `cmux-rd linux-host enable` first")?;
        let answer =
            self.send("POST", "/v1/auth/device", Some(&json!({ "userId": user })), None, true)?;
        let session =
            answer["session"].as_str().ok_or("no session in the hub's answer")?.to_owned();
        let expires = answer["expiresAt"].as_u64().unwrap_or(now_ms() + 30 * 60 * 1000);
        Ok((session, expires))
    }

    /// The account session, renewed when it is about to end.
    pub fn session(&self) -> Res<String> {
        let mut slot = self.session.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((token, expires)) = slot.as_ref() {
            if *expires > now_ms() + RENEW_BEFORE_MS {
                return Ok(token.clone());
            }
        }
        let fresh = self.renew()?;
        let token = fresh.0.clone();
        *slot = Some(fresh);
        Ok(token)
    }

    /// One account call, signed by the device.
    pub fn call(&self, method: &str, path: &str, body: Option<&Value>) -> Res<Value> {
        let session = self.session()?;
        self.send(method, path, body, Some(&session), true)
    }

    /// `POST /v1/devices`: registers this device as `linux`.
    pub fn register(&self) -> Res<Value> {
        let body = json!({
            "id": self.device.id,
            "name": self.device.name,
            "platform": "linux",
            "signingKey": self.signer.public_key(),
            "agreementKey": self.device.agreement_key()?,
        });
        self.call("POST", "/v1/devices", Some(&body))
    }

    /// `POST /v1/auth/device/anchor`: lets this device renew its own host session. Returns
    /// when the anchor ends (ms).
    pub fn anchor(&self) -> Res<u64> {
        let answer = self.call("POST", "/v1/auth/device/anchor", Some(&json!({})))?;
        Ok(answer["anchoredUntil"].as_u64().unwrap_or(0))
    }

    /// `PUT /v1/devices/:id/mac-screen`: this device's sharing switch.
    pub fn set_shared(&self, shared: bool) -> Res<Value> {
        let path = format!("/v1/devices/{}/mac-screen", self.device.id);
        self.call("PUT", &path, Some(&json!({ "shared": shared })))
    }

    /// `POST /v1/sessions/:id/decision`.
    pub fn decide(&self, session: &str, decision: &str, scope: Option<&str>) -> Res<Value> {
        let mut body = json!({ "decision": decision });
        if let Some(scope) = scope {
            body["scope"] = json!(scope);
        }
        self.call("POST", &format!("/v1/sessions/{}/decision", path_segment(session)?), Some(&body))
    }

    /// `POST /v1/sessions/:id/end`.
    pub fn end(&self, session: &str, reason: &str) -> Res<()> {
        let body = json!({ "reason": reason });
        self.call("POST", &format!("/v1/sessions/{}/end", path_segment(session)?), Some(&body))
            .map(|_| ())
    }

    /// The User DO socket (`GET /v1/user/ws`).
    pub fn user_socket(&self) -> Res<WebSocket> {
        let url = Url::join(&self.origin, "/v1/user/ws")?;
        let mut headers = self.device_headers("GET", &url.target, None)?;
        headers.push(("Authorization".into(), format!("Bearer {}", self.session()?)));
        WebSocket::connect(&url, &headers)
    }

    /// A session's signaling socket: `signalURL?ticket=<jws>` with the device headers (the
    /// ticket admits it; no account session).
    pub fn session_socket(&self, signal_url: &str, ticket: &str) -> Res<WebSocket> {
        if !ticket.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b)) {
            return Err("the ticket is not a compact JWS".into());
        }
        let separator = if signal_url.contains('?') { '&' } else { '?' };
        let url = Url::parse(&format!("{signal_url}{separator}ticket={ticket}"))?;
        // The ticket goes only to this hub.
        let hub = Url::parse(&self.origin)?;
        if url.host != hub.host || url.tls != hub.tls || url.port != hub.port {
            return Err(format!("the ticket's signal URL is not on {}", self.origin).into());
        }
        let headers = self.device_headers("GET", &url.target, None)?;
        WebSocket::connect(&url, &headers)
    }
}

/// A hub id as one path segment (ids are UUIDs; anything else is refused).
fn path_segment(id: &str) -> Res<&str> {
    if !id.is_empty()
        && id.len() <= 100
        && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        Ok(id)
    } else {
        Err(format!("{id:?} is not a session id").into())
    }
}

/// Verifies a raw r||s P-256 signature with a base64 X9.63 public key.
pub fn verify(public_key: &str, message: &[u8], signature: &[u8]) -> bool {
    let Some(key) = b64::decode(public_key) else { return false };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
        .verify(message, signature)
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn signing_string_matches_the_protocol() {
        assert_eq!(
            signing_string("GET", "/v1/user/ws", 1700000000, None),
            "GET\n/v1/user/ws\n1700000000\n"
        );
        assert_eq!(
            signing_string("POST", "/v1/devices", 7, Some(b"{}")),
            "POST\n/v1/devices\n7\n44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a"
        );
    }

    /// The shared vectors the hub (workers/device-hub) and the apps (CmuxDeviceHub) test too.
    #[test]
    fn request_signing_vectors() {
        let vectors: Value = serde_json::from_str(include_str!(
            "../../../../../schemas/device-hub/request-signing-vectors.json"
        ))
        .unwrap();
        for case in vectors["canonical"].as_array().unwrap() {
            let got = signing_string(
                case["method"].as_str().unwrap(),
                case["pathAndQuery"].as_str().unwrap(),
                case["ts"].as_u64().unwrap(),
                case["body"].as_str().map(str::as_bytes),
            );
            assert_eq!(got, case["canonical"].as_str().unwrap(), "{}", case["name"]);
        }
        let key = vectors["signatures"]["publicKey"].as_str().unwrap();
        for case in vectors["signatures"]["cases"].as_array().unwrap() {
            let sig = b64::decode(case["signature"].as_str().unwrap()).unwrap();
            let message = case["message"].as_str().unwrap().as_bytes();
            let verdict = case["verifies"].as_bool().unwrap();
            assert_eq!(verify(key, message, &sig), verdict, "{}", case["name"]);
        }
    }

    #[test]
    fn device_headers_verify_with_the_registered_key() {
        let hub = Hub::new("https://hub.example", Device::generate("t").unwrap(), None).unwrap();
        let headers = hub.device_headers("POST", "/v1/devices", Some(b"{}")).unwrap();
        let ts: u64 = headers[1].1.parse().unwrap();
        let sig = b64::decode(&headers[2].1).unwrap();
        assert_eq!(sig.len(), 64);
        let message = signing_string("POST", "/v1/devices", ts, Some(b"{}"));
        assert!(verify(&hub.signing_key(), message.as_bytes(), &sig));
        assert!(!verify(&hub.signing_key(), b"other", &sig));
    }

    #[test]
    fn session_ids_and_hub_errors() {
        assert!(path_segment("1b4e28ba-2fa1-11d2-883f-0016d3cca427").is_ok());
        assert!(path_segment("../devices").is_err());
        let e = HubError::from_body(403, br#"{"error":{"code":"not_shared","message":"no"}}"#);
        assert_eq!((e.code.as_str(), e.message.as_str()), ("not_shared", "no"));
    }

    #[test]
    fn a_ticket_is_only_sent_to_its_own_hub() {
        let hub = Hub::new("https://hub.example", Device::generate("t").unwrap(), None).unwrap();
        let err =
            hub.session_socket("wss://elsewhere.example/v1/sessions/s/ws", "a.b.c").err().unwrap();
        assert!(err.to_string().contains("not on"), "{err}");
        assert!(hub.session_socket("wss://hub.example/v1/sessions/s/ws", "a b").is_err());
        let err =
            hub.session_socket("wss://hub.example:8443/v1/sessions/s/ws", "a.b.c").err().unwrap();
        assert!(err.to_string().contains("not on"), "{err}");
    }
}
