use super::*;
use serde_json::json;

#[test]
fn segments_refuse_escapes() {
    assert!(relative_segments("/etc").is_err());
    assert!(relative_segments("web/../..").is_err());
    assert!(relative_segments("web\\x").is_err());
    assert_eq!(relative_segments("./web//a").unwrap(), ["web", "a"]);
}

#[test]
fn no_app_csp_is_the_strict_policy_plus_closed_extras() {
    assert_eq!(
        effective_csp(None),
        "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; \
             img-src 'self' data:; font-src 'self' data:; worker-src 'self'; base-uri 'none'; form-action 'none'"
    );
}

#[test]
fn host_maps_the_id_slash() {
    assert_eq!(app_page_host("local/my-app"), "local.my-app");
    let m = json!({"id": "a/b", "runtime": {"web": {"root": "web/"}},
                       "implements": {"cmux.pane/1": {"web": "web/x/i.html"}}});
    assert_eq!(web_pages(&m)[0].url, "cmux-app://a.b/x/i.html");
}
