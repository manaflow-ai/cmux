use super::*;
use crate::SurfaceOptions;
use crate::server::{
    BoundedOutbound, ClientTransport, ConnectionSurfaceScheduler, QueuedSink,
    handle_connection_frame,
};

/// A local connection with `kind`, bound to an agent when `agent`.
fn connection(mux: &Arc<Mux>, kind: Option<&str>, agent: bool) -> (u64, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    mux.control_clients.state.lock().unwrap().clients.get_mut(&client).unwrap().kind =
        kind.map(str::to_string);
    if agent {
        mux.bind_conversation_principal(client, "agent:test".to_string()).unwrap();
    }
    (client, outbound)
}

/// Sends `line` on the local connection `client` through the daemon's frame
/// dispatch, so the line reaches this module by its route as a real one
/// does. Returns the reply and the JSON parses the line took.
fn send_line(mux: &Arc<Mux>, client: u64, outbound: &BoundedOutbound, line: &str) -> (Value, u64) {
    let writer = mux.control_clients.state.lock().unwrap().clients[&client].writer.clone();
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let stats = crate::diagnostics::IpcStats::default();
    {
        let _parses = crate::diagnostics::JsonParseScope::enter(
            &stats,
            crate::diagnostics::IpcTransport::Lines,
        );
        assert!(handle_connection_frame(
            mux,
            client,
            ClientTransport::Unix,
            line,
            &writer,
            &scheduler
        ));
    }
    let reply = serde_json::from_str(&outbound.try_pop().expect("reply")).unwrap();
    (reply, stats.snapshot().parses.lines.json_parses)
}

/// Hands `request` to this module's route entry on `client` (whatever its
/// transport, so the module's own gates answer) and returns the reply's
/// error code (`None` when the reply is ok).
fn error_code(
    mux: &Arc<Mux>,
    client: u64,
    outbound: &BoundedOutbound,
    request: Value,
) -> Option<String> {
    let writer = mux.control_clients.state.lock().unwrap().clients[&client].writer.clone();
    let message = request.to_string();
    let head = crate::server::RequestHead::parse(&message);
    let line = RouteLine { mux, client, message: &message, writer: &writer, head: &head };
    assert_eq!(handle(&line), Some(true));
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("reply")).unwrap();
    reply["error_code"].as_str().map(str::to_string)
}

fn install(origin: &str) -> Value {
    json!({ "id": 1, "cmd": "apps-set", "origin": origin, "idempotency_key": "k1", "app": "cmux/demo", "installed": true })
}

fn grant(origin: &str) -> Value {
    json!({ "id": 2, "cmd": "apps-set", "origin": origin, "idempotency_key": "k2", "app": "cmux/demo", "grant": { "scope": "workspace:write", "granted": true } })
}

const FORBIDDEN: Option<&str> = Some("apps.origin_forbidden");
/// Gate A2 on apps-set (request-origin.md): not a verified app.
const NOT_VERIFIED: Option<&str> = Some("origin.forbidden");

/// Makes `client` a verified cmux app connection (what P8's proof sets).
fn verify(mux: &Arc<Mux>, client: u64) {
    crate::server::origin_gate::set_role_for_test(mux, client, "main");
    crate::server::origin_gate::set_verified_app_for_test(mux, client, true);
}

#[test]
fn apps_set_needs_the_verified_app_and_origin_user_needs_no_agent() {
    let mux = Mux::new_for_test("apps-origin-gate", SurfaceOptions::default());
    // An agent connection is refused even when it is a verified app.
    let (agent, agent_out) = connection(&mux, Some("app"), true);
    for request in [install("user"), grant("user")] {
        assert_eq!(error_code(&mux, agent, &agent_out, request).as_deref(), NOT_VERIFIED);
    }
    // A local client that is not the app is refused too.
    let (cli, cli_out) = connection(&mux, Some("cli"), false);
    for request in [install("user"), grant("user")] {
        assert_eq!(error_code(&mux, cli, &cli_out, request).as_deref(), NOT_VERIFIED);
    }
    // A self-declared kind app is not the verified app.
    let (declared, declared_out) = connection(&mux, Some("app"), false);
    for request in [install("user"), grant("user")] {
        assert_eq!(error_code(&mux, declared, &declared_out, request).as_deref(), NOT_VERIFIED);
    }
    // The verified app passes both gates (the request then reaches the
    // supervisor, or apps.unavailable in a daemon without an app host).
    let (app, app_out) = connection(&mux, Some("app"), false);
    verify(&mux, app);
    for request in [install("user"), grant("user")] {
        let code = error_code(&mux, app, &app_out, request);
        assert!(code.as_deref() != FORBIDDEN && code.as_deref() != NOT_VERIFIED, "{code:?}");
    }
    // A verified connection that is bound to an agent still cannot act
    // with origin user.
    let (agent_app, agent_app_out) = connection(&mux, Some("app"), true);
    verify(&mux, agent_app);
    for request in [install("user"), grant("user")] {
        assert_eq!(error_code(&mux, agent_app, &agent_app_out, request).as_deref(), FORBIDDEN);
    }
}

