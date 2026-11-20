use super::super::tests::PresentationTestSession;
use super::*;

#[test]
fn cmux_next_frontend_browser_history_is_kept_out_of_the_tree() {
    let session = PresentationTestSession::new("frontend-browser-history");
    let mux = session.open();
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let record = FrontendBrowserRecord {
        engine: "cef".into(),
        url: "https://example.com/".into(),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    let browser = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id;
    assert_eq!(mux.frontend_browser_history(browser).unwrap(), None);
    let history = r#"{"entries":["https://example.com/"],"index":0,"scroll_y":120}"#;
    mux.set_frontend_browser_history(browser, Some(history.into())).unwrap();
    assert_eq!(mux.frontend_browser_history(browser).unwrap().as_deref(), Some(history));
    // The history never reaches the tree.
    let decorations = mux.tree_decorations();
    let tree = mux.with_state(|state| crate::server::workspaces_json(state, &decorations));
    assert!(!tree.to_string().contains("scroll_y"));

    // A PTY tab or an unknown surface has no frontend browser history.
    let error = mux.set_frontend_browser_history(terminal, Some("{}".into())).unwrap_err();
    assert!(error.to_string().contains("not a frontend-rendered browser"));
    assert!(mux.frontend_browser_history(terminal).is_err());
    let error = mux.frontend_browser_history(999_999).unwrap_err();
    assert!(error.to_string().contains("unknown surface"));
    assert!(mux.set_frontend_browser_history(browser, Some("[]".into())).is_err());
    let tab_id = mux.with_state(|state| state.resource_indexes.tab_ids[&browser].clone());
    drop(mux);

    // It survives a daemon restart, and `None` clears it.
    let mux = session.open();
    let restored = mux
        .with_state(|state| state.resource_indexes.tabs.get(&tab_id).copied())
        .expect("frontend browser tab restored");
    assert_eq!(mux.frontend_browser_history(restored).unwrap().as_deref(), Some(history));
    mux.set_frontend_browser_history(restored, None).unwrap();
    assert_eq!(mux.frontend_browser_history(restored).unwrap(), None);
}
