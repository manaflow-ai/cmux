//! Page streams (`page-streams-v1`, plans/cmux-next/request-origin.md "Page
//! streams"): one streamed page relay connection, a stream per page. Each
//! line goes through the connection's hello gate and then the connection
//! message handler, as the line loop sends it.

use serde_json::{Value, json};

use crate::request_origin::params_sha256;
use crate::server::client_hello::{HelloGate, Peer};
use crate::server::origin_gate::{
    set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;

const PEER: &str = "token:10.1";

/// One connection: its hello gate, then its message handler.
pub(super) struct Line {
    pub(super) client: u64,
    gate: HelloGate,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Line {
    pub(super) fn connect(mux: &Arc<Mux>) -> Self {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        let gate = HelloGate::new(ClientTransport::Unix);
        Self { client, gate, writer, outbound, scheduler }
    }

    /// A streamed page relay of peer [`PEER`] (its hello accepted).
    pub(super) fn streamed_relay(mux: &Arc<Mux>) -> Self {
        let mut line = Self::connect(mux);
        let hello = line.send(
            mux,
            &json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "streams": true}),
        );
        assert_eq!(hello["ok"], true, "{hello}");
        assert_eq!(hello["data"]["page_streams"], true, "{hello}");
        line
    }

    /// Sends one line and returns its reply.
    pub(super) fn send(&mut self, mux: &Arc<Mux>, request: &Value) -> Value {
        let text = request.to_string();
        let peer = || Peer { key: Some(PEER.to_string()), token: None };
        if let Some(reply) = self.gate.observe(mux, self.client, &text, peer) {
            return reply;
        }
        assert!(handle_connection_message(mux, self.client, &text, &self.writer, &self.scheduler));
        let message = self.outbound.try_pop().expect("a synchronous reply");
        serde_json::from_str(&message).unwrap()
    }

    /// Opens `stream` for `page` and returns its relay id.
    pub(super) fn open(&mut self, mux: &Arc<Mux>, stream: u16, page: &str) -> String {
        let reply =
            self.send(mux, &json!({"id": 2, "cmd": "open-stream", "stream": stream, "page": page}));
        assert_eq!(reply["ok"], true, "{reply}");
        assert_eq!(reply["data"]["page"], page, "{reply}");
        reply["data"]["relay_id"].as_str().expect("relay id").to_string()
    }
}

pub(super) fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("page-stream-{label}"), crate::SurfaceOptions::default())
}

pub(super) fn v2(
    operation: &str,
    params: Value,
    key: Option<&str>,
    origin: Option<Value>,
) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": "r1",
        "operation": operation,
        "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    if let Some(origin) = origin {
        request["origin"] = origin;
    }
    request
}

/// The `origin` claim of a page request on `stream`.
pub(super) fn on_stream(stream: u16) -> Option<Value> {
    Some(json!({"claim": "page", "stream": stream}))
}

fn current() -> Value {
    json!({"machine": "current", "session": "current"})
}

fn history_list(origin: Option<Value>) -> Value {
    v2("history.entries.list", current(), None, origin)
}

fn remove_params() -> Value {
    json!({"machine": "current", "session": "current", "ids": ["h1"]})
}

fn history_remove(origin: Option<Value>) -> Value {
    v2("history.entries.remove", remove_params(), Some("remove-1"), origin)
}

fn forbidden_reason(reply: &Value) -> &str {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    reply["error"]["details"]["reason"].as_str().unwrap_or_default()
}

/// A legacy (raw command) refusal: its `error_code` and details reason.
fn raw_refusal(reply: &Value) -> (&str, &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    let code = reply["error_code"].as_str().unwrap_or_default();
    (code, reply["error_details"]["reason"].as_str().unwrap_or_default())
}

fn assert_not_forbidden(reply: &Value) {
    assert_ne!(reply["error"]["code"], "origin.forbidden", "{reply}");
}

/// The verified app of peer [`PEER`].
fn verified_app(mux: &Arc<Mux>) -> Line {
    let app = Line::connect(mux);
    set_role_for_test(mux, app.client, "main");
    set_peer_key_for_test(mux, app.client, PEER);
    set_verified_app_for_test(mux, app.client, true);
    app
}

