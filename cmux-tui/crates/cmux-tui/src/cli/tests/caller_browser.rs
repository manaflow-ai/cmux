use super::*;

fn params(value: Value) -> Map<String, Value> {
    value.as_object().cloned().expect("an object")
}

#[test]
fn only_a_current_browser_chain_is_the_callers() {
    assert!(wants(&params(
        json!({"workspace": "current", "tab": "current", "browser": "current"})
    )));
    assert!(wants(&params(json!({"browser": "current"}))));
    assert!(!wants(&params(json!({"tab": "tab_x", "browser": "current"}))));
    assert!(!wants(&params(json!({"workspace": "ws_x", "browser": "current"}))));
    assert!(!wants(&params(json!({"browser": "browser_x"}))));
    assert!(!wants(&params(json!({"browser": "focused"}))));
}

#[test]
fn the_nearest_browser_replaces_the_focused_chain() {
    let mut chain = params(json!({"workspace": "current", "tab": "current", "browser": "current"}));
    let identity = json!({
        "caller": {"workspace": "ws_mine", "tab": "tab_chat"},
        "browser": {"tab": "tab_near", "pane": "pane_b", "screen": "screen_a",
                    "workspace": "ws_mine", "session": null},
    });
    assert_eq!(apply(&mut chain, &identity), Ok(true));
    // The daemon reads a `current` browser only below a full chain.
    assert_eq!(
        Value::Object(chain),
        json!({"workspace": "ws_mine", "screen": "screen_a", "pane": "pane_b",
               "tab": "tab_near", "browser": "current"})
    );
}

#[test]
fn a_caller_with_no_browser_near_it_is_refused_not_sent_to_the_focused_one() {
    let mut chain = params(json!({"workspace": "current", "tab": "current", "browser": "current"}));
    let identity = json!({"caller": {"workspace": "ws_mine"}, "browser": null});
    let error = apply(&mut chain, &identity).expect_err("no browser near the caller");
    assert_eq!(error["code"], "selector.not_found");
    let elsewhere =
        json!({"caller": {"workspace": "ws_mine"}, "browser": {"tab": "tab_r", "session": "m1"}});
    assert_eq!(
        apply(&mut chain, &elsewhere).expect_err("another session")["code"],
        "selector.invalid"
    );
}

#[test]
fn an_unplaced_caller_or_an_older_app_keeps_the_chain() {
    let chain = params(json!({"workspace": "current", "tab": "current", "browser": "current"}));
    let mut kept = chain.clone();
    assert_eq!(apply(&mut kept, &json!({"caller": {"found": false}})), Ok(false));
    assert_eq!(apply(&mut kept, &json!({"caller": {"workspace": "ws_mine"}})), Ok(false));
    // A place the daemon cannot name by id: no screen, or a surface fallback id.
    let partial = json!({"caller": {"workspace": "ws_mine"},
        "browser": {"tab": "tab_near", "pane": "pane_b", "workspace": "ws_mine", "session": null}});
    assert_eq!(apply(&mut kept, &partial), Ok(false));
    let fallback = json!({"caller": {"workspace": "ws_mine"},
        "browser": {"tab": "surface:4", "pane": "pane:2", "screen": "screen_a",
                    "workspace": "ws_mine", "session": null}});
    assert_eq!(apply(&mut kept, &fallback), Ok(false));
    assert_eq!(kept, chain);
}
