use super::prompt_suggestions_forced;
use serde_json::json;

#[test]
fn only_a_managed_push_forces_and_a_non_boolean_is_off() {
    let forced = |p| prompt_suggestions_forced(&p).unwrap();
    assert_eq!(forced(json!({})), None, "an older app sends neither key");
    assert_eq!(forced(json!({"promptSuggestions": false})), None, "not managed: the file decides");
    assert_eq!(forced(json!({"promptSuggestionsManaged": null})), None);
    assert_eq!(
        forced(json!({"promptSuggestions": false, "promptSuggestionsManaged": true})),
        Some(false)
    );
    assert_eq!(
        forced(json!({"promptSuggestions": true, "promptSuggestionsManaged": true})),
        Some(true)
    );
    assert_eq!(
        forced(json!({"promptSuggestions": "true", "promptSuggestionsManaged": true})),
        Some(false)
    );
    assert_eq!(forced(json!({"promptSuggestionsManaged": true})), Some(false));
    assert!(prompt_suggestions_forced(&json!({"promptSuggestionsManaged": "yes"})).is_err());
}
