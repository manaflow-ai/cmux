use super::*;

fn grants(list: &[&str]) -> BTreeSet<String> {
    list.iter().map(|s| s.to_string()).collect()
}

#[test]
fn only_granted_https_hosts_pass_and_credentials_are_stripped() {
    let g = grants(&["net:api.github.com", "net:*.example.com"]);
    let ok = admit(&json!({ "url": "https://api.github.com/x", "headers": { "Authorization": "t", "Cookie": "c", "Accept": "a" } }), &g, false).unwrap();
    assert_eq!(ok.headers, vec![("Accept".to_string(), "a".to_string())]);
    assert!(admit(&json!({ "url": "https://a.b.example.com/" }), &g, false).is_ok());
    assert_eq!(
        admit(&json!({ "url": "https://example.com/" }), &g, false).unwrap_err().code,
        "scope.missing"
    );
    assert_eq!(
        admit(&json!({ "url": "https://evilexample.com/" }), &g, false).unwrap_err().code,
        "scope.missing"
    );
    assert_eq!(
        admit(&json!({ "url": "http://api.github.com/" }), &g, false).unwrap_err().code,
        "scope.missing"
    );
    assert_eq!(
        admit(&json!({ "url": "https://user:pw@api.github.com/" }), &g, false).unwrap_err().code,
        "scope.missing"
    );
    assert_eq!(
        admit(&json!({ "url": "https://other.org/" }), &g, false).unwrap_err().code,
        "scope.missing"
    );
}

#[test]
fn sandboxed_apps_never_reach_the_network() {
    let g = grants(&["net:api.github.com"]);
    assert_eq!(
        admit(&json!({ "url": "https://api.github.com/" }), &g, true).unwrap_err().code,
        "scope.missing"
    );
}
