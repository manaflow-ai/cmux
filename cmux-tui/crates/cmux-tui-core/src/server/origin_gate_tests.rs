//! The v2 request origin (plans/cmux-next/request-origin.md): derivation,
//! narrowing claims, gate A2 and the confirmation token, driven through the
//! connection message handler.

use serde_json::{Value, json};
use sha2::{Digest, Sha256};

use crate::server::origin_gate::{
    advance_origin_clock_for_test, jump_origin_wall_clock_for_test, set_peer_key_for_test,
    set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;

const TTL_MS: u64 = 60_000;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("origin-{label}"), crate::SurfaceOptions::default())
}

fn connect(mux: &Arc<Mux>) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

/// A page relay connection whose peer is `peer`.
fn relay(mux: &Arc<Mux>, peer: &str) -> Conn {
    let conn = connect(mux);
    set_role_for_test(mux, conn.client, "page_relay");
    set_peer_key_for_test(mux, conn.client, peer);
    conn
}

/// A verified cmux app connection (role main) whose peer is `peer`.
fn verified_app(mux: &Arc<Mux>, peer: &str) -> Conn {
    let conn = connect(mux);
    set_role_for_test(mux, conn.client, "main");
    set_peer_key_for_test(mux, conn.client, peer);
    set_verified_app_for_test(mux, conn.client, true);
    conn
}

fn send(mux: &Arc<Mux>, conn: &Conn, request: &Value) -> Value {
    assert!(handle_connection_message(
        mux,
        conn.client,
        &request.to_string(),
        &conn.writer,
        &conn.scheduler
    ));
    let message = conn.outbound.try_pop().expect("a synchronous reply");
    serde_json::from_str(&message).unwrap()
}

