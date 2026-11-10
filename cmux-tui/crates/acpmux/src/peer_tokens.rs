//! The remote daemon's tokens an `ssh://` peer read over ssh, kept for its next connect.
//!
//! Reading them is a whole ssh login of its own (`read_config_argv`), before the tunnel's login:
//! about 10 round trips, 400 ms at a 40 ms RTT, on every redial. The dashboard token lives in
//! the remote's config and the peer token for as long as the remote daemon runs, so a redial
//! presents the ones it read last and reads again only when they stop working:
//! - the upgrade is refused (401 or 403): the dashboard token changed; read again once, at once;
//! - the remote served the link as Web: its peer token changed (`Peer::stale_token`);
//! - the remote announced a restart (Close 1012): its next launch writes a new peer token.
//!
//! Only a read that found a peer token is kept: a remote with none is starting, or too old to
//! make one, and is read again at each connect as before (`TOKEN_REREADS`).

use std::sync::Mutex;

/// The dashboard token and the peer token.
pub(crate) type Tokens = (String, Option<String>);

#[derive(Default)]
pub(crate) struct TokenCache(Mutex<Option<Tokens>>);

impl TokenCache {
    pub(crate) fn get(&self) -> Option<Tokens> {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Kept only with a peer token (see the module note).
    pub(crate) fn keep(&self, tokens: &Tokens) {
        if tokens.1.is_some() {
            *self.0.lock().unwrap_or_else(|e| e.into_inner()) = Some(tokens.clone());
        }
    }

    pub(crate) fn forget(&self) {
        *self.0.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }

    /// A replacement of the same peer (`Hub::spawn_peer`) starts with what the old one read.
    pub(crate) fn carry(&self, from: &TokenCache) {
        if let Some(tokens) = from.get() {
            self.keep(&tokens);
        }
    }
}

/// The remote refused the WebSocket upgrade's credentials.
pub(crate) fn refused(error: &tokio_tungstenite::tungstenite::Error) -> bool {
    matches!(error, tokio_tungstenite::tungstenite::Error::Http(response)
        if refused_status(response.status().as_u16()))
}

fn refused_status(status: u16) -> bool {
    matches!(status, 401 | 403)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_only_a_read_with_a_peer_token() {
        let cache = TokenCache::default();
        cache.keep(&("dash".into(), None));
        assert_eq!(cache.get(), None, "a remote with no peer token is read at each connect");
        cache.keep(&("dash".into(), Some("peer".into())));
        assert_eq!(cache.get(), Some(("dash".into(), Some("peer".into()))));
        let next = TokenCache::default();
        next.carry(&cache);
        assert_eq!(next.get(), cache.get());
        cache.forget();
        assert_eq!(cache.get(), None);
    }

    /// Review of #38002: a token read that finished after `stop` opened a tunnel anyway.
    #[tokio::test]
    async fn a_stopped_peer_opens_no_tunnel_and_reads_no_tokens() {
        let (tx, _rx) = tokio::sync::mpsc::channel(8);
        let peer = super::super::Peer::new("p", "ssh://box.invalid:7777", None, None, tx);
        peer.stop();
        assert_eq!(peer.open_tunnel().await.err().as_deref(), Some("peer stopped"));
        assert!(peer.tunnel.lock().await.is_none(), "no ssh after stop");
        assert_eq!(peer.connect_tokens().await.err().as_deref(), Some("peer stopped"));
    }

    #[test]
    fn a_401_or_403_upgrade_is_a_refusal_and_nothing_else_is() {
        assert!(refused_status(401));
        assert!(refused_status(403));
        assert!(!refused_status(502));
        assert!(!refused(&tokio_tungstenite::tungstenite::Error::ConnectionClosed));
    }
}