/// `user_origin_allowed` (the `client-hello` field) matches the door:
/// only the verified app that is not bound to an agent.
#[test]
fn user_origin_allowed_matches_the_apps_door() {
    let mux = Mux::new_for_test("apps-user-origin-allowed", SurfaceOptions::default());
    let (cli, _cli_out) = connection(&mux, Some("app"), false);
    assert!(!user_origin_allowed(&mux, cli));
    let (app, _app_out) = connection(&mux, Some("app"), false);
    verify(&mux, app);
    assert!(user_origin_allowed(&mux, app));
    let (agent_app, _agent_app_out) = connection(&mux, Some("app"), true);
    verify(&mux, agent_app);
    assert!(!user_origin_allowed(&mux, agent_app));
}

/// P8 3b-2: kind `app` is a self-declared label. Provider registration
/// counts only the verified app, never a declared kind or a page relay.
#[test]
fn only_the_verified_app_is_the_hosting_app_for_providers() {
    let mux = Mux::new_for_test("apps-provider-claim", SurfaceOptions::default());
    let (declared, _declared_out) = connection(&mux, Some("app"), false);
    assert!(!claim_for(&mux, declared).verified_app);
    let (relay, _relay_out) = connection(&mux, Some("app"), false);
    crate::server::origin_gate::set_role_for_test(&mux, relay, "page_relay");
    crate::server::origin_gate::set_verified_app_for_test(&mux, relay, true);
    assert!(!claim_for(&mux, relay).verified_app);
    let (app, _app_out) = connection(&mux, None, false);
    verify(&mux, app);
    assert!(claim_for(&mux, app).verified_app);
}

#[test]
fn cmux_next_agent_inventory_invalidation_requires_a_verified_non_agent_local_connection() {
    let mux = Mux::new_for_test("inventory-provider-claim", SurfaceOptions::default());
    let frame = || json!({"id":1,"cmd":"apps-agent-inventory-changed","demand_sequence":u64::MAX});
    let (declared, out) = connection(&mux, Some("app"), false);
    assert_eq!(
        error_code(&mux, declared, &out, frame()).as_deref(),
        Some("apps.provider.forbidden")
    );
    let (agent, out) = connection(&mux, Some("app"), true);
    verify(&mux, agent);
    assert_eq!(error_code(&mux, agent, &out, frame()).as_deref(), Some("apps.provider.forbidden"));
    for transport in [ClientTransport::WebSocket, ClientTransport::Remote] {
        let outbound = Arc::new(BoundedOutbound::default());
        let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
        let client = mux.control_clients.register(transport, writer);
        verify(&mux, client);
        assert_eq!(error_code(&mux, client, &outbound, frame()).as_deref(), Some("apps.local"));
    }
    let (relay, out) = connection(&mux, Some("app"), false);
    crate::server::origin_gate::set_role_for_test(&mux, relay, "page_relay");
    crate::server::origin_gate::set_verified_app_for_test(&mux, relay, true);
    assert_eq!(error_code(&mux, relay, &out, frame()).as_deref(), Some("apps.provider.forbidden"));
}

#[test]
fn cmux_next_agent_inventory_invalidation_rejects_payloads_selectors_and_malformed_sequences() {
    let mux = Mux::new_for_test("inventory-provider-frame", SurfaceOptions::default());
    let (client, out) = connection(&mux, Some("app"), false);
    for key in
        ["origin", "machine", "expected_machine_id", "event", "stream", "clis", "command", "params"]
    {
        let mut frame = json!({"id":1,"cmd":"apps-agent-inventory-changed","demand_sequence":1});
        frame[key] = json!("untrusted");
        assert_eq!(error_code(&mux, client, &out, frame).as_deref(), Some("bad-request"));
    }
    for sequence in [
        Value::Null,
        json!(true),
        json!(-1),
        json!(1.5),
        json!("1"),
        serde_json::from_str("18446744073709551616").unwrap(),
    ] {
        let frame = json!({"id":1,"cmd":"apps-agent-inventory-changed","demand_sequence":sequence});
        assert_eq!(error_code(&mux, client, &out, frame).as_deref(), Some("bad-request"));
    }
    assert_eq!(
        error_code(&mux, client, &out, json!({"id":1,"cmd":"apps-agent-inventory-changed"}))
            .as_deref(),
        Some("bad-request")
    );
    // The full UInt64 range is parsed exactly before the authority gate.
    let frame = json!({"id":1,"cmd":"apps-agent-inventory-changed","demand_sequence":u64::MAX});
    assert_eq!(error_code(&mux, client, &out, frame).as_deref(), Some("apps.provider.forbidden"));
}

