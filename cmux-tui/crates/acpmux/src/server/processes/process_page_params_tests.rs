use super::*;

#[test]
fn a_cursor_requires_a_positive_limited_session_page() {
    assert_eq!(process_page_params(&json!({})).unwrap(), None);
    assert_eq!(process_page_params(&json!({"limit": 1})).unwrap(), Some((1, None)));
    assert_eq!(
        process_page_params(&json!({"limit": 3_000, "cursor": "s/task"})).unwrap(),
        Some((1_000, Some("s/task")))
    );
    for bad in [
        json!({"cursor": "s/task"}),
        json!({"limit": 0}),
        json!({"limit": -1}),
        json!({"limit": "3"}),
        json!({"limit": true}),
        json!({"limit": 1, "cursor": ""}),
        json!({"limit": 1, "cursor": 13}),
    ] {
        assert!(process_page_params(&bad).is_err(), "{bad}");
    }
}
