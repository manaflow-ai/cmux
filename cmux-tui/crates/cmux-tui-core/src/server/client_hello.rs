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
//! Features: the daemon outlives the app, so a role
//! `main` hello may carry the app's daemon features, `features: {hash,
//! values: {name: bool}}` (its `daemon` and `both` features). The reply's
//! `features: {hash, applied, pending}` says what the daemon did
//! (`cmux_features::Live::reconcile`): a verified app's off for a
//! `process=daemon` kill switch applies at once, every other difference is
//! pending and the daemon keeps its own value for the session. A challenged
//! step 1 reports with no kill; its step 2, once proved, reports again with
//! the kills. Nothing here reads a file or the network.
//!
//! Bridges (spec/transports.md "Framed IPC grants"): a byte
//! bridge that splices a far client onto this socket may send `{cmd:
//! "bridge-hello", features: [name]}` as the connection's very first line.
//! With `bridge-frames-v1` it says that it reads each `0xFF` message by its
//! frame header, so the connection may be granted frames but never
//! descriptors (capabilities.rs `IpcPeer::FramedBridge`). The reply is
//! `{features}`, the names the daemon took. The far client's own hello
//! window stays open behind it. Anywhere else it is
//! `bridge_hello.window_closed`; off a local Unix connection it is
//! `bridge_hello.local_only`.
//!
//! A page relay connection carries only `cmux.protocol/2` requests (pages
//! speak nothing else through the relay). Every other line on it is refused
//! with `origin.forbidden {required: "agent", derived: "page"}` (default
//! deny), except `identify`, a (late, so refused) `client-hello`, and a
//! plain `subscribe` when its page hears events (`page-events-v1`; the
//! stream then carries only those events, cmd_subscribe.rs). This keeps
//! every other legacy command away from page JS; page JS never sends the
//! `subscribe` (the host does, in its relay handshake).
//!
//! Page streams (`page-streams-v1`, request-origin.md "Page streams"): a
//! page relay hello with `streams: true` (and no `page`) makes one
//! connection carry every page, a stream per page. The connection's own
//! lines (stream 0) are then only `open-stream {stream, page}` and
//! `close-stream {stream}`; every `cmux.protocol/2` request names its open
//! stream in `origin.stream`. Any other connection refuses `open-stream`
//! with `origin.forbidden {reason: page_stream_not_here}`: page streams
//! never live on the main connection, whose origin is not page.

use crate::panic_free::JsonFields;
use cmux_features::Live;
use cmux_link::app_caller::PeerToken;
use cmux_local_auth::frontend_proof::{self, NONCE_LEN};
use zeroize::Zeroizing;

use super::*;
use std::num::NonZeroU16;

use crate::request_origin::{
    HelloRole, OpenStreamRefusal, RequestOrigin, page_router_table, valid_install_id,
};

const CLIENT_HELLO: &str = "client-hello";
const BRIDGE_HELLO: &str = "bridge-hello";
/// What both hellos' names end with: after the window closes, a line without
/// it (or a page-stream command) is neither, so it skips the JSON parse.
const HELLO_SUFFIX: &str = "-hello";
/// Most feature names one bridge hello may carry.
const MAX_BRIDGE_FEATURES: usize = 16;
const OPEN_STREAM: &str = "open-stream";
const CLOSE_STREAM: &str = "close-stream";
/// Most feature values one hello may carry (the registry has far fewer).
const MAX_HELLO_FEATURES: usize = 512;
/// Longest feature name or hash a hello may carry.
const MAX_FEATURE_TEXT: usize = 128;

/// Installs the daemon's features, resolved once at start, that hellos
/// reconcile against. False when they were installed already.
pub fn install_daemon_features(mux: &Mux, features: Live) -> bool {
    mux.control_clients.features.set(features).is_ok()
}

/// The daemon's features with the kill switches hellos turned off; None
/// before [`install_daemon_features`].
pub fn daemon_features(mux: &Mux) -> Option<&Live> {
    mux.control_clients.features.get()
}

/// The app's daemon features from a role-main hello.
struct HelloFeatures {
    hash: Option<String>,
    values: Vec<(String, bool)>,
}