fn v2(operation: &str, params: Value, key: Option<&str>, origin: Option<Value>) -> Value {
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

fn install_params() -> Value {
    json!({"app": "cmux/demo", "version": "1.0.0", "grant_optional": ["b", "a"]})
}

fn install(origin: Option<Value>) -> Value {
    v2("apps.install", install_params(), Some("k1"), origin)
}

fn ping(origin: Option<Value>) -> Value {
    v2("session.ping", json!({"machine": "current", "session": "current"}), None, origin)
}

/// SHA-256 of `{"app":"cmux/demo","grant_optional":["b","a"],"version":"1.0.0"}`:
/// the install params in canonical JSON (sorted keys, no whitespace).
fn install_params_sha256() -> String {
    let canonical = r#"{"app":"cmux/demo","grant_optional":["b","a"],"version":"1.0.0"}"#;
    Sha256::digest(canonical.as_bytes()).iter().map(|byte| format!("{byte:02x}")).collect()
}

fn issue(mux: &Arc<Mux>, caller: &Conn, operation: &str, sha: &str, relay: &Conn) -> Value {
    send(
        mux,
        caller,
        &v2(
            "origin.confirmation.issue",
            json!({
                "machine": "current",
                "session": "current",
                "operation": operation,
                "params_sha256": sha,
                "relay_connection_id": relay.client.to_string(),
            }),
            None,
            None,
        ),
    )
}

fn issued_token(reply: &Value) -> String {
    assert_eq!(reply["ok"], true, "{reply}");
    let token = reply["result"]["token"].as_str().expect("token").to_string();
    assert_eq!(token.len(), 43, "32 bytes base64url without padding: {token}");
    assert!(token.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
    assert!(reply["result"]["expires_at"].is_string(), "{reply}");
    token
}

fn user_claim(token: &str) -> Value {
    json!({"claim": "user", "confirmation": token})
}

fn assert_forbidden(reply: &Value) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
}

fn assert_not_forbidden(reply: &Value) {
    assert_ne!(reply["error"]["code"], "origin.forbidden", "{reply}");
}

fn assert_a2_refusal(reply: &Value, derived: &str) {
    assert_forbidden(reply);
    assert_eq!(reply["error"]["message"], "needs a verified cmux app connection", "{reply}");
    assert_eq!(reply["error"]["details"], json!({"required": "user", "derived": derived}));
}

#[test]
fn gate_a2_refuses_install_uninstall_and_enable_before_p8() {
    let mux = mux("a2");
    let conn = connect(&mux);
    for (operation, params) in [
        ("apps.install", install_params()),
        ("apps.uninstall", json!({"app": "cmux/demo"})),
        ("apps.enable", json!({"app": "cmux/demo"})),
    ] {
        let reply = send(&mux, &conn, &v2(operation, params, Some("k1"), None));
        assert_a2_refusal(&reply, "agent");
    }
}

#[test]
fn a_verified_app_connection_derives_user_and_passes_gate_a2() {
    let mux = mux("a2-user");
    let app = verified_app(&mux, "token:10.1");
    assert_not_forbidden(&send(&mux, &app, &install(None)));
}

#[test]
fn page_relay_request_with_no_origin_derives_page() {
    let mux = mux("relay-page");
    let relay = relay(&mux, "token:10.1");
    assert_a2_refusal(&send(&mux, &relay, &install(None)), "page");
    // Page calls that need no person are served.
    assert_eq!(send(&mux, &relay, &ping(None))["ok"], true);
    assert_eq!(send(&mux, &relay, &ping(Some(json!({"claim": "page"}))))["ok"], true);
}

#[test]
fn page_relay_accepts_only_page_or_confirmed_user_claims() {
    let mux = mux("relay-claims");
    let relay = relay(&mux, "token:10.1");
    for claim in [
        json!({"claim": "user"}),
        json!({"claim": "agent"}),
        json!({"claim": "app"}),
        json!({"claim": "page", "confirmation": "x"}),
        json!({"claim": "user", "confirmation": "not-a-token"}),
    ] {
        assert_forbidden(&send(&mux, &relay, &ping(Some(claim))));
    }
}

#[test]
fn a_client_claim_may_only_narrow() {
    let mux = mux("narrow");
    let conn = connect(&mux);
    // No origin behaves as today.
    assert_eq!(send(&mux, &conn, &ping(None))["ok"], true);
    // Narrowing agent to page is accepted; the gate then sees page.
    assert_eq!(send(&mux, &conn, &ping(Some(json!({"claim": "page"}))))["ok"], true);
    assert_a2_refusal(&send(&mux, &conn, &install(Some(json!({"claim": "page"})))), "page");
    // Widening is refused.
    for claim in ["user", "app"] {
        assert_forbidden(&send(&mux, &conn, &ping(Some(json!({"claim": claim})))));
    }
}

#[test]
fn issue_is_refused_on_a_page_relay_and_on_a_non_verified_connection() {
    let mux = mux("issue-refused");
    let relay = relay(&mux, "token:10.1");
    let sha = install_params_sha256();
    assert_forbidden(&issue(&mux, &relay, "apps.install", &sha, &relay));
    let plain = connect(&mux);
    set_role_for_test(&mux, plain.client, "main");
    set_peer_key_for_test(&mux, plain.client, "token:10.1");
    let reply = issue(&mux, &plain, "apps.install", &sha, &relay);
    assert_forbidden(&reply);
    assert_eq!(reply["error"]["details"]["required"], "user", "{reply}");
}

#[test]
fn issue_with_a_relay_of_another_peer_is_refused() {
    let mux = mux("issue-peer");
    let app = verified_app(&mux, "token:10.1");
    let sha = install_params_sha256();
    // Same pid, other pid version: a different process.
    let other = relay(&mux, "token:10.2");
    assert_forbidden(&issue(&mux, &app, "apps.install", &sha, &other));
    // A connection that is not a page relay is never a relay target.
    let main = verified_app(&mux, "token:10.1");
    assert_forbidden(&issue(&mux, &app, "apps.install", &sha, &main));
}

#[test]
fn a_confirmed_user_claim_passes_once() {
    let mux = mux("token-once");
    let app = verified_app(&mux, "token:10.1");
    let relay = relay(&mux, "token:10.1");
    let token = issued_token(&issue(&mux, &app, "apps.install", &install_params_sha256(), &relay));
    assert_not_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
    // Single use.
    assert_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
}

#[test]
fn a_token_for_other_params_or_another_operation_is_refused() {
    let mux = mux("token-params");
    let app = verified_app(&mux, "token:10.1");
    let relay = relay(&mux, "token:10.1");
    let sha = install_params_sha256();
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &relay));
    let other_params = v2(
        "apps.install",
        json!({"app": "cmux/other", "version": "1.0.0", "grant_optional": ["b", "a"]}),
        Some("k1"),
        Some(user_claim(&token)),
    );
    assert_forbidden(&send(&mux, &relay, &other_params));
    let token = issued_token(&issue(&mux, &app, "apps.uninstall", &sha, &relay));
    assert_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
}

