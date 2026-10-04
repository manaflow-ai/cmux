//! automation.input v1 against the shared vectors (the same file the app's
//! decoder replays), and the emitter's events against the same rules.

use super::*;
use serde_json::json;
use std::sync::Arc;

const VECTORS: &str = include_str!("../../../../schemas/automation-input/vectors.json");

/// The schema's rules that serde types cannot hold (event.schema.json).
fn check(event: &AutomationInputEvent) -> Result<(), String> {
    if event.v != 1 {
        return Err("v must be 1".into());
    }
    if event.session_id.is_empty() || event.target_id.is_empty() {
        return Err("session_id and target_id must not be empty".into());
    }
    let pointed = !matches!(event.kind, Kind::Type | Kind::Key);
    if pointed && event.point.is_none() {
        return Err(format!("{:?} needs a point", event.kind));
    }
    if matches!(event.kind, Kind::Drag | Kind::Scroll) && event.to.is_none() {
        return Err(format!("{:?} needs to", event.kind));
    }
    let desktop = event.target_id.starts_with("cua:");
    match (desktop, event.space) {
        (true, Space::Window) | (false, Space::Viewport) => {}
        _ => return Err("cua: targets use window space, tabs viewport space".into()),
    }
    if let Some(zoom) = event.zoom {
        if event.space == Space::Window {
            return Err("zoom applies only to viewport space".into());
        }
        if zoom <= 0.0 || !zoom.is_finite() {
            return Err("zoom must be positive".into());
        }
    }
    if let Some(rect) = event.rect
        && (rect.w < 0.0 || rect.h < 0.0)
    {
        return Err("rect size must not be negative".into());
    }
    if event.t_ms < 0.0 {
        return Err("t_ms must not be negative".into());
    }
    Ok(())
}

fn numbers_as_f64(value: &Value) -> Value {
    match value {
        Value::Number(n) => json!(n.as_f64()),
        Value::Array(list) => Value::Array(list.iter().map(numbers_as_f64).collect()),
        Value::Object(map) => {
            Value::Object(map.iter().map(|(k, v)| (k.clone(), numbers_as_f64(v))).collect())
        }
        other => other.clone(),
    }
}

fn decode(value: &Value) -> Result<AutomationInputEvent, String> {
    let event: AutomationInputEvent =
        serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
    check(&event)?;
    Ok(event)
}

#[test]
fn the_shared_vectors_hold_for_this_encoder() {
    let vectors: Value = serde_json::from_str(VECTORS).expect("vectors parse");
    let valid = vectors["valid"].as_array().expect("valid");
    assert!(!valid.is_empty());
    for value in valid {
        let event = decode(value).unwrap_or_else(|e| panic!("{value}: {e}"));
        // Every valid event is one this type writes back (numbers compared
        // by value: 48 and 48.0 are the same JSON number).
        assert_eq!(numbers_as_f64(&serde_json::to_value(&event).unwrap()), numbers_as_f64(value));
    }
    let invalid = vectors["invalid"].as_array().expect("invalid");
    assert!(!invalid.is_empty());
    for case in invalid {
        assert!(decode(&case["event"]).is_err(), "accepted: {}", case["why"]);
    }
}

fn recorder() -> (InputEmitter, Arc<Mutex<Vec<Value>>>) {
    let seen = Arc::new(Mutex::new(Vec::new()));
    let sink_seen = seen.clone();
    let sink: EventSink = Arc::new(move |event: DriverEvent| {
        assert_eq!(event.name, EVENT);
        sink_seen.lock().unwrap().push(event.payload);
    });
    (InputEmitter::new("lease-s", sink), seen)
}

fn emit(emitter: &InputEmitter, method: &str, params: Value) {
    if let Some(planned) = emitter.plan(method, &params) {
        emitter.publish(planned);
    }
}

