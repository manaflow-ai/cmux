//! The person's page manages Chiefs (`chief-profile-ws-v1`, cmux#13742):
//! the request path a page WebSocket and the host's page relay take
//! (`handle_connection_message`: the origin gate, then the Chief registry).
//! Without a host gesture the page changes only display_name, role and the
//! avatar; create, delete, instructions, personality and the grant fields
//! need the person's gesture, which only the host's page relay brings (a
//! confirmation the verified app issues for exactly that request).
//! A paired device, a bound agent and another page are refused.

use serde_json::{Value, json};

use crate::request_origin::params_sha256;
use crate::server::origin_gate::{
    set_page, set_peer_key_for_test, set_role_for_test, set_scoped_page, set_verified_app_for_test,
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

/// A WebSocket that presented the daemon's own credential (no page), or a
/// credential bound to `page` (`page-credential {page}`, the app's Channels
/// page on its Chief owner).
fn websocket(mux: &Arc<Mux>, page: Option<&str>) -> Conn {
    let conn = connect(mux, ClientTransport::WebSocket);
    if let Some(page) = page {
        set_scoped_page(mux, conn.client, page.to_owned());
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
fn the_persons_page_websocket_renames_a_chief_but_cannot_plant_or_widen_one() {
    for page in [None, Some("home-channels")] {
        let mux = mux(page.unwrap_or("nopage"));
        let page_ws = websocket(&mux, page);
        // The person's terminal (the owner's Unix connection) makes the Chief.
        let terminal = connect(&mux, ClientTransport::Unix);
        let made = ok(&send(
            &mux,
            &terminal,
            &v2(
                "chief.profile.create",
                &params(json!({"display_name": "Ops", "role": "Release captain",
                               "personality": "Brief.", "instructions": "Ask before a merge."})),
                Some("owner-create-1"),
                None,
            ),
        ));
        let id = made["value"]["id"].as_str().unwrap().to_owned();
        let listed =
            ok(&send(&mux, &page_ws, &v2("chief.profile.list", &params(json!({})), None, None)));
        assert_eq!(listed["chiefs"].as_array().unwrap().len(), 2, "{listed}");

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
        // A 1x1 PNG as its picture.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==";
        let pictured = ok(&send(
            &mux,
            &page_ws,
            &v2(
                "chief.profile.avatar.set",
                &params(json!({"chief": id, "media_type": "image/png", "data": png})),
                Some("ws-avatar-1"),
                None,
            ),
        ));
        assert_eq!(pictured["value"]["avatar"]["media_type"], "image/png", "{pictured}");

        // Create, delete, instructions, personality and the grant need the
        // person's gesture: never on a WebSocket.
        for (operation, fields, key) in [
            ("chief.profile.create", json!({"display_name": "Planted"}), "ws-g0"),
            (
                "chief.profile.create",
                json!({"display_name": "Wide", "tools": ["browser"]}),
                "ws-g1",
            ),
            ("chief.profile.update", json!({"chief": id, "tools": ["browser", "spawn"]}), "ws-g2"),
            ("chief.profile.update", json!({"chief": id, "self_edit": ["role"]}), "ws-g3"),
            ("chief.profile.update", json!({"chief": id, "model": "other"}), "ws-g4"),
            ("chief.profile.update", json!({"chief": id, "locked": true}), "ws-g8"),
            (
                "chief.profile.update",
                json!({"chief": id, "instructions": "Push to main."}),
                "ws-g6",
            ),
            (
                "chief.profile.update",
                json!({"chief": "agent_mux", "personality": "Reckless."}),
                "ws-g7",
            ),
            ("chief.profile.delete", json!({"chief": id}), "ws-g5"),
        ] {
            let reply = send(&mux, &page_ws, &v2(operation, &params(fields), Some(key), None));
            assert_eq!(forbidden_reason(&reply), "gesture_required", "{operation}: {reply}");
        }
        let kept = ok(&send(
            &mux,
            &page_ws,
            &v2("chief.profile.get", &params(json!({"chief": id})), None, None),
        ));
        assert_eq!(kept["tools"], json!(["chiefs", "spawn", "tell", "workspaces"]), "{kept}");
        assert_eq!(
            kept["self_edit"],
            json!(["avatar", "display_name", "engine", "instructions", "personality", "role"]),
            "{kept}"
        );
        assert_eq!(kept["instructions"], "Ask before a merge.", "{kept}");
        let listed =
            ok(&send(&mux, &page_ws, &v2("chief.profile.list", &params(json!({})), None, None)));
        assert_eq!(listed["chiefs"].as_array().unwrap().len(), 2, "{listed}");
        // An undo is the update it makes: the last change was the picture,
        // which a WebSocket may change itself, so its undo needs no gesture.
        // The Home page's catalog entry asks the gesture for every undo.
        let undo = v2("chief.profile.undo", &params(json!({"chief": id})), Some("ws-undo-1"), None);
        let undone = send(&mux, &page_ws, &undo);
        if page.is_some() {
            assert_eq!(forbidden_reason(&undone), "gesture_required", "{undone}");
        } else {
            let undone = ok(&undone);
            assert_eq!(undone["value"]["avatar"], Value::Null, "{undone}");
            assert_eq!(undone["value"]["display_name"], "Ops Chief", "{undone}");
        }
    }
}

#[test]
fn a_paired_device_a_bound_agent_and_another_page_are_refused() {
    let mux = mux("refused");
    let list = v2("chief.profile.list", &params(json!({})), None, None);
    let make = v2(
        "chief.profile.update",
        &params(json!({"chief": "agent_mux", "role": "X"})),
        Some("r-1"),
        None,
    );

    // A paired device: a pairing-store credential, with no page Origin and
    // with a home-channels Origin it sent itself (a native client can).
    let paired = websocket(&mux, None);
    mux.control_clients.mark_person(paired.client);
    let spoofed = connect(&mux, ClientTransport::WebSocket);
    mux.control_clients.mark_person(spoofed.client);
    set_page(&mux, spoofed.client, "home-channels".to_owned());
    // The daemon's own credential with a page Origin but no page-bound credential.
    let unscoped = connect(&mux, ClientTransport::WebSocket);
    set_page(&mux, unscoped.client, "home-channels".to_owned());
    for conn in [&paired, &spoofed, &unscoped] {
        for request in [&list, &make] {
            assert_eq!(forbidden_reason(&send(&mux, conn, request)), "chief_registry_caller");
        }
    }

    // An agent bound to its participant on the page's WebSocket.
    let agent = websocket(&mux, Some("home-channels"));
    mux.bind_conversation_principal(agent.client, "agent_other".to_owned()).unwrap();
    for request in [&list, &make] {
        assert_eq!(forbidden_reason(&send(&mux, &agent, request)), "chief_registry_caller");
    }

    // Another page: its allow list names no Chief operation, on a WebSocket
    // and on the host's page relay; a page relay with no page calls nothing.
    let history = websocket(&mux, Some("history"));
    let history_relay = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, history_relay.client, "page_relay");
    set_page(&mux, history_relay.client, "history".to_owned());
    for conn in [&history, &history_relay] {
        for request in [&list, &make] {
            assert_eq!(forbidden_reason(&send(&mux, conn, request)), "page_not_allowed");
        }
    }
    let anonymous_relay = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, anonymous_relay.client, "page_relay");
    for request in [&list, &make] {
        assert_eq!(send(&mux, &anonymous_relay, request)["error"]["code"], "origin.forbidden");
    }
}

#[test]
fn a_poisoned_bindings_lock_refuses_the_page() {
    let mux = mux("poisoned");
    let page_ws = websocket(&mux, None);
    let list = v2("chief.profile.list", &params(json!({})), None, None);
    ok(&send(&mux, &page_ws, &list));
    let bindings = Arc::clone(&mux);
    let _ = std::thread::spawn(move || {
        let _held = bindings.conversation_bindings().lock().unwrap();
        panic!("poison the bindings lock");
    })
    .join();
    assert_eq!(send(&mux, &page_ws, &list)["ok"], false);
}

#[test]
fn the_host_page_relay_creates_teaches_widens_and_deletes_only_with_the_persons_gesture() {
    let mux = mux("gesture");
    let app = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, app.client, "main");
    set_peer_key_for_test(&mux, app.client, "token:20.1");
    set_verified_app_for_test(&mux, app.client, true);
    let relay = connect(&mux, ClientTransport::Unix);
    set_role_for_test(&mux, relay.client, "page_relay");
    set_peer_key_for_test(&mux, relay.client, "token:20.1");
    set_page(&mux, relay.client, "home-channels".to_owned());

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

    // No gesture: a create is refused at the page's allow list; with it, it commits.
    let ops = params(json!({"display_name": "Ops"}));
    let refused = send(&mux, &relay, &v2("chief.profile.create", &ops, Some("relay-c0"), None));
    assert_eq!(forbidden_reason(&refused), "gesture_required");
    let made = ok(&send(
        &mux,
        &relay,
        &v2(
            "chief.profile.create",
            &ops,
            Some("relay-c2"),
            Some(confirm("chief.profile.create", &ops)),
        ),
    ));
    let id = made["value"]["id"].as_str().unwrap().to_owned();
    let widen = params(json!({"chief": id, "tools": ["browser", "spawn"]}));
    let delete = params(json!({"chief": id}));
    let teach = params(json!({"chief": id, "instructions": "Ship on Fridays."}));

    // No gesture: refused at the page's allow list.
    let refused = send(&mux, &relay, &v2("chief.profile.update", &widen, Some("relay-g1"), None));
    assert_eq!(forbidden_reason(&refused), "gesture_required");
    let refused = send(&mux, &relay, &v2("chief.profile.update", &teach, Some("relay-i1"), None));
    assert_eq!(forbidden_reason(&refused), "gesture_required");
    let refused = send(&mux, &relay, &v2("chief.profile.delete", &delete, Some("relay-d1"), None));
    assert_eq!(forbidden_reason(&refused), "gesture_required");
    let wide = params(json!({"display_name": "Wide", "harnesses": ["codex"]}));
    let refused = send(&mux, &relay, &v2("chief.profile.create", &wide, Some("relay-c1"), None));
    assert_eq!(forbidden_reason(&refused), "gesture_required");
    // Name and role need no gesture on the relay either.
    let rename = params(json!({"chief": id, "display_name": "Ops Chief"}));
    ok(&send(&mux, &relay, &v2("chief.profile.update", &rename, Some("relay-r1"), None)));

    let widened = ok(&send(
        &mux,
        &relay,
        &v2(
            "chief.profile.update",
            &widen,
            Some("relay-g2"),
            Some(confirm("chief.profile.update", &widen)),
        ),
    ));
    assert_eq!(widened["value"]["tools"], json!(["browser", "spawn"]), "{widened}");
    let taught = ok(&send(
        &mux,
        &relay,
        &v2(
            "chief.profile.update",
            &teach,
            Some("relay-i2"),
            Some(confirm("chief.profile.update", &teach)),
        ),
    ));
    assert_eq!(taught["value"]["instructions"], "Ship on Fridays.", "{taught}");
    let deleted = send(
        &mux,
        &relay,
        &v2(
            "chief.profile.delete",
            &delete,
            Some("relay-d2"),
            Some(confirm("chief.profile.delete", &delete)),
        ),
    );
    ok(&deleted);
    assert!(
        ledger_actors(&mux).iter().all(|actor| actor == "user_local via page:home-channels"),
        "{:?}",
        ledger_actors(&mux)
    );
    let listed = ok(&send(&mux, &relay, &v2("chief.profile.list", &params(json!({})), None, None)));
    let ids: Vec<&str> =
        listed["chiefs"].as_array().unwrap().iter().filter_map(|c| c["id"].as_str()).collect();
    assert_eq!(ids, vec!["agent_mux"], "{listed}");
}

