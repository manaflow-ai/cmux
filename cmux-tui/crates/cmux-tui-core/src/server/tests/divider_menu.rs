//! The divider menu's wire: `set-divider-visible` with the layout's
//! `hidden_dividers` (`split-divider-visibility-v1`), and `split` with
//! `around` (`split-around-v1`).

use super::*;

fn screen_layout(mux: &Arc<Mux>) -> Value {
    run_json_command(mux, json!({"cmd": "list-workspaces"})).unwrap()["workspaces"][0]["screens"][0]
        .clone()
}

#[test]
fn set_divider_visible_hides_and_shows_a_divider_in_the_layout() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    mux.split(pane, SplitDir::Right, None).unwrap();
    let split = screen_layout(&mux)["layout"]["split"].as_u64().expect("split handle");
    assert!(screen_layout(&mux).get("hidden_dividers").is_none());

    let reply = run_json_command(
        &mux,
        json!({"cmd": "set-divider-visible", "split": split, "visible": false, "transaction": 3}),
    )
    .unwrap();
    assert_eq!(reply, json!({}));
    assert_eq!(screen_layout(&mux)["hidden_dividers"], json!([split]));

    // The same value again is a no-op.
    run_json_command(&mux, json!({"cmd": "set-divider-visible", "split": split, "visible": false}))
        .unwrap();
    assert_eq!(screen_layout(&mux)["hidden_dividers"], json!([split]));

    run_json_command(&mux, json!({"cmd": "set-divider-visible", "split": split, "visible": true}))
        .unwrap();
    assert!(screen_layout(&mux).get("hidden_dividers").is_none());

    let error = run_json_command(
        &mux,
        json!({"cmd": "set-divider-visible", "split": 999_999, "visible": false}),
    )
    .unwrap_err();
    assert_eq!(error.to_string(), "unknown split 999999");
    assert_eq!(response_error_code(&error).as_deref(), Some(LayoutRatioError::UNKNOWN_TARGET_CODE));
    mux.shutdown();
}

#[test]
fn split_around_wraps_the_whole_split_and_refuses_a_pane_it_does_not_end_at() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let x = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let b = mux.split(x, SplitDir::Right, None).unwrap();
    let b = mux.with_state(|state| state.pane_of(b.id).unwrap());
    let y = mux.split(x, SplitDir::Down, None).unwrap();
    let y = mux.with_state(|state| state.pane_of(y.id).unwrap());
    let layout = screen_layout(&mux)["layout"].clone();
    let a = layout["a"]["split"].as_u64().expect("a is a split");

    let refused =
        run_json_command(&mux, json!({"cmd": "split", "pane": x, "dir": "right", "around": a}))
            .unwrap_err();
    assert!(
        format!("{refused:#}").contains(&format!("around split {a} does not end at pane {x}")),
        "{refused:#}"
    );
    assert_eq!(screen_layout(&mux)["layout"], layout);

    run_json_command(&mux, json!({"cmd": "split", "pane": y, "dir": "right", "around": a}))
        .unwrap();
    let after = screen_layout(&mux)["layout"].clone();
    // ((X / Y) | new) | B
    assert_eq!(after["b"], json!({"type": "leaf", "pane": b}));
    assert_eq!(after["a"]["dir"], "right");
    assert_eq!(after["a"]["a"]["split"], a);
    assert_eq!(after["a"]["a"]["a"]["pane"], x);
    assert_eq!(after["a"]["a"]["b"]["pane"], y);
    assert_eq!(after["a"]["b"]["type"], "leaf");
    mux.shutdown();
}
