//! A renderer grant lets its holder view a terminal, so only a trusted local
//! caller may mint one. One test per caller class, each over the real line
//! loop of `client_hello_tests`:
//! (a) a remote relay connection; (b) a page relay connection's legacy
//! commands; (c) a `cmux.protocol/2` request whose origin is `page`;
//! (d) a WebSocket connection. A local Unix connection is the control.
//!
//! The test mux has no terminal host, so a request that reaches the minter
//! fails with "surface is not backed by a terminal host". A refusal must come
//! before that point, from the caller check.

use serde_json::{Value, json};

use super::tests::Client;
use crate::server::*;

const NOT_HOSTED: &str = "surface is not backed by a terminal host";

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("mint-{label}"), crate::SurfaceOptions::default())
}

/// A live PTY surface: its local handle and its public terminal id.
fn terminal(mux: &Arc<Mux>) -> (SurfaceId, String) {
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let terminal = surface.terminal_public_id().expect("a PTY terminal id").to_string();
    (surface.id, terminal)
}

fn legacy_mints(surface: SurfaceId, terminal: &str) -> [Value; 2] {
    [
        json!({"cmd": "mint-terminal-renderer", "surface": surface, "ttl_ms": 1000}),
        json!({"cmd": "mint-terminal-renderer-by-terminal", "terminal": terminal, "ttl_ms": 1000}),
    ]
}

fn v2_grant(terminal: &str, origin: Option<Value>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "operation": "terminal.renderer_grant.create",
        "params": {"machine": "current", "session": "current", "terminal": terminal, "ttl_ms": 1000},
    });
    if let Some(origin) = origin {
        request["origin"] = origin;
    }
    request
}

/// A legacy reply that holds no grant and carries `origin.forbidden`.
fn assert_legacy_forbidden(reply: &Value, derived: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.get("data").is_none_or(Value::is_null), "{reply}");
    assert_eq!(reply["error_code"], "origin.forbidden", "{reply}");
    assert_eq!(reply["error_details"]["derived"], derived, "{reply}");
}

/// A v2 reply that holds no grant and carries `origin.forbidden`.
fn assert_v2_forbidden(reply: &Value, derived: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.get("result").is_none_or(Value::is_null), "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    assert_eq!(reply["error"]["details"]["derived"], derived, "{reply}");
}

#[test]
fn a_local_unix_connection_reaches_the_minter() {
    let mux = mux("local");
    let (surface, terminal) = terminal(&mux);
    let mut client = Client::connect(&mux, "mint-local");
    for request in legacy_mints(surface, &terminal) {
        let reply = client.request(request);
        assert_eq!(reply["ok"], false, "{reply}");
        assert!(reply["error"].as_str().is_some_and(|e| e.contains(NOT_HOSTED)), "{reply}");
    }
    let reply = client.request(v2_grant(&terminal, None));
    assert_eq!(reply["error"]["code"], "operation.failed", "{reply}");
    assert!(reply["error"]["message"].as_str().is_some_and(|e| e.contains(NOT_HOSTED)), "{reply}");
}

#[test]
fn a_remote_relay_connection_cannot_mint() {
    let mux = mux("remote");
    let (surface, terminal) = terminal(&mux);
    let mut client = Client::connect_with(&mux, "mint-remote", ClientTransport::Remote);
    for request in legacy_mints(surface, &terminal) {
        let reply = client.request(request);
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error_code"], "remote_denied", "{reply}");
    }
    let reply = client.request(v2_grant(&terminal, None));
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "remote_denied", "{reply}");
}

#[test]
fn a_page_relay_connection_cannot_mint_with_a_legacy_command() {
    let mux = mux("relay-legacy");
    let (surface, terminal) = terminal(&mux);
    let mut client = Client::connect(&mux, "mint-relay-legacy");
    assert_eq!(client.hello(json!({"role": "page_relay"}))["ok"], true);
    for request in legacy_mints(surface, &terminal) {
        assert_legacy_forbidden(&client.request(request), "page");
    }
}

/// Pages speak only `cmux.protocol/2` through the relay, so every legacy
/// line on a page relay is refused (default deny), except `identify`.
#[test]
fn a_page_relay_connection_refuses_every_legacy_command_but_identify() {
    let mux = mux("relay-deny");
    let mut client = Client::connect(&mux, "mint-relay-deny");
    assert_eq!(client.hello(json!({"role": "page_relay"}))["ok"], true);
    for request in [
        json!({"cmd": "ping"}),
        json!({"cmd": "list-workspaces"}),
        json!({"cmd": "read-screen", "surface": 1}),
        json!({"cmd": "send", "surface": 1, "text": "id\n"}),
        json!({"cmd": "subscribe"}),
        json!({"cmd": "some-future-command"}),
        json!({"no_cmd": true}),
    ] {
        let reply = client.request(request.clone());
        assert_legacy_forbidden(&reply, "page");
        assert_eq!(reply["error_details"]["required"], "agent", "{request} -> {reply}");
    }
    assert_eq!(client.identify()["ok"], true);
}

#[test]
fn a_page_origin_v2_request_cannot_mint() {
    let mux = mux("page-v2");
    let (_, terminal) = terminal(&mux);
    // A page relay connection derives `page` with or without a page claim.
    let mut relay = Client::connect(&mux, "mint-page-v2-relay");
    assert_eq!(relay.hello(json!({"role": "page_relay"}))["ok"], true);
    for origin in [None, Some(json!({"claim": "page"}))] {
        assert_v2_forbidden(&relay.request(v2_grant(&terminal, origin)), "page");
    }
    drop(relay);
    // A local connection that narrows itself to `page` is a page request too.
    let mut local = Client::connect(&mux, "mint-page-v2-local");
    let reply = local.request(v2_grant(&terminal, Some(json!({"claim": "page"}))));
    assert_v2_forbidden(&reply, "page");
}

#[test]
fn a_websocket_connection_cannot_mint() {
    let mux = mux("websocket");
    let (surface, terminal) = terminal(&mux);
    let mut client = Client::connect_with(&mux, "mint-websocket", ClientTransport::WebSocket);
    for request in legacy_mints(surface, &terminal) {
        let reply = client.request(request);
        assert_legacy_forbidden(&reply, "agent");
        assert_eq!(reply["error_details"]["reason"], "local_only", "{reply}");
    }
    let reply = client.request(v2_grant(&terminal, None));
    assert_v2_forbidden(&reply, "agent");
    assert_eq!(reply["error"]["details"]["reason"], "local_only", "{reply}");
}
