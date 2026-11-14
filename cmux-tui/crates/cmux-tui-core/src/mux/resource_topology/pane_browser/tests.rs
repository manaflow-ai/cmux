use super::*;

fn fields(value: Value) -> Map<String, Value> {
    value.as_object().unwrap().clone()
}

/// Restart recovery looks for the right evidence: a browser-pane split
/// was a browser creation, a plain split a terminal creation.
#[test]
fn browser_pane_split_recovers_as_a_browser_creation() {
    let browser = fields(json!({"direction":"right", PANE_BROWSER_URL_FIELD:"https://a.test"}));
    let terminal = fields(json!({"direction":"right"}));
    assert_eq!(
        creation_identity_kind(ResourceOperation::PaneSplit, &browser),
        Some(CreatedIdentityKind::Browser)
    );
    assert_eq!(
        creation_identity_kind(ResourceOperation::PaneSplit, &terminal),
        Some(CreatedIdentityKind::Terminal)
    );
    assert_eq!(
        creation_identity_kind(ResourceOperation::PaneCreate, &browser),
        Some(CreatedIdentityKind::Terminal),
        "only pane.split reads the browser field"
    );
}

#[test]
fn browser_pane_fields_refuse_terminal_fields_and_empty_urls() {
    let url = "https://a.test";
    assert!(validate_pane_browser_fields(&fields(json!({PANE_BROWSER_URL_FIELD:url}))).is_ok());
    assert!(validate_pane_browser_fields(&fields(json!({PANE_BROWSER_URL_FIELD:""}))).is_err());
    assert!(validate_pane_browser_fields(&fields(json!({PANE_BROWSER_URL_FIELD:3}))).is_err());
    for field in TERMINAL_ONLY_FIELDS {
        let mut request = fields(json!({PANE_BROWSER_URL_FIELD:url}));
        request.insert(field.to_string(), json!("x"));
        assert!(validate_pane_browser_fields(&request).is_err(), "{field}");
    }
}
