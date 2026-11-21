//! A viewer's Touch ID grant for a Mac that asks for consent before it serves
//! a screen session (CMUX-572). Leo, 2026-11-17: "be better than macOS
//! screensharing permissions; option potentialy, macOS if u want to
//! screenshare other macOS, u can make touch ID?; maybe be more convenient,
//! store credentials in keychain potentially".
//!
//! The case: the Labs machine-join consent is on for a host, and the host has
//! not granted screen (or control) to its signed-in machines, so today a
//! same-account share is refused until someone runs `acpmux host consent grant
//! --screen` on the host itself. With a viewer grant, the person allows it
//! once, with Touch ID or the login password, on the Mac they start from, and
//! nothing is asked again.
//!
//! What the host trusts is never the viewer's word. The viewer makes a Secure
//! Enclave key whose use needs Touch ID or the password, and registers its
//! public half for one host and one scope over the hub's authenticated device
//! channel ([`register`]: the registering device must be the viewer the grant
//! names). For each session the host issues a one-time challenge
//! ([`Challenges::issue`]), the viewer signs [`Proof::canonical`] (Touch ID
//! gates the signature), and the host serves only after [`verify`] passes:
//! the ticket's hub-authenticated viewer, this host, the session, the scope,
//! a fresh unused challenge, and the registered key's signature. A grant record
//! copied to another device, or a signature by any other key, is refused.
//!
//! Scopes are separate: a view grant never admits a control session. A
//! control grant admits a view session of the same viewer, since control
//! includes seeing the screen.
//!
//! Lifetime: a grant lasts until one of these ends it, and nothing else does:
//! the person revokes it ([`GrantBook::revoke`], which deletes the public key
//! on the host); the host signs out or signs in to another account
//! ([`GrantBook::for_account`] keeps only the account's grants, so a sign-out
//! leaves none); the viewer leaves the account's device list
//! ([`GrantBook::retain_devices`]); or the viewer deletes its key (it can no
//! longer sign). Grants are keyed to the hub-authenticated device ids and the
//! host's hub account, never to an account name stored on either Mac.

use std::collections::HashMap;

use base64::Engine as _;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// The proof format; the first line of [`Proof::canonical`].
pub const PROOF_VERSION: &str = "cmux.viewer-proof.v1";
/// How long an issued challenge may wait for its proof.
pub const CHALLENGE_TTL_SECS: u64 = 60;

/// What a session may do. A view grant never covers control.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Scope {
    View,
    Control,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::View => "view",
            Self::Control => "control",
        }
    }

    /// Whether a grant of `self` admits a session of `wanted`.
    pub fn covers(self, wanted: Scope) -> bool {
        self == wanted || (self == Scope::Control && wanted == Scope::View)
    }
}

/// One viewer's registered key for this host and one scope, as the host keeps it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewerGrant {
    /// The viewer device (its device hub id).
    pub viewer: String,
    pub scope: Scope,
    /// base64 X9.63 P-256 public key of the viewer's Secure Enclave key.
    pub key: String,
    /// When it was registered, Unix seconds.
    pub registered_at: u64,
}

/// A registration as it arrives over the hub's authenticated device channel.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Registration {
    pub host: String,
    pub viewer: String,
    pub scope: Scope,
    pub key: String,
}

/// The facts of a session ticket the hub delivered to this host: the hub
/// authenticated the viewer device, so they are not the viewer's claim.
#[derive(Clone, Copy, Debug)]
pub struct Ticket<'a> {
    pub session: &'a str,
    pub viewer: &'a str,
    pub scope: Scope,
}

/// The viewer's signature over one challenge.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Proof {
    pub v: String,
    pub host: String,
    pub viewer: String,
    pub scope: Scope,
    pub session: String,
    pub challenge: String,
    /// base64 raw r||s ECDSA P-256 SHA-256 signature of [`Self::canonical`].
    pub signature: String,
}

