//! Device pairing (cnx-ios `verify/phone-approvals.md`, audit B2): a Stack
//! token alone never reaches the Mac's terminals and agents.
//!
//! - Each phone holds two Secure Enclave P-256 keys: an identity key that
//!   signs without a prompt, and an approval key that needs Face ID.
//! - The first channel of every link is `auth` with `{identityKey,
//!   approvalKey, name}`. hostd sends a fresh challenge; the phone signs
//!   [`challenge_message`] with its identity key. A channel the phone opens
//!   after `auth` waits for its outcome (so a link opens its channels at
//!   once); one opened with no `auth` before it is refused with `unpaired`.
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

/// Where a link's `auth` stands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AuthState {
    /// No `auth` channel is running, and none passed.
    Idle,
    /// This many `auth` channels are running and none passed yet.
    Running(usize),
    /// The phone proved keys the Mac approved (for the life of the link).
    Paired,
}

/// Whether this link's phone proved an approved key.
#[derive(Debug)]
pub struct LinkAuth {
    state: watch::Sender<AuthState>,
}

impl Default for LinkAuth {
    fn default() -> Self {
        Self { state: watch::channel(AuthState::Idle).0 }
    }
}

impl LinkAuth {
    pub fn is_authenticated(&self) -> bool {
        *self.state.borrow() == AuthState::Paired
    }

    /// An `auth` channel opened (called by the link's accept loop, in open
    /// order): channels opened after it wait for the outcome ([`LinkAuth::paired`]).
    /// Every `begin` is matched by one [`LinkAuth::end`].
    pub fn begin(&self) {
        self.state.send_modify(|state| {
            *state = match *state {
                AuthState::Paired => AuthState::Paired,
                AuthState::Idle => AuthState::Running(1),
                AuthState::Running(n) => AuthState::Running(n + 1),
            }
        });
    }

    /// An `auth` channel finished; `paired` when it proved approved keys.
    /// Waiters are refused only when no other `auth` on the link is still running.
    pub fn end(&self, paired: bool) {
        self.state.send_modify(|state| {
            *state = match (*state, paired) {
                (AuthState::Paired, _) | (_, true) => AuthState::Paired,
                (AuthState::Running(n), false) if n > 1 => AuthState::Running(n - 1),
                _ => AuthState::Idle,
            }
        });
    }

    /// Whether the link is paired, waiting while an `auth` opened before this
    /// channel is still running (at most the signature and approval waits).
    pub async fn paired(&self) -> bool {
        let mut state = self.state.subscribe();
        let wait = tokio::time::timeout(SIGNATURE_WAIT + APPROVAL_WAIT + Duration::from_secs(5), async {
            loop {
                match *state.borrow_and_update() {
                    AuthState::Paired => return true,
                    AuthState::Idle => return false,
                    AuthState::Running(_) => {}
                }
                if state.changed().await.is_err() {
                    return false;
                }
            }
        });
        wait.await.unwrap_or(false)
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
///
/// The caller marks the channel's open with [`LinkAuth::begin`] first.
pub async fn serve(
    pairing: Option<&Pairing>,
    phone: &str,
    link: &LinkAuth,
    args: &Value,
    sender: &ChannelSender,
    receiver: &mut ChannelReceiver,
) -> Result<(), Refused> {
    // The accept loop counted this channel when it opened (`begin`).
    let result = authenticate(pairing, phone, args, sender, receiver).await;
    link.end(result.is_ok() && action_is_pair(args));
    result
}

fn action_is_pair(args: &Value) -> bool {
    matches!(args.get("action").and_then(Value::as_str), None | Some("" | "pair"))
}

async fn authenticate(
    pairing: Option<&Pairing>,
    phone: &str,
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

    #[tokio::test]
    async fn waiters_follow_every_running_auth() {
        // No auth yet: refused at once.
        let link = LinkAuth::default();
        assert!(!link.paired().await);
        // Two auths running; the first fails, the second passes: the waiter is served.
        link.begin();
        link.begin();
        let waiter = {
            let link = std::sync::Arc::new(link);
            let held = std::sync::Arc::clone(&link);
            (tokio::spawn(async move { held.paired().await }), link)
        };
        waiter.1.end(false);
        tokio::task::yield_now().await;
        assert!(!waiter.0.is_finished());
        waiter.1.end(true);
        assert!(waiter.0.await.unwrap());
        // Paired holds for the link: a later failed auth (an unpair) changes nothing.
        waiter.1.begin();
        waiter.1.end(false);
        assert!(waiter.1.is_authenticated());
        // The last running auth failing refuses the waiters.
        let other = LinkAuth::default();
        other.begin();
        other.end(false);
        assert!(!other.paired().await);
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