fn issue(mux: &Arc<Mux>, app: &mut Line, operation: &str, params: &Value, relay_id: &str) -> Value {
    let fields = json!({
        "machine": "current",
        "session": "current",
        "operation": operation,
        "params_sha256": params_sha256(params),
        "relay_connection_id": relay_id,
    });
    app.send(mux, &v2("origin.confirmation.issue", fields, None, None))
}

fn issued_token(reply: &Value) -> String {
    assert_eq!(reply["ok"], true, "{reply}");
    reply["result"]["token"].as_str().expect("token").to_string()
}

fn confirmed_on(stream: u16, token: &str) -> Option<Value> {
    Some(json!({"claim": "user", "confirmation": token, "stream": stream}))
}

#[test]
fn each_stream_is_judged_with_its_own_pages_allow_list() {
    let mux = mux("allow-list");
    let mut relay = Line::streamed_relay(&mux);
    relay.open(&mux, 1, "history");
    relay.open(&mux, 2, "apps");
    // History may read its entries; the App Store page may not.
    assert_not_forbidden(&relay.send(&mux, &history_list(on_stream(1))));
    assert_eq!(
        forbidden_reason(&relay.send(&mux, &history_list(on_stream(2)))),
        "page_not_allowed"
    );
    // A routed operation follows the same rule: the App Store page reads
    // the catalog, History does not.
    let catalog = v2("apps.catalog.list", current(), None, on_stream(2));
    assert_not_forbidden(&relay.send(&mux, &catalog));
    let catalog = v2("apps.catalog.list", current(), None, on_stream(1));
    assert_eq!(forbidden_reason(&relay.send(&mux, &catalog)), "page_not_allowed");
    mux.shutdown();
}

#[test]
fn no_page_stream_request_acts_as_user() {
    let mux = mux("never-user");
    let mut relay = Line::streamed_relay(&mux);
    relay.open(&mux, 1, "history");
    // A gesture operation without the host's confirmation stays page.
    let reply = relay.send(&mux, &history_remove(on_stream(1)));
    assert_eq!(forbidden_reason(&reply), "gesture_required");
    assert_eq!(reply["error"]["details"]["derived"], "page", "{reply}");
    // Claims other than page or a confirmed user are refused.
    for claim in ["user", "agent", "app"] {
        let origin = Some(json!({"claim": claim, "stream": 1}));
        let reply = relay.send(&mux, &history_list(origin));
        assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
        assert_eq!(reply["error"]["details"]["claim"], claim, "{reply}");
    }
    // A user-only operation (gate A2) is refused for the page.
    let params = json!({"machine": "current", "session": "current", "profile": "p",
        "url": "https://example.com", "at_ms": "1"});
    let record = v2("history.visit.record", params, Some("visit-1"), on_stream(1));
    assert_eq!(relay.send(&mux, &record)["error"]["code"], "origin.forbidden");
    // The connection itself derives page and never mints confirmations.
    let fields = json!({"machine": "current", "session": "current", "operation": "session.ping",
        "params_sha256": params_sha256(&current()), "relay_connection_id": relay.client.to_string()});
    let issue = v2("origin.confirmation.issue", fields, None, on_stream(1));
    assert_eq!(relay.send(&mux, &issue)["error"]["code"], "origin.forbidden");
    mux.shutdown();
}

#[test]
fn a_streams_page_is_immutable_for_its_life() {
    let mux = mux("immutable");
    let mut relay = Line::streamed_relay(&mux);
    relay.open(&mux, 1, "history");
    let reopen =
        relay.send(&mux, &json!({"id": 3, "cmd": "open-stream", "stream": 1, "page": "apps"}));
    assert_eq!(reopen["error_code"], "page_stream.in_use", "{reopen}");
    // Still the History page.
    assert_not_forbidden(&relay.send(&mux, &history_list(on_stream(1))));
    // The role is fixed too: a second hello is refused.
    let hello = relay.send(&mux, &json!({"id": 4, "cmd": "client-hello", "role": "main"}));
    assert_eq!(hello["error_code"], "client_hello.window_closed", "{hello}");
    // After close-stream the id is free; a new stream life may pick a page.
    let close = relay.send(&mux, &json!({"id": 5, "cmd": "close-stream", "stream": 1}));
    assert_eq!(close["data"]["closed"], true, "{close}");
    let again = relay.send(&mux, &json!({"id": 6, "cmd": "close-stream", "stream": 1}));
    assert_eq!(again["data"]["closed"], false, "{again}");
    assert_eq!(forbidden_reason(&relay.send(&mux, &history_list(on_stream(1)))), "stream_not_open");
    relay.open(&mux, 1, "apps");
    assert_eq!(
        forbidden_reason(&relay.send(&mux, &history_list(on_stream(1)))),
        "page_not_allowed"
    );
    mux.shutdown();
}