impl HelloFeatures {
    /// `features: {hash?, values: {name: bool}}`; None when absent or null.
    fn parse(value: Option<&Value>) -> Result<Option<Self>, ()> {
        let object = match value {
            None | Some(Value::Null) => return Ok(None),
            Some(Value::Object(object)) => object,
            Some(_) => return Err(()),
        };
        if object.keys().any(|key| key != "hash" && key != "values") {
            return Err(());
        }
        let hash = match object.get("hash") {
            None => None,
            Some(Value::String(hash)) if hash.len() <= MAX_FEATURE_TEXT => Some(hash.clone()),
            Some(_) => return Err(()),
        };
        let Some(Value::Object(values)) = object.get("values") else { return Err(()) };
        if values.len() > MAX_HELLO_FEATURES {
            return Err(());
        }
        let values = values
            .iter()
            .map(|(name, enabled)| match enabled {
                Value::Bool(enabled) if name.len() <= MAX_FEATURE_TEXT => {
                    Ok((name.clone(), *enabled))
                }
                _ => Err(()),
            })
            .collect::<Result<_, _>>()?;
        Ok(Some(Self { hash, values }))
    }

    /// The reply's `features`, after reconciling with the daemon's (kills
    /// only for a `verified` app); None before the daemon installed its own.
    fn reconcile(&self, mux: &Mux, verified: bool) -> Option<Value> {
        daemon_features(mux).map(|live| self.report(live, verified))
    }

    /// The reply's `features` from `live` alone. The hello's values and the
    /// daemon's in-memory features are all this step gets, so it can read
    /// no file, no flags document and no network.
    fn report(&self, live: &Live, verified: bool) -> Value {
        let values = self.values.iter().map(|(name, enabled)| (name.as_str(), *enabled));
        let reconciled = live.reconcile(self.hash.as_deref(), values, verified);
        let pending: Vec<Value> = reconciled
            .pending
            .iter()
            .map(|item| json!({"name": item.name, "app": item.app, "daemon": item.daemon}))
            .collect();
        json!({"hash": reconciled.hash, "applied": reconciled.applied, "pending": pending})
    }
}

enum Window {
    /// Step 1 may come; `identified` once the one allowed `identify` came.
    Open {
        identified: bool,
    },
    /// Step 1 issued a nonce; the next line must be the proof (P8).
    Challenged {
        install_id: String,
        nonce: Zeroizing<[u8; NONCE_LEN]>,
        /// Reconciled again, with kills, once step 2 proves the app.
        features: Option<HelloFeatures>,
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
    /// A streamed page relay (`page-streams-v1`): its own lines are only
    /// `open-stream` and `close-stream`.
    page_streams: bool,
    /// A page relay whose page hears subscribe events (page-router.json
    /// `events`): its `subscribe` line goes to dispatch, which narrows the
    /// stream to those events.
    page_events: bool,
    /// A WebSocket admitted with a page-bound credential (`page-credential
    /// {page}`): only these raw commands reach dispatch; its
    /// `cmux.protocol/2` lines go on to the page's allow list.
    scoped_raw: Option<&'static [&'static str]>,
    /// The first line was a `bridge-hello`; a second one is refused.
    bridge_declared: bool,
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
            page_streams: false,
            page_events: false,
            scoped_raw: None,
            bridge_declared: false,
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

    /// Whether the window has closed: no later line changes the connection's
    /// role or proof, so its origin is final.
    pub(super) fn is_closed(&self) -> bool {
        matches!(self.window, Window::Closed)
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
        // After the window closes only a late hello, a page stream command
        // (refused off a streamed relay), or any line of a page relay, is
        // looked at here; the test is a superset of those cases.
        if let Some(allowed) = self.scoped_raw {
            return scoped_refusal(line, allowed);
        }
        let open = !matches!(self.window, Window::Closed);
        let looked_at = open
            || self.page_relay
            || [HELLO_SUFFIX, OPEN_STREAM, CLOSE_STREAM].iter().any(|cmd| line.contains(cmd));
        if !looked_at {
            return None;
        }
        let window = std::mem::replace(&mut self.window, Window::Closed);
        crate::diagnostics::note_json_parse();
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
                Window::Challenged { install_id, nonce, features } => {
                    prove(mux, client, &value, &install_id, &nonce, features.as_ref())
                }
            },
            Some(BRIDGE_HELLO) => match window {
                Window::Open { identified: false } if !self.bridge_declared => {
                    // The far client's hello may still come: the window stays.
                    self.window = Window::Open { identified: false };
                    self.declare_bridge(mux, client, &value)
                }
                _ => Err((
                    "bridge_hello.window_closed",
                    "bridge-hello must be the connection's first line",
                    None,
                )),
            },
            // Page streams live only on a streamed page relay, never on the
            // main connection (request-origin.md "Page streams").
            Some(OPEN_STREAM | CLOSE_STREAM) if !self.page_streams => {
                Err(page_stream_not_here(origin_gate::derived_origin(mux, client)))
            }
            Some(OPEN_STREAM) => open_stream(mux, client, &value),
            Some(CLOSE_STREAM) => close_stream(mux, client, &value),
            Some("identify") if matches!(window, Window::Open { identified: false }) => {
                self.window = Window::Open { identified: true };
                return None;
            }
            // Stream 0 of a streamed page relay opens and closes streams only.
            _ if self.page_streams => return Some(stream_zero_refusal(id)),
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

