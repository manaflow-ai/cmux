use super::{equal_without_workspace_key, without_workspace_key};
use serde_json::json;

/// The in-place comparison answers as the copying one did.
#[test]
fn the_comparison_in_place_matches_the_copies() {
    let values = [
        json!({"id": "w", "name": "a"}),
        json!({"id": "w", "name": "b"}),
        json!({"id": "w", "name": "a", "extra": {}}),
        json!({"id": "w", "name": "a", "extra": {"key": "k"}}),
        json!({"id": "w", "name": "a", "extra": {"key": "k2"}}),
        json!({"id": "w", "name": "a", "extra": {"key": "k", "title": "t"}}),
        json!({"id": "w", "name": "a", "extra": {"title": "t"}}),
        json!({"id": "w", "name": "a", "extra": {"title": "u"}}),
        json!({"id": "w", "name": "a", "extra": {"title": "t", "color": "c"}}),
        json!({"id": "w", "name": "a", "focused": true}),
        json!({"id": "w", "extra": {"key": "k"}}),
        json!({"id": "w", "name": "a", "extra": "odd"}),
        json!("not an object"),
    ];
    for a in &values {
        for b in &values {
            assert_eq!(
                equal_without_workspace_key(a, b),
                without_workspace_key(a) == without_workspace_key(b),
                "{a} vs {b}"
            );
        }
    }
}
