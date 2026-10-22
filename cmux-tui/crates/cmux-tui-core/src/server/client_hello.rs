//! `client-hello` step 1 (plans/cmux-next/request-origin.md, "Hello and
//! capability"): `{cmd: "client-hello", role: "main"|"page_relay",
//! install_id?, page?}` -> `{connection_id, user_origin_allowed, nonce?,
//! page?, page_operations?, page_events?}`. `page` (page relays only,
//! `page-router-v1`) names the page the relay serves; the reply carries that
//! page's allow list and the events it hears (`page-events-v1`) from
//! spec/page-router.json.
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
//! connection_id, user_origin_allowed}`; any other line closes the window,
//! and a refused proof is `client_hello.refused` (no retry). Either prover sets the
//! connection's `verified_app`; neither changes its `peer_key`.
//!
//! A page relay connection carries only `cmux.protocol/2` requests (pages
//! speak nothing else through the relay). Every other line on it is refused
//! with `origin.forbidden {required: "agent", derived: "page"}` (default
//! deny), except `identify`, a (late, so refused) `client-hello`, and a
//! plain `subscribe` when its page hears events (`page-events-v1`; the
//! stream then carries only those events, cmd_subscribe.rs). This keeps
//! every other legacy command away from page JS; page JS never sends the
//! `subscribe` (the host does, in its relay handshake).

use crate::panic_free::JsonFields;
use cmux_link::app_caller::PeerToken;
use cmux_local_auth::frontend_proof::{self, NONCE_LEN};
use zeroize::Zeroizing;

use super::*;
use crate::request_origin::{HelloRole, RequestOrigin, page_router_table, valid_install_id};

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

impl Peer {
    /// A transport with no socket peer facts (a WebSocket).
    pub(super) const fn unknown() -> Self {
        Self { key: None, token: None }
    }
}

/// The hello state of ONE connection, owned by its read loop, so ordinary
/// lines pay one enum check after the window closes.
pub(super) struct HelloGate {
    transport: ClientTransport,
    window: Window,
    page_relay: bool,
    /// A page relay whose page hears subscribe events (page-router.json
    /// `events`): its `subscribe` line goes to dispatch, which narrows the
    /// stream to those events.
    page_events: bool,
    /// A WebSocket admitted with a page-bound credential (`page-credential
    /// {page}`): only these raw commands reach dispatch; its
    /// `cmux.protocol/2` lines go on to the page's allow list.
    scoped_raw: Option<&'static [&'static str]>,
}

/// The raw commands a page-bound credential's connection may send, by page:
/// the Channels page reads and writes the local conversations and hears
/// their events. Every other page gets none (its `cmux.protocol/2` allow
/// list only).
fn scoped_raw_commands(page: &str) -> &'static [&'static str] {
    match page {
        "home-channels" => &[
            "identify",
            "set-client-info",
            "subscribe",
            "conversation-list",
            "conversation-create",
            "conversation-snapshot",
            "conversation-history",
            "conversation-thread",
            "conversation-op",
            "conversation-typing",
            "conversation-search",
            "conversation-link-resolve",
            "conversation-runs",
            "conversation-run",
            "conversation-live",
            "conversation-inbox-op",
            "home-inbox",
            "conversation-attachment-upload",
            "conversation-attachment-read",
            "conversation-attachment-link",
        ],
        _ => &[],
    }
}

type Refusal = (&'static str, &'static str, Option<Value>);

impl HelloGate {
    pub(super) fn new(transport: ClientTransport) -> Self {
        Self {
            transport,
            window: Window::Open { identified: false },
            page_relay: false,
            page_events: false,
            scoped_raw: None,
        }
    }

    /// Limits this connection to `page`'s raw commands and `cmux.protocol/2`
    /// allow list (a WebSocket admitted with a page-bound credential).
    pub(super) fn scope_to_page(&mut self, page: &str) {
        self.scoped_raw = Some(scoped_raw_commands(page));
    }

