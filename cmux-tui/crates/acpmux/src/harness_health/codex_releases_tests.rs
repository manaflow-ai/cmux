use super::*;
use serde_json::json;

#[test]
fn only_visible_rows_and_stable_release_tags_supply_evidence() {
    assert!(catalog_url("0.171.0").is_some());
    assert!(catalog_url("0.171.0/other").is_none());
    let rows = json!({"models":[{"slug":"public","visibility":"list"},{"slug":"private","visibility":"hide"}]});
    assert_eq!(visible(&rows).unwrap().into_keys().collect::<Vec<_>>(), ["public"]);
    assert!(visible(&json!({"models":[]})).is_none());
}
