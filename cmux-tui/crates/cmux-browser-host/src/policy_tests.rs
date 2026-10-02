use super::*;

fn url(text: &str) -> Url {
    Url::parse(text).unwrap()
}

fn layer(allowed: Option<&[&str]>, prohibited: &[&str]) -> Layer {
    let parse =
        |list: &[&str]| list.iter().map(|p| DomainPattern::parse(p).unwrap()).collect::<Vec<_>>();
    Layer { allowed: allowed.map(parse), prohibited: parse(prohibited), block_ips: false }
}

#[test]
fn patterns_parse_like_the_runtime() {
    let p = DomainPattern::parse("HTTPS://*.Example.com:8443/path").unwrap();
    assert_eq!(
        (p.scheme.as_deref(), p.host.as_str(), p.port.as_deref()),
        (Some("https"), "*.example.com", Some("8443"))
    );
    assert_eq!(DomainPattern::parse("example.com:*").unwrap().port, None);
    for bad in ["", "  ", "a.*", "*.*.com", "ex*ample.com", "exa mple.com"] {
        assert!(DomainPattern::parse(bad).is_err(), "{bad:?} should be refused");
    }
    assert!(DomainPattern::parse("*").is_ok());
}

#[test]
fn matching_follows_scheme_port_wildcard_and_www_rules() {
    let p = DomainPattern::parse("example.com").unwrap();
    assert!(p.matches(&url("https://example.com/a"), false));
    assert!(p.matches(&url("http://www.example.com/"), false));
    assert!(!p.matches(&url("https://evil-example.com/"), false));
    assert!(!p.matches(&url("ftp://example.com/"), false));
    assert!(!p.matches(&url("http://example.com/"), true), "secure matching needs https");
    assert!(
        DomainPattern::parse("localhost").unwrap().matches(&url("http://localhost:3000/"), true)
    );

    let wild = DomainPattern::parse("*.example.com").unwrap();
    assert!(wild.matches(&url("https://a.b.example.com/"), false));
    assert!(wild.matches(&url("https://example.com/"), false));
    assert!(!wild.matches(&url("https://example.com.evil.test/"), false));

    let ported = DomainPattern::parse("example.com:443").unwrap();
    assert!(ported.matches(&url("https://example.com/"), false));
    assert!(!ported.matches(&url("https://example.com:8443/"), false));
    assert!(
        DomainPattern::parse("ws*://example.com")
            .unwrap()
            .matches(&url("wss://example.com/"), false)
    );
}

#[test]
fn agents_never_open_local_or_internal_schemes() {
    let policy = Policy::default();
    for refused in [
        "file:///etc/passwd",
        "chrome://settings",
        "devtools://x",
        "view-source:https://a.test",
        "javascript:alert(1)",
        "about:config",
    ] {
        assert!(policy.navigation_refusal(refused).is_some(), "{refused} must be refused");
    }
    for allowed in ["https://a.test/", "about:blank", "data:text/html,hi", "example.com"] {
        assert_eq!(policy.navigation_refusal(allowed), None, "{allowed}");
    }
}

#[test]
fn the_agent_layer_only_narrows_the_base_layer() {
    let mut policy = Policy::default();
    policy.set(Writer::Owner, layer(Some(&["example.com", "docs.test"]), &[]), true).unwrap();
    assert!(policy.locked());
    assert!(policy.navigation_refusal("https://other.test/").is_some());

    // The agent tries to widen: the base layer still refuses.
    policy.set(Writer::Agent, layer(Some(&["other.test", "example.com"]), &[]), false).unwrap();
    assert!(policy.navigation_refusal("https://other.test/").is_some());
    assert_eq!(policy.navigation_refusal("https://example.com/"), None);
    // The agent narrows: docs.test is now refused by its own layer.
    assert!(
        policy.navigation_refusal("https://docs.test/").unwrap().contains("session.allowedDomains")
    );

    assert!(policy.set(Writer::Owner, Layer::default(), false).is_err(), "locked");
    policy.set(Writer::Agent, Layer::default(), false).unwrap();
    assert!(
        policy.navigation_refusal("https://other.test/").is_some(),
        "clearing the agent layer keeps the base"
    );
    policy.set(Writer::Agent, Layer::default(), true).unwrap();
    assert!(
        policy.set(Writer::Agent, Layer::default(), false).is_err(),
        "a session lock holds against later VM code"
    );
}

#[test]
fn prohibited_domains_and_ip_blocking_apply_to_subresources() {
    let mut policy = Policy::default();
    let mut base = layer(None, &["ads.test"]);
    base.block_ips = true;
    policy.set(Writer::Owner, base, false).unwrap();
    assert!(
        policy.subresource_refusal(&url("https://cdn.ads.test/x.js")).is_none(),
        "ads.test has no wildcard"
    );
    assert_eq!(
        policy.subresource_refusal(&url("https://ads.test/x.js")).unwrap(),
        "prohibited by ads.test (session.prohibitedDomains)"
    );
    assert_eq!(
        policy.subresource_refusal(&url("http://10.0.0.1/")).unwrap(),
        "IP addresses are blocked (session.blockIPAddresses)"
    );
    assert!(policy.subresource_refusal(&url("http://10.0.0.1/")).is_some());
    assert!(policy.subresource_refusal(&url("http://[::1]/")).is_some());
    assert!(policy.subresource_refusal(&url("data:image/png;base64,AA")).is_none());
}
