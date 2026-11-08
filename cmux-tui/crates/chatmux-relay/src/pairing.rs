//! The pairing ceremony: `POST /v2/pairing/start`, then the ceremony
//! WebSocket (`/v2/pairing/{pairId}/socket`) through claimed → confirm →
//! paired. Behavior port of the JS relay's `startPairing`/`awaitCeremony`
//! (`packages/relay/bin/cmux-relay.mjs`); the pairing wire stays version 1.

use base64::Engine as _;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use futures_util::{SinkExt as _, StreamExt as _};
use serde_json::Value;
use sha2::{Digest, Sha256};
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

use crate::config::Config;
use crate::error::RelayError;
use crate::fingerprint::derive_cute_code;
use crate::trust::Trust;
use crate::wire::PAIRING_WIRE_VERSION;

pub struct StartedPairing {
    pub pair_id: String,
    pub secret: String,
    pub relay_public_key: String,
    pub cute_code: String,
    pub expires_at: Option<Value>,
}

/// How the relay side confirms once the phone/page claims the ceremony.
pub enum CeremonyMode {
    /// URL flow: auto-confirm — the single human action is the Approve
    /// click on the page; the cute code shown there is bound to OUR public
    /// key, so the visual match on the page is the man-in-the-middle check.
    Url,
    /// `--code` fallback: mutual six-digit SAS verification at the terminal.
    Code { sas_auto_approve: bool },
}

pub struct PairedOutcome {
    pub config: Config,
    /// Value-safe UI hint only. It is kept in process memory and never
    /// copied into the saved pairing config or effective trust.
    pub requested_trust: Option<Trust>,
}

/// New pairing id, W100 shape: `pair_<24 base36>`. Mirrors the chatmux id
/// registry (`packages/protocol/src/ids.ts`); rejection sampling keeps the
/// 36-symbol alphabet uniform (216 = 36 * 6).
pub fn mint_pair_id() -> Result<String, RelayError> {
    let alphabet = b"0123456789abcdefghijklmnopqrstuvwxyz";
    let mut tail = String::with_capacity(24);
    while tail.len() < 24 {
        let mut bytes = [0_u8; 48];
        getrandom::fill(&mut bytes)
            .map_err(|error| RelayError::fatal(format!("pairing id randomness failed: {error}")))?;
        for byte in bytes {
            if byte >= 216 {
                continue;
            }
            tail.push(char::from(alphabet[usize::from(byte % 36)]));
            if tail.len() == 24 {
                break;
            }
        }
    }
    Ok(format!("pair_{tail}"))
}

fn random_secret() -> Result<String, RelayError> {
    let mut bytes = [0_u8; 32];
    getrandom::fill(&mut bytes)
        .map_err(|error| RelayError::fatal(format!("pairing secret randomness failed: {error}")))?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

/// Fresh X25519 public key as base64url SPKI DER — the exact byte layout
/// Node's `generateKeyPairSync("x25519")` SPKI export produces (12-byte
/// RFC 8410 prefix + 32 raw key bytes).
fn mint_relay_public_key() -> Result<String, RelayError> {
    const SPKI_X25519_PREFIX: [u8; 12] =
        [0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00];
    let mut seed = [0_u8; 32];
    getrandom::fill(&mut seed)
        .map_err(|error| RelayError::fatal(format!("relay key randomness failed: {error}")))?;
    let secret = x25519_dalek::StaticSecret::from(seed);
    let public = x25519_dalek::PublicKey::from(&secret);
    let mut der = Vec::with_capacity(44);
    der.extend_from_slice(&SPKI_X25519_PREFIX);
    der.extend_from_slice(public.as_bytes());
    Ok(URL_SAFE_NO_PAD.encode(der))
}

fn hash_base64url(value: &str) -> String {
    URL_SAFE_NO_PAD.encode(Sha256::digest(value.as_bytes()))
}

pub fn websocket_url(value: &str) -> String {
    if let Some(rest) = value.strip_prefix("https:") {
        format!("wss:{rest}")
    } else if let Some(rest) = value.strip_prefix("http:") {
        format!("ws:{rest}")
    } else {
        value.to_owned()
    }
}

/// `POST /v2/pairing/start`; verifies the server derived OUR cute code.
pub async fn start_pairing(
    client: &reqwest::Client,
    backend: &str,
    name: &str,
    platform: &str,
) -> Result<StartedPairing, RelayError> {
    let pair_id = mint_pair_id()?;
    let secret = random_secret()?;
    let relay_public_key = mint_relay_public_key()?;
    let cute_code = derive_cute_code(&relay_public_key);
    let response = client
        .post(format!("{backend}/v2/pairing/start"))
        .json(&serde_json::json!({
            "version": PAIRING_WIRE_VERSION,
            "pairId": pair_id,
            "secretHash": hash_base64url(&secret),
            "relayPublicKey": relay_public_key,
            "relayName": name,
            "platform": platform,
        }))
        .send()
        .await
        .map_err(|error| RelayError::transient(format!("pairing start failed: {error}")))?;
    if response.status() == reqwest::StatusCode::TOO_MANY_REQUESTS {
        return Err(RelayError::fatal(
            "The server is rate-limiting pairing attempts from this network. \
             Wait a minute, then re-run npx cmux-relay.",
        ));
    }
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(RelayError::fatal(format!("{}: {body}", status.as_u16())));
    }
    let start: Value = response
        .json()
        .await
        .map_err(|error| RelayError::fatal(format!("pairing start returned no JSON: {error}")))?;
    if let Some(server_code) = start.get("cuteCode").and_then(Value::as_str)
        && server_code != cute_code
    {
        // The server would show a different code than this terminal: someone
        // or something between us altered the key. Do not continue.
        return Err(RelayError::fatal(
            "Verification-code mismatch between this terminal and the server. \
             Aborting pairing; try again on a network you trust.",
        ));
    }
    Ok(StartedPairing {
        pair_id,
        secret,
        relay_public_key,
        cute_code,
        expires_at: start.get("expiresAt").cloned(),
    })
}

