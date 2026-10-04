//! A browser shown by two tabs stays live when one of them closes: closing
//! a tab ends its browser only when no live tab still shows that browser.
//! Before, the close tombstoned the browser (and the other tab's row) while
//! memory kept the other tab, so every later commit re-upserted the
//! tombstoned id and failed ("tombstoned public id cannot be reused:
//! browser_…"), including workspace creation.

use super::*;
use crate::resource::{BrowserPublicId, ContentPublicId};
use serde_json::{Value, json};

fn request(mux: &Arc<Mux>, operation: &str, fields: Value, key: &str) -> Value {
    let mut params = json!({"machine":"current","session":"current"});
    params.as_object_mut().unwrap().extend(fields.as_object().unwrap().clone());
    let envelope = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":format!("test-{key}"),
        "operation":operation,
        "params":params,
        "idempotency_key":key,
    });
    crate::resource_router::handle_resource_message(mux, &envelope.to_string()).unwrap()
}

fn ok(response: Value) -> Value {
    assert_eq!(response["ok"], true, "{response}");
    response["result"]["value"].clone()
}

#[test]
fn closing_one_of_two_tabs_on_a_browser_keeps_the_browser_and_later_commits_work() {
    let mux = Mux::new_for_test("shared-browser", SurfaceOptions::default());
    let a = ok(request(&mux, "tab.create_browser", json!({"url":"file:///tmp/README.md"}), "page-a"));
    let b = ok(request(&mux, "tab.create_browser", json!({"url":"file:///tmp/app.ts"}), "page-b"));
    let browser = BrowserPublicId::parse(a["browser_id"].as_str().unwrap()).unwrap();
    let (tab_a, tab_b) =
        (a["tab_id"].as_str().unwrap().to_string(), b["tab_id"].as_str().unwrap().to_string());
    // Tab B shows tab A's browser (one page in two tabs), committed once.
    {
        let mut state = mux.state.lock().unwrap();
        let slot = *state
            .resource_indexes
            .tab_ids
            .iter()
            .find(|(_, id)| id.as_str() == tab_b)
            .unwrap()
            .0;
        state.resource_indexes.content_ids.insert(slot, ContentPublicId::Browser(browser.clone()));
    }
    mux.commit_ordinary_full_resource_projection("test-share-browser", json!({})).unwrap();

    ok(request(&mux, "tab.close", json!({"tab":tab_a}), "close-a"));

    let snapshot = crate::resource_api::public_session_snapshot(&mux).unwrap();
    let tabs: Vec<_> =
        snapshot["tabs"].as_array().unwrap().iter().map(|t| t["id"].as_str().unwrap().to_string()).collect();
    assert!(tabs.contains(&tab_b), "the other tab of the browser was closed: {tabs:?}");
    assert!(
        snapshot["browsers"].as_array().unwrap().iter().any(|x| x["id"] == browser.as_str()),
        "the browser a live tab shows was tombstoned"
    );
    let created = request(&mux, "workspace.create", json!({"initial_content":"terminal","name":"after"}), "create");
    assert_eq!(created["ok"], true, "a later workspace create failed: {created}");
    mux.shutdown();
}
