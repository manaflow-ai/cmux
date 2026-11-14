use super::*;

/// A save answered with `status` and `body`.
fn save_refused(status: u16, body: Value) -> CloudError {
    refused(&HttpReply { status, body }).expect_err("a refused save fails")
}

#[test]
fn a_vault_code_reaches_the_sheet_and_an_upstream_message_never_does() {
    for status in [400, 503] {
        let error = save_refused(
            status,
            json!({"_tag": "MachineBadRequest", "code": "vault.secret_without_host",
                       "message": "TOKEN=hunter2 has no host"}),
        );
        let CloudError::Rejected { code, message, retryable } = &error else {
            panic!("{status}: {error:?}");
        };
        assert_eq!(code, "vault.secret_without_host");
        assert_eq!(*retryable, status >= 500);
        assert!(!message.contains("hunter2"), "{message}");
    }
}

#[test]
fn a_code_outside_the_sheets_prefixes_is_not_forwarded_nor_its_message() {
    for (status, body) in [
        (400, json!({"code": "other.thing", "message": "hunter2"})),
        (400, json!({"error": {"code": "other.thing", "message": "hunter2"}})),
        (400, json!({"code": "vault.has space", "message": "hunter2"})),
        (400, json!({"code": format!("vault.{}", "a".repeat(128)), "message": "hunter2"})),
        (503, json!({"code": "other.thing", "message": "hunter2"})),
    ] {
        let error = save_refused(status, body);
        let text = format!("{error:?}");
        assert!(!text.contains("other.thing") && !text.contains("vault."), "{text}");
        assert!(!text.contains("hunter2"), "{text}");
        match error {
            CloudError::Rejected { code, .. } => assert_eq!(code, format!("http_{status}")),
            CloudError::Unavailable(_) => assert_eq!(status, 503),
            other => panic!("{other:?}"),
        }
    }
}

#[test]
fn redact_keeps_only_a_secrets_name_dates_hosts_and_header_name_and_format() {
    let mut environment = json!({
        "id": "env_a",
        "secrets": [{
            "name": "TOKEN",
            "updated_at": 3,
            "value": "hunter2",
            "sealed": "v2.abc",
            "hosts": ["api.example.com", {"value": "hunter2"}],
            "header": {
                "name": "authorization",
                "format": "Bearer {value}",
                "value": "hunter2",
                "nested": {"value": "hunter2"},
            },
        }, "hunter2"],
    });
    redact(&mut environment);
    assert_eq!(
        environment,
        json!({
            "id": "env_a",
            "secrets": [{
                "name": "TOKEN",
                "updated_at": 3,
                "hosts": ["api.example.com"],
                "header": {"name": "authorization", "format": "Bearer {value}"},
            }],
        })
    );
    assert!(!environment.to_string().contains("hunter2"));
}

#[test]
fn redact_drops_a_partial_header_or_hosts_that_is_not_the_expected_shape() {
    let mut environment = json!({
        "secrets": [
            {"name": "TOKEN", "header": "Bearer hunter2", "hosts": "hunter2"},
            {"name": "PARTIAL", "header": {"name": "authorization"}},
            {"name": "NOT_TEXT", "header": {"name": "authorization", "format": 7}},
        ],
    });
    redact(&mut environment);
    assert_eq!(
        environment,
        json!({"secrets": [{"name": "TOKEN"}, {"name": "PARTIAL"}, {"name": "NOT_TEXT"}]})
    );
}
