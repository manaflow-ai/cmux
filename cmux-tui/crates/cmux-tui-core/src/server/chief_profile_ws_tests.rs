//! The person's page manages Chiefs (`chief-profile-ws-v1`, cmux#13742):
//! the request path a page WebSocket and the host's page relay take
//! (`handle_connection_message`: the origin gate, then the Chief registry).
//! The page lists, reads, creates and edits profile text; a grant field or a
//! delete needs the person's gesture, which only the host's page relay
//! brings (a confirmation the verified app issues for exactly that request).
//! A paired device, a bound agent and another page are refused.

use serde_json::{Value, json};

use crate::request_origin::params_sha256;
use crate::server::origin_gate::{
    set_page, set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
};
use crate::server::*;

struct Conn {
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

fn mux(label: &str) -> Arc<Mux> {
    Mux::new_for_test(format!("chief-ws-{label}"), crate::SurfaceOptions::default())
}

fn connect(mux: &Arc<Mux>, transport: ClientTransport) -> Conn {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(transport, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    Conn { client, writer, outbound, scheduler }
}

/// A WebSocket that presented the daemon's own credential, serving `page`.
fn websocket(mux: &Arc<Mux>, page: Option<&str>) -> Conn {
    let conn = connect(mux, ClientTransport::WebSocket);
    if let Some(page) = page {
        set_page(mux, conn.client, page.to_owned());
    }
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

fn params(fields: Value) -> Value {
    let mut params = json!({"machine": "current", "session": "current"});
    for (key, value) in fields.as_object().unwrap() {
        params[key] = value.clone();
    }
    params
}

fn v2(operation: &str, params: &Value, key: Option<&str>, origin: Option<Value>) -> Value {
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "r1",
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    if let Some(origin) = origin {
        request["origin"] = origin;
    }
    request
}

fn ok(reply: &Value) -> Value {
    assert_eq!(reply["ok"], true, "{reply}");
    reply["result"].clone()
}

fn forbidden_reason(reply: &Value) -> String {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], "origin.forbidden", "{reply}");
    reply["error"]["details"]["reason"].as_str().unwrap_or_default().to_owned()
}

fn create(mux: &Arc<Mux>, conn: &Conn, name: &str, key: &str) -> String {
    let made = ok(&send(
        mux,
        conn,
        &v2("chief.profile.create", &params(json!({"display_name": name})), Some(key), None),
    ));
    made["value"]["id"].as_str().unwrap().to_owned()
}

#[test]
fn the_persons_page_websocket_creates_and_edits_chiefs_but_not_their_grants() {
    for page in [None, Some("home-channels")] {
        let mux = mux(page.unwrap_or("nopage"));
        let page_ws = websocket(&mux, page);
        let listed = ok(&send(&mux, &page_ws, &v2("chief.profile.list", &params(json!({})), None, None)));
        assert_eq!(listed["chiefs"][0]["id"], "agent_mux", "{listed}");

        // A create with no grant field gets the default grant.
        let made = ok(&send(
            &mux,
            &page_ws,
            &v2(
                "chief.profile.create",
                &params(json!({"display_name": "Ops", "role": "Release captain",
                               "personality": "Brief.", "instructions": "Ask before a merge."})),
                Some("ws-create-1"),
                None,
            ),
        ));
        let id = made["value"]["id"].as_str().unwrap().to_owned();
        assert_eq!(made["value"]["tools"], json!(["spawn", "tell", "workspaces"]), "{made}");

        let renamed = ok(&send(
            &mux,
            &page_ws,
            &v2(
                "chief.profile.update",
                &params(json!({"chief": id, "display_name": "Ops Chief", "role": "Train"})),
                Some("ws-rename-1"),
                None,
            ),
        ));
        assert_eq!(renamed["value"]["display_name"], "Ops Chief", "{renamed}");

        // Grant fields and delete need the person's gesture: never on a WebSocket.
        for (operation, fields, key) in [
            ("chief.profile.create", json!({"display_name": "Wide", "tools": ["browser"]}), "ws-g1"),
            ("chief.profile.update", json!({"chief": id, "tools": ["browser", "spawn"]}), "ws-g2"),
            ("chief.profile.update", json!({"chief": id, "self_edit": ["role"]}), "ws-g3"),
            ("chief.profile.update", json!({"chief": id, "model": "other"}), "ws-g4"),
            ("chief.profile.delete", json!({"chief": id}), "ws-g5"),
        ] {
            let reply = send(&mux, &page_ws, &v2(operation, &params(fields), Some(key), None));
            assert_eq!(forbidden_reason(&reply), "gesture_required", "{operation}: {reply}");
        }
        let kept = ok(&send(&mux, &page_ws, &v2("chief.profile.get", &params(json!({"chief": id})), None, None)));
        assert_eq!(kept["tools"], json!(["spawn", "tell", "workspaces"]), "{kept}");
        assert_eq!(kept["self_edit"], json!(["avatar"]), "{kept}");
    }
}

#[test]
fn a_paired_device_a_bound_agent_and_another_page_are_refused() {
    let mux = mux("refused");
    let list = v2("chief.profile.list", &params(json!({})), None, None);
    let make = v2("chief.profile.create", &params(json!({"display_name": "X"})), Some("r-1"), None);

    // A paired device: a pairing-store credential with no page.
    let paired = websocket(&mux, None);
    mux.control_clients.mark_person(paired.client);
    for request in [&list, &make] {
        assert_eq!(forbidden_reason(&send(&mux, &paired, request)), "chief_registry_caller");
    }

    // An agent bound to its participant on a WebSocket.
    let agent = websocket(&mux, Some("home-channels"));
    mux.bind_conversation_principal(agent.client, "agent_other".to_owned()).unwrap();
    for request in [&list, &make] {
        assert_eq!(forbidden_reason(&send(&mux, &agent, request)), "chief_registry_caller");
    }

    // Another page: its allow list names no Chief operation.
    let history = websocket(&mux, Some("history"));
    for request in [&list, &make] {
        assert_eq!(forbidden_reason(&send(&mux, &history, request)), "page_not_allowed");
    }
    // The person's own page connection with the app's page credential is the person.
    let app_page = websocket(&mux, Some("home-channels"));
    mux.control_clients.mark_person(app_page.client);
    ok(&send(&mux, &app_page, &list));
}

#[test]
fn the_host_page_relay_changes_grants_and_deletes_only_with_the_persons_gesture() {
    let mux = mux("gesture");
    let app = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, app.client, "main");
    set_peer_key_for_test(&mux, app.client, "token:20.1");
    set_verified_app_for_test(&mux, app.client, true);
    let relay = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, relay.client, "page_relay");
    set_peer_key_for_test(&mux, relay.client, "token:20.1");
    set_page(&mux, relay.client, "home-channels".to_owned());

    let id = create(&mux, &relay, "Ops", "relay-create-1");
    let widen = params(json!({"chief": id, "tools": ["browser", "spawn"]}));
    let delete = params(json!({"chief": id}));

    // No gesture: refused at the page's allow list.
    let refused = send(&mux, &relay, &v2("chief.profile.update", &widen, Some("relay-g1"), None));
    assert_eq!(forbidden_reason(&refused), "gesture_required");
    let refused = send(&mux, &relay, &v2("chief.profile.delete", &delete, Some("relay-d1"), None));
    assert_eq!(forbidden_reason(&refused), "gesture_required");

    // The host spends the person's click: a confirmation for exactly that request.
    let confirm = |operation: &str, params: &Value| {
        let issued = ok(&send(
            &mux,
            &app,
            &v2(
                "origin.confirmation.issue",
                &json!({"machine": "current", "session": "current", "operation": operation,
                        "params_sha256": params_sha256(params),
                        "relay_connection_id": relay.client.to_string()}),
                None,
                None,
            ),
        ));
        json!({"claim": "user", "confirmation": issued["token"]})
    };
    let widened = ok(&send(
        &mux,
        &relay,
        &v2("chief.profile.update", &widen, Some("relay-g2"), Some(confirm("chief.profile.update", &widen))),
    ));
    assert_eq!(widened["value"]["tools"], json!(["browser", "spawn"]), "{widened}");
    let deleted = send(
        &mux,
        &relay,
        &v2("chief.profile.delete", &delete, Some("relay-d2"), Some(confirm("chief.profile.delete", &delete))),
    );
    ok(&deleted);
    let listed = ok(&send(&mux, &relay, &v2("chief.profile.list", &params(json!({})), None, None)));
    let ids: Vec<&str> =
        listed["chiefs"].as_array().unwrap().iter().filter_map(|c| c["id"].as_str()).collect();
    assert_eq!(ids, vec!["agent_mux"], "{listed}");
}
