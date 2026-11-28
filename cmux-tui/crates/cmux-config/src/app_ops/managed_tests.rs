use super::*;

fn run(op: &str, request: Value) -> Value {
    call(op, &request).expect("known op").expect("answers")
}

#[test]
fn manifest_lists_five_files() {
    let files = run("managed.manifest", json!({}));
    assert_eq!(files["files"].as_array().map(Vec::len), Some(5));
}

#[test]
fn policy_keys_match_the_table() {
    let keys = run("managed.policy_keys", json!({}));
    assert_eq!(keys["keys"].as_array().map(Vec::len), Some(POLICY_KEYS.len()));
    assert_eq!(keys["keys"][4]["choices"], json!(["stable", "nightly"]));
}

#[test]
fn enrollment_token_is_forced_and_trimmed() {
    assert_eq!(
        run("managed.enrollment_token", json!({ "forced": { "EnrollmentToken": "  abc \n" } })),
        json!({ "token": "abc" })
    );
    assert_eq!(
        run("managed.enrollment_token", json!({ "forced": { "EnrollmentToken": " " } })),
        json!({})
    );
    assert_eq!(run("managed.enrollment_token", json!({})), json!({}));
}

/// Swift `TeamPolicyLayerCatalogTests`: only keys of the catalog survive, and an unmanaged policy is `{}`.
#[test]
fn device_policy_layer_is_limited_to_the_catalog() {
    let layer = run(
        "managed.device_policy_layer",
        json!({ "value": {
            "managed": true, "team": "team_1", "team_name": "T", "version": 2,
            "defaults": { "browser.searchEngine": "kagi", "nonsense.key": 1 },
            "enforced": { "shortcuts": {}, "app.language": "en" },
        } }),
    );
    assert_eq!(layer["team"], "team_1");
    assert_eq!(layer["version"], 2);
    assert_eq!(layer["defaults"], json!({ "browser.searchEngine": "kagi" }));
    assert_eq!(layer["enforced"], json!({ "app.language": "en" }));
    assert_eq!(
        run("managed.device_policy_layer", json!({ "value": { "managed": false } })),
        json!({})
    );
}

#[test]
fn enrollment_hash_is_base64url_sha256_without_padding() {
    let hash = run("managed.enrollment_token_hash", json!({ "token": "abc" }));
    assert_eq!(hash["hash"], "ungWv48Bz-pBQUDeXa4iI7ADYaOWF3qctBD_YfIAFa0");
}

#[test]
fn disabled_features_op_reports_a_problem() {
    let out = run("managed.disabled_features", json!({ "value": "mcp" }));
    assert_eq!(out["features"].as_array().map(Vec::len), Some(6));
    assert!(out["problem"].is_string());
}