#[test]
fn a_token_for_stream_x_fails_on_stream_y() {
    let mux = mux("token-stream");
    let mut app = verified_app(&mux);
    let mut relay = Line::streamed_relay(&mux);
    let first = relay.open(&mux, 1, "history");
    relay.open(&mux, 2, "history");
    let operation = "history.entries.remove";
    // Issued for stream 1, presented on stream 2: refused, and spent.
    let token = issued_token(&issue(&mux, &mut app, operation, &remove_params(), &first));
    let reply = relay.send(&mux, &history_remove(confirmed_on(2, &token)));
    assert_eq!(forbidden_reason(&reply), "confirmation_invalid");
    let reply = relay.send(&mux, &history_remove(confirmed_on(1, &token)));
    assert_eq!(forbidden_reason(&reply), "confirmation_invalid");
    // A fresh token on its own stream passes the origin gate once.
    let token = issued_token(&issue(&mux, &mut app, operation, &remove_params(), &first));
    assert_not_forbidden(&relay.send(&mux, &history_remove(confirmed_on(1, &token))));
    // Closing a stream drops its tokens; the reopened stream has a new
    // relay id, so the old one names nothing.
    let token = issued_token(&issue(&mux, &mut app, operation, &remove_params(), &first));
    relay.send(&mux, &json!({"id": 7, "cmd": "close-stream", "stream": 1}));
    let reopened = relay.open(&mux, 1, "history");
    assert_ne!(reopened, first);
    let reply = relay.send(&mux, &history_remove(confirmed_on(1, &token)));
    assert_eq!(forbidden_reason(&reply), "confirmation_invalid");
    let stale = issue(&mux, &mut app, operation, &remove_params(), &first);
    assert_eq!(forbidden_reason(&stale), "relay_mismatch");
    // The streamed connection's own id names no page: no token for it.
    let own = issue(&mux, &mut app, operation, &remove_params(), &relay.client.to_string());
    assert_eq!(forbidden_reason(&own), "relay_mismatch");
    mux.shutdown();
}

#[test]
fn a_token_for_a_stream_of_another_peer_is_refused() {
    let mux = mux("token-peer");
    let mut app = verified_app(&mux);
    let mut relay = Line::streamed_relay(&mux);
    let relay_id = relay.open(&mux, 1, "history");
    set_peer_key_for_test(&mux, relay.client, "token:10.2");
    let reply = issue(&mux, &mut app, "history.entries.remove", &remove_params(), &relay_id);
    assert_eq!(forbidden_reason(&reply), "relay_mismatch");
    mux.shutdown();
}

#[test]
fn an_untagged_request_on_a_streamed_relay_is_refused() {
    let mux = mux("untagged");
    let mut relay = Line::streamed_relay(&mux);
    relay.open(&mux, 1, "history");
    assert_eq!(forbidden_reason(&relay.send(&mux, &history_list(None))), "stream_required");
    let page = Some(json!({"claim": "page"}));
    assert_eq!(forbidden_reason(&relay.send(&mux, &history_list(page))), "stream_required");
    // Routed operations need the tag too.
    let catalog = v2("apps.catalog.list", current(), None, None);
    assert_eq!(forbidden_reason(&relay.send(&mux, &catalog)), "stream_required");
    // A stream that is not open, and stream 0, name no page.
    assert_eq!(forbidden_reason(&relay.send(&mux, &history_list(on_stream(9)))), "stream_not_open");
    let zero = relay.send(&mux, &history_list(on_stream(0)));
    assert_eq!(zero["error"]["code"], "validation.invalid", "{zero}");
    mux.shutdown();
}

