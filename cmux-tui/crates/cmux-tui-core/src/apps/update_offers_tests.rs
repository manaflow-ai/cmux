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
