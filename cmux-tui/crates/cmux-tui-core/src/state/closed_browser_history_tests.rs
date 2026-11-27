//! Reopen Closed brings a frontend browser tab back with its session
//! history (cx-d0d.11, plans/cmux-next/reopen-closed.md S6): the back and
//! forward entries and scroll positions the app stored for the tab
//! (`frontend-browser-history-v1`) wait in the closed record, so a reopen
//! after a relaunch walks Back as Chrome's does. They never reach
//! `closed.list`.

use serde_json::json;

use super::tests::{mutate, read, tab_id, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::FrontendBrowserRecord;

const HISTORY: &str = r#"{"entries":[{"url":"https://example.com/a","title":"A","scrollY":640},{"url":"https://example.com/b","title":"B","scrollY":0}],"index":1}"#;

fn browser_tab(mux: &Arc<Mux>, engine: &str) -> SurfaceId {
    let terminal = terminal_tabs(mux, 1)[0];
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let record = FrontendBrowserRecord {
        engine: engine.into(),
        url: "https://example.com/b".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id
}

/// Close `surface`'s tab and reopen the newest closed group; the reopened
/// tab's surface.
fn close_and_reopen(mux: &Arc<Mux>, surface: SurfaceId, key: &str) -> SurfaceId {
    mutate(mux, "tab.close", json!({"tab": tab_id(mux, surface)}), &format!("{key}-close"));
    let closed = read(mux, "closed.list", json!({}));
    assert!(
        !closed.to_string().contains("scrollY"),
        "closed.list must not carry the session history: {closed}"
    );
    let reopened =
        mutate(mux, "closed.reopen", json!({"closed": closed[0]["id"]}), &format!("{key}-reopen"));
    let tab = reopened["tab_ids"][0].as_str().expect("reopened tab id").to_string();
    mux.with_state(|state| {
        state
            .resource_indexes
            .tab_ids
            .iter()
            .find(|(_, public)| public.to_string() == tab)
            .map(|(surface, _)| *surface)
    })
    .expect("a surface shows the reopened tab")
}

#[test]
fn cmux_next_a_reopened_browser_tab_gets_its_session_history_back() {
    for engine in ["cef", "webkit"] {
        let mux = Mux::new_for_test("closed-browser-history", SurfaceOptions::default());
        let browser = browser_tab(&mux, engine);
        mux.set_frontend_browser_history(browser, Some(HISTORY.into())).unwrap();
        let reopened = close_and_reopen(&mux, browser, engine);
        assert_eq!(
            mux.frontend_browser_history(reopened).unwrap().as_deref(),
            Some(HISTORY),
            "{engine}: the reopened tab must get the closed tab's history"
        );
        mux.shutdown();
    }
}

/// A tab the app stored no history for reopens with none.
#[test]
fn cmux_next_a_reopened_browser_tab_without_history_has_none() {
    let mux = Mux::new_for_test("closed-browser-no-history", SurfaceOptions::default());
    let browser = browser_tab(&mux, "cef");
    let reopened = close_and_reopen(&mux, browser, "none");
    assert_eq!(mux.frontend_browser_history(reopened).unwrap(), None);
    mux.shutdown();
}
