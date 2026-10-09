use super::*;

fn cdp(session: Option<&str>, method: &str, params: Value) -> CdpEvent {
    CdpEvent { session_id: session.map(str::to_owned), method: method.to_owned(), params }
}

fn attach(state: &mut State, target: &str, session: &str, opener: Option<&str>) -> Applied {
    let mut info = json!({"targetId": target, "type": "page", "url": "about:blank", "title": ""});
    if let Some(opener) = opener {
        info["openerId"] = json!(opener);
    }
    state.apply(&cdp(
        None,
        "Target.attachedToTarget",
        json!({"sessionId": session, "targetInfo": info, "waitingForDebugger": true}),
    ))
}

fn navigate_main(state: &mut State, session: &str, loader: &str, url: &str) -> Applied {
    state.apply(&cdp(
        Some(session),
        "Page.frameNavigated",
        json!({"frame": {"id": "MAIN", "loaderId": loader, "url": url}, "type": "Navigation"}),
    ))
}

#[test]
fn destroyed_and_crashed_targets_emit_once() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    state.active = Some("T1".into());
    let crashed = state.apply(&cdp(Some("S1"), "Inspector.targetCrashed", json!({})));
    assert_eq!(crashed.events[0].name, "tab.crashed");
    let again = state.apply(&cdp(None, "Target.targetCrashed", json!({"targetId": "T1"})));
    assert!(again.events.is_empty());
    let closed = state.apply(&cdp(None, "Target.targetDestroyed", json!({"targetId": "T1"})));
    assert_eq!(closed.events[0].name, "tab.closed");
    assert!(state.active.is_none());
    assert!(state.sessions.is_empty());
    let twice = state.apply(&cdp(None, "Target.detachedFromTarget", json!({"sessionId": "S1"})));
    assert!(twice.events.is_empty());
}

#[test]
fn error_messages_drop_the_error_name() {
    assert_eq!(error_message("Error: boom\n at x"), "boom");
    assert_eq!(error_message("Uncaught (in promise) oops"), "Uncaught (in promise) oops");
    assert_eq!(error_message(""), "");
}

#[test]
fn navigation_after_a_crash_clears_it() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    state.apply(&cdp(Some("S1"), "Inspector.targetCrashed", json!({})));
    assert!(state.tabs["T1"].crashed);
    navigate_main(&mut state, "S1", "L2", "https://a.test/");
    assert!(!state.tabs["T1"].crashed);
}

/// page.on("request" | "response" | "requestfinished") need the Network
/// domain's events, mapped to the tab (parity 16 had none).
#[test]
fn network_events_report_requests_of_the_tab() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    let names = |applied: Applied| -> Vec<String> {
        applied
            .events
            .into_iter()
            .map(|e| format!("{}:{}", e.name, e.payload["targetId"]))
            .collect()
    };
    let sent = state.apply(&cdp(
        Some("S1"),
        "Network.requestWillBeSent",
        json!({"requestId": "r1", "type": "Fetch", "request": {"url": "http://a.test/api/data", "method": "GET"}}),
    ));
    assert_eq!(names(sent), vec!["request:\"T1\""]);
    let response = state.apply(&cdp(
        Some("S1"),
        "Network.responseReceived",
        json!({"requestId": "r1", "response": {"status": 200}}),
    ));
    assert_eq!(names(response), vec!["response:\"T1\""]);
    let done = state.apply(&cdp(Some("S1"), "Network.loadingFinished", json!({"requestId": "r1"})));
    assert_eq!(names(done), vec!["requestfinished:\"T1\""]);
}
