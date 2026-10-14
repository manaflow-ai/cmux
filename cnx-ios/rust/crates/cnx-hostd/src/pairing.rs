//! Device pairing (cnx-ios `verify/phone-approvals.md`, audit B2): a Stack
//! token alone never reaches the Mac's terminals and agents.
//!
//! - Each phone holds two Secure Enclave P-256 keys: an identity key that
//!   signs without a prompt, and an approval key that needs Face ID.
//! - The first channel of every link is `auth` with `{identityKey,
//!   approvalKey, name}`. hostd sends a fresh challenge; the phone signs
//!   [`challenge_message`] with its identity key. Until that succeeds, every
//!   other service on the link is refused with `unpaired`.
//! - A key pair the Mac already approved for this device id passes at once.
//!   Otherwise hostd asks the app (`pair_request`), which asks the user ("Allow
//!   <phone> to connect?"), and waits up to [`APPROVAL_WAIT`] for the app's
//!   next `devices` list to approve or deny it.
//! - `{action: "unpair"}` with a valid signature by an approved key tells the
//!   app to forget that device (the phone's sign-out).
//!
//! The device id is the link's authenticated sender (backend-stamped), never
//! an argument. Unsupervised hostd (tests, `run-host.sh`) runs without
//! pairing, as before.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cnx_link::ChannelEvent;
use cnx_link::link::{ChannelReceiver, ChannelSender};
use serde::Deserialize;
use serde_json::{Value, json};
use tokio::sync::watch;

use crate::control::Event;

/// How long a link waits for the user to answer the Mac's pairing prompt.
pub const APPROVAL_WAIT: Duration = Duration::from_secs(120);
/// How long hostd waits for the phone's signature.
const SIGNATURE_WAIT: Duration = Duration::from_secs(30);
const DOMAIN: &str = "cnx-link-auth-v1";

/// One device the Mac approved.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct TrustedDevice {
    pub id: String,
    /// The 65-byte X9.63 identity key, lowercase hex.
    pub identity_key: String,
    /// The approval key, lowercase hex (empty: none).
    #[serde(default)]
    pub approval_key: String,
}

/// What the app approved and refused, as it last said.
#[derive(Debug, Clone, Default, PartialEq, Eq, Deserialize)]
pub struct DeviceTrust {
    pub devices: Vec<TrustedDevice>,
    /// Identity keys the user refused for a device id: refused at once, never asked again.
    #[serde(default)]
    pub denied: Vec<DeniedDevice>,
}

/// One request the user refused: that device id with that identity key.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
pub struct DeniedDevice {
    pub id: String,
    pub identity_key: String,
}

/// Where a decision about this request stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Standing {
    Trusted,
    Denied,
    Unknown,
}

impl DeviceTrust {
    pub fn standing(&self, id: &str, identity_key: &str, approval_key: &str) -> Standing {
        if self
            .devices
            .iter()
            .any(|d| d.id == id && d.identity_key == identity_key && d.approval_key == approval_key)
        {
            Standing::Trusted
        } else if self.denied.iter().any(|d| d.id == id && d.identity_key == identity_key) {
            Standing::Denied
        } else {
            Standing::Unknown
        }
    }

    fn knows_identity(&self, id: &str, identity_key: &str) -> bool {
        self.devices.iter().any(|d| d.id == id && d.identity_key == identity_key)
    }
}

/// Pairing for a supervised hostd.
#[derive(Clone)]
pub struct Pairing {
    /// This Mac's device id (bound into every challenge).
    pub mac_device_id: String,
    /// The app's latest `devices` line (`None` until it sends one).
    pub trust: watch::Receiver<Option<DeviceTrust>>,
    /// Where events for the app go (stdout when supervised).
    pub emit: Arc<dyn Fn(Event) + Send + Sync>,
}

impl std::fmt::Debug for Pairing {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Pairing").field("mac_device_id", &self.mac_device_id).finish_non_exhaustive()
    }
}

/// Whether this link's phone proved an approved key.
#[derive(Debug, Default)]
pub struct LinkAuth {
    authenticated: AtomicBool,
}

impl LinkAuth {
    pub fn is_authenticated(&self) -> bool {
        self.authenticated.load(Ordering::SeqCst)
    }
}

/// The bytes the phone's identity key signs.
pub fn challenge_message(
    mac: &str,
    phone: &str,
    nonce: &str,
    identity_key: &str,
    approval_key: &str,
    action: &str,
) -> Vec<u8> {
    let mut out = DOMAIN.as_bytes().to_vec();
    for part in [mac, phone, nonce, identity_key, approval_key, action] {
        out.push(0);
        out.extend_from_slice(part.as_bytes());
    }
    out
}

