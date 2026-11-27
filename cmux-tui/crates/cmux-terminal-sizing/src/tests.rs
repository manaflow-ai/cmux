use super::*;
use serde_json::Value;

const FIXTURES: &str = include_str!("../../../../schemas/terminal-sizing/fixtures.json");

fn size(value: &Value) -> TerminalGridSize {
    TerminalGridSize::new(
        value["cols"].as_u64().unwrap() as u16,
        value["rows"].as_u64().unwrap() as u16,
    )
}

#[test]
fn the_sole_latest_participant_is_the_one_that_acted_last_and_none_on_a_tie() {
    let mut engine =
        TerminalSizingEngine::new(TerminalGridSize::new(80, 24), TerminalSizingPolicy::default());
    assert_eq!(engine.sole_latest(), None, "no participant");
    let view = |id: &str, device_kind| TerminalSizingParticipant {
        id: id.to_owned(),
        device_kind,
        ..TerminalSizingParticipant::default()
    };
    engine.attach(view("phone-a", TerminalDeviceKind::Iphone));
    engine.attach(view("phone-b", TerminalDeviceKind::Iphone));
    assert_eq!(engine.sole_latest(), None, "two handheld attaches tie at activity 0");
    engine.attach(view("mac", TerminalDeviceKind::Mac));
    assert_eq!(engine.sole_latest(), Some("mac"));
    engine.note_activity("phone-a");
    assert_eq!(engine.sole_latest(), Some("phone-a"));
    engine.detach("phone-a");
    assert_eq!(engine.sole_latest(), Some("mac"));
}

#[test]
fn sizing_policy_replays_shared_fixture_corpus() {
    let corpus: Value = serde_json::from_str(FIXTURES).unwrap();
    let cases = corpus["cases"].as_array().unwrap();
    assert!(!cases.is_empty());
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let mut engine =
            TerminalSizingEngine::new(size(&case["initial"]), TerminalSizingPolicy::default());
        for (index, step) in case["steps"].as_array().unwrap().iter().enumerate() {
            let at = format!("{name} step {index}");
            let id = step["id"].as_str().unwrap_or_default();
            match step["op"].as_str().unwrap() {
                "attach" => {
                    let participant: TerminalSizingParticipant =
                        serde_json::from_value(step["participant"].clone()).unwrap();
                    engine.attach(participant);
                }
                "detach" => {
                    engine.detach(id);
                }
                "report" => {
                    engine.report(id, size(step));
                }
                "activity" => {
                    engine.note_activity(id);
                }
                "clear_viewport" => {
                    engine.clear_viewport(id);
                }
                "set_counts" => {
                    engine.set_counts_override(id, step["counts_override"].as_bool());
                }
                "set_policy" => {
                    let policy: TerminalSizingPolicy =
                        serde_json::from_value(step["policy"].clone()).unwrap();
                    engine.set_policy(policy);
                }
                "expect" => {
                    let state = engine.state();
                    if let Some(cols) = step.get("cols") {
                        assert_eq!(u64::from(state.cols), cols.as_u64().unwrap(), "{at} cols");
                    }
                    if let Some(rows) = step.get("rows") {
                        assert_eq!(u64::from(state.rows), rows.as_u64().unwrap(), "{at} rows");
                    }
                    if let Some(owners) = step.get("owners") {
                        let owners: Vec<String> = serde_json::from_value(owners.clone()).unwrap();
                        assert_eq!(state.owners, owners, "{at} owners");
                    }
                    if let Some(reason) = step.get("reason") {
                        assert_eq!(
                            serde_json::to_value(state.reason).unwrap(),
                            *reason,
                            "{at} reason"
                        );
                    }
                    if let Some(generation) = step.get("generation") {
                        assert_eq!(
                            state.generation,
                            generation.as_u64().unwrap(),
                            "{at} generation"
                        );
                    }
                    if let Some(keys) = step.get("priority_keys").and_then(Value::as_object) {
                        for (participant, expected) in keys {
                            assert_eq!(
                                state.participant(participant).map(|row| row.priority_key.as_str()),
                                expected.as_str(),
                                "{at} priority_key {participant}"
                            );
                        }
                    }
                    if let Some(counts) = step.get("counts").and_then(Value::as_object) {
                        for (participant, expected) in counts {
                            assert_eq!(
                                engine.counts(participant),
                                expected.as_bool().unwrap(),
                                "{at} counts {participant}"
                            );
                            assert_eq!(
                                state.participant(participant).map(|row| row.counts),
                                expected.as_bool(),
                                "{at} published counts {participant}"
                            );
                        }
                    }
                }
                other => panic!("{at}: unknown op {other}"),
            }
        }
    }
}

#[test]
fn sizing_policy_state_matches_contract_wire_shape() {
    // Mirrors the `latest` example in docs/shared-terminal-sizing.md.
    let mut engine = TerminalSizingEngine::new(
        TerminalGridSize::new(80, 24),
        TerminalSizingPolicy::new(TerminalSizingMode::Latest, Vec::new(), None),
    );
    engine.attach(TerminalSizingParticipant {
        id: "c3".into(),
        user_id: Some("u_maya".into()),
        display_name: Some("Maya Ortiz".into()),
        device_kind: TerminalDeviceKind::Mac,
        device_name: Some("Mac Studio".into()),
        viewport: Some(TerminalGridSize::new(118, 38)),
        ..TerminalSizingParticipant::default()
    });
    let wire = serde_json::to_value(engine.state()).unwrap();
    assert_eq!(
        wire,
        serde_json::json!({
            "generation": 1, "cols": 118, "rows": 38, "reason": "latest", "owners": ["c3"],
            "policy": {"mode": "latest", "priority": [], "fixed": null},
            "participants": [{
                "id": "c3", "user_id": "u_maya", "display_name": "Maya Ortiz",
                "device_kind": "mac", "device_name": "Mac Studio", "device_id": null,
                "via": null,
                "viewport": {"cols": 118, "rows": 38}, "counts_override": null,
                "counts": true, "priority_key": "u_maya/mac"
            }]
        })
    );
    let decoded: TerminalSizingState = serde_json::from_value(wire).unwrap();
    assert_eq!(&decoded, engine.state());
}