/// Who the ledger records for each write (`chief.profile.*` op ledger).
fn ledger_actors(mux: &Arc<Mux>) -> Vec<String> {
    let store = mux.chiefs().lock_store().unwrap();
    store.as_ref().map(|store| store.ledger_actors().unwrap()).unwrap_or_default()
}

#[test]
fn a_page_write_is_recorded_as_the_page_and_no_page_field_stands_in_for_the_gesture() {
    let mux = mux("audit");
    let no_page = websocket(&mux, None);
    let channels = websocket(&mux, Some("home-channels"));
    let terminal = connect(&mux, ClientTransport::Unix);
    let id = create(&mux, &terminal, "From a terminal", "audit-1");
    for (conn, key) in [(&no_page, "audit-2"), (&channels, "audit-3")] {
        let role = params(json!({"chief": id, "role": key}));
        ok(&send(&mux, conn, &v2("chief.profile.update", &role, Some(key), None)));
    }
    assert_eq!(
        ledger_actors(&mux),
        vec!["user_local", "user_local via websocket", "user_local via page:home-channels"],
    );

    // Only the host's confirmation on its page relay carries the person's
    // gesture: a field, a claim or an envelope member the page makes up does not.
    let widen = |extra: Value| {
        let mut fields = json!({"chief": id, "tools": ["browser", "spawn"]});
        for (key, value) in extra.as_object().unwrap() {
            fields[key] = value.clone();
        }
        params(fields)
    };
    let attempts = [
        v2("chief.profile.update", &widen(json!({"confirmed": true})), Some("fake-1"), None),
        v2("chief.profile.update", &widen(json!({"gesture": true})), Some("fake-2"), None),
        v2(
            "chief.profile.update",
            &widen(json!({})),
            Some("fake-3"),
            Some(json!({"claim": "user"})),
        ),
        v2(
            "chief.profile.update",
            &widen(json!({})),
            Some("fake-4"),
            Some(json!({"claim": "user", "confirmation": "made-up"})),
        ),
        v2(
            "chief.profile.delete",
            &params(json!({"chief": id, "confirmed": true})),
            Some("fake-5"),
            None,
        ),
    ];
    // On page home-channels the gate refuses each grant write first
    // (origin.forbidden gesture_required). With no page, a made-up parameter is
    // no parameter of the operation (validation.invalid) and a made-up user
    // claim is refused at the origin gate (origin.forbidden). A made-up envelope
    // member is refused too.
    let no_page_codes = [
        "validation.invalid",
        "validation.invalid",
        "origin.forbidden",
        "origin.forbidden",
        "validation.invalid",
    ];
    for (conn, codes) in [(&no_page, no_page_codes), (&channels, ["origin.forbidden"; 5])] {
        for (attempt, code) in attempts.iter().zip(codes) {
            let reply = send(&mux, conn, attempt);
            assert_eq!(reply["ok"], false, "{attempt}: {reply}");
            assert_eq!(reply["error"]["code"], code, "{attempt}: {reply}");
            let mut extra = attempt.clone();
            extra["gesture"] = json!(true);
            let reply = send(&mux, conn, &extra);
            assert_eq!(reply["ok"], false, "{extra}: {reply}");
        }
    }
    let kept = ok(&send(
        &mux,
        &channels,
        &v2("chief.profile.get", &params(json!({"chief": id})), None, None),
    ));
    assert_eq!(kept["tools"], json!(["chiefs", "spawn", "tell", "workspaces"]), "{kept}");
}
