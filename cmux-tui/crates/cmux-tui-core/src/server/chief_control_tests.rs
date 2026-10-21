//! `chief.engine.get|set`, `chief.stop` and `chief.settings.get|set`: the
//! owner's trusted connection only, forwarded to the brain's tools socket as
//! optchat-chief's `engine`, `stop` and `settings` tools, its answer and
//! refusals mapped to the v2 result.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::Mutex as StdMutex;

use super::super::*;
use super::{ask, handle_with, require_owner, result, tool_line};

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

/// A fake brain tools socket: answers each line with `reply` and keeps the
/// lines it got.
fn brain(reply: Value) -> (cmux_unix_socket::TestDir, PathBuf, Arc<StdMutex<Vec<Value>>>) {
    let dir = cmux_unix_socket::short_test_dir("chctl");
    let path = dir.path().join("tools.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let seen = Arc::new(StdMutex::new(Vec::new()));
    let lines = seen.clone();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let mut out = conn.try_clone().unwrap();
            let mut line = String::new();
            if BufReader::new(conn).read_line(&mut line).is_ok() {
                lines.lock().unwrap().push(serde_json::from_str(&line).unwrap_or(Value::Null));
                let _ = writeln!(out, "{reply}");
            }
        }
    });
    (dir, path, seen)
}

fn fields(value: Value) -> serde_json::Map<String, Value> {
    value.as_object().cloned().unwrap()
}

#[test]
fn only_the_owner_connection_controls_the_chief() {
    let mux = Mux::new_for_test("chief-control", crate::SurfaceOptions::default());
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    assert!(require_owner(&mux, owner).is_ok());
    for transport in [ClientTransport::Remote, ClientTransport::WebSocket] {
        let other = mux.control_clients.register(transport, writer());
        assert_eq!(require_owner(&mux, other).unwrap_err().code, "origin.forbidden");
    }
    // An agent-bound connection (the Chief's own turn) is refused too.
    let token = handle_command(
        &mux,
        owner,
        serde_json::from_value(json!({"cmd":"conversation-agent-token","participant":"agent_mux"}))
            .unwrap(),
        &writer(),
    )
    .unwrap()["token"]
        .clone();
    let agent = mux.control_clients.register(ClientTransport::Unix, writer());
    handle_command(
        &mux,
        agent,
        serde_json::from_value(
            json!({"cmd":"conversation-bind","participant":"agent_mux","token":token}),
        )
        .unwrap(),
        &writer(),
    )
    .unwrap();
    let refused = require_owner(&mux, agent).unwrap_err();
    assert_eq!(refused.code, "origin.forbidden");
    assert_eq!(refused.details["reason"], "chief_owner_only");
}

#[test]
fn each_operation_is_one_brain_tool_line() {
    assert_eq!(
        tool_line(ResourceOperation::ChiefEngineGet, &fields(json!({}))),
        json!({"tool":"engine","action":"show"})
    );
    assert_eq!(
        tool_line(ResourceOperation::ChiefEngineSet, &fields(json!({"model":"m","effort":"high"}))),
        json!({"tool":"engine","action":"set","model":"m","effort":"high"})
    );
    assert_eq!(tool_line(ResourceOperation::ChiefStop, &fields(json!({}))), json!({"tool":"stop"}));
}

#[test]
fn the_brain_answer_becomes_the_v2_result() {
    let mux = Mux::new_for_test("chief-control", crate::SurfaceOptions::default());
    let report = json!({"engine":{"harness":"claude","model":"m","effort":"high"},"choice":{},"last_turn":null,"recent":[]});
    let (_dir, sock, seen) = brain(report.clone());
    let line = tool_line(ResourceOperation::ChiefEngineSet, &fields(json!({"effort":"high"})));
    let answer = ask(ResourceOperation::ChiefEngineSet, &line, Some(&sock));
    let set = result(&mux, ResourceOperation::ChiefEngineSet, answer).unwrap();
    assert_eq!(set["value"], report);
    assert_eq!(set["replayed"], false);
    assert_eq!(seen.lock().unwrap()[0], json!({"tool":"engine","action":"set","effort":"high"}));
    let get = result(&mux, ResourceOperation::ChiefEngineGet, Ok(report.clone())).unwrap();
    assert_eq!(get, report);
    let stop = result(&mux, ResourceOperation::ChiefStop, Ok(json!({"stopped":true}))).unwrap();
    assert_eq!(stop["value"], json!({"stopped":true}));
}