#[test]
fn stream_zero_only_opens_and_closes_page_streams() {
    let mux = mux("stream-zero");
    let mut relay = Line::streamed_relay(&mux);
    for line in [
        json!({"id": 10, "cmd": "identify"}),
        json!({"id": 11, "cmd": "subscribe"}),
        json!({"id": 12, "cmd": "list-workspaces"}),
        json!({"id": 13, "cmd": "send", "surface": 1, "data": "x"}),
    ] {
        let reply = relay.send(&mux, &line);
        assert_eq!(raw_refusal(&reply), ("origin.forbidden", "stream_zero"), "{line}");
    }
    for (line, field) in [
        (json!({"id": 14, "cmd": "open-stream", "stream": 0, "page": "history"}), "stream"),
        (json!({"id": 15, "cmd": "open-stream", "stream": 65536, "page": "history"}), "stream"),
        (json!({"id": 16, "cmd": "open-stream", "stream": 1, "page": "Not A Page"}), "page"),
        (json!({"id": 17, "cmd": "open-stream", "stream": 1}), "page"),
        (
            json!({"id": 18, "cmd": "open-stream", "stream": 1, "page": "history", "role": "main"}),
            "role",
        ),
        (json!({"id": 19, "cmd": "close-stream", "stream": 1, "page": "history"}), "page"),
    ] {
        let reply = relay.send(&mux, &line);
        assert_eq!(reply["error_code"], "page_stream.bad_request", "{reply}");
        assert_eq!(reply["error_details"]["field"], field, "{reply}");
    }
    mux.shutdown();
}

#[test]
fn page_streams_never_open_off_a_streamed_relay() {
    let mux = mux("not-here");
    let open = json!({"id": 20, "cmd": "open-stream", "stream": 1, "page": "history"});
    let close = json!({"id": 21, "cmd": "close-stream", "stream": 1});
    // The main connection, before and after its hello window closes.
    let mut main = Line::connect(&mux);
    let hello = main.send(&mux, &json!({"id": 1, "cmd": "client-hello", "role": "main"}));
    assert_eq!(hello["ok"], true, "{hello}");
    for line in [&open, &close] {
        let reply = main.send(&mux, line);
        assert_eq!(raw_refusal(&reply), ("origin.forbidden", "page_stream_not_here"), "{reply}");
        assert_eq!(reply["error_details"]["derived"], "agent", "{reply}");
    }
    // A stream tag on the main connection's v2 request is refused too.
    let tagged = main.send(&mux, &history_list(Some(json!({"claim": "agent", "stream": 1}))));
    assert_eq!(forbidden_reason(&tagged), "page_stream_not_here");
    // A connection with no hello, and a one-page relay.
    let mut legacy = Line::connect(&mux);
    let reply = legacy.send(&mux, &open);
    assert_eq!(raw_refusal(&reply), ("origin.forbidden", "page_stream_not_here"), "{reply}");
    let mut one_page = Line::connect(&mux);
    let hello = json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "history"});
    assert_eq!(one_page.send(&mux, &hello)["ok"], true);
    let reply = one_page.send(&mux, &open);
    assert_eq!(raw_refusal(&reply), ("origin.forbidden", "page_stream_not_here"), "{reply}");
    mux.shutdown();
}

#[test]
fn streams_is_only_for_a_page_relay_without_a_page() {
    let mux = mux("hello-streams");
    for hello in [
        json!({"id": 1, "cmd": "client-hello", "role": "main", "streams": true}),
        json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "page": "history", "streams": true}),
        json!({"id": 1, "cmd": "client-hello", "role": "page_relay", "streams": "yes"}),
    ] {
        let mut line = Line::connect(&mux);
        let reply = line.send(&mux, &hello);
        assert_eq!(reply["error_code"], "client_hello.bad_request", "{reply}");
        assert_eq!(reply["error_details"]["field"], "streams", "{reply}");
    }
    mux.shutdown();
}
