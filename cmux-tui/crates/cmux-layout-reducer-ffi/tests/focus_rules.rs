//! The window focus rules (the machine behind `cmux_focus_*`), replayed
//! against a corpus recorded from the macOS app's Swift `FocusReducer`
//! before the rules moved to `cmux-focus-core`: every step's state (with
//! its derived keyboard target and context) and effects must come back the
//! same, in the same JSON shape the app decodes.
//!
//! Corpus: tests/focus/corpus.json, written by a recorder that drove the
//! Swift reducer with seeded random event sequences (topology changes,
//! pane and tab choices, responder reports, overlays, expectations, drags,
//! focus mode, sidebar visibility, restores) over both close-focus
//! policies. Each step stores the event, the effects and only the
//! top-level state keys that changed (null: the key is gone; "=event": the
//! topology the event carried). The corpus also holds every combination of
//! the child-window key facts and seeded type-ahead queue sequences, each
//! with the Swift rule's answers.
//!
//! Seeds 38, 44, 57, 81 and 88 were re-recorded from the Rust rules when a
//! closed pane's column whose id changed (two columns collapsing into a
//! split screen) started to map to its surviving panes: each now focuses
//! the closed pane's column neighbor instead of the first pane.

use cmux_focus_core::event::{FocusEffect, FocusEvent};
use cmux_focus_core::reducer;
use cmux_focus_core::state::FocusState;
use cmux_layout_reducer_ffi::{ERR_BUFFER, OK, cmux_layout_reducer_json};
use serde_json::{Map, Value, json};

fn call(operation: &std::ffi::CStr, request: &Value) -> Value {
    let request = serde_json::to_vec(request).unwrap();
    let mut capacity = 4096;
    loop {
        let mut output = vec![0u8; capacity];
        let mut len = 0usize;
        let code = unsafe {
            cmux_layout_reducer_json(
                request.as_ptr(),
                request.len(),
                operation.as_ptr(),
                output.as_mut_ptr(),
                output.len(),
                &mut len,
            )
        };
        if code == ERR_BUFFER && len > capacity {
            capacity = len;
            continue;
        }
        assert_eq!(code, OK, "{operation:?} refused {}", String::from_utf8_lossy(&request));
        return serde_json::from_slice(&output[..len]).unwrap();
    }
}

/// The Swift recorder wrote sets (browser focus mode) in hash order, and
/// effects for several dead focus-mode tabs in that order too.
fn normalize_state(mut state: Value) -> Value {
    if let Some(Value::Array(tabs)) = state.get_mut("browserFocusMode") {
        tabs.sort_by(|a, b| a.as_str().cmp(&b.as_str()));
    }
    state
}

fn normalize_effects(effects: &Value) -> Vec<Value> {
    let mut out: Vec<Value> = effects.as_array().unwrap().clone();
    let mut start = 0;
    while start < out.len() {
        let mut end = start;
        while end < out.len() && out[end].get("browserFocusMode").is_some() {
            end += 1;
        }
        if end > start {
            out[start..end].sort_by_key(|e| e.to_string());
            start = end;
        } else {
            start += 1;
        }
    }
    out
}

fn corpus() -> Value {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/focus/corpus.json");
    serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap()
}

#[test]
fn the_rust_focus_rules_reproduce_every_recorded_swift_step() {
    let corpus = corpus();
    let sequences = corpus["sequences"].as_array().unwrap();
    assert!(sequences.len() >= 100, "the corpus holds {} sequences", sequences.len());
    let mut steps_checked = 0usize;
    for sequence in sequences {
        let seed = &sequence["seed"];
        let mut expected: Map<String, Value> = sequence["initial"].as_object().unwrap().clone();
        let mut state =
            FocusState::import(&serde_json::to_vec(&Value::Object(expected.clone())).unwrap())
                .unwrap();
        let mut effects: Vec<FocusEffect> = Vec::new();
        for (index, step) in sequence["steps"].as_array().unwrap().iter().enumerate() {
            let event = &step["event"];
            let decoded: FocusEvent = serde_json::from_value(event.clone()).unwrap();
            // The app sends a topology through `set_topology` (an equal one returns at once).
            match decoded {
                FocusEvent::Topology { topology } => {
                    reducer::set_topology(&mut state, topology, &mut effects);
                }
                event => {
                    reducer::reduce(&mut state, &event, &mut effects);
                }
            }
            let response = json!({"state": state.export(), "effects": effects});
            for (key, value) in step["state"].as_object().unwrap() {
                match value {
                    Value::Null => {
                        expected.remove(key);
                    }
                    Value::String(marker) if marker == "=event" => {
                        expected.insert(key.clone(), event["topology"]["_0"].clone());
                    }
                    _ => {
                        expected.insert(key.clone(), value.clone());
                    }
                }
            }
            let want = normalize_state(Value::Object(expected.clone()));
            let got = normalize_state(response["state"].clone());
            assert_eq!(got, want, "seed {seed} step {index}: state after {event}");
            assert_eq!(
                normalize_effects(&response["effects"]),
                normalize_effects(&step["effects"]),
                "seed {seed} step {index}: effects of {event}"
            );
            steps_checked += 1;
        }
    }
    assert!(steps_checked >= 2_000, "only {steps_checked} steps");
}

