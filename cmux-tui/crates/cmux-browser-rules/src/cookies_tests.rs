//! Cookie matching, clear scoping and `cookies.set` reading.

use crate::cookies::*;

fn url(scheme: &str, host: &str, path: &str) -> UrlParts {
    UrlParts { scheme: Some(scheme.into()), host: Some(host.into()), path: path.into() }
}

fn facts(domain: &str, path: &str, secure: bool) -> CookieFacts {
    CookieFacts { domain: domain.into(), path: path.into(), secure }
}

#[test]
fn a_clear_covers_the_host_its_parents_and_its_subdomains_not_siblings() {
    let host = "app.example.com";
    assert!(in_scope("app.example.com", host));
    assert!(in_scope(".app.example.com", host));
    assert!(in_scope(".EXAMPLE.com", host));
    assert!(in_scope("example.com", host));
    assert!(in_scope("deep.app.example.com", host));
    assert!(!in_scope("other.example.com", host));
    assert!(!in_scope("notexample.com", "example.com"));
    assert!(!in_scope("", host));
    assert!(!in_scope("...", host));
}

#[test]
fn a_cookie_is_sent_to_its_domain_and_subdomains() {
    let c = facts(".example.com", "/", false);
    assert!(cookie_matches(&c, &url("http", "example.com", "")));
    assert!(cookie_matches(&c, &url("http", "WWW.Example.com", "/x")));
    assert!(!cookie_matches(&c, &url("http", "badexample.com", "/")));
    assert!(!cookie_matches(&c, &UrlParts { scheme: None, host: None, path: "/".into() }));
}

#[test]
fn a_secure_cookie_needs_https() {
    let c = facts("example.com", "/", true);
    assert!(!cookie_matches(&c, &url("http", "example.com", "/")));
    assert!(cookie_matches(&c, &url("https", "example.com", "/")));
}

#[test]
fn paths_match_on_a_segment_boundary() {
    let c = facts("example.com", "/app", false);
    assert!(cookie_matches(&c, &url("https", "example.com", "/app")));
    assert!(cookie_matches(&c, &url("https", "example.com", "/app/x")));
    assert!(!cookie_matches(&c, &url("https", "example.com", "/apple")));
    assert!(!cookie_matches(&c, &url("https", "example.com", "")));
    let slash = facts("example.com", "/app/", false);
    assert!(cookie_matches(&slash, &url("https", "example.com", "/app/x")));
}

#[test]
fn no_urls_lists_every_cookie() {
    let c = facts("example.com", "/", false);
    assert!(cookie_listed(&c, &[]));
    assert!(!cookie_listed(&c, &[url("https", "other.com", "/")]));
    assert!(cookie_listed(&c, &[url("https", "other.com", "/"), url("https", "example.com", "/")]));
}

#[test]
fn clear_filters_are_exact_and_an_empty_one_is_none() {
    let c = StoredCookie { name: "sid".into(), domain: ".example.com".into(), path: "/".into() };
    let f = |name: &str, domain: &str, path: &str| ClearFilter {
        name: Some(name.into()),
        domain: Some(domain.into()),
        path: Some(path.into()),
    };
    assert!(clear_matches(&c, "example.com", &ClearFilter::default()));
    assert!(clear_matches(&c, "example.com", &f("", "", "")));
    assert!(clear_matches(&c, "example.com", &f("sid", ".example.com", "/")));
    assert!(!clear_matches(&c, "example.com", &f("SID", "", "")));
    assert!(!clear_matches(&c, "example.com", &f("", "example.com", "")));
    assert!(!clear_matches(&c, "other.org", &ClearFilter::default()));
}

#[test]
fn clear_scopes_to_an_http_page() {
    assert_eq!(clear_site(Some("https"), Some("Example.COM")), Ok("example.com".into()));
    assert_eq!(
        clear_site(Some("about"), None).unwrap_err(),
        "cookies.clear: the tab shows a about: page, so it has no site to scope to; open the \
         site first"
    );
    assert!(clear_site(None, None).unwrap_err().contains("shows no page,"));
    assert!(clear_site(Some("https"), Some("")).is_err());
    assert!(clear_site(Some("file"), Some("h")).is_err());
}

#[test]
fn setting_an_expired_cookie_is_refused() {
    assert!(set_refusal(Some(50.0), 100.0).is_some());
    assert!(set_refusal(Some(100.0), 100.0).is_some());
    assert!(set_refusal(Some(0.0), 100.0).is_some());
    assert!(set_refusal(Some(-1.0), 100.0).is_none());
    assert!(set_refusal(Some(101.0), 100.0).is_none());
    assert!(set_refusal(None, 100.0).is_none());
}

#[test]
fn same_site_is_capitalized() {
    assert_eq!(same_site_label("lax"), "Lax");
    assert_eq!(same_site_label("strict"), "Strict");
    assert_eq!(same_site_label(""), "");
}

fn fields() -> PlaywrightFields {
    PlaywrightFields { name: Some("a".into()), value: Some("1".into()), ..Default::default() }
}

#[test]
fn a_playwright_cookie_needs_a_name_a_value_and_a_site() {
    let mut f = fields();
    f.name = None;
    assert_eq!(
        playwright_cookie(&f).unwrap_err(),
        "cookies.set: each cookie needs a name and a value"
    );
    assert_eq!(
        playwright_cookie(&fields()).unwrap_err(),
        "cookies.set: cookie a needs a url, or a domain and a path"
    );
    let mut f = fields();
    f.domain = Some("example.com".into());
    let c = playwright_cookie(&f).unwrap();
    assert_eq!((c.path.as_str(), c.expires, c.secure), ("/", -1.0, false));
}

#[test]
fn a_url_gives_the_domain_and_the_directory_path() {
    let with = |path: &str| PlaywrightFields {
        url: Some("https://x".into()),
        url_host: Some("x.example.com".into()),
        url_path: Some(path.into()),
        ..fields()
    };
    assert_eq!(playwright_cookie(&with("/a/b")).unwrap().path, "/a");
    assert_eq!(playwright_cookie(&with("/a/b/")).unwrap().path, "/a/b/");
    assert_eq!(playwright_cookie(&with("/a")).unwrap().path, "/");
    assert_eq!(playwright_cookie(&with("")).unwrap().path, "/");
    assert_eq!(playwright_cookie(&with("/a")).unwrap().domain, "x.example.com");
    let mut explicit = with("/a/b");
    explicit.path = Some("/keep".into());
    assert_eq!(playwright_cookie(&explicit).unwrap().path, "/keep");
    let mut bad = with("/");
    bad.url = Some("nope".into());
    bad.url_host = None;
    assert_eq!(
        playwright_cookie(&bad).unwrap_err(),
        "cookies.set: url: expected an http(s) URL, got nope"
    );
}