    /// A bridge's first line: records `bridge-frames-v1` on the connection
    /// when its kernel facts allow (origin_gate::declare_frame_bridge).
    fn declare_bridge(&mut self, mux: &Mux, client: u64, value: &Value) -> Result<Value, Refusal> {
        if !matches!(self.transport, ClientTransport::Unix) {
            return Err((
                "bridge_hello.local_only",
                "bridge-hello needs a local Unix socket connection",
                None,
            ));
        }
        let bad = || {
            (
                "bridge_hello.bad_request",
                "bridge-hello features must be an array of at most 16 names of at most 128 characters",
                Some(json!({"field": "features"})),
            )
        };
        let Some(Value::Array(features)) = value.get("features") else { return Err(bad()) };
        if features.len() > MAX_BRIDGE_FEATURES {
            return Err(bad());
        }
        let mut frames = false;
        for feature in features {
            match feature.as_str() {
                Some(name) if name.len() <= MAX_FEATURE_TEXT => {
                    frames |= name == capabilities::BRIDGE_FRAMES_FEATURE;
                }
                _ => return Err(bad()),
            }
        }
        self.bridge_declared = true;
        let taken: &[&str] = if frames && origin_gate::declare_frame_bridge(mux, client) {
            &[capabilities::BRIDGE_FRAMES_FEATURE]
        } else {
            &[]
        };
        Ok(json!({"features": taken}))
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
                "streams" => {
                    "client-hello streams is a boolean, true only for role page_relay without a page"
                }
                "features" => {
                    "client-hello features is for role main: {hash?: string, values: {name: bool}}, at most 512 values"
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
        // One page relay connection for every page, a stream per page
        // (page-streams-v1): its pages come with open-stream, not here.
        let streams = match value.get("streams") {
            None | Some(Value::Null | Value::Bool(false)) => false,
            Some(Value::Bool(true)) if role == HelloRole::PageRelay && page.is_none() => true,
            Some(_) => return Err(bad("streams")),
        };
        let features = HelloFeatures::parse(value.get("features")).map_err(|()| bad("features"))?;
        if features.is_some() && role != HelloRole::Main {
            return Err(bad("features"));
        }
        let peer = peer();
        // Prover A, outside every lock: role main on a signed build.
        let signed =
            role == HelloRole::Main && mux.control_clients.app_trust.signature_proves(peer.token);
        if !origin_gate::set_hello(mux, client, role, peer.key, signed, page.clone(), streams) {
            return Err(("client_hello.window_closed", "this connection already has a role", None));
        }
        self.page_relay = role == HelloRole::PageRelay;
        self.page_streams = streams;
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
        if streams {
            data.insert("page_streams", json!(true));
        }
        // A signed app is verified now; an install-key app only after step 2.
        if let Some(report) = features.as_ref().and_then(|features| features.reconcile(mux, signed))
        {
            data.insert("features", report);
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
            let features = features.filter(|_| !signed);
            self.window =
                Window::Challenged { install_id: install_id.to_string(), nonce, features };
        }
        Ok(data)
    }
}

/// The answer to a legacy line on a page relay connection.
/// A page-bound connection's line: `None` dispatches it (a
/// `cmux.protocol/2` request, which the page's allow list then decides, or
/// an allowed raw command); anything else is refused here.
fn scoped_refusal(line: &str, allowed: &[&str]) -> Option<Value> {
    crate::diagnostics::note_json_parse();
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

/// The answer to any line of a streamed page relay's stream 0 that is not
/// `open-stream`, `close-stream` or a `cmux.protocol/2` request.
fn stream_zero_refusal(id: Option<Value>) -> Value {
    json!({
        "id": id,
        "ok": false,
        "error": "stream 0 of a streamed page relay only opens and closes page streams",
        "error_code": "origin.forbidden",
        "error_details": {"reason": "stream_zero", "derived": RequestOrigin::Page.wire_name()},
    })
}

/// `open-stream` or `close-stream` on a connection that is not a streamed
/// page relay (the main connection, a one-page relay, a WebSocket).
fn page_stream_not_here(derived: RequestOrigin) -> Refusal {
    (
        "origin.forbidden",
        "only a streamed page relay connection opens page streams",
        Some(json!({"reason": "page_stream_not_here", "derived": derived.wire_name()})),
    )
}

fn page_stream_bad_request(field: &str) -> Refusal {
    let message = match field {
        "stream" => "a page stream id is 1-65535 (stream 0 is the connection's own)",
        "page" => "a page id is 1-64 characters of a-z 0-9 -, starting with a letter",
        _ => "open-stream takes stream and page, close-stream takes stream",
    };
    ("page_stream.bad_request", message, Some(json!({"field": field})))
}

/// The line's `stream` once every member is one of `members`.
fn stream_member(value: &Value, members: &[&str]) -> Result<NonZeroU16, Refusal> {
    let object = value.as_object().ok_or_else(|| page_stream_bad_request("cmd"))?;
    if let Some(unknown) = object.keys().find(|key| !members.contains(&key.as_str())) {
        return Err(page_stream_bad_request(unknown));
    }
    object
        .get("stream")
        .and_then(Value::as_u64)
        .and_then(|stream| u16::try_from(stream).ok())
        .and_then(NonZeroU16::new)
        .ok_or_else(|| page_stream_bad_request("stream"))
}

/// `open-stream {stream, page}`: the stream speaks for `page` until
/// `close-stream`. The reply's `relay_id` is the stream's
/// `relay_connection_id` for `origin.confirmation.issue`.
fn open_stream(mux: &Mux, client: u64, value: &Value) -> Result<Value, Refusal> {
    let stream = stream_member(value, &["cmd", "id", "stream", "page"])?;
    let page = value
        .get("page")
        .and_then(Value::as_str)
        .filter(|page| page_router_table::valid_page_id(page))
        .ok_or_else(|| page_stream_bad_request("page"))?;
    let relay_id =
        origin_gate::open_page_stream(mux, client, stream, page.to_owned()).map_err(|refusal| {
            match refusal {
                OpenStreamRefusal::InUse => (
                    "page_stream.in_use",
                    "the page stream is open, and its page never changes: close it first",
                    Some(json!({"stream": stream})),
                ),
                OpenStreamRefusal::Limit => (
                    "page_stream.limit",
                    "this page relay has as many open page streams as it may",
                    Some(json!({"limit": MAX_SERVER_CONNECTIONS})),
                ),
                OpenStreamRefusal::NotStreamed => page_stream_not_here(RequestOrigin::Page),
            }
        })?;
    Ok(json!({
        "stream": stream,
        "page": page,
        "relay_id": relay_id.to_string(),
        "page_operations": page_router_table::page_operations(page),
    }))
}

/// `close-stream {stream}`: ends the stream and every token issued for it;
/// idempotent (`closed: false` for a stream that was not open).
fn close_stream(mux: &Mux, client: u64, value: &Value) -> Result<Value, Refusal> {
    let stream = stream_member(value, &["cmd", "id", "stream"])?;
    let closed = origin_gate::close_page_stream(mux, client, stream);
    Ok(json!({"stream": stream, "closed": closed}))
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
    features: Option<&HelloFeatures>,
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
    let mut data = json!({
        "verified": true,
        "install_id": install_id,
        "connection_id": client.to_string(),
        "user_origin_allowed": user_origin_allowed(mux, client),
    });
    if let Some(report) = features.and_then(|features| features.reconcile(mux, true)) {
        data.insert("features", report);
    }
    Ok(data)
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
