//! A script's new column (`pane.split` with `viewport_width` from the CLI, MCP
//! or an SDK) shares the window with the columns already there, so the row
//! never becomes a sideways-scrolling strip the person did not choose (Aziz
//! 2026-11-06: an agent's two `split --right --viewport-width 0.5` made a
//! two-viewport-wide strip). A screen that already scrolls keeps its widths,
//! and the app's own New Column still resizes no column (R3b).

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource::PanePublicId;

fn send(mux: &Arc<Mux>, fields: Value, key: &str) -> Value {
    send_operation(mux, "pane.split", fields, key)
}

fn send_operation(mux: &Arc<Mux>, operation: &str, fields: Value, key: &str) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("split-fit-{key}"),
        "operation":operation,
        "params":params,
        "idempotency_key":key,
    });
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(response["ok"], true, "{operation} failed: {response}");
    response["result"].clone()
}

fn workspace(mux: &Arc<Mux>, key: &str) -> String {
    let created = send_operation(
        mux,
        "workspace.create",
        json!({"initial_content":"terminal","name":key}),
        key,
    );
    created["value"]["pane_id"].as_str().unwrap().to_string()
}

fn pane_id(mux: &Arc<Mux>, pane: &str) -> crate::PaneId {
    let id = PanePublicId::parse(pane.to_string()).unwrap();
    mux.with_state(|state| state.pane_by_public_id(&id).map(|pane| pane.id)).unwrap()
}

/// The widths of the columns of the screen holding `pane`, left to right.
fn column_widths(mux: &Arc<Mux>, pane: &str) -> Vec<f32> {
    let target = pane_id(mux, pane);
    mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(target).unwrap();
        state.workspaces[workspace].screens[screen]
            .layout_columns
            .iter()
            .map(|column| column.width)
            .collect()
    })
}

fn assert_widths(actual: &[f32], expected: &[f32]) {
    assert_eq!(actual.len(), expected.len(), "{actual:?} vs {expected:?}");
    for (a, e) in actual.iter().zip(expected) {
        assert!((a - e).abs() < 1e-3, "{actual:?} vs {expected:?}");
    }
    let sum: f32 = actual.iter().sum();
    assert!(sum <= 1.0 + 1e-3, "the columns overflow the window: {actual:?}");
}

fn mux() -> Arc<Mux> {
    Mux::new_for_test("split-fit", SurfaceOptions::default())
}

#[test]
fn a_scripts_columns_share_the_window_instead_of_scrolling() {
    let mux = mux();
    let first = workspace(&mux, "fit-two");
    let split =
        |key: &str| send(&mux, json!({"pane":first,"direction":"right","viewport_width":0.5}), key);
    split("fit-two-a");
    assert_widths(&column_widths(&mux, &first), &[0.5, 0.5]);
    split("fit-two-b");
    assert_widths(&column_widths(&mux, &first), &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]);
}

#[test]
fn a_screen_that_already_scrolls_keeps_its_widths() {
    let mux = mux();
    let first = workspace(&mux, "fit-scrolling");
    // The app's New Column (the person's own scrolling layout): no fit, R3b.
    mux.new_pane_right(pane_id(&mux, &first), 0.5, None).unwrap();
    assert_eq!(column_widths(&mux, &first), vec![1.0, 0.5]);
    send(
        &mux,
        json!({"pane":first,"direction":"right","viewport_width":0.5}),
        "fit-scrolling-split",
    );
    assert_eq!(column_widths(&mux, &first), vec![1.0, 0.5, 0.5]);
}