#[test]
fn hiding_needs_the_verified_app_and_listing_does_not() {
    let mux = Mux::new_for_test("apps-origin-other", SurfaceOptions::default());
    let hide = |origin: &str| json!({ "id": 3, "cmd": "apps-set", "origin": origin, "idempotency_key": format!("h-{origin}"), "app": "cmux/demo", "hidden": true });
    // apps-set changes apps, so an agent connection cannot hide either
    // (Gate A2 on every apps-set change).
    let (agent, out) = connection(&mux, None, true);
    for origin in ["cli", "script", "mcp"] {
        assert_eq!(error_code(&mux, agent, &out, hide(origin)).as_deref(), NOT_VERIFIED);
    }
    let list = json!({ "id": 4, "cmd": "apps-list" });
    assert_ne!(error_code(&mux, agent, &out, list).as_deref(), NOT_VERIFIED);
    // The verified app hides with any origin.
    let (app, app_out) = connection(&mux, Some("app"), false);
    verify(&mux, app);
    for origin in ["cli", "script", "mcp"] {
        let code = error_code(&mux, app, &app_out, hide(origin));
        assert!(code.as_deref() != FORBIDDEN && code.as_deref() != NOT_VERIFIED, "{code:?}");
    }
}

fn parse(value: Value) -> Request {
    serde_json::from_value(value).expect("request")
}

#[test]
fn requests_parse_with_origin_defaulting_to_cli() {
    let list = parse(json!({ "id": 1, "cmd": "apps-list" }));
    assert!(matches!(list.command, Command::List) && list.origin == crate::apps::Origin::Cli);
    let set = parse(
        json!({ "id": 2, "cmd": "apps-set", "origin": "user", "idempotency_key": "k", "app": "cmux/a", "hidden": true, "grant": { "scope": "agent:read", "granted": true } }),
    );
    assert_eq!(set.origin, crate::apps::Origin::User);
    assert!(matches!(
        set.command,
        Command::Set { hidden: Some(true), grant: Some(GrantParam { granted: true, .. }), .. }
    ));
    let mount = parse(
        json!({ "cmd": "apps-mount", "app": "cmux/a", "interface": "cmux.section/1", "mount_id": "m", "context": { "preview": true } }),
    );
    assert!(
        matches!(mount.command, Command::Mount { ref context, .. } if context["preview"] == true)
    );
    assert!(
        serde_json::from_value::<Request>(json!({ "cmd": "apps-set", "app": "cmux/a" })).is_err(),
        "apps-set needs an idempotency key"
    );
    let register = parse(json!({ "cmd": "apps-provider-register", "families": ["fs", "action"] }));
    assert!(
        matches!(register.command, Command::ProviderRegister { ref families, inventory_watch: false } if families.len() == 2)
    );
    let result = parse(
        json!({ "cmd": "apps-provider-result", "request_id": 4, "ok": false, "body": { "code": "x" } }),
    );
    assert!(matches!(result.command, Command::ProviderResult { request_id: 4, ok: false, .. }));
}

#[test]
fn error_replies_carry_details_and_retryable() {
    let mux = Mux::new_for_test("apps-error-details", SurfaceOptions::default());
    let (client, outbound) = connection(&mux, Some("app"), false);
    let writer = mux.control_clients.state.lock().unwrap().clients[&client].writer.clone();
    let mut error = crate::apps::ApiError::new("cmux.cloud.not_found", "no such machine");
    error.details = Some(json!({ "status": 404, "upstream_code": "vm_not_found" }));
    error.retryable = true;
    assert!(reply(&writer, Some(json!(7)), Err(error)));
    let sent: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!(
        sent,
        json!({ "id": 7, "ok": false, "error": "no such machine", "error_code": "cmux.cloud.not_found",
            "error_details": { "status": 404, "upstream_code": "vm_not_found" }, "retryable": true })
    );
    // Without details the reply still says whether a retry may help.
    assert!(reply(&writer, Some(json!(8)), Err(crate::apps::ApiError::new("apps.unknown", "no"))));
    let plain: Value = serde_json::from_str(&outbound.try_pop().unwrap()).unwrap();
    assert_eq!((plain.get("error_details"), plain["retryable"].clone()), (None, json!(false)));
}

