//! The daemon's hook for carrier grants (`ClientAuthMode::Grant`).
//!
//! A daemon admits a grant only through the [`GrantVerifier`] its owner
//! installs at start ([`crate::identity::AuthDatabase::set_grant_verifier`]).
//! With none installed, every grant is refused. The verifier sees the token
//! and the Noise static key that just finished the handshake, after the
//! handshake, and answers the session's services and a stable device id, or
//! a refusal. The Cloud verifier is cmux-link's
//! [`CarrierGrantVerifier`](cmux_link::carrier_grant::CarrierGrantVerifier).
//!
//! A grant only admits a new session (generation 0): an admitted session is
//! never re-checked against the grant's expiry, and it ends only by the
//! session's own rules (its resume lease, or a retire pushed to it). A resume
//! (generation 1 and up) carries no grant: the daemon re-admits the Noise key
//! a grant admitted before ([`AdmittedGrants`]), with the same device id and
//! services. Its generation fence admits that only into the key's existing
//! session, so a resume never opens a new one.

use std::collections::{HashMap, VecDeque};
use std::sync::Mutex;

use sha2::{Digest as _, Sha256};

use cmux_link::carrier_grant::CarrierGrantVerifier;
use cmux_remote_protocol::{Service, SessionId};

use crate::crypto::{ConnectionAttemptId, ServiceAuthority, public_key_fingerprint};

/// The most grant-admitted Noise keys the daemon remembers for resumes.
pub const MAX_ADMITTED_GRANTS: usize = 4096;

/// The device id prefix of a session a carrier grant admitted.
pub const GRANT_DEVICE_PREFIX: &str = "carrier:";

/// What a presented grant is checked against.
#[derive(Debug, Clone, Copy)]
pub struct GrantPresentation<'a> {
    pub token: &'a str,
    /// The client's Noise static public key, from the finished handshake.
    pub noise_key: &'a [u8; 32],
    /// [`link_group`] of the handshake: every physical link of one new
    /// session presents the same grant with the same group.
    pub link_group: [u8; 32],
}

/// The daemon's digest of one new session's physical links: its session,
/// generation and connection attempt. The daemon's generation fence makes a
/// group that already registered unable to open a session again.
pub fn link_group(session: SessionId, generation: u64, attempt: ConnectionAttemptId) -> [u8; 32] {
    let mut digest = Sha256::new();
    digest.update(b"cmux-carrier-grant-link-group-v1");
    digest.update(session.0);
    digest.update(generation.to_be_bytes());
    digest.update(attempt.0);
    digest.finalize().into()
}

/// The grants this daemon admitted, by Noise key, for resumes. Bounded: the
/// oldest is forgotten first, and a forgotten key needs a new grant.
#[derive(Debug, Default)]
pub(crate) struct AdmittedGrants {
    inner: Mutex<(HashMap<[u8; 32], GrantAdmission>, VecDeque<[u8; 32]>)>,
}

impl AdmittedGrants {
    pub(crate) fn remember(&self, noise_key: [u8; 32], admission: GrantAdmission) {
        let mut guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let (admitted, order) = &mut *guard;
        if admitted.insert(noise_key, admission).is_none() {
            order.push_back(noise_key);
            while order.len() > MAX_ADMITTED_GRANTS {
                if let Some(oldest) = order.pop_front() {
                    admitted.remove(&oldest);
                }
            }
        }
    }

    pub(crate) fn get(&self, noise_key: &[u8; 32]) -> Option<GrantAdmission> {
        let guard = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        guard.0.get(noise_key).cloned()
    }
}

/// An admitted grant.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GrantAdmission {
    /// `carrier:<subject>:<key fingerprint>`; see [`grant_device_id`].
    pub device_id: String,
    pub authority: ServiceAuthority,
}

/// Checks carrier grants. Installed once at daemon start.
pub trait GrantVerifier: Send + Sync {
    /// Admit the grant, or say why not. The message goes back to the client,
    /// so it never carries token or key bytes.
    fn verify(&self, presentation: GrantPresentation<'_>) -> Result<GrantAdmission, String>;
}

/// The stable device id of `subject`'s client with `noise_key`:
/// `carrier:<subject>:<fingerprint>`. The subject never holds a `:`, so the
/// id never collides with a trusted carrier's `carrier:<fingerprint>`.
pub fn grant_device_id(subject: &str, noise_key: &[u8; 32]) -> String {
    format!("{GRANT_DEVICE_PREFIX}{subject}:{}", public_key_fingerprint(noise_key))
}

/// Whether `device_id` names a grant-admitted session.
pub fn is_grant_device_id(device_id: &str) -> bool {
    device_id.strip_prefix(GRANT_DEVICE_PREFIX).is_some_and(|rest| rest.contains(':'))
}

/// A service name a grant may carry: the wire name of a cmux-remote
/// [`Service`] (`mux-control`, `workspace-rpc`, `process-stream`,
/// `terminal-bytes-v1`, `tcp-tunnel`, `computer-use`).
pub fn service_from_name(name: &str) -> Option<Service> {
    serde_json::from_value(serde_json::Value::String(name.to_owned())).ok()
}

impl GrantVerifier for CarrierGrantVerifier {
    fn verify(&self, presentation: GrantPresentation<'_>) -> Result<GrantAdmission, String> {
        let grant = CarrierGrantVerifier::verify(
            self,
            presentation.token,
            presentation.noise_key,
            presentation.link_group,
        )
        .map_err(|refusal| format!("carrier grant refused: {refusal}"))?;
        // A name this daemon does not know grants nothing; a grant naming
        // only unknown services admits nothing.
        let services =
            grant.services.iter().filter_map(|name| service_from_name(name)).collect::<Vec<_>>();
        if services.is_empty() {
            return Err("carrier grant refused: no service this daemon serves".into());
        }
        Ok(GrantAdmission {
            device_id: grant_device_id(&grant.subject, presentation.noise_key),
            authority: ServiceAuthority::from_services(services),
        })
    }
}