#[test]
fn a_brain_refusal_keeps_its_code_and_text() {
    let mux = Mux::new_for_test("chief-control", crate::SurfaceOptions::default());
    let refusal = json!({"error":{"code":"unknown_harness","message":"known: claude, codex"}});
    let error = result(&mux, ResourceOperation::ChiefEngineSet, Ok(refusal)).unwrap_err();
    assert_eq!(error.code, "operation.failed");
    assert_eq!(error.details["reason"], "unknown_harness");
    assert_eq!(error.details["extra"]["message"], "known: claude, codex");
    let missing = Path::new("/nonexistent/cmux-chief-tools.sock");
    let error =
        ask(ResourceOperation::ChiefStop, &json!({"tool":"stop"}), Some(missing)).unwrap_err();
    assert_eq!(error.details["reason"], "unavailable");
}

/// Runs `operation` through the origin gate's parse and `handle_with` on
/// `client`, with the fake brain at `socket`; the response line.
fn call(mux: &Arc<Mux>, client: u64, operation: &str, socket: &Path) -> Value {
    call_with(mux, client, operation, json!({}), socket)
}

/// [`call`] with `extra` params beside the selectors.
fn call_with(mux: &Arc<Mux>, client: u64, operation: &str, extra: Value, socket: &Path) -> Value {
    let (writer, outbound) = tests::captured_writer();
    let mut params = json!({"machine":"current","session":"current"});
    for (key, value) in extra.as_object().cloned().unwrap_or_default() {
        params[key] = value;
    }
    let mut line = json!({"protocol":"cmux.protocol/2","type":"request","id":"c","operation":operation,
                          "params":params});
    if !operation.ends_with(".get") {
        line["idempotency_key"] = json!("k1");
    }
    let line = line.to_string();
    let actor = crate::workspace_registry::Actor::local_user();
    let request = crate::resource_router::parse_resource_request_as(&line, actor).unwrap();
    assert!(handle_with(mux, client, request, &writer, Some(socket.to_owned())));
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if let Some(line) = outbound.try_pop() {
            return serde_json::from_str(&line).unwrap();
        }
        assert!(Instant::now() < deadline, "no response within 5 s");
        std::thread::yield_now();
    }
}

#[test]
fn an_agent_bound_connection_reaches_nothing_and_the_owner_reaches_the_brain() {
    let mux = Mux::new_for_test("chief-control-gate", crate::SurfaceOptions::default());
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    let token = handle_command(
        &mux,
        owner,
        serde_json::from_value(json!({"cmd":"conversation-agent-token","participant":"agent_mux"}))
            .unwrap(),
        &writer(),
    )
    .unwrap()["token"]
        .clone();
    let agent = mux.control_clients.register(ClientTransport::Unix, writer());
    handle_command(
        &mux,
        agent,
        serde_json::from_value(
            json!({"cmd":"conversation-bind","participant":"agent_mux","token":token}),
        )
        .unwrap(),
        &writer(),
    )
    .unwrap();
    let (_dir, sock, seen) = brain(json!({"stopped": true}));
    for operation in [
        "chief.stop",
        "chief.engine.set",
        "chief.engine.get",
        "chief.settings.get",
        "chief.settings.set",
    ] {
        let extra = if operation == "chief.settings.set" {
            json!({"key": "approvals.autoApproveAll", "value": "true"})
        } else {
            json!({})
        };
        let refused = call_with(&mux, agent, operation, extra, &sock);
        assert_eq!(refused["error"]["code"], "origin.forbidden", "{operation}: {refused}");
    }
    assert!(seen.lock().unwrap().is_empty(), "nothing reached the brain");
    let stopped = call(&mux, owner, "chief.stop", &sock);
    assert_eq!(stopped["result"]["value"]["stopped"], true, "{stopped}");
    assert_eq!(seen.lock().unwrap().as_slice(), [json!({"tool":"stop"})]);
}

