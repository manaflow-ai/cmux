//! The composer's Stop presence against the corpus the agent pane page's copy
//! (webviews composer/turnPresence.ts, `turnPresence.test.ts`) reads too, so
//! the two cannot drift apart.

use cmux_motion::{
    TURN_PRESENCE_DWELL_MS, TURN_PRESENCE_HOLD_MS, TURN_PRESENCE_LINGER_MS, TurnPresence,
};
use serde_json::Value;

#[test]
fn the_shared_corpus_holds() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/cases/turn_presence.json"
    ))
    .expect("tests/cases/turn_presence.json");
    let doc: Value = serde_json::from_str(&text).expect("the corpus is JSON");
    assert_eq!(doc["dwellMs"].as_u64(), Some(TURN_PRESENCE_DWELL_MS));
    assert_eq!(doc["lingerMs"].as_u64(), Some(TURN_PRESENCE_LINGER_MS));
    assert_eq!(doc["holdMs"].as_u64(), Some(TURN_PRESENCE_HOLD_MS));
    let cases = doc["cases"].as_array().expect("cases");
    assert!(!cases.is_empty());
    for case in cases {
        let name = case["name"].as_str().expect("name");
        let mut model = TurnPresence::new(case["start"].as_bool().expect("start"), 0);
        for step in case["steps"].as_array().expect("steps") {
            let at = step["at"].as_u64().expect("at");
            match step["running"].as_bool() {
                Some(running) => {
                    model.set(running, at, step["immediate"].as_bool().unwrap_or(false));
                }
                None => model.advance(at),
            }
            assert_eq!(model.shown(), step["shown"].as_bool().unwrap(), "{name} at {at}: shown");
            assert_eq!(
                u64::from(model.pulses()),
                step["pulses"].as_u64().unwrap(),
                "{name} at {at}: pulses"
            );
            assert_eq!(model.next_wake(), step["wake"].as_u64(), "{name} at {at}: wake");
        }
    }
}