#[test]
fn view_changing_events_are_the_ones_the_swift_rule_named() {
    let corpus = corpus();
    for sequence in corpus["sequences"].as_array().unwrap() {
        for step in sequence["steps"].as_array().unwrap() {
            let event: FocusEvent = serde_json::from_value(step["event"].clone()).unwrap();
            assert_eq!(json!(event.changes_view()), step["changesView"], "{}", step["event"]);
        }
    }
}

#[test]
fn keys_queued_for_a_loading_page_match_the_swift_queue() {
    let corpus = corpus();
    let sequences = corpus["typeAhead"].as_array().unwrap();
    assert!(sequences.len() >= 50);
    for sequence in sequences {
        let mut queue = json!({"text": ""});
        for (index, entry) in sequence["ops"].as_array().unwrap().iter().enumerate() {
            let op = &entry["op"];
            let want = &entry["result"];
            let context = format!("seed {} op {index}: {op}", sequence["seed"]);
            if op.get("drop").is_some() {
                // The app resets its queue value; no rule runs.
                queue = json!({"text": ""});
            } else {
                let response = call(c"focus_type_ahead", &json!({"queue": queue, "op": op}));
                queue = response["queue"].clone();
                if let Some(text) = want.get("text") {
                    assert_eq!(response.get("text").unwrap_or(&Value::Null), text, "{context}");
                }
                if let Some(pending) = want.get("pending") {
                    assert_eq!(&response["pending"], pending, "{context}");
                }
            }
            assert_eq!(queue.get("surface").unwrap_or(&Value::Null), &want["surface"], "{context}");
            assert_eq!(queue["text"], want["queued"], "{context}");
        }
    }
}

#[test]
fn a_child_window_that_becomes_key_is_decided_as_the_swift_rule_did() {
    let corpus = corpus();
    let cases = corpus["childWindow"].as_array().unwrap();
    assert_eq!(cases.len(), 3 * 64);
    for case in cases {
        let response = call(c"focus_child_window_key", &json!({"facts": case["facts"]}));
        let decision = case["decision"].as_str().unwrap();
        assert_eq!(response["decision"], json!({decision: {}}), "{}", case["facts"]);
        assert_eq!(response["shouldReclaim"], case["shouldReclaim"], "{}", case["facts"]);
    }
}

/// Cmd-W on the only pane of one of a screen's two columns leaves a plain
/// split screen, whose one column takes the screen's id. The focus stays in
/// the column that is left, never on a pane of another screen that was
/// focused earlier.
#[test]
fn closing_one_of_two_columns_keeps_the_focus_on_its_screen() {
    let topology = |panes: &[&str], screens: Value| -> FocusEvent {
        let panes: Vec<Value> = panes
            .iter()
            .map(|pane| {
                let tab = format!("{pane}-tab");
                json!({"id": pane, "selected": tab, "tabs": [{"id": tab, "kind": "terminal"}]})
            })
            .collect();
        serde_json::from_value(json!({"topology": {"_0": {
            "workspace": "ws", "panes": panes, "screens": screens,
        }}}))
        .unwrap()
    };
    let mut state = FocusState::default();
    let mut effects = Vec::new();
    let FocusEvent::Topology { topology: before } = topology(
        &["p1", "p2", "q1"],
        json!([[{"id": "c1", "panes": ["p1"]}, {"id": "c2", "panes": ["p2"]}],
               [{"id": "s2", "panes": ["q1"]}]]),
    ) else {
        unreachable!()
    };
    reducer::set_topology(&mut state, before, &mut effects);
    for pane in ["p1", "q1", "p2"] {
        let event: FocusEvent = serde_json::from_value(
            json!({"focusPane": {"_0": pane, "source": "mouse", "workspace": "ws"}}),
        )
        .unwrap();
        reducer::reduce(&mut state, &event, &mut effects);
    }
    assert_eq!(state.pane.as_deref(), Some("p2"));
    let FocusEvent::Topology { topology: after } = topology(
        &["p1", "q1"],
        json!([[{"id": "s1", "panes": ["p1"]}], [{"id": "s2", "panes": ["q1"]}]]),
    ) else {
        unreachable!()
    };
    reducer::set_topology(&mut state, after, &mut effects);
    assert_eq!(
        state.pane.as_deref(),
        Some("p1"),
        "the focus left the screen for a pane of another screen"
    );
}
