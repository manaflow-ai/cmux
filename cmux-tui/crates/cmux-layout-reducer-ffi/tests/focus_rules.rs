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

/// QA chrome-parity-v2-2-2 bug 1: the launch window showed the home workspace (Home's page first, the
/// pane beside it with a terminal and the selected browser tab) before it adopted the saved window
/// record, whose focused pane, the browser pane, came as `restoredPane` for that shown workspace. It was
/// dropped, so the first pane (Home) kept the focus and the keys went to Home's message box.
fn restore_after_the_workspace_shows(before_record: &[Value]) -> FocusState {
    let topology = json!({"topology": {"_0": {"workspace": "w", "panes": [
        {"id": "home", "tabs": [{"id": "home-tab", "kind": "page"}], "selected": "home-tab"},
        {"id": "right", "tabs": [{"id": "term", "kind": "terminal"}, {"id": "web", "kind": "browser"}], "selected": "web"},
    ]}}});
    let restored = json!({"restoredPane": {"_0": "right", "workspace": "w"}});
    let mut state = FocusState::default();
    let mut effects: Vec<FocusEffect> = Vec::new();
    for event in std::iter::once(&topology).chain(before_record).chain(std::iter::once(&restored)) {
        let event: FocusEvent = serde_json::from_value(event.clone()).unwrap();
        reducer::reduce(&mut state, &event, &mut effects);
    }
    state
}

#[test]
fn a_record_for_the_shown_workspace_focuses_its_saved_pane() {
    let browser = json!({"browserPage": {"pane": "right", "tab": "web"}});
    let state = restore_after_the_workspace_shows(&[]);
    assert_eq!(json!(state.resolved()), browser, "the saved pane, not the first one");
    // Home's message box took the keyboard by itself first (a programmatic report): no person's choice.
    let home_took_it =
        json!({"responder": {"_0": {"content": {"pane": "home"}}, "source": "programmatic"}});
    let state = restore_after_the_workspace_shows(&[home_took_it]);
    assert_eq!(json!(state.resolved()), browser, "a view's own grab does not keep the restore");
    // The person chose Home after the window opened: that choice stays.
    let clicked = json!({"focusPane": {"_0": "home", "source": "mouse"}});
    let state = restore_after_the_workspace_shows(&[clicked]);
    assert_eq!(json!(state.resolved()), json!({"page": {"pane": "home", "tab": "home-tab"}}));
}
