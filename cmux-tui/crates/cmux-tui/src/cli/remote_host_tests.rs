use serde_json::json;

use super::still_open;

#[test]
fn a_confirmation_past_its_wait_says_the_dialog_still_counts() {
    let expected = crate::localization::catalog().app_control.remote_confirm_still_open;
    let read = json!({"code": "app.transport", "message": "the cmux app did not answer", "details": {"timeout_seconds": 130}});
    assert_eq!(still_open(read)["message"], expected);
    let app =
        json!({"code": "timeout", "message": "remote.confirm did not finish within 130000 ms"});
    assert_eq!(still_open(app)["message"], expected);
    let other = json!({"code": "app.unreachable", "message": "no app"});
    assert_eq!(still_open(other.clone()), other);
}
