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
fn attached_pages_become_tabs_and_ask_for_setup() {
    let mut state = State::default();
    let applied = attach(&mut state, "T1", "S1", None);
    assert!(applied.events.is_empty(), "tabs the host opened are not tab.created");
    assert_eq!(
        applied.follow_ups,
        vec![FollowUp::SetUpPage { target_id: "T1".into(), session_id: "S1".into() }]
    );
    assert_eq!(state.target_for_session("S1"), Some("T1"));
    assert!(!state.tabs["T1"].ready);
}

#[test]
fn popups_emit_tab_created_with_their_opener() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    let applied = attach(&mut state, "T2", "S2", Some("T1"));
    assert_eq!(applied.events.len(), 1);
    assert_eq!(applied.events[0].name, "tab.created");
    assert_eq!(applied.events[0].payload["targetId"], "T2");
    assert_eq!(applied.events[0].payload["openerTargetId"], "T1");
    assert_eq!(state.order, vec!["T1".to_string(), "T2".to_string()]);
}

#[test]
fn paused_workers_are_resumed_and_not_tabs() {
    let mut state = State::default();
    let applied = state.apply(&cdp(
        None,
        "Target.attachedToTarget",
        json!({"sessionId": "W", "targetInfo": {"targetId": "WT", "type": "service_worker"}, "waitingForDebugger": true}),
    ));
    assert_eq!(applied.follow_ups, vec![FollowUp::Resume { session_id: "W".into() }]);
    assert!(state.tabs.is_empty());
}

#[test]
fn main_frame_navigation_resets_lifecycle_and_counts() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    let applied = navigate_main(&mut state, "S1", "L1", "https://a.test/");
    assert_eq!(applied.events[0].name, "tab.navigated");
    assert_eq!(applied.events[0].payload["sameDocument"], false);
    let tab = &state.tabs["T1"];
    assert_eq!(tab.loader.as_deref(), Some("L1"));
    assert_eq!(tab.nav_seq, 1);
    assert_eq!(tab.load_state(), "commit");

    let stale = state.apply(&cdp(
        Some("S1"),
        "Page.lifecycleEvent",
        json!({"frameId": "MAIN", "loaderId": "OLD", "name": "load"}),
    ));
    assert!(stale.events.is_empty(), "lifecycle of an older loader is ignored");
    let dcl = state.apply(&cdp(
        Some("S1"),
        "Page.lifecycleEvent",
        json!({"frameId": "MAIN", "loaderId": "L1", "name": "DOMContentLoaded"}),
    ));
    assert_eq!(dcl.events[0].payload["state"], "domcontentloaded");
    let repeat = state.apply(&cdp(
        Some("S1"),
        "Page.lifecycleEvent",
        json!({"frameId": "MAIN", "loaderId": "L1", "name": "DOMContentLoaded"}),
    ));
    assert!(repeat.events.is_empty(), "each lifecycle state is reported once");
    assert_eq!(state.tabs["T1"].load_state(), "domcontentloaded");

    let same = state.apply(&cdp(
        Some("S1"),
        "Page.navigatedWithinDocument",
        json!({"frameId": "MAIN", "url": "https://a.test/#x"}),
    ));
    assert_eq!(same.events[0].payload["sameDocument"], true);
    let tab = &state.tabs["T1"];
    assert_eq!(tab.nav_seq, 2);
    assert!(tab.last_nav_same_document);
    assert_eq!(tab.url, "https://a.test/#x");
    assert_eq!(tab.load_state(), "domcontentloaded", "same-document keeps the document's state");
}

#[test]
fn child_frame_navigation_keeps_main_frame_state() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    navigate_main(&mut state, "S1", "L1", "https://a.test/");
    let applied = state.apply(&cdp(
        Some("S1"),
        "Page.frameNavigated",
        json!({"frame": {"id": "CHILD", "parentId": "MAIN", "loaderId": "L9", "url": "https://b.test/", "urlFragment": "#f"}}),
    ));
    assert_eq!(applied.events[0].payload["frameId"], "CHILD");
    assert_eq!(applied.events[0].payload["url"], "https://b.test/#f");
    assert_eq!(state.tabs["T1"].loader.as_deref(), Some("L1"));
    assert_eq!(state.tabs["T1"].nav_seq, 1);
}

