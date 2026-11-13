//! The pick a gesture ticket is bound to (tests/cases/picks.json; Swift
//! `AgentPaneGesturePick`): a prompt's own id without a hand-off turn's
//! label, a question's answers and annotations by the sha256 of their
//! canonical JSON (`AcpmuxSecretKey.canonicalDigest`, acpmux
//! `approvers::canonical_json`), and numbers compared as Swift's Double.

use cmux_agent_pane_policy::check::GesturePick;
use serde_json::Value;
use std::path::Path;

#[test]
fn gesture_picks() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases/picks.json");
    let cases: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let cases = cases.as_array().unwrap();
    assert!(!cases.is_empty(), "picks.json holds no cases");
    for c in cases {
        let name = c["name"].as_str().unwrap();
        let params = c["params"].as_object().cloned().unwrap_or_default();
        let got = GesturePick::new(c["method"].as_str(), &params);
        let want = &c["pick"];
        assert_eq!(got.method.as_deref(), want["method"].as_str(), "{name} method");
        let got_params = got.params.map(|p| Value::Object(p.into_iter().collect()));
        assert_eq!(got_params.unwrap_or(Value::Null), want["params"], "{name} params");
    }
}
