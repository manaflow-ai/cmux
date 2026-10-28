//! tab-attention-v1: an agent marks the tab where the person must act. The
//! mark rides on the tab record (`extra.attention`), never moves focus, and
//! clears on the agent's clear, a browser tab's navigation, or the tab's
//! close; a reopened tab does not bring it back.

use serde_json::json;

use super::tests::{error_code, mutate, read, send, snapshot, tab_id, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::FrontendBrowserRecord;

const REASON: &str = "Confirm GitHub access";

fn browser_tab(mux: &Arc<Mux>) -> SurfaceId {
    let terminal = terminal_tabs(mux, 1)[0];
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let record = FrontendBrowserRecord {
        engine: "webkit".into(),
        url: "https://github.com/settings/apps".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id
}

fn listed_attention(mux: &Mux, tab: &str) -> Value {
    snapshot(mux)["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|listed| listed["id"] == tab)
        .map(|listed| listed["extra"]["attention"].clone())
        .unwrap_or(Value::Null)
}

fn focused(mux: &Mux) -> Option<SurfaceId> {
    mux.active_surface()
}

#[test]
fn an_agent_marks_a_tab_without_moving_focus_and_clears_it() {
    let mux = Mux::new_for_test("state-tab-attention", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let tab = tab_id(&mux, tabs[0]);
    let focus_before = focused(&mux);
    let marked =
        mutate(&mux, "tab.update", json!({"tab": tab, "attention": REASON}), "attention-1");
    assert_eq!(marked["extra"]["attention"]["reason"], REASON);
    assert!(marked["extra"]["attention"]["at_ms"].as_u64().is_some());
    assert_eq!(listed_attention(&mux, &tab)["reason"], REASON);
    assert_eq!(focused(&mux), focus_before, "a request never moves focus");
    let zoomed = mutate(&mux, "tab.update", json!({"tab": tab, "zoom": 1.5}), "attention-2");
    assert_eq!(zoomed["extra"]["attention"]["reason"], REASON, "another field keeps the mark");
    let cleared = mutate(&mux, "tab.update", json!({"tab": tab, "attention": null}), "attention-3");
    assert!(cleared["extra"].get("attention").is_none());
    assert_eq!(cleared["extra"]["zoom"], 1.5);
    let bad_values = [
        json!(""),
        json!("two\nlines"),
        json!("two\u{2028}lines"),
        json!(true),
        json!("x".repeat(201)),
    ];
    for (index, bad) in bad_values.into_iter().enumerate() {
        assert_eq!(
            error_code(send(
                &mux,
                "tab.update",
                json!({"tab": tab, "attention": bad}),
                Some(&format!("attention-bad-{index}"))
            )),
            "validation.invalid",
            "{bad}"
        );
    }
}

#[test]
fn a_browser_tab_drops_its_mark_when_its_page_changes_but_not_on_a_title_change() {
    let mux = Mux::new_for_test("state-tab-attention-nav", SurfaceOptions::default());
    let browser = browser_tab(&mux);
    let tab = tab_id(&mux, browser);
    mutate(&mux, "tab.update", json!({"tab": tab, "attention": REASON}), "attention-nav-1");
    mux.update_frontend_browser_tab(browser, None, Some("GitHub".into()), None).unwrap();
    assert_eq!(listed_attention(&mux, &tab)["reason"], REASON, "a title alone keeps the mark");
    mux.update_frontend_browser_tab(
        browser,
        Some("https://github.com/settings/apps".into()),
        None,
        None,
    )
    .unwrap();
    assert_eq!(listed_attention(&mux, &tab)["reason"], REASON, "the same page keeps the mark");
    mux.update_frontend_browser_tab(browser, Some("https://github.com/".into()), None, None)
        .unwrap();
    assert!(listed_attention(&mux, &tab).is_null(), "another page clears the mark");
    // The agent marks the page the tab is on now; that page's navigation
    // clear, arriving after the mark, keeps it (it decides in its own commit).
    mutate(&mux, "tab.update", json!({"tab": tab, "attention": REASON}), "attention-nav-2");
    assert!(listed_attention(&mux, &tab).get("page").is_none(), "extra.attention shows no page");
    mux.clear_attention_after_navigation(&crate::Actor::Daemon, browser, "https://github.com/");
    assert_eq!(listed_attention(&mux, &tab)["reason"], REASON, "a late clear for its own page");
    // A stale clear for a page the tab already left (two navigations
    // overlapping) keeps the mark the agent set on the page it is on now.
    mux.clear_attention_after_navigation(
        &crate::Actor::Daemon,
        browser,
        "https://github.com/settings/apps",
    );
    assert_eq!(listed_attention(&mux, &tab)["reason"], REASON, "a stale clear dropped the mark");
    mux.update_frontend_browser_tab(browser, Some("https://github.com/x".into()), None, None)
        .unwrap();
    assert!(listed_attention(&mux, &tab).is_null(), "the next page clears it");
}

#[test]
fn a_closed_tab_drops_its_mark_and_a_reopen_does_not_bring_it_back() {
    let mux = Mux::new_for_test("state-tab-attention-close", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let tab = tab_id(&mux, tabs[1]);
    mutate(&mux, "tab.update", json!({"tab": tab, "attention": REASON}), "attention-close-1");
    mutate(&mux, "tab.close", json!({"tab": tab}), "attention-close-2");
    let closed = read(&mux, "closed.list", json!({}));
    let reopened = mutate(
        &mux,
        "closed.reopen",
        json!({"closed": closed[0]["id"].clone()}),
        "attention-close-3",
    );
    let reopened = reopened["tab_ids"][0].as_str().unwrap();
    assert!(listed_attention(&mux, reopened).is_null());
}
