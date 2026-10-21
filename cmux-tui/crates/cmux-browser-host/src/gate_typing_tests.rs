//! The typing an input event carries: the focused field, masking, fills.

use super::*;

/// A gate that publishes inputs, and the events it published.
fn typing_gate() -> (Gate, Arc<FakeDriver>, Arc<Mutex<Vec<Value>>>) {
    let (gate, driver) = make_gate(json!("https://login.example.com/form"), false);
    let seen: Arc<Mutex<Vec<Value>>> = Arc::default();
    let sink_seen = seen.clone();
    let sink: crate::driver::EventSink = Arc::new(move |event: crate::protocol::DriverEvent| {
        sink_seen.lock().unwrap().push(event.payload);
    });
    (gate.with_input_events("lease-s", sink), driver, seen)
}

fn focus(driver: &FakeDriver, answer: Value) {
    *driver.focused_input.lock().unwrap() = answer;
}

#[test]
fn typed_text_and_keys_reach_the_event_with_the_focused_field() {
    let (gate, driver, seen) = typing_gate();
    focus(&driver, json!({"secret": false, "x": 10, "y": 20, "w": 200, "h": 30}));
    gate.driver_call("input.insertText", json!({"targetId": "T", "text": "hello"})).unwrap();
    gate.driver_call(
        "input.key",
        json!({"targetId": "T", "type": "down", "key": "a", "text": "a", "modifiers": ["Meta"]}),
    )
    .unwrap();
    gate.driver_call("input.key", json!({"targetId": "T", "type": "up", "key": "a"})).unwrap();
    gate.driver_call("input.key", json!({"targetId": "T", "type": "down", "key": "Enter"}))
        .unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 3, "a key release is not shown");
    assert_eq!(seen[0]["kind"], "type");
    assert_eq!(seen[0]["typing"], json!({"text": "hello"}));
    assert_eq!(seen[0]["rect"], json!({"x": 10.0, "y": 20.0, "w": 200.0, "h": 30.0}));
    assert_eq!(seen[1]["typing"], json!({"text": "a", "key": "a", "modifiers": ["Meta"]}));
    assert_eq!(seen[2]["typing"], json!({"key": "Enter"}));
}

#[test]
fn a_password_field_or_a_field_the_host_cannot_see_masks_what_is_typed() {
    let (gate, driver, seen) = typing_gate();
    focus(&driver, json!({"secret": true, "x": 0, "y": 0, "w": 100, "h": 20}));
    gate.driver_call("input.insertText", json!({"targetId": "T", "text": "hunter2"})).unwrap();
    gate.driver_call(
        "input.key",
        json!({"targetId": "T", "type": "down", "key": "x", "text": "x"}),
    )
    .unwrap();
    gate.driver_call("input.key", json!({"targetId": "T", "type": "down", "key": "Enter"}))
        .unwrap();
    focus(&driver, json!({"unknown": true}));
    gate.driver_call("input.insertText", json!({"targetId": "T", "text": "4242"})).unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0]["typing"], json!({"text": "•••••••", "masked": true}));
    assert_eq!(
        seen[1]["typing"],
        json!({"text": "•", "masked": true}),
        "a masked key is not named"
    );
    assert_eq!(seen[2]["typing"], json!({"key": "Enter"}), "Enter types nothing to hide");
    assert_eq!(seen[3]["typing"], json!({"text": "••••", "masked": true}), "a cross-origin field");
    assert!(seen[3].get("rect").is_none());
    for event in seen.iter() {
        let text = event.to_string();
        assert!(!text.contains("hunter2") && !text.contains("4242"), "{text}");
    }
}

#[test]
fn a_secret_shows_eight_dots_and_never_its_value() {
    let (gate, driver, seen) = typing_gate();
    agent_secret(&gate, "*.example.com");
    focus(&driver, json!({"secret": false, "x": 0, "y": 0, "w": 100, "h": 20}));
    gate.driver_call("input.insertText", json!({"targetId": "T", "secret": "pw"})).unwrap();
    // Typed again in plain text, the tab's record still masks it.
    gate.driver_call("input.insertText", json!({"targetId": "T", "text": "s3cret-value"})).unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0]["typing"], json!({"text": "••••••••", "masked": true}));
    assert_eq!(seen[1]["typing"]["masked"], true);
    for event in seen.iter() {
        assert!(!event.to_string().contains("s3cret"), "{event}");
    }
}

#[test]
fn a_page_agent_fill_is_a_type_event_that_replaces_the_text() {
    let (gate, driver, seen) = typing_gate();
    let fill = |value: &str, extra: Option<&str>| {
        let mut args = vec![json!("fill"), json!("h1"), json!(value)];
        args.extend(extra.map(|marker| json!(marker)));
        json!({"targetId": "T", "world": "agent", "source": "(m, ...a) => x[m](...a)", "args": args})
    };
    driver.observed.lock().unwrap().insert("describe".into(), json!("<input name=\"q\"/>"));
    driver
        .observed
        .lock()
        .unwrap()
        .insert("rect".into(), json!({"x": 5, "y": 6, "width": 70, "height": 8}));
    gate.driver_call("frame.evaluate", fill("cats", None)).unwrap();
    driver
        .observed
        .lock()
        .unwrap()
        .insert("describe".into(), json!("<input type=\"password\" name=\"p\"/>"));
    gate.driver_call("frame.evaluate", fill("pw1", None)).unwrap();
    gate.driver_call("frame.evaluate", fill("0", Some(crate::automation_input::FILL_STAND_IN)))
        .unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 2, "a secret's stand-in is not shown");
    assert_eq!(seen[0]["kind"], "type");
    assert_eq!(seen[0]["typing"], json!({"text": "cats", "replace": true}));
    assert_eq!(seen[0]["rect"], json!({"x": 5.0, "y": 6.0, "w": 70.0, "h": 8.0}));
    assert_eq!(seen[1]["typing"], json!({"text": "•••", "masked": true, "replace": true}));
}

#[test]
fn a_session_that_publishes_no_inputs_reads_no_field() {
    let (gate, driver) = make_gate(json!("https://login.example.com/form"), false);
    gate.driver_call("input.insertText", json!({"targetId": "T", "text": "hello"})).unwrap();
    let probes = driver
        .calls
        .lock()
        .unwrap()
        .iter()
        .filter(|(m, p)| {
            m == "frame.evaluate"
                && p["source"].as_str().is_some_and(|s| s.contains("cmux-focused-input"))
        })
        .count();
    assert_eq!(probes, 0);
}
