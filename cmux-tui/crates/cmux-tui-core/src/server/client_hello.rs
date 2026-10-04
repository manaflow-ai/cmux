//! `client-hello` step 1 (plans/cmux-next/request-origin.md, "Hello and
//! capability"): `{cmd: "client-hello", role: "main"|"page_relay",
//! install_id?}` -> `{connection_id}`.
//!
//! The hello is accepted only as a connection's first line, or as its second
//! line right after exactly one `identify`; any other line first (a second
//! `identify` included) closes the window. Every error closes the window and
//! changes nothing: `client_hello.local_only` off a local Unix connection,
//! `client_hello.bad_request {field}` for a missing or unknown role or a
//! malformed install id, `client_hello.window_closed` for a late or second
//! hello. The role is fixed for the connection's life; `set-client-info`
//! never sets it.
//!
//! P8 (server/app_trust.rs): a role-main hello on a signed build is checked
//! against the app's code signature (prover A). A role-main hello with an
//! install id always gets a nonce, and the very next line must be step 2,
//! `{cmd: "client-hello", install_id, proof}` -> `{verified, install_id,
//! connection_id}`; any other line closes the window, and a refused proof
//! is `client_hello.refused` (no retry). Either prover sets the
//! connection's `verified_app`; neither changes its `peer_key`.
//!
//! A page relay connection may not `subscribe` (its requests are page
//! requests; it reads replies, not the event stream).

use cmux_link::app_caller::PeerToken;
use cmux_local_auth::frontend_proof::{self, NONCE_LEN};
use zeroize::Zeroizing;

use super::*;
use crate::request_origin::{HelloRole, RequestOrigin, valid_install_id};

const CLIENT_HELLO: &str = "client-hello";

enum Window {
    /// Step 1 may come; `identified` once the one allowed `identify` came.
    Open {
        identified: bool,
    },
    /// Step 1 issued a nonce; the next line must be the proof (P8).
    Challenged {
        install_id: String,
        nonce: Zeroizing<[u8; NONCE_LEN]>,
    },
    Closed,
}

/// What the socket says about its peer, read when the hello comes.
pub(super) struct Peer {
    /// `token:<pid>.<pid version>` (request-origin.md peer_key).
    pub(super) key: Option<String>,
    /// The audit token (prover A); macOS only.
    pub(super) token: Option<PeerToken>,
}

/// The hello state of ONE connection, owned by its read loop, so ordinary
/// lines pay one enum check after the window closes.
pub(super) struct HelloGate {
    transport: ClientTransport,
    window: Window,
    page_relay: bool,
}

type Refusal = (&'static str, &'static str, Option<Value>);

impl HelloGate {
    pub(super) fn new(transport: ClientTransport) -> Self {
        Self { transport, window: Window::Open { identified: false }, page_relay: false }
    }

    /// Ends the hello window (a line the connection's admission refused
    /// still counts as a line).
    pub(super) fn close(&mut self) {
        self.window = Window::Closed;
    }