/// chief.engine.set forwards speed and the compactor's speed, harness and
/// model; chief.stop forwards
/// a subagent's name, and its result keeps the brain's subagents and note.
#[test]
fn engine_speed_and_a_named_stop_reach_the_brain() {
    assert_eq!(
        tool_line(
            ResourceOperation::ChiefEngineSet,
            &fields(
                json!({"speed":"fast","compactor_speed":"default","compactor_harness":"claude-sr","compactor_model":"default"})
            )
        ),
        json!({"tool":"engine","action":"set","speed":"fast","compactor_speed":"default","compactor_harness":"claude-sr","compactor_model":"default"})
    );
    assert_eq!(
        tool_line(ResourceOperation::ChiefStop, &fields(json!({"name":"a3"}))),
        json!({"tool":"stop","name":"a3"})
    );
    let mux = Mux::new_for_test("chief-control", crate::SurfaceOptions::default());
    let brain_answer = json!({"stopped":true,"subagents":["a3"],"note":"Stopped by the user: a3."});
    let stop = result(&mux, ResourceOperation::ChiefStop, Ok(brain_answer)).unwrap();
    assert_eq!(
        stop["value"],
        json!({"stopped":true,"subagents":["a3"],"note":"Stopped by the user: a3."})
    );
}

/// chief.settings.get|set are optchat-chief's `settings` tool: the set is
/// read back, both answer the brain's settings as JSON, and the brain's
/// refusal (another person's or a remote turn) keeps its words.
#[test]
fn the_settings_ops_reach_the_brains_settings_tool() {
    assert_eq!(
        tool_line(ResourceOperation::ChiefSettingsGet, &fields(json!({}))),
        json!({"tool":"settings"})
    );
    assert_eq!(
        tool_line(
            ResourceOperation::ChiefSettingsSet,
            &fields(json!({"key":"approvals.autoApproveAll","value":"true"}))
        ),
        json!({"tool":"settings","key":"approvals.autoApproveAll","value":"true"})
    );
    let mux = Mux::new_for_test("chief-control-settings", crate::SurfaceOptions::default());
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    let settings = json!({"approvals":{"autoApproveAll":true},"remote":{"ask":false}});
    let (_dir, sock, seen) = brain(json!({"text": format!("{settings:#}")}));
    // A loosening: the verified app's (only_the_verified_app_loosens_...).
    let app = verified_app(&mux, std::process::id());
    let set = call_with(
        &mux,
        app,
        "chief.settings.set",
        json!({"key":"approvals.autoApproveAll","value":"true"}),
        &sock,
    );
    assert_eq!(set["result"]["value"]["settings"], settings, "{set}");
    assert_eq!(
        seen.lock().unwrap().as_slice(),
        [
            json!({"tool":"settings","key":"approvals.autoApproveAll","value":"true"}),
            json!({"tool":"settings"})
        ]
    );
    let get = call(&mux, owner, "chief.settings.get", &sock);
    assert_eq!(get["result"]["settings"], settings, "{get}");
    let refusal = json!({"error":"refused: approvals.autoApproveAll can be set to true only by the owner on the Mac"});
    let error = result(&mux, ResourceOperation::ChiefSettingsSet, Ok(refusal)).unwrap_err();
    assert_eq!(error.code, "operation.failed");
    assert_eq!(error.details["reason"], "refused");
    assert!(
        error.details["extra"]["message"].as_str().unwrap().contains("only by the owner"),
        "{:?}",
        error.details
    );
}

const LOOSEN: [(&str, &str); 4] = [
    ("approvals.autoApproveAll", "true"),
    ("remote.autoApprove", "true"),
    ("remote.ask", "false"),
    ("home.ask", "false"),
];
const TIGHTEN: [(&str, &str); 4] = [
    ("approvals.autoApproveAll", "false"),
    ("remote.autoApprove", "false"),
    ("remote.ask", "true"),
    ("home.ask", "true"),
];

fn settings_set(mux: &Arc<Mux>, client: u64, (key, value): (&str, &str), sock: &Path) -> Value {
    call_with(mux, client, "chief.settings.set", json!({"key": key, "value": value}), sock)
}

/// A registered Unix client that is the verified cmux app (role main and
/// its proof), its socket peer the process `pid`.
fn verified_app(mux: &Arc<Mux>, pid: u32) -> u64 {
    use super::super::origin_gate::{
        set_peer_key_for_test, set_role_for_test, set_verified_app_for_test,
    };
    let app = mux.control_clients.register(ClientTransport::Unix, writer());
    set_role_for_test(mux, app, "main");
    set_verified_app_for_test(mux, app, true);
    set_peer_key_for_test(mux, app, &format!("token:{pid}.1"));
    app
}