fn group_code(code: &str) -> String {
    if code.len() >= 6 { format!("{} {}", &code[..3], &code[3..]) } else { code.to_owned() }
}

fn confirm_frame(approved: bool, short_code: &str) -> String {
    serde_json::json!({
        "version": PAIRING_WIRE_VERSION,
        "type": "confirm",
        "approved": approved,
        "shortCode": short_code,
    })
    .to_string()
}

/// Shared ceremony socket: authenticate with the QR/link secret, then wait
/// for claimed/paired/rejected. `mode` decides how the relay side confirms
/// (auto in the URL flow, human SAS check in `--code`).
pub async fn await_ceremony(
    backend: &str,
    started: &StartedPairing,
    mode: CeremonyMode,
    name: &str,
    platform: &str,
) -> Result<PairedOutcome, RelayError> {
    let socket_url = websocket_url(&format!("{backend}/v2/pairing/{}/socket", started.pair_id));
    let (mut socket, _response) = connect_async(socket_url.as_str())
        .await
        .map_err(|error| RelayError::transient(format!("pairing socket failed: {error}")))?;
    let authenticate = serde_json::json!({
        "version": PAIRING_WIRE_VERSION,
        "type": "authenticate",
        "secret": started.secret,
    })
    .to_string();
    socket
        .send(Message::Text(authenticate.into()))
        .await
        .map_err(|error| RelayError::transient(format!("pairing socket failed: {error}")))?;

    let mut claimed = false;
    loop {
        let message = match socket.next().await {
            Some(Ok(message)) => message,
            Some(Err(error)) => {
                return Err(RelayError::transient(format!("pairing socket failed: {error}")));
            }
            None => {
                return Err(RelayError::PairingExpired {
                    message: "Pairing connection closed".to_owned(),
                });
            }
        };
        let text = match message {
            Message::Text(text) => text,
            Message::Ping(payload) => {
                let _ = socket.send(Message::Pong(payload)).await;
                continue;
            }
            Message::Close(frame) => {
                let code = frame.map(|frame| frame.code.to_string()).unwrap_or_default();
                return Err(RelayError::PairingExpired {
                    message: format!("Pairing connection closed ({code})"),
                });
            }
            _ => continue,
        };
        let Ok(frame) = serde_json::from_str::<Value>(&text) else { continue };
        let frame_type = frame.get("type").and_then(Value::as_str).unwrap_or_default();
        match frame_type {
            "error" => {
                let code = frame.get("code").and_then(Value::as_str).unwrap_or("unknown");
                return Err(RelayError::fatal(format!("Pairing failed: {code}")));
            }
            "status" if frame.get("status").and_then(Value::as_str) == Some("rejected") => {
                return Err(RelayError::fatal("Pairing denied from the chatmux app."));
            }
            "claimed" if !claimed => {
                claimed = true;
                let short_code =
                    frame.get("shortCode").and_then(Value::as_str).unwrap_or_default().to_owned();
                match &mode {
                    CeremonyMode::Url => {
                        // Single human action = the Approve click on the page.
                        socket
                            .send(Message::Text(confirm_frame(true, &short_code).into()))
                            .await
                            .map_err(|error| {
                            RelayError::transient(format!("pairing socket failed: {error}"))
                        })?;
                        println!(
                            "Opened in the chatmux app — click Approve there if the codes match."
                        );
                    }
                    CeremonyMode::Code { sas_auto_approve } => {
                        println!("Your verification code is: {}", group_code(&short_code));
                        let relay_name = frame
                            .get("relayName")
                            .and_then(Value::as_str)
                            .unwrap_or(name)
                            .to_owned();
                        let approved = *sas_auto_approve
                            || crate::prompt::ask(&format!(
                                "Does your phone show {} and {relay_name}? Approve pairing?",
                                group_code(&short_code)
                            ))
                            .await;
                        socket
                            .send(Message::Text(confirm_frame(approved, &short_code).into()))
                            .await
                            .map_err(|error| {
                                RelayError::transient(format!("pairing socket failed: {error}"))
                            })?;
                        if !approved {
                            return Err(RelayError::fatal("Pairing rejected locally"));
                        }
                    }
                }
            }
            "paired" => {
                let requested_trust = crate::trust::requested_trust_hint(
                    frame.get("requestedTrust").and_then(Value::as_str),
                );
                let device_id =
                    frame.get("deviceId").and_then(Value::as_str).unwrap_or_default().to_owned();
                let token =
                    frame.get("relayToken").and_then(Value::as_str).unwrap_or_default().to_owned();
                let config = Config {
                    version: Some(2),
                    backend: backend.to_owned(),
                    device_id,
                    token,
                    name: Some(name.to_owned()),
                    platform: Some(platform.to_owned()),
                    scope: Some("personal".to_owned()),
                    trust: Some("supervised".to_owned()),
                    ..Config::default()
                };
                let _ = socket.close(None).await;
                return Ok(PairedOutcome { config, requested_trust });
            }
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pair_ids_have_the_w100_shape() {
        for _ in 0..16 {
            let id = mint_pair_id().expect("OS randomness available in test");
            assert_eq!(id.len(), "pair_".len() + 24);
            let tail = id.strip_prefix("pair_").expect("prefix");
            assert!(tail.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit()));
        }
        assert_ne!(mint_pair_id().unwrap(), mint_pair_id().unwrap());
    }

    #[test]
    fn relay_public_keys_are_x25519_spki_der_base64url() {
        let key = mint_relay_public_key().expect("OS randomness available in test");
        // 44 DER bytes -> 59 unpadded base64url characters.
        assert_eq!(key.len(), 59);
        let der = URL_SAFE_NO_PAD.decode(&key).expect("decodes");
        assert_eq!(der.len(), 44);
        assert_eq!(
            &der[..12],
            &[0x30, 0x2a, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x6e, 0x03, 0x21, 0x00]
        );
        assert_ne!(mint_relay_public_key().unwrap(), mint_relay_public_key().unwrap());
    }

    #[test]
    fn secrets_are_43_base64url_characters() {
        // The Worker's pairing URL regex pins #<secret> to exactly 43
        // [A-Za-z0-9_-] characters (32 bytes, unpadded).
        let secret = random_secret().expect("OS randomness available in test");
        assert_eq!(secret.len(), 43);
        assert!(secret.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    }

    #[test]
    fn websocket_urls_upgrade_scheme_like_the_js_relay() {
        assert_eq!(websocket_url("https://api.chatmux.dev/x"), "wss://api.chatmux.dev/x");
        assert_eq!(websocket_url("http://localhost:8788/x"), "ws://localhost:8788/x");
    }

    #[test]
    fn secret_hash_matches_node_sha256_base64url() {
        // node -e 'console.log(require("crypto").createHash("sha256").update("secret").digest("base64url"))'
        assert_eq!(hash_base64url("secret"), "K7gNU3sdo-OL0wNhqoVWhr3g6s1xYv72ol_pe_Unols");
    }
}