/// The CLI's Ctrl-C (spec/cli.md "apps run"): `cancel-request` on the
/// connection that sent the `apps-run` reaches the apps door and is
/// answered `{}`, also when no such run exists (an unknown or answered
/// request changes nothing).
#[test]
fn a_cancel_request_is_answered_on_the_apps_door() {
    let mux = Mux::new_for_test("apps-cancel-request", SurfaceOptions::default());
    let (cli, out) = connection(&mux, Some("cli"), false);
    let cancel =
        json!({ "id": "cancel-request-1", "cmd": "cancel-request", "target": "apps-run-1" });
    let (reply, _) = send_line(&mux, cli, &out, &cancel.to_string());
    assert_eq!(
        (reply["id"].clone(), reply["ok"].clone(), reply["data"].clone()),
        (json!("cancel-request-1"), json!(true), json!({}))
    );
    // Without a target the frame is a bad request, not silence.
    let bad = json!({ "id": 2, "cmd": "cancel-request" });
    let (reply, _) = send_line(&mux, cli, &out, &bad.to_string());
    assert_eq!(reply["error_code"], "bad-request");
}

/// The route is found by the line's decoded `cmd`, never a substring of the
/// raw line: an `apps-*` or `cancel-request` name spelled with
/// a JSON escape answers as its plain spelling, and every line, accepted or
/// refused, takes two parses (the head and the route's one decode).
#[test]
fn cmux_next_apps_routes_by_the_decoded_cmd_and_decodes_once() {
    let mux = Mux::new_for_test("apps-routes-decoded-cmd", SurfaceOptions::default());
    let (cli, out) = connection(&mux, Some("cli"), false);
    // The JSON escape of `-`.
    let dash = "\\u002d";
    let cases = [
        // Answered by the door (an app host or `apps.unavailable`).
        (
            r#"{"id":1,"cmd":"apps-list"}"#.to_string(),
            format!(r#"{{"id":1,"cmd":"apps{dash}list"}}"#),
        ),
        // Refused by the typed parse: apps-set needs an idempotency key.
        (
            r#"{"id":2,"cmd":"apps-set","app":"cmux/a"}"#.to_string(),
            format!(r#"{{"id":2,"cmd":"apps{dash}set","app":"cmux/a"}}"#),
        ),
        // Refused by Gate A2: apps-set needs the verified app.
        (
            r#"{"id":3,"cmd":"apps-set","idempotency_key":"k","app":"cmux/a","installed":true}"#
                .to_string(),
            format!(
                r#"{{"id":3,"cmd":"apps{dash}set","idempotency_key":"k","app":"cmux/a","installed":true}}"#
            ),
        ),
        (
            r#"{"id":4,"cmd":"cancel-request","target":"apps-run-1"}"#.to_string(),
            format!(r#"{{"id":4,"cmd":"cancel{dash}request","target":"apps-run-1"}}"#),
        ),
    ];
    for (plain, escaped) in &cases {
        let (expected, parses) = send_line(&mux, cli, &out, plain);
        assert_eq!(parses, 2, "{plain}: the head and the route's decode");
        let (routed, parses) = send_line(&mux, cli, &out, escaped);
        assert_eq!(routed, expected, "{escaped}");
        assert_eq!(parses, 2, "{escaped}");
    }
    // A repeated `cmd` routes and decodes by its last value, as the head
    // reads it: the earlier `apps-set` is not what answers.
    let repeated = r#"{"id":5,"cmd":"apps-set","cmd":"cancel-request","target":"apps-run-1"}"#;
    let (reply, _) = send_line(&mux, cli, &out, repeated);
    assert_eq!((reply["id"].clone(), reply["data"].clone()), (json!(5), json!({})), "{reply}");
    // A null id is answered as null.
    let (reply, _) = send_line(&mux, cli, &out, r#"{"id":null,"cmd":"cancel-request"}"#);
    assert_eq!(reply.get("id"), Some(&Value::Null), "{reply}");
    assert_eq!(reply["error_code"], "bad-request");
}

/// `identify` advertises cancel-request-v1 exactly when it advertises
/// apps-v1: the frame cancels `apps-run` requests, so a daemon without
/// an app host does not offer it (the CLI then closes the connection).
#[test]
fn cancel_request_is_advertised_with_the_app_host() {
    assert_eq!(
        crate::apps::advertised_with(true),
        vec![crate::apps::CAPABILITY, crate::apps::CANCEL_REQUEST_CAPABILITY]
    );
    assert!(crate::apps::advertised_with(false).is_empty());
    assert_eq!(crate::apps::CANCEL_REQUEST_CAPABILITY, "cancel-request-v1");
}

/// A deserializer error that keeps the variant list serde gives
/// `unknown_variant`, so the test reads `Command`'s wire names from the
/// derive itself and not from an error message.
#[derive(Debug)]
enum VariantList {
    Variants(&'static [&'static str]),
    Other(String),
}

impl std::fmt::Display for VariantList {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(formatter, "{self:?}")
    }
}

impl std::error::Error for VariantList {}

impl serde::de::Error for VariantList {
    fn custom<T: std::fmt::Display>(message: T) -> Self {
        Self::Other(message.to_string())
    }

    fn unknown_variant(_variant: &str, expected: &'static [&'static str]) -> Self {
        Self::Variants(expected)
    }
}

/// Every serde name of this module's `Command` enum.
fn apps_command_names() -> Vec<&'static str> {
    let deserializer = serde::de::value::MapDeserializer::<_, VariantList>::new(std::iter::once((
        "cmd",
        "__no_such_command__",
    )));
    match Command::deserialize(deserializer) {
        Err(VariantList::Variants(names)) => names.to_vec(),
        Err(VariantList::Other(message)) => panic!("no variant list: {message}"),
        Ok(_) => panic!("an unknown command was accepted"),
    }
}

