use super::*;

#[test]
fn a_unique_exact_name_becomes_its_id_and_an_id_stays() {
    let records = json!([
        {"id": "room-a", "name": "Work"},
        {"id": "room-b", "name": "Home"},
        {"id": "room-c", "name": "room-a"},
    ]);
    assert_eq!(state_id("room", "Work", &records).ok().flatten().as_deref(), Some("room-a"));
    // An id wins over a record named like it.
    assert_eq!(state_id("room", "room-a", &records).ok().flatten(), None);
    assert_eq!(state_id("room", "Nowhere", &records).ok().flatten(), None);
}

#[test]
fn a_shared_name_is_ambiguous_with_candidates() {
    let records = json!([
        {"id": "g1", "name": "agents"},
        {"id": "g2", "name": "agents"},
    ]);
    let Err(Failure::Resource(error)) = state_id("tab_group", "agents", &records) else {
        panic!("a shared name resolved");
    };
    assert_eq!(error["code"], "selector.ambiguous");
    assert_eq!(error["details"]["candidates"], json!(["g1", "g2"]));
    assert!(error["message"].as_str().unwrap().contains("tab group"));
}

#[test]
fn browser_zoom_goes_to_the_app_and_terminal_zoom_to_the_daemon() {
    let browser = json!({"id": "tab_1", "content_kind": "browser", "pane_id": "pane_1"});
    let terminal = json!({"id": "tab_2", "content_kind": "terminal", "pane_id": "pane_1"});
    let route = |tab: &Value, step| match tab_zoom_route(tab, step) {
        Ok(action) => Ok(action),
        Err(Failure::Resource(error)) => Err(error["code"].as_str().unwrap().to_owned()),
        Err(_) => Err("other".into()),
    };
    assert_eq!(route(&browser, ZoomStep::In), Ok(Some("browserZoomIn")));
    assert_eq!(route(&browser, ZoomStep::Out), Ok(Some("browserZoomOut")));
    assert_eq!(route(&browser, ZoomStep::Reset), Ok(Some("browserZoomReset")));
    assert_eq!(route(&browser, ZoomStep::Value), Err("validation.invalid".into()));
    assert_eq!(route(&terminal, ZoomStep::Value), Ok(None));
    assert_eq!(route(&terminal, ZoomStep::Reset), Ok(None));
    assert_eq!(route(&terminal, ZoomStep::In), Err("validation.invalid".into()));
}

#[test]
fn the_shown_tab_is_read_from_the_pane_leaf_of_the_screen_layout() {
    let screen = json!({"layout": {"root": {"columns": [{"root": {
        "kind": "split",
        "first": {"kind": "leaf", "pane_id": "pane_a", "active_tab_id": "tab_a"},
        "second": {"kind": "leaf", "pane_id": "pane_b", "active_tab_id": "tab_b"},
    }}]}}});
    assert_eq!(active_tab_of(&screen, "pane_b").as_deref(), Some("tab_b"));
    assert_eq!(active_tab_of(&screen, "pane_c"), None);
}

fn caller_path_fixture() -> Map<String, Value> {
    json!({
        "workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine",
        "tab": "tab_mine", "terminal": "term_mine",
    })
    .as_object()
    .unwrap()
    .clone()
}

fn scoped(
    params: Value,
    caller_route: bool,
    path: Option<Map<String, Value>>,
) -> Result<Value, String> {
    let mut params = params.as_object().unwrap().clone();
    match caller_scopes(&mut params, caller_route, || Ok(path)) {
        Ok(()) => Ok(Value::Object(params)),
        Err(Failure::Resource(error)) => Err(error["code"].as_str().unwrap().to_owned()),
        Err(_) => Err("other".into()),
    }
}

