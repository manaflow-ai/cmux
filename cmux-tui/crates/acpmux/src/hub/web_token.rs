//! The dashboard token the web listener checks right now
//! (plans/cmux-next/identity.md section 4).
//!
//! The token is saved in config.json (0600) and kept across launches,
//! unlike the per-launch LocalApp and peer tokens: a `ws://` peer added with
//! `peer add --token`, a dashboard link a user kept, and a browser on another
//! machine behind `tailscale serve` have no channel that could hand them a
//! new token at each launch. `_acpmux/web_token_rotate` (unix socket only;
//! `acpmux web --rotate-token`) replaces it at once: the listener checks the
//! new token from the next handshake on, and every connection that used the
//! old one as its only credential (Web, Peer) is closed.

use super::*;

/// The listener's current token; empty before a listener starts.
pub struct WebToken(tokio::sync::watch::Sender<String>);

impl WebToken {
    pub fn new(initial: String) -> Self {
        Self(tokio::sync::watch::channel(initial).0)
    }

    /// The token a handshake must present now.
    pub fn current(&self) -> String {
        self.0.borrow().clone()
    }

    /// Sets the token the listener serves (at bind, or after a rotation).
    pub fn set(&self, token: String) {
        self.0.send_replace(token);
    }

    /// Resolves when the token changes after this call.
    pub fn changed(&self) -> impl std::future::Future<Output = ()> + Send + 'static {
        let mut rx = self.0.subscribe();
        async move {
            // An error means the hub is gone; the connection ends with it.
            let _ = rx.changed().await;
        }
    }
}

/// 24 random bytes as 48 lowercase hex characters.
fn random_token() -> Result<String, RpcError> {
    use std::io::Read;
    let mut bytes = [0u8; 24];
    std::fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut bytes))
        .map_err(|e| RpcError::internal(format!("read /dev/urandom for the web token: {e}")))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

impl Hub {
    /// `_acpmux/web_token_rotate`: a new saved token, served at once.
    /// Refused while a `--token` value serves (it is never saved, so a new
    /// saved token would not change what the listener checks).
    pub async fn rotate_web_token(&self) -> Result<Value, RpcError> {
        let mut cfg = self.config.write().await;
        if cfg.web_token_override.is_some() {
            return Err(RpcError::invalid_params(
                "this daemon serves a --token value; restart it without --token to rotate the saved token",
            ));
        }
        if cfg.web_listener().is_none() {
            return Err(RpcError::invalid_params("this daemon has no web listener"));
        }
        let token = random_token()?;
        let old = cfg.websocket.as_mut().and_then(|w| w.token.replace(token.clone()));
        if let Err(e) = cfg.save() {
            // Never serve a token config.json does not hold (ssh peers read it).
            if let Some(w) = cfg.websocket.as_mut() {
                w.token = old;
            }
            return Err(RpcError::internal(format!("could not save the new web token: {e:#}")));
        }
        self.web_token.set(token);
        tracing::info!("the web token was rotated; run `acpmux web` for the new link");
        Ok(json!({"webUrl": web_url(&cfg)}))
    }
}
