//! The Peer origin: another acpmux daemon of the same user, connected over
//! the WebSocket listener. The dashboard token alone never proves a peer:
//! every Web client (the dashboard page, a paired device) holds it. A
//! connection is `Origin::Peer` only when its upgrade request carries BOTH
//! the dashboard token (checked by the handshake, as for every connection)
//! and exactly one `x-acpmux-peer-token` header equal to this launch's peer
//! token, compared in constant time. Anything else (no header, a wrong or
//! empty value, two headers, a value in the first frame or the query) stays
//! `Origin::Web`.
//!
//! The peer token is 32 random bytes made at every daemon start, kept only
//! in `ACPMUX_HOME/run/peer.token` (mode 0600, created with `O_EXCL` and
//! `O_NOFOLLOW` in a private directory, removed at stop), and never
//! returned by any RPC. A connecting daemon reads it over the same ssh
//! access it already uses for the dashboard token (`peer.rs`), or takes it
//! from its local config (`peers.<name>.peerToken`, unix socket only).

use std::path::{Path, PathBuf};

/// The upgrade request header that carries the peer token.
pub const HEADER: &str = "x-acpmux-peer-token";

/// Where the peer token of `home` lives.
pub fn token_path(home: &Path) -> PathBuf {
    home.join("run").join("peer.token")
}

/// This launch's peer token.
pub struct PeerAuth {
    token: String,
    path: PathBuf,
}

impl PeerAuth {
    /// Make this launch's token (`local_app::create_secret`).
    pub fn create(home: &Path) -> anyhow::Result<Self> {
        let path = token_path(home);
        let token = super::local_app::create_secret(&path)?;
        Ok(Self { token, path })
    }

    /// Whether the `x-acpmux-peer-token` values of an upgrade request (which
    /// passed the dashboard token check) prove a peer: exactly one, equal to
    /// this launch's token.
    pub fn is_peer(&self, presented: &[String]) -> bool {
        match presented {
            [one] => !one.is_empty() && cmux_local_auth::tokens_match(one, &self.token),
            _ => false,
        }
    }

    /// The file this launch's token is in (removed when the daemon stops).
    pub fn path(&self) -> &Path {
        &self.path
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn auth(tag: &str) -> (PeerAuth, String) {
        let home = std::env::temp_dir().join(format!(
            "acpmux-pa-{tag}-{}-{}",
            std::process::id(),
            uuid::Uuid::now_v7()
        ));
        let auth = PeerAuth::create(&home).unwrap();
        let token = std::fs::read_to_string(token_path(&home)).unwrap();
        (auth, token)
    }

    #[test]
    fn only_one_exact_token_proves_a_peer() {
        let (auth, token) = auth("one");
        assert!(auth.is_peer(std::slice::from_ref(&token)));
        assert!(!auth.is_peer(&[]));
        assert!(!auth.is_peer(&[String::new()]));
        assert!(!auth.is_peer(&["0".repeat(64)]));
        assert!(!auth.is_peer(&[token.clone(), token.clone()]));
        let (_, other) = auth_again();
        assert!(!auth.is_peer(&[other]), "another launch's token");
    }

    fn auth_again() -> (PeerAuth, String) {
        auth("two")
    }

    #[test]
    fn the_token_is_private_and_new_at_every_launch() {
        use std::os::unix::fs::PermissionsExt;
        let home = std::env::temp_dir().join(format!("acpmux-pa-l-{}", uuid::Uuid::now_v7()));
        let first = PeerAuth::create(&home).unwrap();
        let a = std::fs::read_to_string(token_path(&home)).unwrap();
        let mode = std::fs::metadata(token_path(&home)).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
        let second = PeerAuth::create(&home).unwrap();
        let b = std::fs::read_to_string(token_path(&home)).unwrap();
        assert_ne!(a, b);
        assert!(!second.is_peer(&[a]));
        drop(first);
    }
}
