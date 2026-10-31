//! Tests: a surface the frontend creates is selected once both its completion
//! and the cached tree that holds it have arrived, in either order
//! (https://github.com/manaflow-ai/cmux/issues/26031).

use super::*;

fn completion(action: SessionCompletionAction) -> SessionCompletion {
    SessionCompletion { mutation_generation: 1, semantic_intent: None, action }
}

fn adopted_app(mux: &Arc<Mux>) -> App {
    let mut app = test_app(Session::Local(mux.clone()));
    app.sidebar_visible = false;
    app.replace_tree(app.session.tree());
    app
}

#[test]
fn split_completed_before_its_tree_is_selected_when_the_tree_lands() {
    let mux = Mux::new("completed-split-before-tree-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut app = adopted_app(&mux);

    let split = mux.split(pane, SplitDir::Right, Some((40, 24))).unwrap();
    app.apply_session_completion(completion(SessionCompletionAction::SurfaceCreated {
        surface: split.id,
    }));
    assert_eq!(app.active_surface(), Some(first.id), "the cached tree has no split yet");
    app.claim_active_terminal_geometry(true);

    app.replace_tree(app.session.tree());

    assert_eq!(app.active_surface(), Some(split.id));
    mux.close_surface(split.id).unwrap();
    mux.close_surface(first.id).unwrap();
}

#[test]
fn screen_completed_before_its_tree_is_selected_when_the_tree_lands() {
    let mux = Mux::new("completed-screen-before-tree-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
    let mut app = adopted_app(&mux);
    let first_screen = app.tree.active_screen().unwrap().id;

    let screen = mux.new_screen(Some(workspace), Some((80, 24))).unwrap();
    app.apply_session_completion(completion(SessionCompletionAction::SurfaceCreated {
        surface: screen.id,
    }));
    assert_eq!(app.tree.active_screen().unwrap().id, first_screen);

    app.replace_tree(app.session.tree());

    assert_eq!(app.active_surface(), Some(screen.id));
    assert_ne!(app.tree.active_screen().unwrap().id, first_screen);
    mux.close_surface(screen.id).unwrap();
    mux.close_surface(first.id).unwrap();
}

#[test]
fn completed_surface_already_in_the_tree_is_selected_at_once() {
    let mux = Mux::new("completed-split-after-tree-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut app = adopted_app(&mux);

    let split = mux.split(pane, SplitDir::Right, Some((40, 24))).unwrap();
    app.replace_tree(app.session.tree());
    assert_eq!(app.active_surface(), Some(first.id));
    app.apply_session_completion(completion(SessionCompletionAction::SurfaceCreated {
        surface: split.id,
    }));

    assert_eq!(app.active_surface(), Some(split.id));
    mux.close_surface(split.id).unwrap();
    mux.close_surface(first.id).unwrap();
}

#[test]
fn deferred_completion_selection_yields_to_a_focus_change() {
    let mux = Mux::new("completed-split-focus-moved-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let second = mux.split(pane, SplitDir::Right, Some((40, 24))).unwrap();
    let mut app = adopted_app(&mux);
    assert_eq!(app.active_surface(), Some(second.id));

    let created = mux.new_tab(Some(pane), None, Some((40, 24))).unwrap();
    app.apply_session_completion(completion(SessionCompletionAction::SurfaceCreated {
        surface: created.id,
    }));
    let [workspace, screen, _, _] = app.tab_locations[&first.id];
    assert!(app.tree.set_active_pane(workspace, screen, pane));
    assert_eq!(app.active_surface(), Some(first.id));

    app.replace_tree(app.session.tree());

    assert_eq!(
        app.active_surface(),
        Some(first.id),
        "a late tree must not pull focus back after the user moved"
    );
    for surface in [created.id, second.id, first.id] {
        mux.close_surface(surface).unwrap();
    }
}

#[test]
fn browser_tab_completed_before_its_tree_focuses_the_omnibar_when_the_tree_lands() {
    let mux = Mux::new("completed-browser-before-tree-test", SurfaceOptions::default());
    let first = mux.new_workspace(None, Some((80, 24))).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let mut app = adopted_app(&mux);

    let browser =
        mux.new_browser_tab("about:blank".to_string(), Some(pane), Some((80, 24))).unwrap();
    app.apply_session_completion(completion(SessionCompletionAction::BrowserTabCreated {
        surface: browser.id,
    }));
    assert!(app.omnibar.is_none());
    app.pane_areas.push(PaneArea { pane, ..browser_completion_area(browser.id) });

    app.replace_tree(app.session.tree());

    assert_eq!(app.active_surface(), Some(browser.id));
    assert_eq!(app.omnibar.as_ref().map(|state| state.surface), Some(browser.id));
    mux.close_surface(browser.id).unwrap();
    mux.close_surface(first.id).unwrap();
}

#[test]
fn deferred_completion_selection_stays_canceled_after_focus_returns() {
    for navigation in ["tab", "pane", "screen", "workspace"] {
        let mux = Mux::new("completed-selection-focus-round-trip", SurfaceOptions::default());
        let first = mux.new_workspace(None, Some((80, 24))).unwrap();
        let workspace = mux.with_state(|state| state.workspaces[state.active_workspace].id);
        let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
        let tab = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
        let split = mux.split(pane, SplitDir::Right, Some((40, 24))).unwrap();
        let other_pane = mux.with_state(|state| state.pane_of(split.id).unwrap());
        let screen = mux.new_screen(Some(workspace), Some((80, 24))).unwrap();
        let other_workspace = mux.new_workspace(None, Some((80, 24))).unwrap();
        let mut app = adopted_app(&mux);
        assert!(app.tree.select_surface(first.id));
        app.claim_active_terminal_geometry(true);

        let created = mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
        app.apply_session_completion(completion(SessionCompletionAction::SurfaceCreated {
            surface: created.id,
        }));
        match navigation {
            "tab" => app.select_tab_for_client(Some(pane), Some(1), None),
            "pane" => app.focus_pane_after_input(other_pane),
            "screen" => app.select_screen_for_client(Some(1), None),
            _ => app.select_workspace_for_client(Some(1), None),
        }
        assert_ne!(app.active_surface(), Some(first.id), "{navigation}: focus moved away");
        match navigation {
            "tab" => app.select_tab_for_client(Some(pane), Some(0), None),
            "pane" => app.focus_pane_after_input(pane),
            "screen" => app.select_screen_for_client(Some(0), None),
            _ => app.select_workspace_for_client(Some(0), None),
        }
        assert_eq!(app.active_surface(), Some(first.id), "{navigation}: focus returned");

        app.replace_tree(app.session.tree());

        assert_eq!(
            app.active_surface(),
            Some(first.id),
            "{navigation}: returning to the original surface must not revive a late selection"
        );
        for surface in [created.id, other_workspace.id, screen.id, split.id, tab.id, first.id] {
            mux.close_surface(surface).unwrap();
        }
    }
}
