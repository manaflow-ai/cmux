//! Incognito tabs on the shared headless browser (private data P1,
//! driver-protocol.md `tabs.open`): an in-memory store of the session's
//! own, no cookie from the profile, nothing written back, listed as
//! incognito, never kept, closed with the session. A module of the
//! `chromium` test target (helpers from its root).

use super::sessions::headless_session;
use super::*;

fn launch() -> Arc<cmux_browser_host::headless_source::HeadlessSource> {
    use cmux_browser_host::headless_source::HeadlessSource;
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
        .expect("launch the shared browser")
}

fn open(
    session: &cmux_browser_host::headless_source::HeadlessSession,
    params: Value,
) -> Result<String, cmux_browser_host::protocol::DriverError> {
    session.call("tabs.open", &params).map(|opened| opened["targetId"].as_str().unwrap().to_owned())
}

fn page(
    session: &cmux_browser_host::headless_source::HeadlessSession,
    target: &str,
    source: &str,
) -> Value {
    session
        .call("frame.evaluate", &json!({"targetId": target, "world": "page", "source": source}))
        .unwrap()
}

/// The `tabs.list` entry of the tab whose URL ends with `suffix`, waiting
/// for a popup to be listed.
fn listed(session: &cmux_browser_host::headless_source::HeadlessSession, suffix: &str) -> Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let tabs = session.call("tabs.list", &json!({})).unwrap();
        if let Some(tab) = tabs
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["url"].as_str().unwrap_or("").ends_with(suffix))
        {
            return tab.clone();
        }
        assert!(Instant::now() < deadline, "no tab {suffix}: {tabs}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn an_incognito_tab_keeps_nothing_and_closes_with_its_session() {
    use cmux_browser_host::headless_source::HeadlessBrowsers;
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let source = launch();
    let browsers: HeadlessBrowsers = Arc::default();
    let s = headless_session(&source, &browsers, "s");
    let plain = open(&s, json!({"url": format!("{origin}/second?plain")})).unwrap();
    page(&s, &plain, "() => { document.cookie = 'brepl_profile=1; path=/'; return 1; }");
    let private =
        open(&s, json!({"url": format!("{origin}/second?incognito"), "incognito": true})).unwrap();
    assert_eq!(listed(&s, "?incognito")["incognito"], true);
    assert_ne!(listed(&s, "?plain")["incognito"], true, "a profile tab is not incognito");
    assert_eq!(page(&s, &private, "() => document.cookie"), "", "the profile's cookies reached it");
    page(&s, &private, "() => { document.cookie = 'brepl_incognito=1; path=/'; return 1; }");
    assert_eq!(page(&s, &plain, "() => document.cookie"), "brepl_profile=1", "written back");
    let kept = s.call("tab.keep", &json!({"targetId": private})).unwrap_err();
    assert_eq!(kept.code, ErrorCode::Forbidden, "{kept}");
    s.end_session();
    drop(s);
    let t = headless_session(&source, &browsers, "t");
    let tabs = t.call("tabs.list", &json!({})).unwrap();
    assert!(
        !tabs.as_array().unwrap().iter().any(|tab| tab["targetId"] == private.as_str()),
        "the incognito tab outlived its session: {tabs}"
    );
    let cookies = t.call("cookies.get", &json!({"urls": [origin]})).unwrap();
    assert!(!cookies.to_string().contains("brepl_incognito"), "{cookies}");
}

#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn an_incognito_session_opens_every_tab_incognito() {
    use cmux_browser_host::headless_source::HeadlessBrowsers;
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let source = launch();
    let browsers: HeadlessBrowsers = Arc::default();
    let s = headless_session(&source, &browsers, "s");
    s.call("session.configure", &json!({"incognito": true})).unwrap();
    let tab = open(&s, json!({"url": format!("{origin}/second?inherit")})).unwrap();
    assert_eq!(listed(&s, "?inherit")["incognito"], true);
    let off = s.call("session.configure", &json!({"incognito": false})).unwrap_err();
    assert_eq!(off.code, ErrorCode::Forbidden, "{off}");
    let refused =
        open(&s, json!({"url": format!("{origin}/second?persistent"), "incognito": false}))
            .unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused}");
    page(
        &s,
        &tab,
        &format!(
            "() => {{ document.cookie = 'brepl_session=1; path=/'; window.open('{origin}/second?popup'); return 1; }}"
        ),
    );
    assert_eq!(listed(&s, "?popup")["incognito"], true, "the popup left the incognito store");
    // The session's tab-less cookies.* use its incognito store.
    let cookies = s.call("cookies.get", &json!({"urls": [origin]})).unwrap();
    assert!(cookies.to_string().contains("brepl_session"), "{cookies}");
    // A tab-less fetch runs in a hidden shell of the profile's store, which
    // would send and keep the profile's cookies: refused in this session.
    let fetch = s.call("net.fetch", &json!({"url": format!("{origin}/second")})).unwrap_err();
    assert_eq!(fetch.code, ErrorCode::Unsupported, "{fetch}");
    let other = headless_session(&source, &browsers, "other");
    let profile = other.call("cookies.get", &json!({"urls": [origin]})).unwrap();
    assert!(!profile.to_string().contains("brepl_session"), "{profile}");
}
