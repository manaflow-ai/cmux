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
    /// The listener's minted credential, to write its file again if it went missing.
    token: Option<String>,
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
        let token = startup.as_ref().and_then(|(_, file)| file.as_ref()).and(minted);
        let listener = Arc::new(Self {
            mux: Arc::downgrade(mux),
            socket,
            access,
            state: Mutex::new(State { listener: startup, token, closed: false }),
        });
        let opener = listener.clone();
        mux.set_page_listener(Some(Arc::new(move |origin| opener.open(origin))));
        listener
    }

    /// The listener for shutdown; no later `ws-listen` opens one.
    pub(crate) fn take(&self) -> Option<Listener> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.closed = true;
        state.listener.take()
    }

    fn open(&self, origin: Option<String>) -> anyhow::Result<Value> {
        let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        anyhow::ensure!(!state.closed, "the daemon is shutting down");
        let state = &mut *state;
        if let Some((server, file)) = &mut state.listener {
            anyhow::ensure!(
                file.is_some(),
                "this daemon's WebSocket listener uses a configured credential (--ws-token or server.ws_token), so it has no credential file to share"
            );
            let addr = server.local_addr();
            // Someone removed the file: the app reads only the file, so write it again.
            if let Some(token) = &state.token
                && !websocket_credential::path_for(&self.socket).exists()
            {
                *file = Some(websocket_credential::write(&self.socket, addr, token)?);
            }
            return Ok(endpoint(addr, false));
        }
        let mux =
            self.mux.upgrade().ok_or_else(|| anyhow::anyhow!("the daemon is shutting down"))?;
        let mut access = self.access.clone();
        if let Some(origin) = origin
            && !access.origins.contains(&origin)
        {
            access.origins.push(origin);
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
        Ok(endpoint(addr, true))
    }
}

fn endpoint(addr: SocketAddr, opened: bool) -> Value {
    json!({"url": format!("ws://{addr}/"), "pages": format!("http://{addr}/pages/"), "opened": opened})
}