/// The SDK schema (spec/sdk-schema.json) describes exactly
/// the commands this door serves: the `apps` family holds them and no
/// other, each is local-admin (the door refuses non-Unix connections) and
/// names the capability `identify` advertises for it.
#[test]
fn every_apps_command_is_in_the_sdk_schema() {
    let schema: Value =
        serde_json::from_str(include_str!("../../../../spec/sdk-schema.json")).unwrap();
    let family = schema["families"]["apps"]["id"].as_u64().expect("the apps family");
    let mut served = apps_command_names();
    served.push("cancel-request");
    let mut in_family: Vec<&str> = schema["commands"]
        .as_object()
        .expect("the schema's commands")
        .iter()
        .filter(|(_, command)| command["method_id"].as_u64().map(|id| id >> 8) == Some(family))
        .map(|(name, _)| name.as_str())
        .collect();
    served.sort_unstable();
    in_family.sort_unstable();
    assert_eq!(in_family, served);
    let invalidation = crate::apps::AGENT_INVENTORY_INVALIDATION_CAPABILITY;
    let capability = |name: &str| match name {
        "cancel-request" => crate::apps::CANCEL_REQUEST_CAPABILITY,
        "apps-agent-inventory-changed" => invalidation,
        _ => crate::apps::CAPABILITY,
    };
    for name in served {
        let command = &schema["commands"][name];
        assert_eq!(command["authority"], "local-admin", "{name}");
        assert_eq!(command["capability"], capability(name), "{name}");
    }
    // An apps-v1 daemon older than the inventory watch ignores
    // inventory_watch, so the field and its answer carry their own gate.
    let register = &schema["commands"]["apps-provider-register"]["request"]["fields"];
    assert_eq!(register["inventory_watch"]["capability"], invalidation);
    let result = &schema["types"]["AppsProviderRegisterResult"]["fields"];
    assert_eq!(result["inventory_demand"]["capability"], invalidation);
}

#[test]
fn a_client_open_token_is_not_part_of_an_apps_run_request() {
    // The supervisor alone mints open tokens; a client's top-level one is
    // not a field of the request, so it is dropped while parsing.
    let run = parse(
        json!({ "id": 5, "cmd": "apps-run", "origin": "user", "app": "cmux/a", "op": "a.go", "open_token": "forged", "args": {} }),
    );
    let Command::Run { args, .. } = run.command else { panic!("apps-run") };
    assert_eq!(args, json!({}));
}

#[test]
fn the_app_supervisor_starts_off_the_daemon_startup_path() {
    // The job stands in for building the supervisor; it blocks until
    // released, and the caller must already have returned.
    let (release, wait) = std::sync::mpsc::channel::<()>();
    let (done, finished) = std::sync::mpsc::channel::<()>();
    let handle = spawn_off_startup(move || {
        wait.recv().unwrap();
        done.send(()).unwrap();
    })
    .unwrap();
    assert!(finished.try_recv().is_err(), "the caller returned while the start still runs");
    release.send(()).unwrap();
    handle.join().unwrap();
    assert!(finished.try_recv().is_ok());
    // Without an app host (no apps-v1) nothing starts and nothing blocks.
    let mux = Mux::new_for_test("apps-start-off-path", SurfaceOptions::default());
    start_apps_when_ready(&mux);
}
