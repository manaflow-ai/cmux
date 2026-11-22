//! The owner's one loopback page listener, at startup (`server ensure
//! --ws-loopback`) or on request (`ws-listen`, `ws-listen-v1`, cx-hnmbt.5).
//!
//! An owner started without the listener (by the CLI, an agent, or an app
//! build before the page listener) opens it when the app asks, with the same
//! minted credential file as at startup (`websocket_credential`), so the app's
//! pages never wait forever for an endpoint. The reply names the endpoint
//! only; the credential stays in the 0600 file.

use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, PoisonError, Weak};

use cmux_tui_core::Mux;
use cmux_tui_core::server::{WebSocketAccess, WebSocketServer};
use serde_json::{Value, json};

use crate::websocket_credential::{self, CredentialFile};
use cmux_json::JsonSet as _;

/// A bound listener and, for a minted credential, its file.
pub(crate) type Listener = (WebSocketServer, Option<CredentialFile>);

pub(crate) struct PageListener {
    mux: Weak<Mux>,
    socket: PathBuf,
    access: WebSocketAccess,
    state: Mutex<State>,
}

#[derive(Default)]
struct State {
    listener: Option<Listener>,
    /// The listener's minted credential, to write its file again if it went missing
    /// (none: a configured credential, which has no file to share).
    token: Option<String>,
    /// The extra page origins the listener admits (fixed when it binds).
    origins: Vec<String>,
    /// Shutdown took the listener; nothing opens another.
    closed: bool,
}

impl PageListener {
    /// Keeps the startup listener (if any) and installs the `ws-listen` opener.
    pub(crate) fn install(
        mux: &Arc<Mux>,
        socket: PathBuf,
        access: WebSocketAccess,
        startup: Option<Listener>,
        minted: Option<String>,
    ) -> Arc<Self> {
        let token = startup.as_ref().and(minted);
        let origins = access.origins.clone();
        let listener = Arc::new(Self {
            mux: Arc::downgrade(mux),
            socket,
            access,
            state: Mutex::new(State { listener: startup, token, origins, closed: false }),
        });
        let opener = listener.clone();
        mux.set_page_listener(Some(Arc::new(move |origins| opener.open(origins))));
        listener
    }

    /// The listener for shutdown; no later `ws-listen` opens one.
    pub(crate) fn take(&self) -> Option<Listener> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.closed = true;
        state.listener.take()
    }

    fn open(&self, origins: Vec<String>) -> anyhow::Result<Value> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        anyhow::ensure!(!state.closed, "the daemon is shutting down");
        let state = &mut *state;
        if let Some((server, file)) = &mut state.listener {
            let Some(token) = &state.token else {
                anyhow::bail!(
                    "this daemon's WebSocket listener uses a configured credential (--ws-token or server.ws_token), so it has no credential file to share"
                );
            };
            // The admitted origins are fixed when the listener binds. A request that names
            // some admitted origins still gets the endpoint (an owner started by an older app
            // keeps serving the pages it admits); one that names only others is refused.
            if !origins.is_empty() && !origins.iter().any(|origin| state.origins.contains(origin)) {
                anyhow::bail!(
                    "this daemon's page listener does not admit the origin {}; restart the daemon to admit it",
                    origins.join(", ")
                );
            }
            let addr = server.local_addr();
            // The startup write failed, or someone removed the file: the app reads only the file.
            if file.is_none() || !websocket_credential::path_for(&self.socket).exists() {
                *file = Some(websocket_credential::write(&self.socket, addr, token)?);
            }
            let mut reply = endpoint(addr, false);
            reply.set("origins", json!(state.origins));
            return Ok(reply);
        }
        let mux =
            self.mux.upgrade().ok_or_else(|| anyhow::anyhow!("the daemon is shutting down"))?;
        let mut access = self.access.clone();
        for origin in origins {
            if !access.origins.contains(&origin) {
                access.origins.push(origin);
            }
        }
        let token = websocket_credential::mint_token()?;
        let server = cmux_tui_core::server::serve_websocket_with_pages(
            mux.clone(),
            SocketAddr::from(([127, 0, 0, 1], 0)),
            Some(token.clone()),
            false,
            &access,
            cmux_tui_core::server::page_bundle_dir(),
        )?;
        let addr = server.local_addr();
        // A forwarded page must never reach the daemon's own control port.
        mux.deny_loopback_forward_port(addr.port());
        let file = websocket_credential::write(&self.socket, addr, &token)?;
        crate::client_log::stderr_log!(
            "startup",
            "{BIN}: WebSocket control at ws://{addr} (ws-listen)"
        );
        state.listener = Some((server, Some(file)));
        state.token = Some(token);
        state.origins = access.origins;
        let mut reply = endpoint(addr, true);
        reply.set("origins", json!(state.origins));
        Ok(reply)
    }
}

fn endpoint(addr: SocketAddr, opened: bool) -> Value {
    json!({"url": format!("ws://{addr}/"), "pages": format!("http://{addr}/pages/"), "opened": opened})
}