impl Proof {
    /// The signed bytes, one field per line. The app builds the same string
    /// (`ViewerGrantProof.canonical`); `viewer_grant_vectors.json` holds both sides to it.
    pub fn canonical(&self) -> String {
        format!(
            "{}\nhost={}\nviewer={}\nscope={}\nsession={}\nchallenge={}",
            self.v,
            self.host,
            self.viewer,
            self.scope.as_str(),
            self.session,
            self.challenge
        )
    }
}

/// Why the host refused: a stable code and the person's words.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub code: &'static str,
    pub message: String,
}

impl Refused {
    fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }

    pub fn json(&self) -> Value {
        json!({"code": self.code, "message": self.message})
    }
}

/// The host's grants, for the hub account it is signed in to.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct GrantBook {
    /// The host's hub account (user id) the grants belong to.
    pub account: String,
    /// By viewer device id, then scope.
    pub grants: Vec<ViewerGrant>,
}

impl GrantBook {
    /// The book as it holds for `account` now: another account's grants (a
    /// sign-in to another account) or a signed-out host (empty account) keep none.
    pub fn for_account(self, account: &str) -> Self {
        if account.is_empty() || self.account != account {
            return Self { account: account.to_owned(), grants: Vec::new() };
        }
        self
    }

    /// The grant `viewer` holds for `scope` exactly.
    pub fn get(&self, viewer: &str, scope: Scope) -> Option<&ViewerGrant> {
        self.grants.iter().find(|grant| grant.viewer == viewer && grant.scope == scope)
    }

    /// The grant that admits `viewer` to a `scope` session: the exact scope
    /// first, else a control grant for a view session.
    pub fn covering(&self, viewer: &str, scope: Scope) -> Option<&ViewerGrant> {
        self.get(viewer, scope).or_else(|| {
            self.grants.iter().find(|grant| grant.viewer == viewer && grant.scope.covers(scope))
        })
    }

    /// Deletes `viewer`'s key for `scope` (`None`: every scope). Whether one went.
    pub fn revoke(&mut self, viewer: &str, scope: Option<Scope>) -> bool {
        let before = self.grants.len();
        self.grants.retain(|grant| {
            grant.viewer != viewer || scope.is_some_and(|scope| grant.scope != scope)
        });
        self.grants.len() != before
    }

    /// Keeps only grants of devices still in the account's device list.
    pub fn retain_devices(&mut self, devices: &[&str]) {
        self.grants.retain(|grant| devices.contains(&grant.viewer.as_str()));
    }
}

/// Records `registration` from `authenticated`, the device the hub's
/// authenticated channel says sent it, for this `host`. Replaces the viewer's
/// earlier key for that scope.
pub fn register(
    book: &mut GrantBook,
    registration: &Registration,
    authenticated: &str,
    host: &str,
    now: u64,
) -> Result<(), Refused> {
    if book.account.is_empty() {
        return Err(Refused::new("grant.signed_out", "this Mac is not signed in to an account"));
    }
    if registration.host != host {
        return Err(Refused::new("grant.wrong_host", "the grant is for another Mac"));
    }
    if authenticated.is_empty() || registration.viewer != authenticated {
        return Err(Refused::new(
            "grant.not_the_viewer",
            "only the viewer device itself may register its key",
        ));
    }
    if registration.viewer == host {
        return Err(Refused::new("grant.self", "a Mac needs no grant for itself"));
    }
    if public_key(&registration.key).is_none() {
        return Err(Refused::new("grant.bad_key", "the key is not a P-256 public key"));
    }
    book.revoke(&registration.viewer, Some(registration.scope));
    book.grants.push(ViewerGrant {
        viewer: registration.viewer.clone(),
        scope: registration.scope,
        key: registration.key.clone(),
        registered_at: now,
    });
    Ok(())
}

/// The challenges this host issued and has not seen answered, each for one
/// session and viewer, until [`CHALLENGE_TTL_SECS`].
#[derive(Debug, Default)]
pub struct Challenges {
    open: HashMap<String, (String, String, u64)>,
}

