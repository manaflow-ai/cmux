//! `pane.split` with `fit: true` (`cmux pane <p> split --right --fit`) makes a
//! column that shares the window: on a screen whose columns fit it, the new
//! column takes an equal share and the others are scaled, so the row never
//! becomes a sideways-scrolling strip the person did not choose (Aziz
//! 2026-11-06: an agent's two `split --right --viewport-width 0.5` made a
//! two-viewport-wide strip). `viewport_width` keeps meaning exactly that width,
//! a screen that already scrolls keeps its widths, and the app's own New Column
//! resizes no column (R3b).

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
fn fit_columns_share_the_window_instead_of_scrolling() {
    let mux = mux();
    let first = workspace(&mux, "fit-two");
    let split = |key: &str| send(&mux, json!({"pane":first,"direction":"right","fit":true}), key);
    split("fit-two-a");
    assert_widths(&column_widths(&mux, &first), &[0.5, 0.5]);
    split("fit-two-b");
    assert_widths(&column_widths(&mux, &first), &[1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0]);
}

#[test]
fn an_explicit_viewport_width_is_kept() {
    let mux = mux();
    let first = workspace(&mux, "fit-explicit");
    send(
        &mux,
        json!({"pane":first,"direction":"right","viewport_width":0.5}),
        "fit-explicit-split",
    );
    assert_eq!(column_widths(&mux, &first), vec![1.0, 0.5]);
}

#[test]
fn a_fit_column_on_a_screen_that_already_scrolls_keeps_the_widths() {
    let mux = mux();
    let first = workspace(&mux, "fit-scrolling");
    // The app's New Column (the person's own scrolling layout): no fit, R3b.
    mux.new_pane_right(pane_id(&mux, &first), 0.5, None).unwrap();
    assert_eq!(column_widths(&mux, &first), vec![1.0, 0.5]);
    send(&mux, json!({"pane":first,"direction":"right","fit":true}), "fit-scrolling-split");
    assert_eq!(column_widths(&mux, &first), vec![1.0, 0.5, 0.5]);
}

#[test]
fn fit_with_a_viewport_width_is_refused() {
    let mux = mux();
    let first = workspace(&mux, "fit-both");
    let envelope = json!({
        "protocol":"cmux.protocol/2","type":"request","id":"fit-both","operation":"pane.split",
        "idempotency_key":"fit-both-split",
        "params":{"machine":"current","session":"current","pane":first,"direction":"right",
                  "fit":true,"viewport_width":0.5},
    });
    let response = handle_resource_message(&mux, &envelope.to_string()).unwrap();
    assert_eq!(response["ok"], false, "{response}");
}
