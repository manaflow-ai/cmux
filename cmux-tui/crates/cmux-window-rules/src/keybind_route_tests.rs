use super::*;
use serde_json::json;

fn id(action: Action) -> Option<String> {
    route(&action).map(|route| route.id)
}

fn parse(value: Value) -> Action {
    serde_json::from_value(value).expect("action")
}

/// UpdateCheckFeedbackTests: check_for_updates runs the palette's update check.
#[test]
fn check_for_updates_runs_the_palette_check() {
    assert_eq!(id(Action::CheckForUpdates).as_deref(), Some("palette.checkForUpdates"));
}

#[test]
fn splits_resize_and_focus_map_each_side() {
    use SplitDirection::*;
    for (direction, split, resize) in [
        (Right, "splitRight", "resizePaneRight"),
        (Down, "splitDown", "resizePaneDown"),
        (Left, "splitLeft", "resizePaneLeft"),
        (Up, "splitUp", "resizePaneUp"),
    ] {
        assert_eq!(id(Action::NewSplit { direction }).as_deref(), Some(split));
        // The amount is Ghostty's own and is dropped.
        assert_eq!(id(Action::ResizeSplit { direction, amount: 40 }).as_deref(), Some(resize));
    }
    use SplitNavigation as N;
    for (target, expected) in [
        (N::Left, "focusLeft"),
        (N::Right, "focusRight"),
        (N::Up, "focusUp"),
        (N::Down, "focusDown"),
        (N::Previous, "focusPreviousPane"),
        (N::Next, "focusNextPane"),
    ] {
        assert_eq!(id(Action::GotoSplit { target }).as_deref(), Some(expected));
    }
}

#[test]
fn close_tab_modes() {
    assert_eq!(id(Action::CloseTab { mode: CloseTabMode::This }).as_deref(), Some("closeTab"));
    assert_eq!(
        id(Action::CloseTab { mode: CloseTabMode::Others }).as_deref(),
        Some("closeOtherTabsInPane")
    );
    assert_eq!(
        id(Action::CloseTab { mode: CloseTabMode::Right }).as_deref(),
        Some("closeTabsToRight")
    );
}

#[test]
fn goto_tab_last_is_nine_and_index_floors_at_one() {
    assert_eq!(id(Action::GotoTab { target: TabTarget::Previous }).as_deref(), Some("prevSurface"));
    assert_eq!(id(Action::GotoTab { target: TabTarget::Next }).as_deref(), Some("nextSurface"));
    let last = route(&Action::GotoTab { target: TabTarget::Last }).unwrap();
    assert_eq!(last.id, "selectSurfaceByNumber");
    assert_eq!(last.arguments.get("index"), Some(&json!(9)));
    assert!(last.targets_terminal);
    for (number, expected) in [(3, 3), (1, 1), (0, 1), (-4, 1)] {
        let route = route(&Action::GotoTab { target: TabTarget::Index { number } }).unwrap();
        assert_eq!(route.arguments.get("index"), Some(&json!(expected)));
    }
}

#[test]
fn move_tab_zero_has_no_route_and_sign_picks_the_side() {
    assert_eq!(id(Action::MoveTab { amount: 0 }), None);
    assert_eq!(id(Action::MoveTab { amount: -2 }).as_deref(), Some("moveSurfaceLeft"));
    assert_eq!(id(Action::MoveTab { amount: 1 }).as_deref(), Some("moveSurfaceRight"));
}

#[test]
fn window_titles_target_the_workspace() {
    let prompt = route(&Action::PromptWindowTitle).unwrap();
    assert_eq!(prompt.id, "renameWorkspace");
    assert!(!prompt.targets_terminal);
    assert!(prompt.arguments.is_empty());
    let set = route(&Action::SetWindowTitle { title: "Build".into() }).unwrap();
    assert_eq!(set.id, "renameWorkspace");
    assert!(!set.targets_terminal);
    assert_eq!(set.arguments.get("name"), Some(&json!("Build")));
}

#[test]
fn plain_actions_map_one_to_one_on_the_terminal() {
    for (action, expected) in [
        (Action::EqualizeSplits, "equalizeSplits"),
        (Action::ToggleSplitZoom, "toggleSplitZoom"),
        (Action::NewTab, "newSurface"),
        (Action::NewWindow, "newWindow"),
        (Action::CloseWindow, "closeWindow"),
        (Action::CloseAllWindows, "closeAllWindows"),
        (Action::ToggleFullscreen, "toggleFullScreen"),
        (Action::ToggleMaximize, "zoomWindow"),
        (Action::ToggleCommandPalette, "commandPalette"),
        (Action::PromptTitle, "renameTab"),
        (Action::Find, "find"),
        (Action::Quit, "quit"),
        (Action::Undo, "history.reopen"),
        (Action::ToggleVisibility, "showHideAllWindows"),
        (Action::ToggleTabOverview, "tab.search"),
        (Action::PresentTerminal, "tab.focus"),
        (Action::GotoWindow { next: true }, "selectNextWindow"),
        (Action::GotoWindow { next: false }, "selectPreviousWindow"),
        (Action::MoveTabToNewWindow, "tab.moveToNewWindow"),
    ] {
        let route = route(&action).unwrap();
        assert_eq!(route.id, expected, "{action:?}");
        assert!(route.targets_terminal, "{action:?}");
        assert!(route.arguments.is_empty(), "{action:?}");
    }
}

#[test]
fn inspector_and_redo_have_no_route() {
    assert_eq!(route(&Action::ToggleInspector), None);
    assert_eq!(route(&Action::Redo), None);
}

#[test]
fn wire_shape() {
    assert_eq!(
        parse(json!({ "action": "newSplit", "direction": "down" })),
        Action::NewSplit { direction: SplitDirection::Down }
    );
    assert_eq!(
        parse(json!({ "action": "gotoTab", "target": { "kind": "index", "number": 4 } })),
        Action::GotoTab { target: TabTarget::Index { number: 4 } }
    );
    assert_eq!(
        parse(json!({ "action": "resizeSplit", "direction": "up" })),
        Action::ResizeSplit { direction: SplitDirection::Up, amount: 0 }
    );
    let wire =
        serde_json::to_value(route(&parse(json!({ "action": "setWindowTitle", "title": "x" }))))
            .unwrap();
    assert_eq!(
        wire,
        json!({ "id": "renameWorkspace", "arguments": { "name": "x" }, "targetsTerminal": false })
    );
}