impl Challenges {
    /// A new challenge for `session` of `viewer`: 32 random bytes, base64url.
    /// `None` only when the system random source fails (then nothing is served).
    pub fn issue(&mut self, session: &str, viewer: &str, now: u64) -> Option<String> {
        let mut bytes = [0u8; 32];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).ok()?;
        let challenge = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes);
        self.insert(challenge.clone(), session, viewer, now);
        Some(challenge)
    }

    fn insert(&mut self, challenge: String, session: &str, viewer: &str, now: u64) {
        self.open.retain(|_, (_, _, at)| now.saturating_sub(*at) <= CHALLENGE_TTL_SECS);
        self.open.insert(challenge, (session.to_owned(), viewer.to_owned(), now));
    }

    /// Takes `challenge` if it was issued for `session` and `viewer` and is
    /// still fresh. A challenge is taken once, answered or not.
    fn take(&mut self, challenge: &str, session: &str, viewer: &str, now: u64) -> bool {
        let Some((for_session, for_viewer, at)) = self.open.remove(challenge) else {
            return false;
        };
        for_session == session
            && for_viewer == viewer
            && now.saturating_sub(at) <= CHALLENGE_TTL_SECS
    }
}

/// Whether this host serves `ticket` on `proof`: every check passes, in this
/// order, or the first that fails says why.
pub fn verify(
    book: &GrantBook,
    challenges: &mut Challenges,
    host: &str,
    ticket: &Ticket<'_>,
    proof: &Proof,
    now: u64,
) -> Result<(), Refused> {
    if proof.v != PROOF_VERSION {
        return Err(Refused::new(
            "grant.bad_version",
            format!("unknown proof format {:?}", proof.v),
        ));
    }
    if proof.host != host {
        return Err(Refused::new("grant.wrong_host", "the proof is for another Mac"));
    }
    if proof.viewer != ticket.viewer {
        return Err(Refused::new(
            "grant.wrong_viewer",
            "the proof names another device than the one the hub connected",
        ));
    }
    if proof.session != ticket.session {
        return Err(Refused::new("grant.wrong_session", "the proof is for another session"));
    }
    if proof.scope != ticket.scope {
        return Err(Refused::new("grant.wrong_scope", "the proof is for another scope"));
    }
    if !challenges.take(&proof.challenge, ticket.session, ticket.viewer, now) {
        return Err(Refused::new(
            "grant.bad_challenge",
            "the challenge was not issued for this session, was used, or expired",
        ));
    }
    let Some(grant) = book.covering(ticket.viewer, ticket.scope) else {
        return Err(Refused::new(
            "grant.none",
            format!(
                "this device has no {} grant here; allow it with Touch ID on it",
                ticket.scope.as_str()
            ),
        ));
    };
    if !signature_valid(proof, &grant.key) {
        return Err(Refused::new(
            "grant.bad_signature",
            "the proof is not signed by the key this device registered",
        ));
    }
    Ok(())
}

fn public_key(key: &str) -> Option<Vec<u8>> {
    let bytes = base64::engine::general_purpose::STANDARD.decode(key).ok()?;
    (bytes.len() == 65 && bytes[0] == 4).then_some(bytes)
}

/// Whether `proof.signature` is `key`'s signature of its canonical bytes.
fn signature_valid(proof: &Proof, key: &str) -> bool {
    let (Some(key), Ok(signature)) =
        (public_key(key), base64::engine::general_purpose::STANDARD.decode(&proof.signature))
    else {
        return false;
    };
    ring::signature::UnparsedPublicKey::new(&ring::signature::ECDSA_P256_SHA256_FIXED, key)
        .verify(proof.canonical().as_bytes(), &signature)
        .is_ok()
}

#[cfg(test)]
#[path = "viewer_grant_tests.rs"]
mod tests;
