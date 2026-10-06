//! CdpDriver fetch tests against the scripted browser: the fetch shell
//! (a9 shell-tab conditions), cancels, and script values in the page's key
//! order. A module of the `cdp_driver_fake` test target (helpers from its
//! root).

use super::*;

/// The sent messages since `mark` with their sessions: (method, session, params).
fn sent_with_sessions(h: &Harness, mark: usize) -> Vec<(String, String, Value)> {
    let browser = h.wire.browser.lock().unwrap();
    browser.sent[mark..]
        .iter()
        .map(|m| {
            let session = m["sessionId"].as_str().unwrap_or("").to_owned();
            (m["method"].as_str().unwrap().to_owned(), session, m["params"].clone())
        })
        .collect()
}

/// a9 shell-tab condition (b): the shell tab of a tab-less fetch bypasses
/// service workers before its navigation (a worker could answer the shell
/// document or the fetch); (d) it closes after a fetch that succeeded.
#[test]
fn the_fetch_shell_bypasses_service_workers_before_it_navigates() {
    let h = Harness::new();
    let mark = h.mark();
    let out = h.call("net.fetch", json!({"url": "https://a.test/data", "timeoutMs": 2000}));
    assert_eq!(out["status"], 200, "{out}");
    let sent = sent_with_sessions(&h, mark);
    let bypass = sent
        .iter()
        .position(|(m, on, p)| {
            m == "Network.setBypassServiceWorker" && on == "S1" && p["bypass"] == true
        })
        .unwrap_or_else(|| panic!("no service worker bypass on the shell: {sent:?}"));
    let navigate = sent
        .iter()
        .position(|(m, on, _)| m == "Page.navigate" && on == "S1")
        .unwrap_or_else(|| panic!("the shell never navigated: {sent:?}"));
    assert!(bypass < navigate, "the bypass comes before the navigation: {sent:?}");
    assert!(
        sent.iter().any(|(m, _, p)| m == "Target.closeTarget" && p["targetId"] == "T1"),
        "the shell closes after the fetch: {sent:?}"
    );
}

/// a9 shell-tab conditions (c, d): the shell is hidden from the session (not
/// listed, no events, no page agent, every call refused) and closes when
/// the session ends while its fetch runs.
#[test]
fn the_fetch_shell_is_hidden_and_closes_when_the_session_ends() {
    let h = Harness::with_browser(Browser { hold_fetch: true, ..Browser::default() });
    let mark = h.mark();
    std::thread::scope(|scope| {
        let fetch = scope.spawn(|| {
            h.driver.call("net.fetch", &json!({"url": "https://a.test/data", "timeoutMs": 2000}))
        });
        wait_until(|| h.wire.browser.lock().unwrap().held.is_some(), "the fetch never started");
        assert_eq!(h.call("tabs.list", json!({})), json!([]), "the shell is listed");
        for (method, params) in [
            ("tab.info", json!({"targetId": "T1"})),
            ("tab.screenshot", json!({"targetId": "T1"})),
            ("tabs.activate", json!({"targetId": "T1"})),
            ("frame.evaluate", json!({"targetId": "T1", "source": "() => 1"})),
            ("tab.navigate", json!({"targetId": "T1", "url": "https://a.test/"})),
            ("cdp", json!({"targetId": "T1", "method": "DOM.getDocument"})),
            ("tabs.close", json!({"targetId": "T1"})),
        ] {
            let error = h.driver.call(method, &params).expect_err(method);
            assert_eq!(error.code, ErrorCode::NotFound, "{method}: {error}");
        }
        h.driver.end_session();
        let ended = fetch.join().unwrap();
        assert!(ended.is_err(), "the fetch ends with its shell: {ended:?}");
    });
    let sent = h.sent_since(mark);
    assert!(
        sent.iter().any(|(m, p)| m == "Target.closeTarget" && p["targetId"] == "T1"),
        "{sent:?}"
    );
    assert!(
        !sent.iter().any(|(m, _)| m == "Page.addScriptToEvaluateOnNewDocument"),
        "the shell runs no page agent: {sent:?}"
    );
    // Events are delivered in order: a later tab's navigation is a barrier.
    let later = h.open(Some("https://a.test/later"));
    wait_until(
        || h.events.lock().unwrap().iter().any(|e| e.payload["targetId"] == later.as_str()),
        "the later tab's events never arrived",
    );
    let events = h.events.lock().unwrap().clone();
    assert!(
        events.iter().all(|e| e.payload["targetId"] != "T1"),
        "the shell emitted events: {events:?}"
    );
}

