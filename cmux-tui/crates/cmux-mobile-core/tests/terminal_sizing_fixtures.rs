//! Replays `schemas/terminal-sizing/fixtures.json` through the mobile core's
//! sizing surface. A phone reads the host's published state off the wire, so
//! every `expect` step checks the state after a JSON round trip, too.

use cmux_mobile_core::sizing::{
    TerminalGridSize, TerminalSizingEngine, TerminalSizingParticipant, TerminalSizingPolicy,
    TerminalSizingState,
};
use serde_json::Value;

const FIXTURES: &str = include_str!("../../../../schemas/terminal-sizing/fixtures.json");

fn size(value: &Value) -> TerminalGridSize {
    let cell = |key: &str| u16::try_from(value[key].as_u64().unwrap()).unwrap();
    TerminalGridSize::new(cell("cols"), cell("rows"))
}

fn check(at: &str, engine: &TerminalSizingEngine, state: &TerminalSizingState, step: &Value) {
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
        assert_eq!(&serde_json::to_value(state.reason).unwrap(), reason, "{at} reason");
    }
    if let Some(generation) = step.get("generation") {
        assert_eq!(state.generation, generation.as_u64().unwrap(), "{at} generation");
    }
    for (id, expected) in step.get("priority_keys").and_then(Value::as_object).into_iter().flatten()
    {
        assert_eq!(
            state.participant(id).map(|row| row.priority_key.as_str()),
            expected.as_str(),
            "{at} priority_key {id}"
        );
    }
    for (id, expected) in step.get("counts").and_then(Value::as_object).into_iter().flatten() {
        assert_eq!(engine.counts(id), expected.as_bool().unwrap(), "{at} counts {id}");
        assert_eq!(
            state.participant(id).map(|row| row.counts),
            expected.as_bool(),
            "{at} published counts {id}"
        );
    }
}

#[test]
fn mobile_core_replays_terminal_sizing_fixtures_through_the_wire() {
    let corpus: Value = serde_json::from_str(FIXTURES).unwrap();
    let cases = corpus["cases"].as_array().unwrap();
    assert!(!cases.is_empty());
    let mut expects = 0;
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
                    expects += 1;
                    check(&at, &engine, engine.state(), step);
                    let wire = serde_json::to_string(engine.state()).unwrap();
                    let decoded: TerminalSizingState = serde_json::from_str(&wire).unwrap();
                    assert_eq!(&decoded, engine.state(), "{at} wire round trip");
                    check(&format!("{at} (decoded)"), &engine, &decoded, step);
                }
                other => panic!("{at}: unknown op {other}"),
            }
        }
    }
    assert!(expects > 0, "the corpus has no expect steps");
}
