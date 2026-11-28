use super::*;

const A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn source(commit: &str, version: &str, tag: Option<&str>) -> GitSource {
    serde_json::from_value(serde_json::json!({
        "repository": "https://github.com/octo/hello",
        "host": "github.com",
        "owner": "octo",
        "repo": "hello",
        "commit": commit,
        "tag": tag,
        "version": version,
        "sha256": "00",
        "dir": "github.com/octo/hello/aaaa",
    }))
    .unwrap()
}

#[test]
fn an_offer_names_the_release_version_else_the_short_commit() {
    let tagged = offer("octo/hello", "Hello", &source(A, "1.0.0", None), B, Some("v1.1.0".into()));
    assert_eq!((tagged.version.as_str(), tagged.current_version.as_str()), ("1.1.0", "1.0.0"));
    assert_eq!(tagged.install_app, format!("github.com/octo/hello@{B}"));
    let branch = offer("octo/hello", "Hello", &source(A, "", Some("v1.0.0")), B, None);
    assert_eq!((branch.version.as_str(), branch.current_version.as_str()), ("bbbbbbb", "1.0.0"));
}

#[test]
fn an_offer_lists_only_while_its_app_stays_installed_at_the_checked_commit() {
    let row = offer("octo/hello", "Hello", &source(A, "1.0.0", None), B, None);
    let installed: BTreeSet<String> = ["octo/hello".to_string()].into();
    let at = |commit: &str| -> BTreeMap<String, Value> {
        [("octo/hello".to_string(), serde_json::json!({"commit": commit}))].into()
    };
    assert!(still_offered(&row, &at(A), &installed));
    assert!(!still_offered(&row, &at(B), &installed), "moved since the check");
    assert!(!still_offered(&row, &at(A), &BTreeSet::new()), "uninstalled");
}

#[test]
fn the_shared_update_list_keeps_both_providers_and_git_consent_details() {
    let community = serde_json::json!({
        "updates": [
            {"app": "a/shared", "version": "2.0", "commit": B},
            {"app": "b/community", "version": "3.0"}
        ],
        "revision": 7,
        "checked_at": 1234
    });
    let git = serde_json::json!({
        "updates": [
            {"app": "a/shared", "version": "1.9", "needs_consent": true,
             "new_scopes": ["workspace:read"], "available": {"commit": B}},
            {"app": "c/git", "needs_consent": false}
        ],
        "checking": true,
        "checked_at": 12,
        "errors": [{"app": "d/offline", "error": "offline"}]
    });
    let merged = merge_update_lists(community, git);
    let rows = merged["updates"].as_array().unwrap();
    assert_eq!(rows.len(), 3, "one row per app, including either provider alone");
    assert_eq!(rows[0]["version"], "2.0", "Community takes precedence");
    assert_eq!(rows[0]["needs_consent"], true);
    assert_eq!(rows[0]["new_scopes"], serde_json::json!(["workspace:read"]));
    assert_eq!(rows[0]["available"]["commit"], B);
    assert_eq!(rows[1]["app"], "b/community");
    assert_eq!(rows[2]["app"], "c/git");
    assert_eq!(merged["checking"], true);
    assert_eq!(merged["checked_at"], 1234);
    assert_eq!(merged["revision"], 7);
    assert_eq!(merged["errors"][0]["app"], "d/offline");
}