/// a9 shell-tab condition (d): a shell whose setup failed is closed too.
#[test]
fn the_fetch_shell_closes_when_its_setup_fails() {
    let h = Harness::with_browser(Browser { fail_setup: true, ..Browser::default() });
    let mark = h.mark();
    let error = h
        .driver
        .call("net.fetch", &json!({"url": "https://a.test/data", "timeoutMs": 2000}))
        .expect_err("the shell's setup failed");
    assert_eq!(error.code, ErrorCode::Closed, "{error}");
    let sent = h.sent_since(mark);
    assert!(
        sent.iter().any(|(m, p)| m == "Target.closeTarget" && p["targetId"] == "T1"),
        "the shell leaked: {sent:?}"
    );
}

/// a9 raw_value: frame.evaluate hands the page's value on as the JSON text
/// Chromium sent, in the page's key order (scenario 32's search results).
#[test]
fn script_values_keep_the_page_key_order() {
    use cmux_browser_host::driver::Reply;
    let h = Harness::new();
    let target = h.open(None);
    let reply = h
        .driver
        .call_reply_announced(
            "frame.evaluate",
            &json!({"targetId": target, "source": "() => 'key-order'"}),
            &mut || {},
        )
        .expect("frame.evaluate");
    match reply {
        Reply::Json(raw) => assert_eq!(raw.get(), KEY_ORDER),
        Reply::Value(value) => panic!("the value was parsed (keys sorted): {value}"),
    }
}

/// Classic main: a cancelled fetch stops at once. A shell fetch closes its
/// shell (the detached session fails the pending call).
#[test]
fn a_cancelled_shell_fetch_closes_its_shell_at_once() {
    let h = Harness::with_browser(Browser { hold_fetch: true, ..Browser::default() });
    let mark = h.mark();
    std::thread::scope(|scope| {
        let fetch = scope.spawn(|| {
            h.driver.call(
                "net.fetch",
                &json!({"url": "https://a.test/data", "fetchId": "f1", "timeoutMs": 2000}),
            )
        });
        wait_until(|| h.wire.browser.lock().unwrap().held.is_some(), "the fetch never started");
        let _ = h.driver.call("net.fetch.cancel", &json!({"fetchId": "f1"}));
        wait_until(
            || {
                h.sent_since(mark)
                    .iter()
                    .any(|(m, p)| m == "Target.closeTarget" && p["targetId"] == "T1")
            },
            "the cancel did not close the shell",
        );
        assert!(fetch.join().unwrap().is_err(), "a cancelled fetch fails");
    });
}

/// Classic main: a cancelled in-tab fetch is aborted in the host world.
#[test]
fn a_cancelled_tab_fetch_is_aborted_at_once() {
    let h = Harness::with_browser(Browser { hold_fetch: true, ..Browser::default() });
    let target = h.open(None);
    std::thread::scope(|scope| {
        let fetch = scope.spawn(|| {
            h.driver.call(
                "net.fetch",
                &json!({"targetId": target, "url": "https://a.test/data", "fetchId": "f2", "timeoutMs": 2000}),
            )
        });
        wait_until(|| h.wire.browser.lock().unwrap().held.is_some(), "the fetch never started");
        let _ = h.driver.call("net.fetch.cancel", &json!({"fetchId": "f2"}));
        wait_until(
            || h.wire.browser.lock().unwrap().held.is_none(),
            "the cancel did not abort the fetch",
        );
        assert!(fetch.join().unwrap().is_err(), "a cancelled fetch fails");
    });
}

/// A shell never reports the host world's context, so a tab-less fetch
/// creates the world at once instead of waiting the context grace (500 ms)
/// first.
#[test]
fn a_shell_fetch_creates_the_host_world_without_waiting() {
    let h = Harness::new();
    let mark = h.mark();
    h.call("net.fetch", json!({"url": "https://a.test/data", "timeoutMs": 2000}));
    let browser = h.wire.browser.lock().unwrap();
    let at = |method: &str| {
        (mark..browser.sent.len())
            .find(|&i| browser.sent[i]["method"] == method)
            .map(|i| browser.sent_at[i])
            .unwrap_or_else(|| panic!("no {method}"))
    };
    let waited = at("Page.createIsolatedWorld").duration_since(at("Page.navigate"));
    assert!(
        waited < std::time::Duration::from_millis(250),
        "the shell waited {waited:?} for a context it never reports"
    );
}
