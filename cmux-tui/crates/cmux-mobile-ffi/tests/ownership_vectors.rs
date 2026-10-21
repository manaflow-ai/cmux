//! The phone apps' binding of the stream mirror replays every trace of
//! `schemas/ownership-mirror/vectors.json` (the real TypeScript
//! `ProjectionClient`'s): through the exported JSON-text surface, for each
//! input the frames to send and the view after it equal the TypeScript
//! client's. Swift and Kotlin call exactly these methods. The app observes
//! the view through the listener: after every input that changed the view
//! it is told once, with the view `view()` returns; otherwise not at all.

use cmux_mobile_ffi::ownership::{
    OwnershipMirror, OwnershipMirrorError, OwnershipMirrorListener, OwnershipMirrorView,
};
use serde_json::{Value, json};
use std::path::Path;
use std::sync::{Arc, Mutex};

/// What the app's listener saw.
#[derive(Default)]
struct Seen(Mutex<Vec<OwnershipMirrorView>>);

impl OwnershipMirrorListener for Seen {
    fn on_change(&self, view: OwnershipMirrorView) {
        self.0.lock().unwrap().push(view);
    }
}

impl Seen {
    fn take(&self) -> Vec<OwnershipMirrorView> {
        std::mem::take(&mut *self.0.lock().unwrap())
    }
}

/// The view without its generation: what a screen renders.
fn shown(view: &OwnershipMirrorView) -> OwnershipMirrorView {
    OwnershipMirrorView { generation: 0, ..view.clone() }
}

fn vectors() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../schemas/ownership-mirror/vectors.json");
    let raw = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()));
    serde_json::from_str(&raw).expect("vectors JSON")
}

/// JSON equality where numbers compare by value (`1` equals `1.0`).
fn same(a: &Value, b: &Value) -> bool {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => x == y || x.as_f64() == y.as_f64(),
        (Value::Array(x), Value::Array(y)) => {
            x.len() == y.len() && x.iter().zip(y).all(|(x, y)| same(x, y))
        }
        (Value::Object(x), Value::Object(y)) => {
            x.len() == y.len() && x.iter().all(|(k, v)| y.get(k).is_some_and(|w| same(v, w)))
        }
        _ => a == b,
    }
}

fn parse(text: &str) -> Value {
    serde_json::from_str(text).expect("JSON text from the binding")
}

fn view_json(view: &OwnershipMirrorView) -> Value {
    let keys = |list: &[cmux_mobile_ffi::ownership::OwnershipIntent]| {
        Value::Array(list.iter().map(|i| json!(i.idempotency_key)).collect())
    };
    json!({
        "seq": view.seq,
        "state": parse(&view.state_json),
        "rows": parse(&view.rows_json),
        "pending": keys(&view.pending),
        "expired": keys(&view.expired),
        "awaiting": view.awaiting_snapshot,
        "connected": view.connected,
        "desyncs": view.desyncs,
    })
}

fn now(input: &Value) -> i64 {
    input["now"].as_i64().expect("now")
}

fn step(m: &OwnershipMirror, input: &Value) -> Vec<Value> {
    let sent = match input["t"].as_str().expect("input t") {
        "issue" => {
            let op = input["op"].as_str().expect("op").to_owned();
            match m.issue(op, input["params"].to_string(), "user".into(), now(input)) {
                Ok(issued) => issued.send,
                Err(OwnershipMirrorError::OwnerUnreachable) => {
                    return vec![json!({"error": "owner_unreachable"})];
                }
                Err(e) => panic!("issue: {e}"),
            }
        }
        "receive" => {
            let at = input["now"].as_i64().unwrap_or(0);
            m.receive(input["frame"].to_string(), at).expect("owner frame decodes").send
        }
        "disconnect" => {
            m.disconnect();
            Vec::new()
        }
        "reconnect" => m.reconnect(now(input)),
        "retry" => m.retry(input["key"].as_str().expect("key").to_owned(), now(input)),
        "expire" => {
            m.expire_stale(now(input));
            Vec::new()
        }
        other => panic!("unknown input {other}"),
    };
    sent.iter().map(|text| parse(text)).collect()
}

#[test]
fn the_binding_replays_every_trace_of_the_typescript_client() {
    let doc = vectors();
    let cases = doc["cases"].as_array().expect("cases");
    assert!(cases.len() >= 20, "expected hand and simulated cases, got {}", cases.len());
    let mut steps = 0;
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let m = OwnershipMirror::new(
            case["key_prefix"].as_str().expect("key_prefix").to_owned(),
            case["initial"].to_string(),
        )
        .expect("initial JSON");
        let seen = Arc::new(Seen::default());
        let mut before = m.set_listener(Some(seen.clone()));
        assert_eq!(before, m.view(), "{name}: set_listener returns the view now");
        for (i, s) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let got = Value::Array(step(&m, &s["in"]));
            let now = m.view();
            let told = seen.take();
            if shown(&now) == shown(&before) {
                assert!(told.is_empty(), "{name} step {i}: told without a change: {told:?}");
                assert_eq!(now.generation, before.generation, "{name} step {i}");
            } else {
                assert_eq!(told, vec![now.clone()], "{name} step {i}: the change, told once");
                assert_eq!(now.generation, before.generation + 1, "{name} step {i}");
            }
            before = now;
            let want: Vec<Value> = s["out"]
                .as_array()
                .expect("out")
                .iter()
                .map(|o| {
                    if o.get("error").is_some() { json!({"error": o["error"]}) } else { o.clone() }
                })
                .collect();
            assert!(
                same(&got, &Value::Array(want.clone())),
                "{name} step {i} ({}): sent {got:?}, TypeScript sent {want:?}",
                s["in"]["t"]
            );
            let mut after = s["after"].clone();
            for k in ["held", "settled_ok"] {
                after.as_object_mut().expect("after").remove(k);
            }
            let view = view_json(&m.view());
            assert!(
                same(&view, &after),
                "{name} step {i} ({}): binding {view:#}\nTypeScript {after:#}",
                s["in"]["t"]
            );
            steps += 1;
        }
    }
    assert!(steps > 500, "expected the simulated traces, got {steps} steps");
}

#[test]
fn bad_json_and_bad_origins_are_refused_not_panics() {
    let m = OwnershipMirror::new("c".into(), "{}".into()).expect("mirror");
    assert!(matches!(m.receive("{".into(), 1), Err(OwnershipMirrorError::Invalid { .. })));
    assert!(matches!(
        m.issue("message.send".into(), "{}".into(), "robot".into(), 1),
        Err(OwnershipMirrorError::Invalid { .. })
    ));
    m.disconnect();
    assert_eq!(
        m.issue("message.send".into(), "{}".into(), "user".into(), 1),
        Err(OwnershipMirrorError::OwnerUnreachable)
    );
}
