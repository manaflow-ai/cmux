//! `chief.engine.get|set` and `chief.stop`: the owner's trusted connection
//! only, forwarded to the brain's tools socket as optchat-chief's `engine`
//! and `stop` tools, its answer and refusals mapped to the v2 result.

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
    // Continue and retry use the same owner-only brain socket as stop.
    assert_eq!(
        tool_line(ResourceOperation::ChiefContinue, &fields(json!({}))),
        json!({"tool":"continue"})
    );
    assert_eq!(
        tool_line(ResourceOperation::ChiefRetry, &fields(json!({"message":"msg_7"}))),
        json!({"tool":"retry","message":"msg_7"})
    );
}

#[test]
fn continue_and_retry_are_owner_control_operations() {
    assert!(super::handles(ResourceOperation::ChiefContinue));
    assert!(super::handles(ResourceOperation::ChiefRetry));
    let mux = Mux::new_for_test("chief-control", crate::SurfaceOptions::default());
    let continued =
        result(&mux, ResourceOperation::ChiefContinue, Ok(json!({"continued":true}))).unwrap();
    assert_eq!(continued["value"], json!({"continued":true}));
    let retried =
        result(&mux, ResourceOperation::ChiefRetry, Ok(json!({"retried":false,"reason":"busy"})))
            .unwrap();
    assert_eq!(retried["value"], json!({"retried":false,"reason":"busy"}));
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
    let (writer, outbound) = tests::captured_writer();
    let mut line = json!({"protocol":"cmux.protocol/2","type":"request","id":"c","operation":operation,
                          "params":{"machine":"current","session":"current"}});
    if operation != "chief.engine.get" {
        line["idempotency_key"] = json!("k1");
    }
    if operation == "chief.retry" {
        line["params"]["message"] = json!("msg_7");
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
    for operation in
        ["chief.stop", "chief.continue", "chief.retry", "chief.engine.set", "chief.engine.get"]
    {
        let refused = call(&mux, agent, operation, &sock);
        assert_eq!(refused["error"]["code"], "origin.forbidden", "{operation}: {refused}");
    }
    assert!(seen.lock().unwrap().is_empty(), "nothing reached the brain");
    let stopped = call(&mux, owner, "chief.stop", &sock);
    assert_eq!(stopped["result"]["value"]["stopped"], true, "{stopped}");
    assert_eq!(seen.lock().unwrap().as_slice(), [json!({"tool":"stop"})]);
}

#[test]
fn owner_turn_actions_pass_the_catalog_and_reach_the_brain() {
    for (operation, answer, expected) in [
        ("chief.continue", json!({"continued":true}), json!({"tool":"continue"})),
        ("chief.retry", json!({"retried":true}), json!({"tool":"retry","message":"msg_7"})),
    ] {
        let mux = Mux::new_for_test("chief-turn-action", crate::SurfaceOptions::default());
        let owner = mux.control_clients.register(ClientTransport::Unix, writer());
        let (_dir, socket, seen) = brain(answer.clone());
        let reply = call(&mux, owner, operation, &socket);
        assert_eq!(reply["result"]["value"], answer, "{reply}");
        assert_eq!(*seen.lock().unwrap(), vec![expected]);
    }
}

#[test]
fn retry_requires_a_nonempty_message_id() {
    for fields in [fields(json!({})), fields(json!({"message":""})), fields(json!({"message":17}))]
    {
        let error = super::validate_fields(ResourceOperation::ChiefRetry, &fields).unwrap_err();
        assert_eq!(error.code, "validation.invalid");
    }
    assert!(
        super::validate_fields(ResourceOperation::ChiefRetry, &fields(json!({"message":"msg_7"})))
            .is_ok()
    );
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
    // The reaction classifier's fields reach the brain too (a416).
    assert_eq!(
        tool_line(
            ResourceOperation::ChiefEngineSet,
            &fields(json!({"classifier_model":"claude-haiku-5-5","classifier_harness":"claude",
                "classifier_prompt":"Wake only on 👎.","reactions_can_wake":"false"}))
        ),
        json!({"tool":"engine","action":"set","classifier_model":"claude-haiku-5-5","classifier_harness":"claude",
            "classifier_prompt":"Wake only on 👎.","reactions_can_wake":"false"})
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

/// "Stop all agents" and its toast's Restart (coordinator 2026-10-20):
/// chief.stop forwards all and restart, and its result keeps the brain's
/// subagents, restarted and errors.
#[test]
fn stop_all_and_restart_reach_the_brain() {
    assert_eq!(
        tool_line(ResourceOperation::ChiefStop, &fields(json!({"all":true}))),
        json!({"tool":"stop","all":true})
    );
    assert_eq!(
        tool_line(ResourceOperation::ChiefStop, &fields(json!({"restart":["a1","a2"]}))),
        json!({"tool":"stop","restart":["a1","a2"]})
    );
    let mux = Mux::new_for_test("chief-control", crate::SurfaceOptions::default());
    let stopped = result(
        &mux,
        ResourceOperation::ChiefStop,
        Ok(json!({"stopped":false,"subagents":["a1","a2"]})),
    )
    .unwrap();
    assert_eq!(stopped["value"], json!({"stopped":false,"subagents":["a1","a2"]}));
    let restarted = result(
        &mux,
        ResourceOperation::ChiefStop,
        Ok(json!({"stopped":false,"restarted":["a1"],"errors":["a2: no subagent a2"]})),
    )
    .unwrap();
    assert_eq!(
        restarted["value"],
        json!({"stopped":false,"restarted":["a1"],"errors":["a2: no subagent a2"]})
    );
}