/// A refusal: close code and reason.
pub type Refused = (&'static str, String);

fn is_point(hex: &str) -> bool {
    hex.len() == 130
        && hex.starts_with("04")
        && hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

fn new_nonce() -> Result<String, Refused> {
    use ring::rand::SecureRandom;
    let mut bytes = [0u8; 32];
    ring::rand::SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| ("unavailable", "no randomness".to_owned()))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Verifies `signature` (raw `r || s`, hex) by the X9.63 key `key_hex`.
pub fn verify(key_hex: &str, message: &[u8], signature: &str) -> bool {
    let (Some(key), Some(signature)) = (unhex(key_hex), unhex(signature)) else { return false };
    signature.len() == 64
        && ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, &key)
            .verify(message, &signature)
            .is_ok()
}

/// The `auth` service: prove the identity key, then pass if the Mac approved
/// this device's keys, else ask the app and wait for the user.
pub async fn serve(
    pairing: Option<&Pairing>,
    phone: &str,
    link: &LinkAuth,
    args: &Value,
    sender: &ChannelSender,
    receiver: &mut ChannelReceiver,
) -> Result<(), Refused> {
    let text = |key: &str| args.get(key).and_then(Value::as_str).unwrap_or_default();
    let identity_key = text("identityKey");
    let approval_key = text("approvalKey");
    let action = match text("action") {
        "" | "pair" => "pair",
        "unpair" => "unpair",
        _ => return Err(("bad_request", "action is pair or unpair".into())),
    };
    if !is_point(identity_key) || !(approval_key.is_empty() || is_point(approval_key)) {
        return Err(("bad_request", "keys must be 65-byte uncompressed P-256 points as hex".into()));
    }
    let name: String = text("name").chars().filter(|c| !c.is_control()).take(64).collect();
    let Some(pairing) = pairing else {
        // Unsupervised: no app to approve; every link is served as before.
        link.authenticated.store(true, Ordering::SeqCst);
        send(sender, json!({"ok": true})).await;
        return Ok(());
    };
    let nonce = new_nonce()?;
    send(sender, json!({"challenge": nonce, "mac": pairing.mac_device_id})).await;
    let signature = match tokio::time::timeout(SIGNATURE_WAIT, receiver.recv()).await {
        Ok(Some(ChannelEvent::Data(bytes))) => serde_json::from_slice::<Value>(&bytes)
            .ok()
            .and_then(|v| v.get("signature").and_then(Value::as_str).map(str::to_owned))
            .ok_or(("bad_request", "expected {signature}".to_owned()))?,
        _ => return Err(("timeout", "no signature".into())),
    };
    let message =
        challenge_message(&pairing.mac_device_id, phone, &nonce, identity_key, approval_key, action);
    if !verify(identity_key, &message, &signature) {
        return Err(("unpaired", "the signature does not match the identity key".into()));
    }
    let mut trust = pairing.trust.clone();
    if action == "unpair" {
        let known = trust.borrow().as_ref().is_some_and(|t| t.knows_identity(phone, identity_key));
        if !known {
            return Err(("unpaired", "this device is not paired".into()));
        }
        (pairing.emit)(Event::Unpaired { phone_device_id: phone.to_owned() });
        send(sender, json!({"ok": true})).await;
        return Ok(());
    }
    let standing = |t: &Option<DeviceTrust>| {
        t.as_ref().map_or(Standing::Unknown, |t| t.standing(phone, identity_key, approval_key))
    };
    let mut asked = false;
    let result = tokio::time::timeout(APPROVAL_WAIT, async {
        loop {
            match standing(&trust.borrow_and_update()) {
                Standing::Trusted => return Ok(()),
                Standing::Denied => {
                    return Err(("denied", "the Mac did not allow this iPhone".into()));
                }
                _ => {}
            }
            if !asked {
                asked = true;
                (pairing.emit)(Event::PairRequest {
                    phone_device_id: phone.to_owned(),
                    name: name.clone(),
                    identity_key: identity_key.to_owned(),
                    approval_key: approval_key.to_owned(),
                });
                send(sender, json!({"pending": true})).await;
            }
            if trust.changed().await.is_err() {
                return Err(("unavailable", "the app is gone".into()));
            }
        }
    })
    .await;
    match result {
        Ok(Ok(())) => {
            link.authenticated.store(true, Ordering::SeqCst);
            send(sender, json!({"ok": true})).await;
            Ok(())
        }
        Ok(Err(refused)) => Err(refused),
        Err(_) => Err(("timeout", "nobody answered the Mac's prompt".into())),
    }
}

async fn send(sender: &ChannelSender, value: Value) {
    let _ = sender.send(Bytes::from(value.to_string())).await;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_challenge_is_fixed() {
        // The same vector is in the phone's LinkAuthTests.
        use ring::digest::{SHA256, digest};
        let m = challenge_message("mac-1", "phone-1", "n0", "04aa", "04bb", "pair");
        assert_eq!(&m[..17], b"cnx-link-auth-v1\0");
        let hex: String = digest(&SHA256, &m).as_ref().iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "237c38ed09257b49bfb2a2e105506741f1dbadbc3d63414ff65c40af9faf9084");
    }

    #[test]
    fn standing_needs_the_same_id_and_both_keys() {
        let trust = DeviceTrust {
            devices: vec![TrustedDevice {
                id: "p".into(),
                identity_key: "i".into(),
                approval_key: "a".into(),
            }],
            denied: vec![DeniedDevice { id: "q".into(), identity_key: "i".into() }],
        };
        assert_eq!(trust.standing("p", "i", "a"), Standing::Trusted);
        assert_eq!(trust.standing("p", "i", "b"), Standing::Unknown);
        assert_eq!(trust.standing("x", "i", "a"), Standing::Unknown);
        assert_eq!(trust.standing("q", "i", "a"), Standing::Denied);
        // A new identity key (the phone signed out and in) asks again.
        assert_eq!(trust.standing("q", "j", "a"), Standing::Unknown);
    }
}
