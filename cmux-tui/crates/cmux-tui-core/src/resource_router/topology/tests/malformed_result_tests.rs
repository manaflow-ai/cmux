//! A public value or commit result that lacks the field the topology router
//! reads is a typed `operation.failed`, never a panic or an exported `null`.

use super::*;
use crate::workspace_registry::ResourcePatchCommit;

fn failure_reason(error: &ResourceError) -> &str {
    assert_eq!(error.code, "operation.failed", "{error:?}");
    error.details["reason"].as_str().unwrap()
}

#[test]
fn screen_layout_export_returns_the_layout_document() {
    let layout = json!({"root":{"kind":"viewport"}});
    let exported = screen_layout(json!({"id":"screen-1","layout":layout})).unwrap();
    assert_eq!(exported, layout);
}

#[test]
fn screen_without_layout_is_operation_failed() {
    for screen in [json!({"id":"screen-1"}), json!("screen-1"), Value::Null] {
        let error = screen_layout(screen).unwrap_err();
        assert_eq!(failure_reason(&error), "public screen value omitted its layout");
        assert_eq!(error.details["operation"], "screen.layout.export");
    }
}

#[test]
fn screen_layout_export_dispatch_returns_the_screen_layout() {
    let mux = mux();
    let created = terminal_workspace(&mux, "layout-export");
    let screen = created["value"]["screen_id"].as_str().unwrap().to_string();
    let exported = dispatch(
        &mux,
        parsed(
            ResourceOperation::ScreenLayoutExport,
            selectors(None, Some(&screen), None, None),
            json!({}),
            None,
        ),
    )
    .unwrap();
    let screen_value = public_session_snapshot(&mux).unwrap()["screens"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == screen.as_str())
        .unwrap()["layout"]
        .clone();
    assert!(exported.is_object(), "{exported}");
    assert_eq!(exported, screen_value);
}

#[test]
fn commit_without_public_identity_is_operation_failed() {
    for result in [json!({}), json!({"tab_id":7}), json!([]), Value::Null] {
        let error = result_id(&result, "tab.rename", "tab_id").unwrap_err();
        assert_eq!(failure_reason(&error), "topology commit omitted its public identity");
    }
    assert_eq!(result_id(&json!({"tab_id":"tab-1"}), "tab.rename", "tab_id").unwrap(), "tab-1");
}

#[test]
fn commit_without_its_exact_public_value_is_operation_failed() {
    let mux = mux();
    for result in [
        json!({"tab_id":"tab-1"}),
        json!({"tab_id":"tab-1","public_value":null}),
        json!({"tab_id":"tab-1","public_value":"tab-1"}),
        json!({"tab_id":"tab-1","public_value":{"name":"no id"}}),
        json!({"tab_id":"tab-1","public_value":{"id":"tab-2"}}),
    ] {
        let commit = ResourcePatchCommit { revision: 1, result, replayed: false };
        let error = snapshot_mutation_result(&mux, commit, "tab.rename", "tab_id").unwrap_err();
        assert_eq!(failure_reason(&error), "topology commit omitted its exact public result");
    }
}
