use super::*;

#[test]
fn reads_the_parts_of_an_origin() {
    let parts = parse("HTTPS://u:p@Example.COM:8443/a/b?q=1#f").expect("parts");
    assert_eq!(parts.scheme, "https");
    assert_eq!((parts.user, parts.password), (Some("u"), Some("p")));
    assert_eq!(parts.host, "example.com");
    assert_eq!(parts.port, Some("8443"));
    assert_eq!(parts.path, "/a/b");
    assert_eq!((parts.query, parts.fragment), (Some("q=1"), Some("f")));
    assert_eq!(host("http://[::1]:3777"), Some("::1".to_owned()));
    assert_eq!(host("not a url"), None);
    assert!(parse("1x://host").is_none());
}

#[test]
fn loopback_is_this_machine_or_no_host() {
    for url in
        ["http://localhost:3777", "http://127.0.0.1", "http://[::1]:1", "garbage", "file:///tmp"]
    {
        assert!(is_loopback(url), "{url}");
    }
    for url in ["https://cmux.com", "http://127.0.0.2", "https://localhost.example"] {
        assert!(!is_loopback(url), "{url}");
    }
}

#[test]
fn a_bare_origin_has_nothing_but_scheme_and_host() {
    assert!(is_bare_https_origin("https://cloud-api.cmux.dev"));
    assert!(is_bare_https_origin("https://cloud-api.cmux.dev/"));
    for url in [
        "http://cloud-api.cmux.dev",
        "https://cloud-api.cmux.dev:443",
        "https://u@cloud-api.cmux.dev",
        "https://cloud-api.cmux.dev/v1",
        "https://cloud-api.cmux.dev?x",
        "https://cloud-api.cmux.dev#x",
        "https://",
    ] {
        assert!(!is_bare_https_origin(url), "{url}");
    }
}
