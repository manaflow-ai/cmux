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
    browser_tab_at(mux, "https://github.com/settings/apps")
}

fn browser_tab_at(mux: &Arc<Mux>, url: &str) -> SurfaceId {
    let terminal = terminal_tabs(mux, 1)[0];
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let record = FrontendBrowserRecord {
        engine: "webkit".into(),
        url: url.into(),
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

/// The raw tree's record of the tab on `surface`.
fn tree_tab(mux: &Mux, surface: SurfaceId) -> Value {
    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap().iter())
        .flat_map(|screen| screen["panes"].as_array().unwrap().iter())
        .flat_map(|pane| pane["tabs"].as_array().unwrap().iter())
        .find(|listed| listed["surface"] == json!(surface))
        .cloned()
        .unwrap()
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

#[test]
fn attention_request_identity_clear_is_guarded_and_validated() {
    let mux = Mux::new_for_test("state-attention-request-id", SurfaceOptions::default());
    let tab = tab_id(&mux, terminal_tabs(&mux, 1)[0]);
    let a = mutate(&mux, "tab.update", json!({"tab":tab,"attention":REASON}), "request-a");
    let a_id = a["extra"]["attention"]["request_id"].clone();
    let b = mutate(&mux, "tab.update", json!({"tab":tab,"attention":REASON}), "request-b");
    let b_id = b["extra"]["attention"]["request_id"].clone();
    assert_ne!(a_id, b_id);
    let stale = mutate(
        &mux,
        "tab.update",
        json!({
            "tab":tab,"attention":null,"attention_request_id":a_id,"zoom":1.5
        }),
        "request-stale-clear",
    );
    assert_eq!(stale["extra"]["attention"]["request_id"], b_id);
    assert_eq!(stale["extra"]["zoom"], 1.5);
    // A retry replays the original result, never creates a third identity.
    let replay =
        send(&mux, "tab.update", json!({"tab":tab,"attention":REASON}), Some("request-b")).unwrap();
    assert_eq!(replay["replayed"], true);
    assert_eq!(replay["value"]["extra"]["attention"]["request_id"], b_id);
    for (index, invalid) in [
        Value::Null,
        json!(true),
        json!(""),
        json!("0".repeat(31)),
        json!("0".repeat(33)),
        json!("A".repeat(32)),
        json!("é".repeat(16)),
    ]
    .into_iter()
    .enumerate()
    {
        assert_eq!(
            error_code(send(
                &mux,
                "tab.update",
                json!({
                    "tab":tab,"attention":null,"attention_request_id":invalid
                }),
                Some(&format!("request-invalid-{index}"))
            )),
            "validation.invalid"
        );
        assert_eq!(listed_attention(&mux, &tab)["request_id"], b_id);
    }
    for (index, attention) in [Some(json!(REASON)), None].into_iter().enumerate() {
        let mut params = json!({"tab":tab,"attention_request_id":b_id,"zoom":1.0});
        if let Some(value) = attention {
            params["attention"] = value;
        }
        assert_eq!(
            error_code(send(
                &mux,
                "tab.update",
                params,
                Some(&format!("request-wrong-use-{index}"))
            )),
            "validation.invalid"
        );
    }
    let cleared = mutate(
        &mux,
        "tab.update",
        json!({
            "tab":tab,"attention":null,"attention_request_id":b_id
        }),
        "request-current-clear",
    );
    assert!(cleared["extra"].get("attention").is_none());
}

/// The raw tree (what the TUI and other tree clients read) carries a tab's
/// mark as `attention: {reason, at_ms}`, and drops it when the agent clears it,
/// so a frontend draws marks without reading the resource API.
#[test]
fn the_raw_tree_carries_a_tab_attention_mark_until_it_clears() {
    let mux = Mux::new_for_test("state-tab-attention-tree", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let tab = tab_id(&mux, tabs[1]);
    let tree_tab = |mux: &Mux| tree_tab(mux, tabs[1]);
    assert!(tree_tab(&mux)["attention"].is_null());
    mutate(&mux, "tab.update", json!({"tab": tab, "attention": REASON}), "attention-tree-1");
    let marked = tree_tab(&mux);
    assert_eq!(marked["attention"]["reason"], REASON);
    assert!(marked["attention"]["at_ms"].as_u64().is_some_and(|at| at > 0));
    assert!(marked["attention"].get("request_id").is_none(), "the tree shows only what is drawn");
    mutate(&mux, "tab.update", json!({"tab": tab, "attention": null}), "attention-tree-2");
    assert!(tree_tab(&mux)["attention"].is_null());
}

/// A mark older than `ATTENTION_MAX_AGE_MS` is swept through a state commit:
/// the tab list and the raw tree drop it. A younger mark stays, and the
/// sweep says when it expires.
#[test]
fn the_sweep_clears_an_expired_mark_from_the_list_and_the_tree() {
    use crate::state::tab_state_store::ATTENTION_MAX_AGE_MS;
    let mux = Mux::new_for_test("state-tab-attention-expiry", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let tab = tab_id(&mux, tabs[1]);
    let marked =
        mutate(&mux, "tab.update", json!({"tab": tab, "attention": REASON}), "attention-expiry-1");
    let at = marked["extra"]["attention"]["at_ms"].as_u64().unwrap();
    let expires = at + ATTENTION_MAX_AGE_MS;
    assert_eq!(mux.expire_attention_marks(&crate::Actor::Daemon, expires - 1), Some(expires));
    assert_eq!(listed_attention(&mux, &tab)["reason"], REASON, "a younger mark stays");
    assert_eq!(tree_tab(&mux, tabs[1])["attention"]["reason"], REASON);
    assert_eq!(mux.expire_attention_marks(&crate::Actor::Daemon, expires), None);
    assert!(listed_attention(&mux, &tab).is_null(), "the expired mark is cleared");
    assert!(tree_tab(&mux, tabs[1])["attention"].is_null(), "the tree drops it too");
}

/// A placeholder browser tab on `about:blank` records no page with its
/// mark: an `about:blank` event keeps it and the first real page clears it.
#[test]
fn a_mark_on_about_blank_records_no_page_and_the_first_real_page_clears_it() {
    let mux = Mux::new_for_test("state-tab-attention-blank", SurfaceOptions::default());
    let browser = browser_tab_at(&mux, "about:blank");
    let tab = tab_id(&mux, browser);
    mutate(&mux, "tab.update", json!({"tab": tab, "attention": REASON}), "attention-blank-1");
    let stored = mux
        .personal_state_read(|connection| {
            Ok(connection.query_row(
                "SELECT attention_json FROM tab_state WHERE tab_id = ?1",
                [tab.as_str()],
                |row| row.get::<_, String>(0),
            )?)
        })
        .unwrap();
    let stored: Value = serde_json::from_str(&stored).unwrap();
    assert!(stored.get("page").is_none(), "about:blank is no page: {stored}");
    mux.clear_attention_after_navigation(&crate::Actor::Daemon, browser, "about:blank");
    assert_eq!(listed_attention(&mux, &tab)["reason"], REASON, "about:blank keeps the mark");
    mux.update_frontend_browser_tab(browser, Some("https://github.com/login".into()), None, None)
        .unwrap();
    assert!(listed_attention(&mux, &tab).is_null(), "the first real page clears it");
}