#[test]
fn an_expired_token_is_refused() {
    let mux = mux("token-expired");
    let app = verified_app(&mux, "token:10.1");
    let relay = relay(&mux, "token:10.1");
    let sha = install_params_sha256();
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &relay));
    advance_origin_clock_for_test(&mux, TTL_MS + 1);
    assert_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
    // A token still inside its TTL passes.
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &relay));
    advance_origin_clock_for_test(&mux, TTL_MS - 1_000);
    assert_not_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
}

#[test]
fn a_token_is_consumed_only_on_its_relay_connection() {
    let mux = mux("token-connection");
    let app = verified_app(&mux, "token:10.1");
    let relay_a = relay(&mux, "token:10.1");
    let relay_b = relay(&mux, "token:10.1");
    let token =
        issued_token(&issue(&mux, &app, "apps.install", &install_params_sha256(), &relay_a));
    assert_forbidden(&send(&mux, &relay_b, &install(Some(user_claim(&token)))));
    // A legacy connection cannot present it either.
    let plain = connect(&mux);
    assert_forbidden(&send(&mux, &plain, &install(Some(user_claim(&token)))));
}

const HOUR_MS: i64 = 3_600_000;

#[test]
fn a_token_expires_at_exactly_60_seconds_of_monotonic_time() {
    let mux = mux("token-exact-ttl");
    let app = verified_app(&mux, "token:10.1");
    let relay = relay(&mux, "token:10.1");
    let sha = install_params_sha256();
    // Freeze the test clock so only the steps below move time.
    advance_origin_clock_for_test(&mux, 0);
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &relay));
    advance_origin_clock_for_test(&mux, TTL_MS - 1);
    assert_not_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &relay));
    advance_origin_clock_for_test(&mux, TTL_MS);
    assert_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
}

#[test]
fn a_wall_clock_jump_neither_cuts_nor_extends_a_token() {
    let mux = mux("token-wall-jump");
    let app = verified_app(&mux, "token:10.1");
    let relay = relay(&mux, "token:10.1");
    let sha = install_params_sha256();
    advance_origin_clock_for_test(&mux, 0);
    // A forward wall jump does not cut a live token.
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &relay));
    jump_origin_wall_clock_for_test(&mux, 2 * HOUR_MS);
    assert_not_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
    // A backward wall jump does not extend a token past 60 s.
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &relay));
    jump_origin_wall_clock_for_test(&mux, -2 * HOUR_MS);
    advance_origin_clock_for_test(&mux, TTL_MS);
    assert_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
}

fn apps_set(fields: Value) -> Value {
    let mut request =
        json!({"id": 1, "cmd": "apps-set", "idempotency_key": "k1", "app": "cmux/demo"});
    for (key, value) in fields.as_object().unwrap() {
        request[key] = value.clone();
    }
    request
}

