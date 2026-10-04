//! A closed page (browser) tab never comes back to fail a later commit:
//! after a browser tab is closed, creating a workspace succeeds and leaves no
//! half-created workspace (live repro: "workspace new --cwd" failed with
//! "tombstoned public id cannot be reused: browser_…" on every run after an
//! editor page tab was closed with Cmd-W).

use serde_json::{Value, json};

use super::*;
use crate::SurfaceOptions;
use crate::resource_api::public_session_snapshot;

fn parsed_request(
    operation: &str,
    selectors: &ResourceSelectors,
    fields: Value,
    idempotency_key: &str,
) -> ParsedResourceRequest {
    let mut params = serde_json::to_value(selectors).unwrap().as_object().unwrap().clone();
    params.extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{operation}"),
        "operation":operation,
        "params":params,
        "idempotency_key":idempotency_key,
    });
    parse_resource_request(&serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|e| panic!("{operation} {params:?}: {e:?}", params = envelope["params"]))
}

fn session() -> ResourceSelectors {
    ResourceSelectors {
        machine: Some("current".to_string()),
        session: Some("current".to_string()),
        ..ResourceSelectors::default()
    }
}

/// Opens two page tabs, closes one through `close`, then creates a workspace
/// with a cwd. Returns the create result and the workspace count before it.
fn close_a_page_then_create(close: &str) -> (anyhow::Result<Value>, usize, usize) {
    let mux = Mux::new_for_test(&format!("closed-page-{close}"), SurfaceOptions::default());
    let mut browsers = Vec::new();
    for (index, url) in ["file:///tmp/README.md", "file:///tmp/app.ts"].into_iter().enumerate() {
        let created = topology::dispatch(
            &mux,
            parsed_request("tab.create_browser", &session(), json!({"url":url}), &format!("page-{index}")),
        )
        .unwrap();
        browsers.push((
            created["value"]["browser_id"].as_str().unwrap().to_string(),
            created["value"]["tab_id"].as_str().unwrap().to_string(),
        ));
    }
    let (browser, tab) = browsers.pop().unwrap();
    let selectors = ResourceSelectors {
        browser: (close == "browser.close").then_some(browser),
        tab: (close == "tab.close").then_some(tab),
        ..session()
    };
    let closed = if close == "browser.close" {
        content::dispatch(&mux, parsed_request(close, &selectors, json!({}), "close-page"))
    } else {
        topology::dispatch(&mux, parsed_request(close, &selectors, json!({}), "close-page"))
    };
    closed.unwrap();
    let count = |mux: &Mux| {
        public_session_snapshot(mux).unwrap()["workspaces"].as_array().unwrap().len()
    };
    let before = count(&mux);
    let created = topology::dispatch(
        &mux,
        parsed_request(
            "workspace.create",
            &session(),
            json!({"initial_content":"terminal","name":"after-close"}),
            "create-after-close",
        ),
    )
    .map_err(|e| anyhow::anyhow!("{} {}", e.code, e.message));
    let after = count(&mux);
    mux.shutdown();
    (created, before, after)
}

#[test]
fn creating_a_workspace_after_tab_close_of_a_page_succeeds() {
    let (created, before, after) = close_a_page_then_create("tab.close");
    assert!(created.is_ok(), "{:?}", created.err());
    assert_eq!(after, before + 1);
}

#[test]
fn creating_a_workspace_after_browser_close_of_a_page_succeeds() {
    let (created, before, after) = close_a_page_then_create("browser.close");
    assert!(created.is_ok(), "{:?}", created.err());
    assert_eq!(after, before + 1);
}
