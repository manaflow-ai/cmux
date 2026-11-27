//! `DisabledFeatures` (Swift `ManagedPreferences.disabledFeatures`): a
//! malformed value turns every feature off (the administrator meant to
//! restrict), an unknown name is reported and ignored, and a problem never
//! turns a feature on.

use serde_json::Value;

/// The features an action can belong to (Swift `ActionFeature`), in case order.
pub const FEATURES: [&str; 6] =
    ["computerUse", "browserAutomation", "mcp", "cloud", "apps", "remoteHosts"];

/// `(features, problem message)` for the forced policy value of `DisabledFeatures`.
pub fn disabled_features(value: Option<&Value>) -> (Vec<&'static str>, Option<String>) {
    let Some(value) = value else { return (Vec::new(), None) };
    let items = value.as_array().filter(|items| items.iter().all(Value::is_string));
    let Some(items) = items else {
        return (
            FEATURES.to_vec(),
            Some("DisabledFeatures must be an array of feature names; every feature is turned off until it is fixed".into()),
        );
    };
    let names: Vec<&str> = items.iter().filter_map(Value::as_str).collect();
    let unknown: Vec<&str> = names.iter().copied().filter(|n| !FEATURES.contains(n)).collect();
    let features: Vec<&'static str> =
        FEATURES.iter().copied().filter(|f| names.contains(f)).collect();
    let problem = (!unknown.is_empty()).then(|| {
        format!(
            "DisabledFeatures names unknown features {} (known: {})",
            unknown.join(", "),
            FEATURES.join(", ")
        )
    });
    (features, problem)
}

#[cfg(test)]
mod tests {
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
}