#[test]
fn execution_contexts_are_tracked_per_frame_and_world() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    let created = |id: i64, name: &str, default: bool| {
        cdp(
            Some("S1"),
            "Runtime.executionContextCreated",
            json!({"context": {"id": id, "name": name, "auxData": {"frameId": "MAIN", "isDefault": default}}}),
        )
    };
    state.apply(&created(1, "", true));
    state.apply(&created(2, AGENT_WORLD, false));
    state.apply(&created(3, "some-extension-world", false));
    let tab = &state.tabs["T1"];
    assert_eq!(tab.contexts.get(&("MAIN".to_string(), World::Page)), Some(&("S1".to_string(), 1)));
    assert_eq!(tab.contexts.get(&("MAIN".to_string(), World::Agent)), Some(&("S1".to_string(), 2)));
    assert_eq!(tab.contexts.len(), 2);

    state.apply(&cdp(
        Some("S1"),
        "Runtime.executionContextDestroyed",
        json!({"executionContextId": 2}),
    ));
    assert_eq!(state.tabs["T1"].contexts.len(), 1);
    state.apply(&cdp(Some("S1"), "Runtime.executionContextsCleared", json!({})));
    assert!(state.tabs["T1"].contexts.is_empty());
}

#[test]
fn dialogs_get_ids_and_stay_counted_until_closed() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    let applied = state.apply(&cdp(
        Some("S1"),
        "Page.javascriptDialogOpening",
        json!({"type": "prompt", "message": "name?", "defaultPrompt": "x", "url": "https://a.test/"}),
    ));
    let payload = &applied.events[0].payload;
    assert_eq!(applied.events[0].name, "dialog.opened");
    assert_eq!(payload["dialogId"], "d1");
    assert_eq!(payload["type"], "prompt");
    assert_eq!(payload["defaultValue"], "x");
    assert_eq!(state.dialogs.get("d1").map(|(tab, _)| tab.as_str()), Some("T1"));
    assert_eq!(state.tabs["T1"].open_dialogs, 1);
    state.apply(&cdp(Some("S1"), "Page.javascriptDialogClosed", json!({"result": true})));
    assert_eq!(state.tabs["T1"].open_dialogs, 0);
}

#[test]
fn console_and_page_errors_become_driver_events() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    let console = state.apply(&cdp(
        Some("S1"),
        "Runtime.consoleAPICalled",
        json!({"type": "log", "args": [{"type": "string", "value": "hi"}, {"type": "number", "value": 2}, {"type": "object", "description": "Object"}]}),
    ));
    assert_eq!(console.events[0].payload["text"], "hi 2 Object");
    let error = state.apply(&cdp(
        Some("S1"),
        "Runtime.exceptionThrown",
        json!({"exceptionDetails": {"text": "Uncaught", "exception": {"description": "TypeError: x is not a function\n    at a.js:1"}}}),
    ));
    assert_eq!(error.events[0].name, "pageerror");
    assert_eq!(error.events[0].payload["message"], "x is not a function");
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
fn back_forward_cache_restores_count_as_loaded() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    state.apply(&cdp(
        Some("S1"),
        "Page.frameNavigated",
        json!({"frame": {"id": "MAIN", "loaderId": "L1", "url": "https://a.test/"}, "type": "BackForwardCacheRestore"}),
    ));
    assert_eq!(state.tabs["T1"].load_state(), "load");
    assert!(state.tabs["T1"].lifecycle.contains("networkIdle"));
}

