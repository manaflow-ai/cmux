use super::*;

#[test]
fn the_apps_sign_in_is_the_runs_account() {
    let status = json!({ "signed_in": true, "restoring": false, "email": "a@b.c",
                             "user_id": "u1", "team_id": "team_1", "backend": "https://x" });
    assert_eq!(
        account(&status),
        json!({ "account": { "signed_in": true, "user_id": "u1", "team_id": "team_1" } })
    );
    let personal = json!({ "signed_in": true, "user_id": "u1", "team_id": null });
    assert_eq!(account(&personal)["account"]["team_id"], Value::Null);
    let out = json!({ "signed_in": false, "user_id": null, "team_id": null });
    assert_eq!(account(&out)["account"]["signed_in"], false);
    // An answer that names no sign-in is signed out, never a guess.
    assert_eq!(account(&json!({}))["account"]["signed_in"], false);
}
