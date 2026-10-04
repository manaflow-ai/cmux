//! The host side's check of a link token (cloud-client-contract.md 1.7: the
//! VM's endpoint checks `link_token` on `hello` and closes a link without a
//! valid one).
//!
//! The token format is not decided yet (a signed team-scoped token with a
//! single-use id, or an opaque token checked back at CloudDO). Both plug in
//! behind [`TokenVerifier`]. Until one ships, [`DenyAllTokens`] refuses every
//! token, so no Cloud host serves a link stream.

use crate::dial::Service;
use crate::stamp::LinkPeer;

/// What the host expects a token to grant, from the stream it arrived on.
#[derive(Debug, Clone, Copy)]
pub struct Expected<'a> {
    /// This host's id.
    pub host: &'a str,
    /// This host's current epoch; a token for a lower one is refused.
    pub epoch: u64,
    /// The service the hello asks for.
    pub service: Service,
    /// The WireGuard key of the session the stream came from.
    pub peer_key: &'a [u8; 32],
}

/// Why a token was refused. The host closes the stream and says nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenRefused {
    /// The hello had no token.
    Missing,
    /// The token does not verify, or names another host, epoch or install.
    Invalid,
    /// The token expired.
    Expired,
    /// The token was already used.
    Replayed,
    /// The token does not grant the requested service.
    ServiceNotAllowed,
    /// No token format is configured on this host.
    NoVerifier,
}

/// Checks one token for one stream. A verifier must refuse a token used
/// twice (single use).
pub trait TokenVerifier: Send + Sync + 'static {
    /// The peer the token names, for the stamp, or why it was refused.
    fn verify(&self, token: &str, expected: &Expected<'_>) -> Result<LinkPeer, TokenRefused>;
}

/// The default: no token is valid.
pub struct DenyAllTokens;

impl TokenVerifier for DenyAllTokens {
    fn verify(&self, _token: &str, _expected: &Expected<'_>) -> Result<LinkPeer, TokenRefused> {
        Err(TokenRefused::NoVerifier)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_verifier_refuses_every_token() {
        let expected =
            Expected { host: "host_a", epoch: 1, service: Service::Daemon, peer_key: &[1; 32] };
        assert_eq!(DenyAllTokens.verify("anything", &expected), Err(TokenRefused::NoVerifier));
    }
}
