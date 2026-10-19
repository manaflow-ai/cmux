use cmux_cloud_wire::{InstallAuthorityResult, ReadResponse};
use serde_json::json;

#[test]
fn install_authority_preserves_the_bound_identity_and_requires_a_complete_reply() {
    let value = json!({
        "user": "user_aaaaaaaaaaaaaaaaaaaa", "team": "team_bbbbbbbbbbbbbbbbbbbb",
        "install": "inst_cccccccccccccccccccc", "grant": "grant_dddddddddddddddddddd",
        "authority_version": "e".repeat(64)
    });
    let response = json!({"op": "install.authority", "value": value, "stream": "user:user_aaaaaaaaaaaaaaaaaaaa", "revision": "17"});
    let decoded: ReadResponse<InstallAuthorityResult> =
        serde_json::from_value(response.clone()).unwrap();
    assert_eq!(serde_json::to_value(decoded).unwrap(), response);
    for field in ["user", "team", "install", "grant", "authority_version"] {
        let mut missing = response.clone();
        missing["value"].as_object_mut().unwrap().remove(field);
        assert!(serde_json::from_value::<ReadResponse<InstallAuthorityResult>>(missing).is_err());
    }
}
