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
//! A grant only admits: an admitted session is never re-checked against the
//! grant's expiry, and it ends only by the session's own rules (its resume
//! lease, or a retire pushed to it).

use cmux_link::carrier_grant::CarrierGrantVerifier;
use cmux_remote_protocol::Service;

use crate::crypto::{ConnectionAttemptId, ServiceAuthority, public_key_fingerprint};

/// The device id prefix of a session a carrier grant admitted.
pub const GRANT_DEVICE_PREFIX: &str = "carrier:";

/// What a presented grant is checked against.
#[derive(Debug, Clone, Copy)]
pub struct GrantPresentation<'a> {
    pub token: &'a str,
    /// The client's Noise static public key, from the finished handshake.
    pub noise_key: &'a [u8; 32],
    /// Every physical link of one attempt presents the same grant.
    pub connection_attempt: ConnectionAttemptId,
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
            presentation.connection_attempt.0,
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
