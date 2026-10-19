//! Every trace of `schemas/ownership-mirror/vectors.json` (written by
//! backend/packages/ownership/scripts/export-mirror-vectors.ts from the REAL
//! TypeScript `ProjectionClient`, partly against the real `OwnerEngine`)
//! replays through [`StreamMirror`]: for each input the frames it sends and
//! the client after it equal the TypeScript client's.

use cmux_cloud_wire::{ClientOut, INTENT_TTL_MS, Origin, OwnerFrame, StreamMirror};
use serde_json::{Value, json};
use std::path::Path;

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

fn now(input: &Value) -> i64 {
    input["now"].as_i64().expect("now")
}

fn keys<'a>(it: impl Iterator<Item = &'a str>) -> Value {
    Value::Array(it.map(|k| Value::String(k.to_owned())).collect())
}

fn snapshot_of(m: &StreamMirror) -> Value {
    json!({
        "seq": m.seq(),
        "state": m.state(),
        "rows": m.rows().dump(),
        "pending": keys(m.pending().iter().map(|i| i.idempotency_key.as_str())),
        "expired": keys(m.expired().iter().map(|i| i.idempotency_key.as_str())),
        "held": keys(m.held_keys()),
        "awaiting": m.is_awaiting_snapshot(),
        "connected": m.is_connected(),
        "desyncs": m.desyncs(),
        "settled_ok": keys(m.settled_ok().iter().map(String::as_str)),
    })
}

fn step(m: &mut StreamMirror, input: &Value) -> Vec<Value> {
    let sent: Vec<ClientOut> = match input["t"].as_str().expect("input t") {
        "issue" => {
            let op = input["op"].as_str().expect("op");
            match m.issue(op, input["params"].clone(), Origin::User, now(input)) {
                Ok((_, out)) => out,
                Err(e) => {
                    return vec![
                        json!({ "error": cmux_cloud_wire::OwnerUnreachable::CODE, "message": e.to_string() }),
                    ];
                }
            }
        }
        "receive" => {
            m.receive(OwnerFrame::from_value(input["frame"].clone()).expect("owner frame decodes"))
        }
        "disconnect" => {
            m.disconnect();
            Vec::new()
        }
        "reconnect" => m.reconnect(now(input)),
        "retry" => m.retry(input["key"].as_str().expect("key"), now(input)),
        "expire" => {
            m.expire_stale(now(input));
            Vec::new()
        }
        other => panic!("unknown input {other}"),
    };
    sent.iter().map(ClientOut::to_value).collect()
}

#[test]
fn replays_every_trace_of_the_typescript_client() {
    let doc = vectors();
    assert_eq!(doc["version"], 1);
    assert_eq!(
        doc["intent_ttl_ms"].as_i64(),
        Some(INTENT_TTL_MS),
        "intent TTL drifted from client.ts"
    );
    let cases = doc["cases"].as_array().expect("cases");
    assert!(cases.len() >= 20, "expected hand and simulated cases, got {}", cases.len());
    let mut steps = 0;
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let mut m = StreamMirror::new(
            case["key_prefix"].as_str().expect("key_prefix"),
            case["initial"].clone(),
        );
        for (i, s) in case["steps"].as_array().expect("steps").iter().enumerate() {
            let out = step(&mut m, &s["in"]);
            let want: Vec<Value> = s["out"]
                .as_array()
                .expect("out")
                .iter()
                // The TypeScript refusal carries only the code; the message is ours.
                .map(|o| if o.get("error").is_some() { o["error"].clone() } else { o.clone() })
                .collect();
            let got: Vec<Value> = out
                .iter()
                .map(|o| if o.get("error").is_some() { o["error"].clone() } else { o.clone() })
                .collect();
            assert!(
                same(&Value::Array(got.clone()), &Value::Array(want.clone())),
                "{name} step {i} ({}): sent {got:?}, TypeScript sent {want:?}",
                s["in"]["t"]
            );
            let after = snapshot_of(&m);
            assert!(
                same(&after, &s["after"]),
                "{name} step {i} ({}): mirror {after:#}\nTypeScript {:#}",
                s["in"]["t"],
                s["after"]
            );
            steps += 1;
        }
    }
    assert!(steps > 500, "expected the simulated traces, got {steps} steps");
}
