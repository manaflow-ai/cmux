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
fn a_trailing_dot_does_not_escape_prohibited_domains() {
    let mut policy = Policy::default();
    policy.set(Writer::Owner, layer(None, &["evil.com"]), false).unwrap();
    assert!(policy.navigation_refusal("https://evil.com./x").is_some());
    assert!(policy.navigation_refusal("https://sub.evil.com./").is_none(), "no wildcard");
}

/// The same rule as the app's AgentURLPolicy (CmuxNextBrowser/Core) and the
/// shim's AgentRefusesURL (CEFShim/src/agent_url_policy.h). Their tests read
/// the same file, so the three copies cannot drift.
#[test]
fn browser_pages_follow_the_shared_agent_url_vectors() {
    let doc: serde_json::Value =
        serde_json::from_str(include_str!("../../../../schemas/agent-url-policy/vectors.json"))
            .unwrap();
    let cases = doc["cases"].as_array().unwrap();
    assert!(cases.len() >= 20);
    for case in cases {
        let url = case["url"].as_str().unwrap();
        let refused = case["refused"].as_bool().unwrap();
        assert_eq!(is_browser_page(url), refused, "{url:?}");
    }
}

#[test]
fn patterns_compare_host_names_as_urls_do() {
    // A trailing dot names the same host, in the pattern and in the URL.
    let dotted = DomainPattern::parse("example.com.").unwrap();
    assert!(dotted.matches(&url("https://example.com/"), false));
    assert!(dotted.matches(&url("https://www.example.com./"), false));
    // Internationalized labels compare in Punycode, as the URL parser stores them.
    let idn = DomainPattern::parse("Bücher.example").unwrap();
    assert!(idn.matches(&url("https://xn--bcher-kva.example/"), false));
    assert!(idn.matches(&url("https://BÜCHER.example/"), false));
    let wild = DomainPattern::parse("*.bücher.example").unwrap();
    assert!(wild.matches(&url("https://shop.xn--bcher-kva.example/"), false));
    assert!(!idn.matches(&url("https://bucher.example/"), false));
}
