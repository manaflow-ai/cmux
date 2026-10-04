use crate::policy::{DomainPattern, Layer, Policy, Writer};

fn policy(allowed: Option<&[&str]>, prohibited: &[&str], block_ips: bool) -> Policy {
    let parse =
        |list: &[&str]| list.iter().map(|p| DomainPattern::parse(p).unwrap()).collect::<Vec<_>>();
    let mut policy = Policy::default();
    let layer = Layer { allowed: allowed.map(parse), prohibited: parse(prohibited), block_ips };
    policy.set(Writer::Agent, layer, false).unwrap();
    policy
}

#[test]
fn no_policy_refuses_no_cookie() {
    let p = Policy::default();
    assert_eq!(p.cookie_refusal("evil.test"), None);
    assert_eq!(p.cookie_set_refusal(".evil.test"), None);
}

#[test]
fn cookies_follow_hosts_not_origins() {
    // A prohibited origin covers its host's cookies, whatever the pattern's
    // scheme and port.
    let p = policy(None, &["http://127.0.0.1:8080"], false);
    assert_eq!(
        p.cookie_refusal("127.0.0.1").as_deref(),
        Some("prohibited by http://127.0.0.1:8080 (session.prohibitedDomains)")
    );
    assert_eq!(p.cookie_refusal("localhost"), None);
    // A leading dot names the same host.
    let p = policy(None, &["peer.test"], false);
    assert!(p.cookie_refusal(".peer.test").is_some());
    assert_eq!(p.cookie_refusal("").as_deref(), Some("the cookie names no domain"));
}

#[test]
fn an_allow_list_covers_the_cookies_its_hosts_receive() {
    let p = policy(Some(&["https://www.parent.test"]), &[], false);
    assert_eq!(p.cookie_refusal("www.parent.test"), None);
    // www.parent.test receives cookies set on parent.test.
    assert_eq!(p.cookie_refusal("parent.test"), None);
    assert_eq!(
        p.cookie_refusal("other.test").as_deref(),
        Some("not in session.allowedDomains (https://www.parent.test)")
    );
    assert_eq!(
        policy(Some(&["a.test"]), &[], false).cookie_refusal("").as_deref(),
        Some("the cookie names no domain")
    );
}

#[test]
fn ip_hosts_are_refused_while_ip_addresses_are_blocked() {
    let p = policy(None, &[], true);
    assert_eq!(
        p.cookie_refusal("127.0.0.1").as_deref(),
        Some("IP addresses are blocked (session.blockIPAddresses)")
    );
    assert_eq!(p.cookie_refusal("example.test"), None);
}

#[test]
fn a_domain_cookie_must_not_reach_hosts_outside_the_policy() {
    let p = policy(Some(&["https://www.parent.test"]), &[], false);
    assert_eq!(
        p.cookie_set_refusal(".parent.test").as_deref(),
        Some(
            "a cookie on parent.test reaches its other subdomains, which session.allowedDomains (https://www.parent.test) does not all allow; set it on the allowed host itself"
        )
    );
    assert_eq!(p.cookie_set_refusal("www.parent.test"), None);
    let p = policy(Some(&["*.parent.test"]), &[], false);
    assert_eq!(p.cookie_set_refusal(".parent.test"), None);
    let p = policy(None, &["api.parent.test"], false);
    assert_eq!(
        p.cookie_set_refusal(".parent.test").as_deref(),
        Some("a cookie on parent.test reaches api.parent.test (session.prohibitedDomains)")
    );
    assert_eq!(p.cookie_set_refusal("www.parent.test"), None);
}
