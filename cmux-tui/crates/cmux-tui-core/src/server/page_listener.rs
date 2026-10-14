//! `ws-listen` (`ws-listen-v1`, cx-hnmbt.5): a running owner opens its
//! loopback page listener on request (spec/commands.md `ws-listen`).
//!
//! An owner that started without `--ws-loopback` (the CLI or an agent
//! started it, or an app build before the page listener) has no listener and
//! no credential file, so the app's pages had nothing to connect to. The
//! binary installs the opener ([`Mux::set_page_listener`]): it binds
//! 127.0.0.1, mints the credential into the 0600 file next to the socket and
//! answers the endpoint only, never the credential. Only a trusted local
//! (Unix) connection may ask: a listener is local admin.

use std::sync::Arc;

use serde::Deserialize;
use serde_json::Value;

use super::Mux;

pub const WS_LISTEN_CAPABILITY: &str = "ws-listen-v1";
/// `ws-listen {allow_origins}`: a list of page origins (cx-hnmbt.10).
pub const WS_LISTEN_ORIGINS_CAPABILITY: &str = "ws-listen-origins-v1";

/// Opens (or reports) the owner's loopback page listener for the extra
/// allowed page origins; answers `{url, pages, opened}`.
pub type PageListenerOpener = Arc<dyn Fn(Vec<String>) -> anyhow::Result<Value> + Send + Sync>;

/// `ws-listen`.
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct WsListenParams {
    /// One page origin the listener admits besides its own (`scheme://host[:port]`).
    #[serde(default)]
    allow_origin: Option<String>,
    /// The page origins the listener admits besides its own (`ws-listen-origins-v1`;
    /// the app's first-party pages). Joined with `allow_origin`.
    #[serde(default)]
    allow_origins: Option<Vec<String>>,
}

impl Mux {
    /// Installs the binary's page listener opener (`ws-listen-v1`).
    pub fn set_page_listener(&self, opener: Option<PageListenerOpener>) {
        *self.control_clients.page_listener.lock().unwrap_or_else(|e| e.into_inner()) = opener;
    }

    pub(super) fn serves_ws_listen(&self) -> bool {
        self.control_clients.page_listener.lock().is_ok_and(|opener| opener.is_some())
    }

    /// Loopback forwarding never reaches a listener the daemon opened later.
    pub fn deny_loopback_forward_port(&self, port: u16) {
        self.control_clients.loopback.deny_port(port);
    }
}

pub(super) fn ws_listen(mux: &Mux, client: u64, params: WsListenParams) -> anyhow::Result<Value> {
    anyhow::ensure!(
        mux.control_clients.is_unix(client),
        "ws-listen requires a trusted local connection"
    );
    let mut origins = Vec::new();
    for raw in params.allow_origin.into_iter().chain(params.allow_origins.into_iter().flatten()) {
        let origin = super::parse_websocket_origin(&raw).ok_or_else(|| {
            anyhow::anyhow!(
                "bad request: allow_origin and allow_origins need scheme://host[:port], with no path; null is never allowed"
            )
        })?;
        if !origins.contains(&origin) {
            origins.push(origin);
        }
    }
    let opener = mux
        .control_clients
        .page_listener
        .lock()
        .ok()
        .and_then(|opener| opener.clone())
        .ok_or_else(|| anyhow::anyhow!("this daemon cannot open a page listener"))?;
    opener(origins)
}