    /// Ends the hello window (a line the connection's admission refused
    /// still counts as a line).
    pub(super) fn close(&mut self) {
        self.window = Window::Closed;
    }

    /// Sees every line before dispatch. `Some(reply)` answers the line here
    /// (a `client-hello`, or a page relay's legacy line) and nothing else
    /// sees it; `None` dispatches it as usual.
    pub(super) fn observe(
        &mut self,
        mux: &Mux,
        client: u64,
        line: &str,
        peer: impl FnOnce() -> Peer,
    ) -> Option<Value> {
        // After the window closes only a late hello, or any line of a page
        // relay, is looked at here; the test is a superset of those cases.
        if let Some(allowed) = self.scoped_raw {
            return scoped_refusal(line, allowed);
        }
        let open = !matches!(self.window, Window::Closed);
        if !open && !self.page_relay && !line.contains(CLIENT_HELLO) {
            return None;
        }
        let window = std::mem::replace(&mut self.window, Window::Closed);
        let value = match serde_json::from_str::<Value>(line) {
            Ok(value) => value,
            Err(_) if self.page_relay => return Some(page_relay_refusal(None)),
            Err(_) => return None,
        };
        // The same test dispatch uses for a `cmux.protocol/2` line: those
        // go on to the origin gate.
        if self.page_relay
            && value.as_object().is_some_and(|object| object.contains_key("protocol"))
        {
            return None;
        }
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
            Some("identify") if self.page_relay => return None,
            Some("subscribe") if self.page_relay => {
                return (!self.page_events || !page_relay_subscribe(&value))
                    .then(|| page_relay_subscribe_refusal(id));
            }
            _ if self.page_relay => return Some(page_relay_refusal(id)),
            _ => return None,
        };
        Some(match result {
            Ok(data) => json!({"id": id, "ok": true, "data": data}),
            Err((code, message, details)) => {
                let mut reply =
                    json!({"id": id, "ok": false, "error": message, "error_code": code});
                if let Some(details) = details {
                    reply.insert("error_details", details);
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
            let message = match field {
                "role" => "client-hello needs role main or page_relay",
                "page" => {
                    "client-hello page is for role page_relay: 1-64 characters of a-z 0-9 -, starting with a letter"
                }
                _ => "client-hello install_id must be 1-128 characters of A-Z a-z 0-9 _ -",
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
        // The page this relay serves (page-router-v1): the host names it,
        // never the page; it picks the page's allow list.
        let page = match value.get("page") {
            None | Some(Value::Null) => None,
            Some(Value::String(page))
                if role == HelloRole::PageRelay && page_router_table::valid_page_id(page) =>
            {
                Some(page.clone())
            }
            Some(_) => return Err(bad("page")),
        };
        let peer = peer();
        // Prover A, outside every lock: role main on a signed build.
        let signed =
            role == HelloRole::Main && mux.control_clients.app_trust.signature_proves(peer.token);
        if !origin_gate::set_hello(mux, client, role, peer.key, signed, page.clone()) {
            return Err(("client_hello.window_closed", "this connection already has a role", None));
        }
        self.page_relay = role == HelloRole::PageRelay;
        self.page_events =
            page.as_deref().is_some_and(|page| !page_router_table::page_events(page).is_empty());
        let mut data = json!({
            "connection_id": client.to_string(),
            "user_origin_allowed": user_origin_allowed(mux, client),
        });
        if let Some(page) = page.as_deref() {
            data.insert("page", json!(page));
            data.insert("page_operations", page_router_table::page_operations(page));
            data.insert("page_events", json!(page_router_table::page_events(page)));
        }
        // Uniform nonce rule: role main with an install id always gets one,
        // known id or not and signed build or not (no oracle).
        let (HelloRole::Main, Some(install_id)) = (role, install_id.and_then(Value::as_str)) else {
            return Ok(data);
        };
        let mut nonce = Zeroizing::new([0u8; NONCE_LEN]);
        // A connection whose nonce could not be made stays unverified.
        if getrandom::fill(nonce.as_mut_slice()).is_ok() {
            data.insert("nonce", Value::String(frontend_proof::hex(nonce.as_slice())));
            self.window = Window::Challenged { install_id: install_id.to_string(), nonce };
        }
        Ok(data)
    }
}

/// The answer to a legacy line on a page relay connection.
/// A page-bound connection's line: `None` dispatches it (a
/// `cmux.protocol/2` request, which the page's allow list then decides, or
/// an allowed raw command); anything else is refused here.
fn scoped_refusal(line: &str, allowed: &[&str]) -> Option<Value> {
    let Ok(value) = serde_json::from_str::<Value>(line) else {
        return Some(scoped_page_refusal(None));
    };
    if value.as_object().is_some_and(|object| object.contains_key("protocol")) {
        return None;
    }
    let command = value.get("cmd").and_then(Value::as_str);
    // Its `subscribe` is the plain event stream: no `surface` output (a screen read).
    let narrow = command != Some("subscribe") || page_relay_subscribe(&value);
    if narrow && command.is_some_and(|command| allowed.contains(&command)) {
        return None;
    }
    Some(scoped_page_refusal(value.get("id").cloned()))
}

fn scoped_page_refusal(id: Option<Value>) -> Value {
    json!({
        "id": id,
        "ok": false,
        "error": "a page-bound credential admits only its page's commands",
        "error_code": "origin.forbidden",
        "error_details": {"reason": "page_not_allowed", "derived": RequestOrigin::Page.wire_name()},
    })
}

fn page_relay_refusal(id: Option<Value>) -> Value {
    json!({
        "id": id,
        "ok": false,
        "error": "a page relay connection sends only cmux.protocol/2 requests",
        "error_code": "origin.forbidden",
        "error_details": {"required": "agent", "derived": RequestOrigin::Page.wire_name()},
    })
}

/// A page relay's `subscribe`: the page's event stream only, so no member
/// but `tree_events` (a `surface` output stream is a screen read).
fn page_relay_subscribe(value: &Value) -> bool {
    value.as_object().is_some_and(|object| {
        object.keys().all(|key| matches!(key.as_str(), "cmd" | "id" | "tree_events"))
    })
}

/// The answer to a page relay `subscribe` its page may not send.
fn page_relay_subscribe_refusal(id: Option<Value>) -> Value {
    json!({
        "id": id,
        "ok": false,
        "error": "a page relay hears only its page's events (page-router.json): no terminal output stream, and none for a page without events",
        "error_code": "origin.forbidden",
        "error_details": {"reason": "page_events", "derived": RequestOrigin::Page.wire_name()},
    })
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
        || !origin_gate::set_install_proved(mux, client, install_id)
    {
        return Err(REFUSED);
    }
    Ok(json!({
        "verified": true,
        "install_id": install_id,
        "connection_id": client.to_string(),
        "user_origin_allowed": user_origin_allowed(mux, client),
    }))
}

/// `user_origin_allowed` in both hello replies: whether an origin `user`
/// request on this connection passes the apps door now (the verified app,
/// not bound to an agent). The app sends `user` only when it is true and
/// never resends a refused `user` as `script`.
fn user_origin_allowed(mux: &Mux, client: u64) -> bool {
    #[cfg(unix)]
    {
        apps::user_origin_allowed(mux, client)
    }
    // No apps supervisor here (crate::apps is Unix only); the same rule as
    // `crate::apps::hosting_app_connection` over the same facts. The peer
    // was checked at accept like on Unix (cmux-sdk local_socket: our token
    // user, not an AppContainer, Medium integrity or above).
    #[cfg(not(unix))]
    {
        let facts = origin_gate::app_connection(mux, client);
        !facts.agent && facts.verified_app
    }
}

#[cfg(all(test, unix))]
#[path = "client_hello_tests.rs"]
pub(super) mod tests;

#[cfg(all(test, unix))]
#[path = "untrusted_mint_tests.rs"]
mod untrusted_mint_tests;