#[test]
fn caller_and_current_become_the_callers_own_ids() {
    let mine = Some(caller_path_fixture());
    let chain = json!({"workspace": "current", "screen": "current", "pane": "caller"});
    assert_eq!(
        scoped(chain.clone(), true, mine.clone()),
        Ok(json!({"workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine"}))
    );
    let current = json!({"workspace": "current", "screen": "current", "pane": "current"});
    assert_eq!(
        scoped(current.clone(), true, mine.clone()),
        Ok(json!({"workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine"}))
    );
    // No caller, or a route to another session: `current` stays focused.
    assert_eq!(scoped(current.clone(), true, None), Ok(current.clone()));
    assert_eq!(scoped(current.clone(), false, mine.clone()), Ok(current));
    // `caller` refuses instead of guessing.
    assert_eq!(scoped(chain.clone(), true, None), Err("selector.not_found".into()));
    assert_eq!(scoped(chain, false, mine), Err("selector.invalid".into()));
}

#[test]
fn current_below_a_parent_that_is_not_the_callers_stays_that_parents() {
    let mine = Some(caller_path_fixture());
    let theirs = json!({"workspace": "ws_theirs", "screen": "current", "pane": "current"});
    assert_eq!(scoped(theirs.clone(), true, mine.clone()), Ok(theirs));
    let own = json!({"workspace": "ws_mine", "screen": "current", "pane": "current"});
    assert_eq!(
        scoped(own, true, mine.clone()),
        Ok(json!({"workspace": "ws_mine", "screen": "screen_mine", "pane": "pane_mine"}))
    );
    // A browser is never the caller: its `current` chain stays focused.
    let browser = json!({"workspace": "current", "tab": "current", "browser": "current"});
    assert_eq!(scoped(browser.clone(), true, mine.clone()), Ok(browser));
    // An agent chat has no terminal of its own: `caller` refuses,
    // `current` stays the focused terminal.
    let mut chat = caller_path_fixture();
    chat.remove("terminal");
    let terminal = json!({"workspace": "current", "terminal": "caller"});
    assert_eq!(scoped(terminal, true, Some(chat.clone())), Err("selector.not_found".into()));
    let focused = json!({"workspace": "current", "terminal": "current"});
    assert_eq!(scoped(focused.clone(), true, Some(chat)), Ok(focused));
    // An explicit id below `current` keeps its focused parents.
    let below = json!({"workspace": "current", "screen": "current", "pane": "pane_x"});
    assert_eq!(scoped(below.clone(), true, mine.clone()), Ok(below));
    // Another machine is never the caller's: `apply` routes it as
    // another session.
    let remote = json!({"machine": "m2", "workspace": "current", "pane": "current"});
    assert!(!this_machine(remote.as_object().unwrap()));
    assert!(this_machine(json!({"machine": "current"}).as_object().unwrap()));
    assert!(this_machine(&Map::new()));
    assert_eq!(scoped(remote.clone(), false, mine.clone()), Ok(remote));
    let remote_caller = json!({"machine": "m2", "workspace": "current", "pane": "caller"});
    assert_eq!(scoped(remote_caller, false, mine), Err("selector.invalid".into()));
}

#[test]
fn a_caller_that_cannot_be_found_leaves_current_focused() {
    let current = json!({"workspace": "current", "pane": "current"});
    let mut params = current.as_object().unwrap().clone();
    let lost = || Err(Failure::Transport("app did not answer".into()));
    assert!(caller_scopes(&mut params, true, lost).is_ok());
    assert_eq!(Value::Object(params), current);
    let caller = json!({"workspace": "current", "pane": "caller"});
    let mut params = caller.as_object().unwrap().clone();
    let lost = || Err(Failure::Transport("app did not answer".into()));
    assert!(caller_scopes(&mut params, true, lost).is_err());
}

#[test]
fn route_keeps_only_machine_and_session() {
    let params = json!({"machine": "current", "session": "s", "room": "x"});
    assert_eq!(
        Value::Object(route(params.as_object().unwrap())),
        json!({"machine": "current", "session": "s"})
    );
}
