use super::offered;
use serde_json::json;

#[test]
fn only_a_default_expose_offers_an_op() {
    assert!(offered(&json!({ "mcp": { "expose": "default" } })));
    for entry in [
        json!({ "mcp": { "expose": "opt_in" } }),
        json!({ "mcp": { "expose": "never" } }),
        json!({ "mcp": {} }),
        json!({}),
    ] {
        assert!(!offered(&entry), "{entry}");
    }
}