/// Review of 2fe73a9a (New 1): every Chief turn's environment names this
/// daemon and an unbound local client is the owner, so a loosening
/// `chief.settings.set` reaches the brain only from the verified cmux app
/// connection; a tightening stays the owner's, a plain client included.
#[test]
fn only_the_verified_app_loosens_a_gate_and_the_owner_tightens_one() {
    let mux = Mux::new_for_test("chief-control-loosen", crate::SurfaceOptions::default());
    let settings = json!({"approvals":{"autoApproveAll":false}});
    let (_dir, sock, seen) = brain(json!({"text": format!("{settings:#}")}));
    // A plain local client (a turn's raw socket, the CLI): the owner, but
    // not the app.
    let plain = mux.control_clients.register(ClientTransport::Unix, writer());
    for line in LOOSEN {
        let refused = settings_set(&mux, plain, line, &sock);
        assert_eq!(refused["error"]["code"], "origin.forbidden", "{line:?}: {refused}");
        assert_eq!(refused["error"]["details"]["reason"], "chief_loosen_needs_app", "{refused}");
    }
    // Role main without its proof is no app either.
    let unproved = mux.control_clients.register(ClientTransport::Unix, writer());
    origin_gate::set_role_for_test(&mux, unproved, "main");
    let refused = settings_set(&mux, unproved, LOOSEN[0], &sock);
    assert_eq!(refused["error"]["code"], "origin.forbidden", "{refused}");
    assert!(seen.lock().unwrap().is_empty(), "no loosening reached the brain");
    // Tightening passes.
    for line in TIGHTEN {
        let set = settings_set(&mux, plain, line, &sock);
        assert_eq!(set["result"]["value"]["settings"], settings, "{line:?}: {set}");
    }
    assert_eq!(seen.lock().unwrap().len(), 2 * TIGHTEN.len());
    seen.lock().unwrap().clear();
    // The verified app loosens every gate.
    let app = verified_app(&mux, std::process::id());
    for line in LOOSEN {
        let set = settings_set(&mux, app, line, &sock);
        assert_eq!(set["result"]["value"]["settings"], settings, "{line:?}: {set}");
    }
    let forwarded: Vec<Value> = seen.lock().unwrap().iter().step_by(2).cloned().collect();
    assert_eq!(
        forwarded,
        LOOSEN.map(|(key, value)| json!({"tool":"settings","key":key,"value":value})).to_vec()
    );
}

/// The verified app's connection bound to an agent, or one whose request
/// narrows its origin, does not loosen a gate.
#[test]
fn an_agent_bound_connection_never_loosens_a_gate() {
    let mux = Mux::new_for_test("chief-control-loosen-agent", crate::SurfaceOptions::default());
    let (_dir, sock, seen) = brain(json!({"text": "{}"}));
    // Bound to an agent's conversation: refused by the owner rule already.
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    let token = handle_command(
        &mux,
        owner,
        serde_json::from_value(json!({"cmd":"conversation-agent-token","participant":"agent_mux"}))
            .unwrap(),
        &writer(),
    )
    .unwrap()["token"]
        .clone();
    let bound = verified_app(&mux, std::process::id());
    handle_command(
        &mux,
        bound,
        serde_json::from_value(
            json!({"cmd":"conversation-bind","participant":"agent_mux","token":token}),
        )
        .unwrap(),
        &writer(),
    )
    .unwrap();
    let refused = settings_set(&mux, bound, LOOSEN[0], &sock);
    assert_eq!(refused["error"]["code"], "origin.forbidden", "{refused}");
    assert_eq!(refused["error"]["details"]["reason"], "chief_owner_only", "{refused}");
    assert!(seen.lock().unwrap().is_empty(), "no loosening reached the brain");
}

#[test]
fn which_settings_lines_loosen_a_gate() {
    for (key, value) in LOOSEN {
        assert!(super::loosens_gate(&fields(json!({"key":key,"value":value}))), "{key}");
        let padded = format!(" {value}\n");
        assert!(super::loosens_gate(&fields(json!({"key":key,"value":padded}))), "{key}");
    }
    for (key, value) in TIGHTEN {
        assert!(!super::loosens_gate(&fields(json!({"key":key,"value":value}))), "{key}");
    }
    for extra in [
        json!({"key":"cache.ttl","value":"1h"}),
        json!({"key":"approvals.autoApproveAll","value":true}),
        json!({"key":"approvals.autoApproveAll","value":"yes"}),
        json!({}),
    ] {
        assert!(!super::loosens_gate(&fields(extra.clone())), "{extra}");
    }
}
