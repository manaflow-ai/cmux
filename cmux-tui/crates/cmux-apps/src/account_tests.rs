use super::*;

#[test]
fn only_two_reads_route() {
    assert_eq!(route(&json!({"op": "list"})).unwrap(), "/v1/cloud/apps");
    assert_eq!(
        route(&json!({"op": "get", "slug": "invoice-triage"})).unwrap(),
        "/v1/cloud/apps/invoice-triage"
    );
    for bad in [
        json!({"op": "get", "slug": "../machines"}),
        json!({"op": "get", "slug": "a/b"}),
        json!({"op": "get"}),
        json!({"op": "rollback", "slug": "x"}),
        json!({"op": "promote"}),
        json!({}),
        json!("list"),
    ] {
        assert_eq!(route(&bad).unwrap_err()["ok"], false, "{bad}");
    }
}

#[test]
fn answers_keep_the_platform_code() {
    let ok = answer(200, br#"{"items":[]}"#);
    assert_eq!(ok, json!({"ok": true, "value": {"items": []}}));
    let refused = answer(403, br#"{"error":{"code":"auth.forbidden","message":"no"}}"#);
    assert_eq!(refused["error"]["code"], "auth.forbidden");
    assert_eq!(refused["error"]["status"], 403);
    assert_eq!(answer(502, b"<html>")["error"]["code"], "http_502");
    assert_eq!(answer(200, b"[]")["error"]["code"], "cloud.app.bad_reply");
}

#[test]
fn ls_lists_the_platform_apps() {
    let relayed = json!({"ok": true, "value": {"items": [
        {"id": "app_1", "slug": "demo", "name": "Demo", "team": "team_x", "creator": "user_y",
         "hostname": "a-demo--abcdefgh.preview.cmux.dev", "url": "https://a-demo--abcdefgh.preview.cmux.dev",
         "live": 2, "pinned": false, "createdAt": "2026-11-23T00:00:00Z"}
    ]}});
    let out = ls_output(true, &relayed);
    assert_eq!(out.code, 0);
    let body: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(body["source"], "account");
    assert_eq!(body["items"][0]["slug"], "demo");
    assert_eq!(body["items"][0]["live"], 2);
    assert_eq!(body["items"][0]["url"], "https://a-demo--abcdefgh.preview.cmux.dev");
    let text = ls_output(false, &relayed);
    assert_eq!(text.stdout, "demo\tv2\thttps://a-demo--abcdefgh.preview.cmux.dev\n");
}

#[test]
fn a_refusal_is_an_error_not_an_empty_list() {
    let relayed = json!({"ok": false, "error": {"code": "not_signed_in", "message": "sign in"}});
    let out = ls_output(true, &relayed);
    assert_eq!(out.code, 1);
    let body: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(body["error"]["code"], "not_signed_in");
    assert!(body.get("items").is_none());
    let text = ls_output(false, &relayed);
    assert_eq!(text.code, 1);
    assert!(text.stderr.contains("not_signed_in"));
}

#[test]
fn versions_marks_live() {
    let relayed = json!({"ok": true, "value": {
    "app": {"slug": "demo", "name": "Demo", "live": 2},
    "versions": [
        {"n": 2, "commit": "0123456789abcdef0123", "command": "npm start", "state": "live"},
        {"n": 1, "commit": "fedcba9876543210fedc", "command": "npm start", "state": "retired"}
    ]}});
    let out = versions_output(false, &relayed);
    assert_eq!(
        out.stdout,
        "v2\tlive (live)\t0123456789ab\tnpm start\nv1\tretired\tfedcba987654\tnpm start\n"
    );
    let body: Value = serde_json::from_str(&versions_output(true, &relayed).stdout).unwrap();
    assert_eq!(body["versions"].as_array().unwrap().len(), 2);
}
