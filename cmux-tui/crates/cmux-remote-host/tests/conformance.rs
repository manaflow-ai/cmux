//! Replays `schemas/remote-host/v1-conformance.json` against the Rust host's
//! supervisor link (the Swift host replays the same file; docs/cmux-remote.md,
//! "Windows and Linux", Conformance).

use std::path::PathBuf;
use std::time::Duration;

use cmux_remote_host::host::{Bootstrap, HostCore, Layout};
use cmux_remote_host::wire;
use serde_json::{Value, json};
use tokio::io::{AsyncWriteExt, BufReader};

fn fixture() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/remote-host/v1-conformance.json");
    serde_json::from_slice(&std::fs::read(&path).unwrap_or_else(|error| panic!("{}: {error}", path.display())))
        .expect("the fixture is JSON")
}

/// Every expected key present and equal; "$ANY" matches any present value.
fn matches(expected: &Value, actual: &Value) -> bool {
    match (expected, actual) {
        (Value::String(any), _) if any == "$ANY" => true,
        (Value::Object(expected), Value::Object(actual)) => expected
            .iter()
            .all(|(key, value)| actual.get(key).is_some_and(|present| matches(value, present))),
        (Value::Array(expected), Value::Array(actual)) => {
            expected.len() == actual.len() && expected.iter().zip(actual).all(|(left, right)| matches(left, right))
        }
        _ => expected == actual,
    }
}

fn substitute(value: &Value, secret: &str) -> Value {
    match value {
        Value::String(text) if text == "$SECRET" => json!(secret),
        Value::Object(object) => Value::Object(object.iter().map(|(key, value)| (key.clone(), substitute(value, secret))).collect()),
        Value::Array(items) => Value::Array(items.iter().map(|item| substitute(item, secret)).collect()),
        other => other.clone(),
    }
}

#[tokio::test]
async fn the_rust_host_passes_every_supervisor_case() {
    let fixture = fixture();
    let secret = fixture["secret"].as_str().unwrap().to_owned();
    let cases = fixture["cases"].as_array().unwrap();
    assert!(cases.len() >= 8, "the fixture keeps its cases");
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let scratch = std::env::temp_dir().join(format!("cmux-rh-conformance-{}-{}", std::process::id(), name.len()));
        let mut bootstrap_line = fixture["bootstrap"].clone();
        bootstrap_line["supervisor_secret"] = json!(secret);
        let bootstrap = Bootstrap::parse(&bootstrap_line).expect("bootstrap");
        let core = HostCore::new(bootstrap, Layout { dir: scratch.join("rh") }, scratch.join("state"), None);
        let (client, server) = tokio::io::duplex(1 << 20);
        let peer_is_daemon = case.get("peer_is_daemon").and_then(Value::as_bool).unwrap_or(true);
        let serving = {
            let core = core.clone();
            tokio::spawn(async move { core.serve_supervisor(server, peer_is_daemon).await })
        };
        let (reader, mut writer) = tokio::io::split(client);
        let mut reader = BufReader::new(reader);
        for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let at = format!("{name}, step {index}");
            if let Some(line) = step.get("send") {
                writer.write_all(&wire::encode(&substitute(line, &secret))).await.unwrap();
            } else if let Some(expected) = step.get("expect") {
                loop {
                    let line = tokio::time::timeout(Duration::from_secs(10), wire::read_object(&mut reader))
                        .await
                        .unwrap_or_else(|_| panic!("{at}: no answer"))
                        .unwrap_or_else(|error| panic!("{at}: {error}"))
                        .unwrap_or_else(|| panic!("{at}: closed, expected {expected}"));
                    let line = Value::Object(line);
                    if line["type"] == "event" {
                        continue;
                    }
                    assert!(matches(expected, &line), "{at}: expected {expected}, got {line}");
                    break;
                }
            } else if let Some(event) = step.get("expect_event").and_then(Value::as_str) {
                loop {
                    let line = tokio::time::timeout(Duration::from_secs(10), wire::read_object(&mut reader))
                        .await
                        .unwrap_or_else(|_| panic!("{at}: no event"))
                        .unwrap()
                        .unwrap_or_else(|| panic!("{at}: closed before event {event}"));
                    if line.get("type") == Some(&json!("event")) && line.get("event") == Some(&json!(event)) {
                        break;
                    }
                }
            } else if step.get("expect_closed").is_some() {
                let end = tokio::time::timeout(Duration::from_secs(10), wire::read_object(&mut reader))
                    .await
                    .unwrap_or_else(|_| panic!("{at}: still open"));
                assert!(matches!(end, Ok(None)), "{at}: expected the link to close, got {end:?}");
            } else {
                panic!("{at}: unknown step {step}");
            }
        }
        drop(writer);
        drop(reader);
        let _ = tokio::time::timeout(Duration::from_secs(10), serving).await;
        let _ = std::fs::remove_dir_all(&scratch);
    }
}

#[test]
fn the_matcher_is_a_recursive_subset() {
    assert!(matches(&json!({"a": {"b": 1}}), &json!({"a": {"b": 1, "c": 2}, "d": 3})));
    assert!(!matches(&json!({"a": {"b": 1}}), &json!({"a": {"b": 2}})));
    assert!(matches(&json!({"a": "$ANY"}), &json!({"a": [1]})));
    assert!(!matches(&json!({"a": "$ANY"}), &json!({})));
    assert!(!matches(&json!([1]), &json!([1, 2])));
}