    /// Sees every line before dispatch. `Some(reply)` answers the line here
    /// (a `client-hello`, or a page relay's `subscribe`) and nothing else
    /// sees it; `None` dispatches it as usual.
    pub(super) fn observe(
        &mut self,
        mux: &Mux,
        client: u64,
        line: &str,
        peer: impl FnOnce() -> Peer,
    ) -> Option<Value> {
        // After the window closes only a late hello, or a page relay's
        // subscribe, is answered here; each test is a superset of its case.
        let open = !matches!(self.window, Window::Closed);
        let maybe_subscribe = self.page_relay && line.contains("subscribe");
        if !open && !maybe_subscribe && !line.contains(CLIENT_HELLO) {
            return None;
        }
        let window = std::mem::replace(&mut self.window, Window::Closed);
        let value: Value = serde_json::from_str(line).ok()?;
        let id = value.get("id").cloned();
        let result = match value.get("cmd").and_then(Value::as_str) {
            Some(CLIENT_HELLO) => match window {
                Window::Closed => Err((
                    "client_hello.window_closed",
                    "client-hello must be the first line, or follow exactly one identify",
                    None,
                )),
                _ if !matches!(self.transport, ClientTransport::Unix) => Err((
                    "client_hello.local_only",
                    "client-hello needs a local Unix socket connection",
                    None,
                )),
                Window::Open { .. } => self.start(mux, client, &value, peer),
                Window::Challenged { install_id, nonce } => {
                    prove(mux, client, &value, &install_id, &nonce)
                }
            },
            Some("identify") if matches!(window, Window::Open { identified: false }) => {
                self.window = Window::Open { identified: true };
                return None;
            }
            Some("subscribe") if self.page_relay => Err((
                "origin.forbidden",
                "a page relay connection cannot subscribe",
                Some(json!({"derived": RequestOrigin::Page.wire_name()})),
            )),
            _ => return None,
        };
        Some(match result {
            Ok(data) => json!({"id": id, "ok": true, "data": data}),
            Err((code, message, details)) => {
                let mut reply =
                    json!({"id": id, "ok": false, "error": message, "error_code": code});
                if let Some(details) = details {
                    reply["error_details"] = details;
                }
                reply
            }
        })
    }

    fn start(
        &mut self,
        mux: &Mux,
        client: u64,
        value: &Value,
        peer: impl FnOnce() -> Peer,
    ) -> Result<Value, Refusal> {
        let bad = |field: &str| {
            let message = if field == "role" {
                "client-hello needs role main or page_relay"
            } else {
                "client-hello install_id must be 1-128 characters of A-Z a-z 0-9 _ -"
            };
            ("client_hello.bad_request", message, Some(json!({"field": field})))
        };
        let role = value
            .get("role")
            .and_then(Value::as_str)
            .and_then(HelloRole::declared)
            .ok_or_else(|| bad("role"))?;
        let install_id = value.get("install_id");
        if install_id.is_some_and(|id| !id.as_str().is_some_and(valid_install_id)) {
            return Err(bad("install_id"));
        }
        let peer = peer();
        // Prover A, outside every lock: role main on a signed build.
        let signed =
            role == HelloRole::Main && mux.control_clients.app_trust.signature_proves(peer.token);
        if !origin_gate::set_hello(mux, client, role, peer.key, signed) {
            return Err(("client_hello.window_closed", "this connection already has a role", None));
        }
        self.page_relay = role == HelloRole::PageRelay;
        let mut data = json!({"connection_id": client.to_string()});
        // Uniform nonce rule: role main with an install id always gets one,
        // known id or not and signed build or not (no oracle).
        let (HelloRole::Main, Some(install_id)) = (role, install_id.and_then(Value::as_str)) else {
            return Ok(data);
        };
        let mut nonce = Zeroizing::new([0u8; NONCE_LEN]);
        // A connection whose nonce could not be made stays unverified.
        if getrandom::fill(nonce.as_mut_slice()).is_ok() {
            data["nonce"] = Value::String(frontend_proof::hex(nonce.as_slice()));
            self.window = Window::Challenged { install_id: install_id.to_string(), nonce };
        }
        Ok(data)
    }
}

/// Step 2: the install-key proof over this connection's nonce (prover B).
/// Any refusal is `client_hello.refused` and the window stays closed.
fn prove(
    mux: &Mux,
    client: u64,
    value: &Value,
    install_id: &str,
    nonce: &[u8; NONCE_LEN],
) -> Result<Value, Refusal> {
    const REFUSED: Refusal = ("client_hello.refused", "client-hello refused", None);
    let field = |name: &str| value.get(name).and_then(Value::as_str);
    let (Some(claimed_id), Some(proof)) = (field("install_id"), field("proof")) else {
        return Err(REFUSED);
    };
    if !mux.control_clients.app_trust.install_key_proves(install_id, nonce, claimed_id, proof)
        || !origin_gate::set_install_proved(mux, client)
    {
        return Err(REFUSED);
    }
    Ok(json!({"verified": true, "install_id": install_id, "connection_id": client.to_string()}))
}

#[cfg(all(test, unix))]
#[path = "client_hello_tests.rs"]
mod tests;
