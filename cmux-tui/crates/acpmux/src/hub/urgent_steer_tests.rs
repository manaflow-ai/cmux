use super::carries_blocker;
use serde_json::json;

#[test]
fn a_notice_with_a_blocker_thread_is_urgent() {
    let p = json!({"kind": "inbox_notice", "threads": [{"blocker": false}, {"blocker": true}]});
    assert!(carries_blocker(Some(&p)));
}

#[test]
fn a_notice_without_one_is_not() {
    let p = json!({"kind": "inbox_notice", "threads": [{"blocker": false}]});
    assert!(!carries_blocker(Some(&p)));
    assert!(!carries_blocker(None));
}
