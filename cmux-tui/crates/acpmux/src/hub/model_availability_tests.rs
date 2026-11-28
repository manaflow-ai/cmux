use super::*;
use serde_json::json;

#[test]
fn provider_refusal_survives_a_bundled_release_offer() {
    let mut rows =
        [json!({"id": "m", "codexUpdateVersion": "1.2.0", "unavailable": "Update Codex"})];
    let refused = HashMap::from([(("codex".into(), "m".into()), "Provider refused".into())]);
    mark_unavailable(&mut rows, "codex", &refused);
    assert_eq!(rows[0], json!({"id": "m", "unavailable": "Provider refused"}));
}