/// Every legacy apps-set change: install, uninstall, enable, disable, hide,
/// sandbox and grant, with and without a claimed origin.
fn apps_set_changes() -> Vec<Value> {
    let mut changes = Vec::new();
    for origin in [None, Some("user"), Some("script")] {
        for fields in [
            json!({"installed": true}),
            json!({"installed": false}),
            json!({"enabled": true}),
            json!({"enabled": false}),
            json!({"hidden": true}),
            json!({"sandboxed": false}),
            json!({"grant": {"scope": "workspace:write", "granted": true}}),
        ] {
            let mut request = apps_set(fields);
            if let Some(origin) = origin {
                request["origin"] = json!(origin);
            }
            changes.push(request);
        }
    }
    changes
}

fn assert_legacy_a2_refusal(reply: &Value, derived: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error_code"], "origin.forbidden", "{reply}");
    assert_eq!(reply["error"], "needs a verified cmux app connection", "{reply}");
    assert_eq!(reply["error_details"], json!({"required": "user", "derived": derived}), "{reply}");
}

#[test]
fn legacy_apps_set_is_refused_from_every_connection_but_the_verified_app() {
    let mux = mux("apps-set-a2");
    let client = connect(&mux);
    let page_relay = relay(&mux, "token:10.1");
    let agent = connect(&mux);
    mux.bind_conversation_principal(agent.client, "agent:test".to_string());
    // A self-declared kind app is still not the verified app.
    let declared_app = connect(&mux);
    mux.control_clients.state.lock().unwrap().clients.get_mut(&declared_app.client).unwrap().kind =
        Some("app".to_string());
    for request in apps_set_changes() {
        assert_legacy_a2_refusal(&send(&mux, &client, &request), "agent");
        assert_legacy_a2_refusal(&send(&mux, &page_relay, &request), "page");
        assert_legacy_a2_refusal(&send(&mux, &agent, &request), "agent");
        assert_legacy_a2_refusal(&send(&mux, &declared_app, &request), "agent");
    }
    // The verified app passes the gate: the request reaches the app
    // supervisor (apps.unavailable in a daemon without an app host).
    let app = verified_app(&mux, "token:10.1");
    for request in apps_set_changes() {
        let reply = send(&mux, &app, &request);
        assert_ne!(reply["error_code"], "origin.forbidden", "{reply}");
        assert_ne!(reply["error_code"], "apps.origin_forbidden", "{reply}");
    }
}

#[test]
fn legacy_user_origin_gestures_need_the_verified_app() {
    let mux = mux("apps-run-a2");
    let gesture = json!({
        "id": 1, "cmd": "apps-run", "origin": "user", "app": "cmux/demo", "op": "demo.go",
        "args": {},
    });
    // A connection that only declares kind app is not the hosting app.
    let declared_app = connect(&mux);
    mux.control_clients.state.lock().unwrap().clients.get_mut(&declared_app.client).unwrap().kind =
        Some("app".to_string());
    let agent = connect(&mux);
    mux.bind_conversation_principal(agent.client, "agent:test".to_string());
    let page_relay = relay(&mux, "token:10.1");
    mux.control_clients.state.lock().unwrap().clients.get_mut(&page_relay.client).unwrap().kind =
        Some("app".to_string());
    assert_legacy_a2_refusal(&send(&mux, &declared_app, &gesture), "agent");
    assert_legacy_a2_refusal(&send(&mux, &agent, &gesture), "agent");
    assert_legacy_a2_refusal(&send(&mux, &page_relay, &gesture), "page");
    // The verified app passes the gate without declaring a kind (the run
    // then reaches the supervisor, apps.unavailable without an app host).
    let app = verified_app(&mux, "token:10.1");
    let reply = send(&mux, &app, &gesture);
    assert_ne!(reply["error_code"], "origin.forbidden", "{reply}");
    assert_ne!(reply["error_code"], "apps.origin_forbidden", "{reply}");
    // Other origins keep working from any local connection.
    let script = json!({
        "id": 2, "cmd": "apps-run", "origin": "script", "app": "cmux/demo", "op": "demo.go",
        "args": {},
    });
    let reply = send(&mux, &agent, &script);
    assert_ne!(reply["error_code"], "origin.forbidden", "{reply}");
}

