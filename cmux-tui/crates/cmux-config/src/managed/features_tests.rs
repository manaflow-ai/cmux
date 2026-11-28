use serde_json::json;

use super::*;

#[test]
fn absent_turns_nothing_off() {
    assert_eq!(disabled_features(None), (Vec::new(), None));
}

#[test]
fn a_malformed_value_turns_everything_off() {
    for value in [json!("mcp"), json!(["mcp", 3]), json!({})] {
        let (features, problem) = disabled_features(Some(&value));
        assert_eq!(features, FEATURES.to_vec());
        assert!(problem.is_some());
    }
}

#[test]
fn unknown_names_are_reported_and_the_rest_applies() {
    let (features, problem) = disabled_features(Some(&json!(["mcp", "bogus", "cloud"])));
    assert_eq!(features, vec!["mcp", "cloud"]);
    assert_eq!(
        problem.as_deref(),
        Some(
            "DisabledFeatures names unknown features bogus (known: computerUse, browserAutomation, mcp, cloud, apps, remoteHosts)"
        )
    );
}
