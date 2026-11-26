use super::*;

#[test]
fn focused_follows_the_focus_only_below_its_own_parents() {
    let caller = json!({"workspace": "ws_own", "screen": "screen_own", "pane": "pane_own"});
    // As the app reports it: no screen.
    let focus = json!({"workspace": "ws_front", "pane": "pane_front"});
    let place = |params: Value| {
        let mut params = params.as_object().cloned().unwrap();
        apply(&mut params, Some(&caller), Some(&focus));
        Value::Object(params)
    };
    assert_eq!(
        place(json!({"workspace": "focused", "pane": "focused"})),
        json!({"workspace": "ws_front", "pane": "pane_front"})
    );
    // Below the caller's workspace the focused pane is not there: the
    // daemon's active pane of that workspace.
    assert_eq!(
        place(json!({"workspace": "current", "pane": "focused"})),
        json!({"workspace": "ws_own", "pane": "current"})
    );
    assert_eq!(
        place(json!({"workspace": "ws_front", "pane": "focused"})),
        json!({"workspace": "ws_front", "pane": "pane_front"})
    );
    assert_eq!(
        place(json!({"workspace": "ws_fr", "pane": "focused"})),
        json!({"workspace": "ws_fr", "pane": "pane_front"}),
        "a unique prefix of the focused workspace"
    );
    // `pane focused` implies a focused screen, which the focus does not
    // name: the daemon's, and the pane is still the focused one.
    assert_eq!(
        place(json!({"workspace": "focused", "screen": "focused", "pane": "focused"})),
        json!({"workspace": "ws_front", "screen": "current", "pane": "pane_front"})
    );
    // A screen the focus does not name, other than the implied focused
    // one: the daemon's active pane under it, never the focused pane.
    assert_eq!(
        place(json!({"screen": "current", "pane": "focused"})),
        json!({"screen": "screen_own", "pane": "current"})
    );
    assert_eq!(
        place(json!({"workspace": "ws_front", "screen": "screen_x", "pane": "focused"})),
        json!({"workspace": "ws_front", "screen": "screen_x", "pane": "current"})
    );
    assert_eq!(
        place(json!({"screen": "focused", "pane": "focused"})),
        json!({"screen": "current", "pane": "current"}),
        "no workspace to check the focused pane against"
    );
    // No caller: an unresolved `current` workspace may not be the
    // focused one, so the pane is its active one.
    let mut params = json!({"workspace": "current", "pane": "focused"});
    apply(params.as_object_mut().unwrap(), None, Some(&focus));
    assert_eq!(params, json!({"workspace": "current", "pane": "current"}));
}
