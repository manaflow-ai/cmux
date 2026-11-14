use super::*;

#[test]
fn raw_cdp_allows_inspection_domains_only() {
    assert!(raw_cdp_allowed("DOM.getDocument"));
    assert!(raw_cdp_allowed("Runtime.evaluate"));
    for refused in [
        "Page.navigate",
        "Network.getAllCookies",
        "Fetch.disable",
        "Storage.getCookies",
        "Target.closeTarget",
        "Browser.close",
        "Runtime.disable",
        "IO.read",
        "Page.setDownloadBehavior",
        "DOM",
    ] {
        assert!(!raw_cdp_allowed(refused), "{refused}");
    }
}

#[test]
fn cookies_match_host_only_domains_paths_and_secure() {
    let url = url::Url::parse("https://app.example.com/account/settings").unwrap();
    let cookie = |domain: &str, path: &str, secure: bool| json!({"domain": domain, "path": path, "secure": secure});
    assert!(cookie_matches(&cookie(".example.com", "/", true), &url));
    assert!(cookie_matches(&cookie("app.example.com", "/account", false), &url));
    assert!(
        !cookie_matches(&cookie("example.com", "/", false), &url),
        "host-only cookies do not match subdomains"
    );
    assert!(!cookie_matches(&cookie("app.example.com", "/acc", false), &url));
    let plain = url::Url::parse("http://app.example.com/").unwrap();
    assert!(!cookie_matches(&cookie("app.example.com", "/", true), &plain));
}

#[test]
fn cookies_convert_to_the_playwright_shape() {
    let cdp = json!({"name": "a", "value": "b", "domain": "x.test", "path": "/", "expires": -1, "size": 2, "httpOnly": true, "secure": false, "session": true, "priority": "Medium"});
    assert_eq!(
        playwright_cookie(&cdp),
        json!({"name": "a", "value": "b", "domain": "x.test", "path": "/", "expires": -1, "httpOnly": true, "secure": false, "sameSite": "Lax"})
    );
}
