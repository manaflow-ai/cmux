//! Shared headless browser session tests (items 4c-4e, D2): the person's
//! host log, held input release, session.configure, proxy stores, leases.
//! A module of the `chromium` test target (helpers from its root).

use super::*;

/// D2 log: the host keeps the newest unrouted events (64); only the
/// person (user origin) reads them, through `tab.info` of a tab they may
/// use (`unroutedEvents`, that tab's entries).
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn only_the_person_reads_the_hosts_unrouted_log() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSession, HeadlessSource};
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let open = |name: &str, origin: &str| {
        let lease = cmux_browser_host::lease::LeaseCaller {
            session: name.into(),
            actor: "t".into(),
            on_behalf_of: None,
            origin: origin.into(),
            label: String::new(),
            implicit_session: false,
            engine: "headless".into(),
        };
        HeadlessSession::new(source.clone(), &browsers, Arc::from(AGENT), Arc::new(|_| {}), lease)
            .unwrap()
    };
    let agent = open("agent", "cli");
    let person = open("person", "user");
    let target = agent
        .call("tabs.open", &json!({"url": format!("http://127.0.0.1:{port}/confirm")}))
        .unwrap()["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    agent.call("tab.keep", &json!({"targetId": target})).unwrap();
    // The tab is kept (no creator) and the call is over when the page asks:
    // no session takes the dialog. (A user-origin session cannot act.)
    agent
        .call(
            "frame.evaluate",
            &json!({"targetId": target, "world": "agent",
                "source": "() => { setTimeout(() => confirm('late?'), 50); return 1; }"}),
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let entries = loop {
        let info = person.call("tab.info", &json!({"targetId": target})).unwrap();
        if let Some(entries) = info["unroutedEvents"].as_array().filter(|e| !e.is_empty()) {
            break entries.clone();
        }
        assert!(Instant::now() < deadline, "no unrouted entry for the person: {info}");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(entries.len(), 1, "{entries:?}");
    assert_eq!(entries[0]["event"], "dialog.opened");
    assert_eq!(entries[0]["action"], "dismissed");
    let reader = open("reader", "cli");
    let info = reader.call("tab.info", &json!({"targetId": target})).unwrap();
    assert!(info.get("unroutedEvents").is_none(), "an agent read the host log: {info}");
}

/// driver-protocol.md "Sessions and tabs": when the LAST session leaves a
/// tab, the keys and mouse buttons the sessions left pressed are released
/// (key-ups last pressed first, then button-ups at the last mouse
/// position), as trusted events; not while another session still drives it.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn held_input_is_released_when_the_last_session_leaves() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSession, HeadlessSource};
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let open = |name: &str| {
        let lease = cmux_browser_host::lease::LeaseCaller {
            session: name.into(),
            actor: "t".into(),
            on_behalf_of: None,
            origin: "cli".into(),
            label: String::new(),
            implicit_session: false,
            engine: "headless".into(),
        };
        HeadlessSession::new(source.clone(), &browsers, Arc::from(AGENT), Arc::new(|_| {}), lease)
            .unwrap()
    };
    let read = |session: &HeadlessSession, target: &str| -> String {
        session
            .call(
                "frame.evaluate",
                &json!({"targetId": target, "world": "agent",
                    "source": "() => document.getElementById('log').textContent"}),
            )
            .unwrap()
            .as_str()
            .unwrap_or("")
            .to_owned()
    };
    let a = open("a");
    let target = a
        .call("tabs.open", &json!({"url": format!("http://127.0.0.1:{port}/held")}))
        .unwrap()["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    a.call("tab.keep", &json!({"targetId": target})).unwrap();
    for (key, code) in [("Shift", "ShiftLeft"), ("A", "KeyA")] {
        a.call("input.key", &json!({"targetId": target, "type": "down", "key": key, "code": code}))
            .unwrap();
    }
    a.call("input.mouse", &json!({"targetId": target, "type": "move", "x": 5, "y": 5})).unwrap();
    a.call("input.mouse", &json!({"targetId": target, "type": "down", "button": "left"})).unwrap();
    // b drives the tab too (a read): a's end releases nothing yet.
    let b = open("b");
    b.call("tab.info", &json!({"targetId": target})).unwrap();
    a.end_session();
    drop(a);
    assert_eq!(read(&b, &target), "", "released while b still drives the tab");
    b.end_session();
    drop(b);
    let c = open("c");
    let log = read(&c, &target);
    assert_eq!(log, "keyup A true;keyup Shift true;mouseup 0 true;", "{log}");
}

pub(crate) fn headless_session(
    source: &Arc<cmux_browser_host::headless_source::HeadlessSource>,
    browsers: &cmux_browser_host::headless_source::HeadlessBrowsers,
    name: &str,
) -> cmux_browser_host::headless_source::HeadlessSession {
    let lease = cmux_browser_host::lease::LeaseCaller {
        session: name.into(),
        actor: "t".into(),
        on_behalf_of: None,
        origin: "cli".into(),
        label: String::new(),
        implicit_session: false,
        engine: "headless".into(),
    };
    cmux_browser_host::headless_source::HeadlessSession::new(
        source.clone(),
        browsers,
        Arc::from(AGENT),
        Arc::new(|_| {}),
        lease,
    )
    .unwrap()
}

fn echo_text(
    session: &cmux_browser_host::headless_source::HeadlessSession,
    target: &str,
) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let text = session
            .call(
                "frame.evaluate",
                &json!({"targetId": target, "world": "agent",
                    "source": "() => [document.getElementById('h') && document.getElementById('h').textContent, navigator.userAgent]"}),
            )
            .unwrap();
        if text[0].is_string() {
            return format!("{}|{}", text[0].as_str().unwrap(), text[1].as_str().unwrap_or(""));
        }
        assert!(Instant::now() < deadline, "the echo page never loaded: {text}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// session.configure on the shared headless browser (driver-protocol.md
/// `session.configure`): the user agent and extra headers apply to the tabs
/// the session created (from the first request, popups too) while it is
/// attached; a person's tab it drives keeps its own; keeping a tab undoes them.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn session_configure_applies_to_the_sessions_own_tabs() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSource};
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let open_tab = |session: &cmux_browser_host::headless_source::HeadlessSession, url: String| {
        session.call("tabs.open", &json!({"url": url})).unwrap()["targetId"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    let keeper = headless_session(&source, &browsers, "keeper");
    let user_tab = open_tab(&keeper, format!("{origin}/echo?user"));
    keeper.call("tab.keep", &json!({"targetId": user_tab})).unwrap();
    keeper.end_session();
    drop(keeper);
    let default_ua = echo_text(&headless_session(&source, &browsers, "probe"), &user_tab);
    assert!(default_ua.contains("HeadlessChrome"), "{default_ua}");

    let s = headless_session(&source, &browsers, "s");
    let answer = s
        .call(
            "session.configure",
            &json!({"userAgent": "brepl-ua", "extraHTTPHeaders": {"X-Brepl": "one"}}),
        )
        .unwrap();
    assert_eq!(answer["proxy"], false, "{answer}");
    let own = open_tab(&s, format!("{origin}/echo?own"));
    assert_eq!(echo_text(&s, &own), "brepl-ua|one|brepl-ua", "from the first request");
    // A popup of the session's tab gets them before its first request.
    s.call(
        "frame.evaluate",
        &json!({"targetId": own, "world": "page",
            "source": format!("() => {{ window.open('{origin}/echo?popup'); return 1; }}")}),
    )
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let popup = loop {
        let tabs = s.call("tabs.list", &json!({})).unwrap();
        if let Some(tab) = tabs
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["url"].as_str().unwrap_or("").ends_with("?popup"))
        {
            break tab["targetId"].as_str().unwrap().to_owned();
        }
        assert!(Instant::now() < deadline, "no popup: {tabs}");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(echo_text(&s, &popup), "brepl-ua|one|brepl-ua", "the popup inherits them");
    // The person's tab keeps its own, also when this session reloads it.
    s.call("tab.reload", &json!({"targetId": user_tab, "waitUntil": "load"})).unwrap();
    assert_eq!(echo_text(&s, &user_tab), default_ua);
    // Kept: the tab is the person's now, and its next document has the defaults.
    s.call("tab.keep", &json!({"targetId": own})).unwrap();
    s.call("tab.reload", &json!({"targetId": own, "waitUntil": "load"})).unwrap();
    let ua = default_ua.split('|').next().unwrap();
    assert_eq!(echo_text(&s, &own), format!("{ua}||{ua}"), "undone on keep");
    // null clears.
    s.call("session.configure", &json!({"userAgent": null, "extraHTTPHeaders": null})).unwrap();
    let after = open_tab(&s, format!("{origin}/echo?after"));
    assert_eq!(echo_text(&s, &after), format!("{ua}||{ua}"));
}

/// session.configure {proxy}: tabs the session opens afterwards, and their
/// popups, use a private store (cookies apart from the profile's);
/// `{proxy: null}` returns to the profile's store for new tabs.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_proxy_session_opens_tabs_in_a_private_store() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSource};
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let s = headless_session(&source, &browsers, "s");
    let cookie = |target: &str| -> String {
        s.call(
            "frame.evaluate",
            &json!({"targetId": target, "world": "page", "source": "() => document.cookie"}),
        )
        .unwrap()
        .as_str()
        .unwrap_or("")
        .to_owned()
    };
    let open_tab = |url: String| {
        s.call("tabs.open", &json!({"url": url})).unwrap()["targetId"].as_str().unwrap().to_owned()
    };
    let plain = open_tab(format!("{origin}/second?plain"));
    let answer = s
        .call(
            "session.configure",
            &json!({"proxy": {"server": format!("http://127.0.0.1:{port}")}}),
        )
        .unwrap();
    assert_eq!(answer["proxy"], true, "{answer}");
    let private = open_tab(format!("{origin}/second?private"));
    s.call(
        "frame.evaluate",
        &json!({"targetId": private, "world": "page",
            "source": format!("() => {{ document.cookie = 'brepl_store=private; path=/'; window.open('{origin}/second?popup'); return 1; }}")}),
    )
    .unwrap();
    assert_eq!(cookie(&plain), "", "the profile's store never saw the private cookie");
    let deadline = Instant::now() + Duration::from_secs(10);
    let popup = loop {
        let tabs = s.call("tabs.list", &json!({})).unwrap();
        if let Some(tab) = tabs
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["url"].as_str().unwrap_or("").ends_with("?popup"))
        {
            break tab["targetId"].as_str().unwrap().to_owned();
        }
        assert!(Instant::now() < deadline, "no popup: {tabs}");
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(cookie(&popup), "brepl_store=private", "the popup shares the private store");
    s.call("session.configure", &json!({"proxy": null})).unwrap();
    let back = open_tab(format!("{origin}/second?back"));
    assert_eq!(cookie(&back), "");
}

/// Leases on the shared headless browser (item 4e, automation-lease.md):
/// an act takes the tab's lease, another session's act is refused with
/// lease_held while a read never is, and a closed tab takes its lease
/// with it (the table stays bounded, as the app's tab.gone does).
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn headless_leases_follow_the_contract_and_go_with_the_tab() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSource, SharedHeadless};
    use cmux_browser_host::tab_source::TabSource;
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let shared = SharedHeadless(source.clone());
    let a = headless_session(&source, &browsers, "a");
    let b = headless_session(&source, &browsers, "b");
    let target = a
        .call("tabs.open", &json!({"url": format!("http://127.0.0.1:{port}/second")}))
        .unwrap()["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    let evaluate = json!({"targetId": target, "world": "agent", "source": "() => 1"});
    a.call("frame.evaluate", &evaluate).unwrap();
    assert!(shared.lease_state(&target).is_some(), "a's act took the lease");
    let refused = b.call("frame.evaluate", &evaluate).unwrap_err();
    assert_eq!(refused.error_name.as_deref(), Some("lease_held"), "{refused}");
    b.call("tab.info", &json!({"targetId": target})).expect("a read is never blocked");
    a.call("tabs.close", &json!({"targetId": target})).unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while shared.lease_state(&target).is_some() {
        assert!(Instant::now() < deadline, "the closed tab kept its lease");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// The proxy store (driver-protocol.md `session.configure`, `cookies.*`,
/// `tabs.list`): its tabs, popups included, list one dataStore of their
/// own; cookies.* without a targetId use the session's proxy store; a kept
/// tab in it (also a popup) keeps the store open after the session ends.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_proxy_store_is_named_used_by_cookies_and_kept_with_its_tabs() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSource};
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let s = headless_session(&source, &browsers, "s");
    let open_tab = |url: String| {
        s.call("tabs.open", &json!({"url": url})).unwrap()["targetId"].as_str().unwrap().to_owned()
    };
    let plain = open_tab(format!("{origin}/second?plain"));
    s.call("session.configure", &json!({"proxy": {"server": origin}})).unwrap();
    let private = open_tab(format!("{origin}/second?private"));
    s.call(
        "frame.evaluate",
        &json!({"targetId": private, "world": "page",
            "source": format!("() => {{ document.cookie = 'brepl_store=private; path=/'; window.open('{origin}/second?popup'); return 1; }}")}),
    )
    .unwrap();
    let store_of = |session: &cmux_browser_host::headless_source::HeadlessSession, suffix: &str| {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let tabs = session.call("tabs.list", &json!({})).unwrap();
            if let Some(tab) = tabs
                .as_array()
                .unwrap()
                .iter()
                .find(|t| t["url"].as_str().unwrap_or("").ends_with(suffix))
            {
                return (tab["targetId"].as_str().unwrap().to_owned(), tab["dataStore"].clone());
            }
            assert!(Instant::now() < deadline, "no tab {suffix}: {tabs}");
            std::thread::sleep(Duration::from_millis(20));
        }
    };
    let (popup, popup_store) = store_of(&s, "?popup");
    let (_, private_store) = store_of(&s, "?private");
    let (_, plain_store) = store_of(&s, "?plain");
    assert_eq!(plain_store, "agent");
    assert_ne!(private_store, plain_store, "the proxy store has its own name");
    assert_eq!(popup_store, private_store, "the popup is in its opener's store");
    let names = |cookies: Value| -> Vec<String> {
        cookies
            .as_array()
            .unwrap()
            .iter()
            .map(|c| format!("{}={}", c["name"].as_str().unwrap(), c["value"].as_str().unwrap()))
            .collect()
    };
    let session_cookies = names(s.call("cookies.get", &json!({"urls": [origin]})).unwrap());
    assert!(session_cookies.contains(&"brepl_store=private".to_owned()), "{session_cookies:?}");
    let plain_cookies =
        names(s.call("cookies.get", &json!({"urls": [origin], "targetId": plain})).unwrap());
    assert!(!plain_cookies.contains(&"brepl_store=private".to_owned()), "{plain_cookies:?}");
    // Keep only the popup: the store must outlive the session for it.
    s.call("tab.keep", &json!({"targetId": popup})).unwrap();
    s.end_session();
    drop(s);
    let t = headless_session(&source, &browsers, "t");
    let (kept, _) = store_of(&t, "?popup");
    let cookie = t
        .call(
            "frame.evaluate",
            &json!({"targetId": kept, "world": "page", "source": "() => document.cookie"}),
        )
        .unwrap();
    assert_eq!(cookie, "brepl_store=private", "the kept popup kept its store");
}

/// A dialog routed to a session is dismissed when that session ends
/// (driver-protocol.md: its open dialogs are dismissed), so the page is
/// not left blocked by a dialog no one can answer.
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn a_sessions_end_dismisses_its_open_dialog() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSource};
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let a = headless_session(&source, &browsers, "a");
    let b_events: Arc<Mutex<Vec<DriverEvent>>> = Arc::default();
    let b = {
        let events = Arc::clone(&b_events);
        let lease = cmux_browser_host::lease::LeaseCaller {
            session: "b".into(),
            actor: "t".into(),
            on_behalf_of: None,
            origin: "cli".into(),
            label: String::new(),
            implicit_session: false,
            engine: "headless".into(),
        };
        cmux_browser_host::headless_source::HeadlessSession::new(
            source,
            &browsers,
            Arc::from(AGENT),
            Arc::new(move |event| events.lock().unwrap().push(event)),
            lease,
        )
        .unwrap()
    };
    let target = a
        .call("tabs.open", &json!({"url": format!("http://127.0.0.1:{port}/confirm")}))
        .unwrap()["targetId"]
        .as_str()
        .unwrap()
        .to_owned();
    a.call("tab.keep", &json!({"targetId": target})).unwrap();
    b.call("tab.handleEvents", &json!({"targetId": target, "events": ["dialog"]})).unwrap();
    a.call(
        "frame.evaluate",
        &json!({"targetId": target, "world": "agent",
            "source": "() => { setTimeout(() => { document.getElementById('r').textContent = String(confirm('stay?')); }, 50); return 1; }"}),
    )
    .unwrap();
    wait_event(&b_events, "dialog.opened");
    b.end_session();
    drop(b);
    let read = || {
        a.call(
            "frame.evaluate",
            &json!({"targetId": target, "world": "agent",
                "source": "() => document.getElementById('r').textContent"}),
        )
        .map(|value| value.as_str().unwrap_or("").to_owned())
        .unwrap_or_default()
    };
    let deadline = Instant::now() + Duration::from_secs(5);
    while read() != "false" {
        assert!(Instant::now() < deadline, "b's end left its dialog open: {:?}", read());
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// Permissions option 2 (chief, 2026-10-06): a session that sets
/// permissions opens its new tabs in a private browser context with the
/// grants; no grant reaches a person's tab. The context starts with a
/// one-way copy of the profile's cookies (never written back) and closes at
/// the session's end unless a tab in it was kept. Clipboard grants are
/// refused (the tab's clipboard is the only one, see the clipboard guard).
#[test]
#[ignore = "requires CMUX_BROWSER_HOST_TEST_CHROME; run explicitly with --ignored"]
fn permissions_open_new_tabs_in_a_private_granted_store() {
    use cmux_browser_host::headless_source::{HeadlessBrowsers, HeadlessSource};
    let binary = std::env::var_os("CMUX_BROWSER_HOST_TEST_CHROME")
        .filter(|value| !value.is_empty())
        .expect("CMUX_BROWSER_HOST_TEST_CHROME must name a Chromium binary");
    let port = serve();
    let origin = format!("http://127.0.0.1:{port}");
    let source =
        HeadlessSource::launch(&HeadlessOptions::new(binary.into()), Arc::from(AGENT), "agent")
            .expect("launch the shared browser");
    let browsers: HeadlessBrowsers = Arc::default();
    let page = |session: &cmux_browser_host::headless_source::HeadlessSession,
                target: &str,
                source: &str| {
        session
            .call("frame.evaluate", &json!({"targetId": target, "world": "page", "source": source}))
            .unwrap()
    };
    let open = |session: &cmux_browser_host::headless_source::HeadlessSession, query: &str| {
        session
            .call("tabs.open", &json!({"url": format!("{origin}/second?{query}")}))
            .unwrap()["targetId"]
            .as_str()
            .unwrap()
            .to_owned()
    };
    // The person's profile has a cookie (a tab of a session without options).
    let person = headless_session(&source, &browsers, "person");
    let plain = open(&person, "plain");
    page(&person, &plain, "() => { document.cookie = 'profile=1; path=/'; }");
    person.call("tab.keep", &json!({"targetId": plain})).unwrap();
    let s = headless_session(&source, &browsers, "s");
    let refused = s
        .call("session.configure", &json!({"permissions": ["clipboard-read"]}))
        .unwrap_err();
    assert_eq!(refused.code, ErrorCode::Forbidden, "{refused:?}");
    s.call("session.configure", &json!({"permissions": ["notifications"]})).unwrap();
    let granted = open(&s, "granted");
    assert_eq!(page(&s, &granted, "() => Notification.permission"), "granted");
    assert_eq!(page(&s, &granted, "() => document.cookie"), "profile=1", "copied one way");
    page(&s, &granted, "() => { document.cookie = 'private=1; path=/'; }");
    // The person's tab: no grant, no cookie from the private store.
    assert_ne!(page(&person, &plain, "() => Notification.permission"), "granted");
    assert_eq!(page(&person, &plain, "() => document.cookie"), "profile=1", "never written back");
    // A kept tab keeps its store after the session ends; the others close.
    let kept = open(&s, "kept");
    s.call("tab.keep", &json!({"targetId": kept})).unwrap();
    s.end_session();
    drop(s);
    let t = headless_session(&source, &browsers, "t");
    let urls: Vec<String> = t
        .call("tabs.list", &json!({}))
        .unwrap()
        .as_array()
        .unwrap()
        .iter()
        .map(|tab| tab["url"].as_str().unwrap_or("").to_owned())
        .collect();
    assert!(!urls.iter().any(|u| u.ends_with("?granted")), "{urls:?}");
    assert!(urls.iter().any(|u| u.ends_with("?kept")), "{urls:?}");
    assert_eq!(
        page(&t, &kept, "() => document.cookie.split('; ').sort().join(';')"),
        "private=1;profile=1",
        "the kept tab is still in the private store"
    );
}