/// P8 prover B through the real hello: `role` declared in step 1 with peer
/// key `peer`; a role-main hello also runs step 2 with the install key.
fn hello(mux: &Arc<Mux>, role: &str, peer: &str) -> Conn {
    use cmux_local_auth::frontend_proof::{NONCE_LEN, hello_proof, unhex};
    let conn = connect(mux);
    let mut gate = client_hello::HelloGate::new(ClientTransport::Unix);
    let peer = || client_hello::Peer { key: Some(peer.to_string()), token: None };
    let start = json!({"id": 1, "cmd": "client-hello", "role": role, "install_id": "inst_p8"});
    let started = gate.observe(mux, conn.client, &start.to_string(), peer).expect("handled");
    assert_eq!(started["ok"], true, "{started}");
    if role == "main" {
        let nonce = unhex::<NONCE_LEN>(started["data"]["nonce"].as_str().unwrap()).unwrap();
        let key = unhex::<32>(P8_KEY_HEX).unwrap();
        let proof = json!({"id": 2, "cmd": "client-hello", "install_id": "inst_p8",
            "proof": hello_proof(&key, "inst_p8", &nonce)});
        let proved = gate.observe(mux, conn.client, &proof.to_string(), peer).expect("handled");
        assert_eq!(proved["data"]["verified"], true, "{proved}");
    }
    conn
}

const P8_KEY_HEX: &str = "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";

fn keyed_mux(label: &str) -> Arc<Mux> {
    let mux = mux(label);
    let key = FrontendKey::parse(&format!("cmuxik1 inst_p8 {P8_KEY_HEX}")).unwrap();
    assert!(install_frontend_key(&mux, key));
    mux
}

/// P8 (DEV build, prover B): the install-key proof makes the main
/// connection the verified app without changing its peer key, so the page
/// relay of the same process (same audit-token key) gets a confirmation
/// that passes gate A2 once.
#[test]
fn an_install_proved_main_connection_confirms_for_its_own_page_relay() {
    let mux = keyed_mux("p8-same-peer");
    let app = hello(&mux, "main", "token:20.1");
    let relay = hello(&mux, "page_relay", "token:20.1");
    let token = issued_token(&issue(&mux, &app, "apps.install", &install_params_sha256(), &relay));
    assert_not_forbidden(&send(&mux, &relay, &install(Some(user_claim(&token)))));
}

/// P8: another process (another audit-token key) gets nothing from the
/// install proof. A relay of another process is no relay target for the
/// proved main connection, and another process that proves the same install
/// key cannot confirm for this app's relay either.
#[test]
fn another_process_cannot_use_an_install_proved_confirmation() {
    let mux = keyed_mux("p8-other-peer");
    let sha = install_params_sha256();
    let app = hello(&mux, "main", "token:20.1");
    let foreign_relay = hello(&mux, "page_relay", "token:21.1");
    assert_forbidden(&issue(&mux, &app, "apps.install", &sha, &foreign_relay));
    let app_relay = hello(&mux, "page_relay", "token:20.1");
    let foreign_main = hello(&mux, "main", "token:21.1");
    assert_forbidden(&issue(&mux, &foreign_main, "apps.install", &sha, &app_relay));
    // The app's own confirmation stays usable only on its own relay.
    let token = issued_token(&issue(&mux, &app, "apps.install", &sha, &app_relay));
    assert_forbidden(&send(&mux, &foreign_relay, &install(Some(user_claim(&token)))));
    assert_not_forbidden(&send(&mux, &app_relay, &install(Some(user_claim(&token)))));
}
