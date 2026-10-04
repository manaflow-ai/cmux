//! `verified_app`: is this connection the cmux app? (P8 slice 3b-2,
//! plans/cmux-next/identity.md section 3.)
//!
//! A LOCAL (Unix socket) connection that declared role `main` in its
//! `client-hello` (server/client_hello.rs) becomes the verified app by ONE
//! prover, chosen by how this daemon is built:
//!
//! - A, code signature (Team-signed builds only): the peer's audit token
//!   names code that satisfies the containing app's requirement (team id and
//!   bundle id; `cmux_link::app_caller`). Checked once, at step 1.
//! - B, install key (unsigned DEV builds only): the app that started this
//!   daemon handed it a 32-byte key and its install id over an inherited
//!   pipe (`read_frontend_key`). Step 1 with an install id returns a fresh
//!   nonce; step 2 carries proof = HMAC-SHA256(key, context, install id,
//!   nonce) (`cmux_local_auth::frontend_proof`).
//!
//! The result is `ConnectionOrigin::verified_app` in the connection's
//! registry record (request_origin.rs), so it ends with the connection.
//! The proof never changes the connection's `peer_key`: the main and page
//! relay connections of one app process share the audit-token key, which
//! `origin.confirmation.issue` compares. Fail closed: any other order, a
//! wrong proof, a second hello, a non-local connection or a daemon with no
//! key leaves the connection unverified for its whole life.
//! `set-client-info kind` is a label and never counts.

use std::io::Read;
use std::sync::OnceLock;

use cmux_link::app_caller::PeerToken;
/// The proof math, for clients and tests of other crates.
pub use cmux_local_auth::frontend_proof;
use cmux_local_auth::frontend_proof::{INSTALL_KEY_LEN, NONCE_LEN};
use zeroize::Zeroizing;

/// First token of the launcher pipe payload.
const KEY_MAGIC: &str = "cmuxik1";
/// Upper bound on the launcher pipe payload.
const MAX_KEY_PAYLOAD: u64 = 512;

/// The app's install key and install id, as the launcher handed them over.
pub struct FrontendKey {
    install_id: String,
    key: Zeroizing<[u8; INSTALL_KEY_LEN]>,
}

impl std::fmt::Debug for FrontendKey {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("FrontendKey")
            .field("install_id", &self.install_id)
            .finish_non_exhaustive()
    }
}

impl FrontendKey {
    /// Parses `cmuxik1 <install_id> <64 hex key>` (one line).
    pub fn parse(payload: &str) -> Option<Self> {
        let mut words = payload.trim_end_matches(['\n', '\r']).split(' ');
        let (Some(KEY_MAGIC), Some(install_id), Some(key), None) =
            (words.next(), words.next(), words.next(), words.next())
        else {
            return None;
        };
        if !frontend_proof::valid_install_id(install_id) {
            return None;
        }
        let key = Zeroizing::new(frontend_proof::unhex::<INSTALL_KEY_LEN>(key)?);
        if key.iter().all(|byte| *byte == 0) {
            return None;
        }
        Some(Self { install_id: install_id.to_string(), key })
    }

    /// The pipe payload for this key (the launcher writes it).
    pub fn to_payload(&self) -> Zeroizing<String> {
        Zeroizing::new(format!(
            "{KEY_MAGIC} {} {}\n",
            self.install_id,
            frontend_proof::hex(self.key.as_slice())
        ))
    }

    pub fn install_id(&self) -> &str {
        &self.install_id
    }
}

/// Reads one key payload from `reader` (an inherited pipe) to end of file.
/// The caller closes the descriptor right after.
pub fn read_frontend_key(reader: impl Read) -> std::io::Result<FrontendKey> {
    let mut payload = Zeroizing::new(String::new());
    reader.take(MAX_KEY_PAYLOAD + 1).read_to_string(&mut payload)?;
    if payload.len() as u64 > MAX_KEY_PAYLOAD {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "install key payload too long",
        ));
    }
    FrontendKey::parse(&payload).ok_or_else(|| {
        std::io::Error::new(std::io::ErrorKind::InvalidData, "malformed install key payload")
    })
}

/// Gives the daemon the app's install key. Only the first call wins; the
/// daemon keeps the key in memory only. Returns false when a key was set.
pub fn install_frontend_key(mux: &crate::Mux, key: FrontendKey) -> bool {
    mux.control_clients.app_trust.install_key.set(key).is_ok()
}

/// The daemon side of `verified_app` (one per daemon, in the registry).
pub(crate) struct AppTrust {
    install_key: OnceLock<FrontendKey>,
    /// A signed daemon inside a signed app accepts only prover A: there a
    /// same-uid process could restart the owner with a key it chose, so the
    /// install-key proof alone must not count (security review, P1).
    signed_build: bool,
}

impl Default for AppTrust {
    fn default() -> Self {
        Self {
            install_key: OnceLock::new(),
            signed_build: cmux_link::app_caller::signed_app_build(),
        }
    }
}

impl AppTrust {
    /// Prover A for a role-main hello: true only on a signed build whose
    /// containing app's requirement the peer's audit token satisfies. A few
    /// Security framework calls; the caller holds no lock.
    pub(super) fn signature_proves(&self, token: Option<PeerToken>) -> bool {
        self.signed_build
            && token
                .is_some_and(|token| cmux_link::app_caller::verify_containing_app(&token).is_ok())
    }

    /// Prover B, step 2: checks `proof` for `claimed_id` over this
    /// connection's `install_id` and `nonce`. Every check runs whatever the
    /// earlier ones said (a daemon with no key checks against a throwaway
    /// key), so the time taken does not tell which one failed. A signed
    /// build never accepts it.
    pub(super) fn install_key_proves(
        &self,
        install_id: &str,
        nonce: &[u8; NONCE_LEN],
        claimed_id: &str,
        proof: &str,
    ) -> bool {
        let mut throwaway = Zeroizing::new([0u8; INSTALL_KEY_LEN]);
        let (key, held_id) = match self.install_key.get() {
            Some(key) => (key.key.as_slice(), key.install_id.as_str()),
            None => {
                if getrandom::fill(throwaway.as_mut_slice()).is_err() {
                    return false;
                }
                (throwaway.as_slice(), "")
            }
        };
        let mac_ok = frontend_proof::verify_hello_proof(key, install_id, nonce, proof);
        let same_request = cmux_local_auth::tokens_match(claimed_id, install_id);
        let held = cmux_local_auth::tokens_match(install_id, held_id);
        mac_ok & same_request & held & self.install_key.get().is_some() & !self.signed_build
    }
}

impl super::ClientRegistry {
    /// Whether `client` is a local (Unix socket) connection: the transport
    /// fact the apps gate and `verified_app` start from.
    pub(super) fn is_unix(&self, client: u64) -> bool {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clients
            .get(&client)
            .is_some_and(|record| matches!(record.transport, super::ClientTransport::Unix))
    }
}

#[cfg(test)]
#[path = "app_trust_tests.rs"]
mod tests;