#[test]
fn out_of_process_frames_get_their_own_sessions() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    let applied = state.apply(&cdp(
        Some("S1"),
        "Target.attachedToTarget",
        json!({"sessionId": "C1", "targetInfo": {"targetId": "FRAME9", "type": "iframe", "url": "https://b.test/"}, "waitingForDebugger": true}),
    ));
    assert_eq!(
        applied.follow_ups,
        vec![FollowUp::SetUpFrame { target_id: "T1".into(), session_id: "C1".into() }]
    );
    assert_eq!(state.target_for_session("C1"), Some("T1"));
    assert_eq!(state.tabs["T1"].frame_sessions.get("FRAME9").map(String::as_str), Some("C1"));

    // The frame's own root navigation does not change the tab's main frame.
    navigate_main(&mut state, "S1", "L1", "https://a.test/");
    state.apply(&cdp(
        Some("C1"),
        "Page.frameNavigated",
        json!({"frame": {"id": "FRAME9", "loaderId": "LC", "url": "https://b.test/"}}),
    ));
    assert_eq!(state.tabs["T1"].main_frame.as_deref(), Some("MAIN"));
    assert_eq!(state.tabs["T1"].loader.as_deref(), Some("L1"));

    state.apply(&cdp(
        Some("C1"),
        "Runtime.executionContextCreated",
        json!({"context": {"id": 1, "name": AGENT_WORLD, "auxData": {"frameId": "FRAME9", "isDefault": false}}}),
    ));
    state.apply(&cdp(
        Some("S1"),
        "Runtime.executionContextCreated",
        json!({"context": {"id": 1, "name": "", "auxData": {"frameId": "MAIN", "isDefault": true}}}),
    ));
    // Context ids repeat across sessions: destroying C1's id 1 keeps S1's.
    state.apply(&cdp(
        Some("C1"),
        "Runtime.executionContextDestroyed",
        json!({"executionContextId": 1}),
    ));
    assert_eq!(state.tabs["T1"].contexts.len(), 1);

    let detached =
        state.apply(&cdp(Some("S1"), "Target.detachedFromTarget", json!({"sessionId": "C1"})));
    assert!(detached.events.is_empty(), "a frame detaching is not a closed tab");
    assert!(state.tabs["T1"].frame_sessions.is_empty());
    assert!(state.tabs.contains_key("T1"));
}

#[test]
fn prerender_pages_are_not_tabs() {
    let mut state = State::default();
    let applied = state.apply(&cdp(
        None,
        "Target.attachedToTarget",
        json!({"sessionId": "P", "targetInfo": {"targetId": "PT", "type": "page", "subtype": "prerender"}, "waitingForDebugger": true}),
    ));
    assert_eq!(applied.follow_ups, vec![FollowUp::Resume { session_id: "P".into() }]);
    assert!(state.tabs.is_empty());
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

#[test]
fn closed_dialogs_forget_their_ids() {
    let mut state = State::default();
    attach(&mut state, "T1", "S1", None);
    state.apply(&cdp(
        Some("S1"),
        "Page.javascriptDialogOpening",
        json!({"type": "alert", "message": "m"}),
    ));
    state.apply(&cdp(Some("S1"), "Page.javascriptDialogClosed", json!({"result": true})));
    assert!(state.dialogs.is_empty());
}

#[test]
fn browser_page_targets_never_become_tabs() {
    let mut state = State::default();
    for (session, kind, url) in [
        ("SP", "page", "chrome://password-manager/passwords"),
        ("SE", "page", "chrome-extension://abc/options.html"),
        ("SW", "service_worker", "chrome-extension://abc/background.js"),
    ] {
        let applied = state.apply(&cdp(
            None,
            "Target.attachedToTarget",
            json!({"sessionId": session, "targetInfo": {"targetId": format!("T{session}"), "type": kind, "url": url}, "waitingForDebugger": true}),
        ));
        assert!(
            !applied.follow_ups.iter().any(|f| matches!(f, FollowUp::SetUpPage { .. } | FollowUp::Resume { .. })),
            "{url}: {:?}",
            applied.follow_ups
        );
        assert!(!applied.follow_ups.is_empty(), "{url}: the target must be released");
    }
    assert!(state.tabs.is_empty());
    assert!(state.sessions.is_empty());
}