#[test]
fn inputs_map_to_kinds_with_gap_free_seq() {
    let (emitter, seen) = recorder();
    let mouse = |kind: &str, extra: Value| {
        let mut params = json!({"targetId": "T", "type": kind});
        params.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
        emit(&emitter, "input.mouse", params);
    };
    mouse("move", json!({"x": 10, "y": 20}));
    mouse("down", json!({}));
    mouse("up", json!({}));
    mouse("down", json!({"x": 30, "y": 40, "clickCount": 2}));
    mouse("up", json!({"x": 30, "y": 40, "clickCount": 2}));
    mouse("down", json!({"x": 5, "y": 5, "button": "right"}));
    mouse("up", json!({"x": 5, "y": 5, "button": "right"}));
    mouse("down", json!({"x": 0, "y": 0}));
    mouse("move", json!({"x": 50, "y": 0}));
    mouse("up", json!({"x": 100, "y": 0}));
    mouse("wheel", json!({"x": 1, "y": 2, "deltaX": 0, "deltaY": 480}));
    emit(&emitter, "input.key", json!({"targetId": "T", "type": "down", "key": "q"}));
    emit(&emitter, "input.key", json!({"targetId": "T", "type": "up", "key": "q"}));
    emit(&emitter, "input.insertText", json!({"targetId": "T", "text": "x"}));
    emit(&emitter, "input.insertText", json!({"text": "no tab"}));
    emit(&emitter, "tab.navigate", json!({"targetId": "T", "url": "https://a.test/"}));

    let seen = seen.lock().unwrap();
    let kinds: Vec<&str> = seen.iter().map(|e| e["kind"].as_str().unwrap()).collect();
    assert_eq!(
        kinds,
        vec![
            "move",
            "click",
            "double_click",
            "right_click",
            "move",
            "drag",
            "scroll",
            "key",
            "type"
        ]
    );
    for (i, value) in seen.iter().enumerate() {
        let event = decode(value).unwrap_or_else(|e| panic!("{value}: {e}"));
        assert_eq!(event.seq, i as u64, "gap-free from 0");
        assert_eq!(event.session_id, "lease-s");
    }
    assert_eq!(
        seen[1]["point"],
        json!({"x": 10.0, "y": 20.0}),
        "a click without x/y lands at the pointer"
    );
    assert_eq!(seen[5]["point"], json!({"x": 0.0, "y": 0.0}));
    assert_eq!(seen[5]["to"], json!({"x": 100.0, "y": 0.0}));
    assert_eq!(seen[6]["to"], json!({"x": 0.0, "y": 480.0}), "scroll: wheel delta");
}

#[test]
fn no_text_key_or_url_from_the_params_reaches_an_event() {
    let (emitter, seen) = recorder();
    let calls = [
        (
            "input.insertText",
            json!({"targetId": "T", "text": "hunter2-typed", "url": "https://leak.test/u"}),
        ),
        (
            "input.key",
            json!({"targetId": "T", "type": "down", "key": "Zed-key", "code": "KeyZcode", "text": "z-text"}),
        ),
        (
            "input.mouse",
            json!({"targetId": "T", "type": "move", "x": 1, "y": 2, "url": "https://leak.test/m"}),
        ),
        ("input.insertText", json!({"targetId": "T", "text": {"__secret": "pw-name"}})),
    ];
    for (method, params) in calls {
        emit(&emitter, method, params);
    }
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 4);
    let allowed = [
        "v",
        "session_id",
        "target_id",
        "seq",
        "kind",
        "space",
        "point",
        "rect",
        "to",
        "zoom",
        "t_ms",
    ];
    for value in seen.iter() {
        let text = value.to_string();
        for leak in ["hunter2", "Zed-key", "KeyZcode", "z-text", "leak.test", "pw-name", "__secret"]
        {
            assert!(!text.contains(leak), "{leak} in {text}");
        }
        for key in value.as_object().unwrap().keys() {
            assert!(allowed.contains(&key.as_str()), "field {key} is not in schema v1");
        }
    }
}
