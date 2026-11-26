//! The wire's behavior as `RemoteAcpmuxWire.swift` and CloudAgentChatTests expect it: what a page
//! frame is answered with, which daemon call it asks for, and what is refused.

use cmux_acpmux_remote_wire::wire::{Config, Effect, Event, Failure, Wire};
use serde_json::{Value, json};

fn attached(read_only: bool) -> Wire {
    Wire::new(Config { session: Some("s1".into()), read_only, ..Config::default() })
}

fn frames(fx: &[Effect]) -> Vec<Value> {
    fx.iter()
        .filter_map(|e| match e {
            Effect::Emit { frame } => serde_json::from_str(frame).ok(),
            _ => None,
        })
        .collect()
}

fn call(fx: &[Effect]) -> (u64, &'static str, Value) {
    fx.iter()
        .find_map(|e| match e {
            Effect::Call { task, verb, args } => Some((*task, *verb, args.clone())),
            _ => None,
        })
        .expect("a call effect")
}

fn code(frame: &Value) -> &str {
    frame["error"]["data"]["code"].as_str().unwrap_or("")
}

#[test]
fn unknown_method_is_unsupported() {
    let mut w = attached(false);
    let step = w.frame(r#"{"jsonrpc":"2.0","id":1,"method":"fs/read_text_file","params":{}}"#);
    assert!(step.accepted);
    assert_eq!(code(&frames(&step.effects)[0]), "remote.unsupported");
}

#[test]
fn garbage_frame_is_not_accepted() {
    let mut w = attached(false);
    assert!(!w.frame("nope").accepted);
    assert!(!w.frame("[1]").accepted);
}

#[test]
fn initialize_names_remote_origin_and_btw() {
    let mut w = attached(false);
    let step = w.frame(r#"{"id":1,"method":"initialize","params":{}}"#);
    let (task, _, _) = match &step.effects[0] {
        Effect::Probe { task, .. } => (*task, "", Value::Null),
        other => panic!("{other:?}"),
    };
    let fx = w.done(task, Ok(r#"{"owned":false,"login":true,"side":true}"#.into()));
    let f = &frames(&fx)[0];
    let acpmux = &f["result"]["_meta"]["acpmux"];
    assert_eq!(acpmux["origin"], "remote");
    assert_eq!(acpmux["features"], json!(["agent_login", "btw_inline", "side_chat"]));
}

#[test]
fn prompt_is_accepted_then_replied() {
    let mut w = attached(false);
    let step = w.frame(
        r#"{"id":7,"method":"session/prompt","params":{"sessionId":"s1","prompt":[{"type":"text","text":"hi"}],"_meta":{"acpmux":{"promptId":"p1"}}}}"#,
    );
    let (task, verb, args) = call(&step.effects);
    assert_eq!(verb, "prompt");
    assert_eq!(args["id"], "p1");
    assert_eq!(args["steer"], false);
    let fx = w.done(task, Ok(r#"{"turn_id":"t1","queued":false}"#.into()));
    let out = frames(&fx);
    assert_eq!(out[0]["method"], "_acpmux/prompt_accepted");
    assert_eq!(out[0]["params"]["turnId"], "t1");
    assert_eq!(out[1]["id"], 7);
    assert_eq!(out[1]["result"]["_meta"]["acpmux"]["turnId"], "t1");
}

#[test]
fn prompt_for_another_session_is_refused() {
    let mut w = attached(false);
    let step = w.frame(r#"{"id":1,"method":"session/prompt","params":{"sessionId":"other","prompt":[{"type":"text","text":"x"}]}}"#);
    assert_eq!(code(&frames(&step.effects)[0]), "remote.unsupported");
}

#[test]
fn read_only_refuses_writes() {
    let mut w = attached(true);
    for method in
        ["session/cancel", "session/prompt", "_acpmux/context", "_acpmux/permission_respond"]
    {
        let step =
            w.frame(&format!(r#"{{"id":1,"method":"{method}","params":{{"sessionId":"s1"}}}}"#));
        assert_eq!(code(&frames(&step.effects)[0]), "agent_session.read_only", "{method}");
    }
}

#[test]
fn picks_reach_the_daemon_in_order() {
    let mut w = attached(false);
    let a = w.frame(
        r#"{"id":1,"method":"session/set_model","params":{"sessionId":"s1","modelId":"m1"}}"#,
    );
    let b = w.frame(
        r#"{"id":2,"method":"session/set_mode","params":{"sessionId":"s1","modeId":"plan"}}"#,
    );
    let (ta, va, _) = call(&a.effects);
    assert_eq!(va, "set_model");
    assert!(b.effects.is_empty(), "the second pick waits");
    let fx = w.done(ta, Ok("{}".into()));
    assert_eq!(frames(&fx)[0]["id"], 1);
    assert_eq!(call(&fx).1, "set_mode");
}

#[test]
fn failure_becomes_a_coded_error() {
    let mut w = attached(false);
    let step = w.frame(r#"{"id":3,"method":"_acpmux/context","params":{"sessionId":"s1"}}"#);
    let (task, _, _) = call(&step.effects);
    let fx = w.done(
        task,
        Err(Failure {
            code: "agent_session.gone".into(),
            message: "gone".into(),
            ..Failure::default()
        }),
    );
    assert_eq!(code(&frames(&fx)[0]), "agent_session.gone");
}

#[test]
fn events_forward_as_notifications_and_close_ends_once() {
    let mut w = attached(false);
    let fx = w.event(Event::Record { data: r#"{"seq":1}"#.into() });
    assert_eq!(frames(&fx)[0]["method"], "_acpmux/event");
    let fx = w.event(Event::Closed { reason: "bye".into() });
    assert!(matches!(fx[0], Effect::CloseClient));
    assert!(matches!(fx[1], Effect::ClosePage { code: 1012, .. }));
    assert!(w.event(Event::Closed { reason: "again".into() }).is_empty());
    assert!(w.cancel().is_empty());
}

#[test]
fn events_page_sets_more() {
    let mut w = attached(false);
    let step = w.frame(
        r#"{"id":4,"method":"_acpmux/events","params":{"sessionId":"s1","afterSeq":3,"limit":10}}"#,
    );
    let (task, verb, args) = call(&step.effects);
    assert_eq!(verb, "events");
    assert_eq!(args["page"], json!({"after_seq": 3, "limit": 10}));
    let fx = w.done(task, Ok(r#"{"records":[],"hasMore":true}"#.into()));
    assert_eq!(frames(&fx)[0]["result"]["more"], true);
}

#[test]
fn image_load_wants_an_image_path() {
    let mut w = attached(false);
    let bad = w.frame(r#"{"id":1,"method":"image.load","params":{"src":"/etc/passwd"}}"#);
    assert_eq!(code(&frames(&bad.effects)[0]), "remote.unsupported");
    let ok =
        w.frame(r#"{"id":2,"method":"image.load","params":{"src":"file:///tmp/a%20b.PNG#x"}}"#);
    let (_, verb, args) = call(&ok.effects);
    assert_eq!(verb, "media");
    assert_eq!(args["path"], "/tmp/a b.PNG");
}

#[test]
fn new_chat_starts_once_and_then_has_a_session() {
    let mut w = Wire::new(Config { start: true, ..Config::default() });
    let step = w.frame(r#"{"id":1,"method":"session/new","params":{"cwd":"/work","_meta":{"acpmux":{"harness":"claude"}}}}"#);
    let Effect::Start { task, cwd, harness, .. } = &step.effects[0] else { panic!() };
    assert_eq!((cwd.as_deref(), harness.as_deref()), (Some("/work"), Some("claude")));
    let again = w.frame(r#"{"id":2,"method":"session/new","params":{}}"#);
    assert_eq!(code(&frames(&again.effects)[0]), "remote.unsupported");
    let fx = w.done(*task, Ok(r#"{"session":"abc"}"#.into()));
    assert_eq!(frames(&fx)[0]["result"]["sessionId"], "abc");
}
