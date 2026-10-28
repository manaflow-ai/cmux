//! Reopen restores layouts (Leo 2026-10-19: "reopening tabs/workspaces
//! doesn't restore their layouts"). Close then reopen gives back the same
//! split tree (directions, shares, nesting), each pane's tabs in order with
//! its selected tab and pins, the focused and zoomed pane, the shown
//! screen, and a workspace's color, icon and title.

use serde_json::{Value, json};

use super::tests::{mutate, read, tab_id};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;
use crate::{Node, SplitDir};

/// A named terminal tab in `pane`.
fn named_tab(mux: &Arc<Mux>, pane: PaneId, name: &str) -> SurfaceId {
    let surface = mux.new_tab(Some(pane), None, None).unwrap().id;
    assert!(mux.rename_surface(surface, name.to_string()));
    surface
}

fn pane_of(mux: &Mux, surface: SurfaceId) -> PaneId {
    mux.with_state(|state| state.pane_of(surface).unwrap())
}

/// A split of `pane` holding one new tab named `name`.
fn split_named(mux: &Arc<Mux>, pane: PaneId, dir: SplitDir, name: &str) -> PaneId {
    let surface = mux.split(pane, dir, None).unwrap().id;
    assert!(mux.rename_surface(surface, name.to_string()));
    pane_of(mux, surface)
}

/// The layout of every screen of the workspace named `name`, by tab names:
/// splits with direction and share, each pane's tabs (with pins), selected
/// tab, focus and zoom; and the shown screen.
fn layout_of(mux: &Arc<Mux>, name: &str) -> Value {
    let (screens, active) = mux.with_state(|state| {
        let workspace = state
            .workspaces
            .iter()
            .find(|workspace| workspace.name == name)
            .unwrap_or_else(|| panic!("no workspace named {name}"));
        let screens = workspace
            .screens
            .iter()
            .map(|screen| {
                let panes = |pane: PaneId| {
                    let tabs = state.panes[&pane]
                        .tabs
                        .iter()
                        .map(|tab| state.resource_indexes.tab_ids[tab].to_string())
                        .collect::<Vec<_>>();
                    (tabs, state.panes[&pane].active_tab)
                };
                (describe_with(&screen.root, &panes), screen.active_pane, screen.zoomed_pane)
            })
            .collect::<Vec<_>>();
        (screens, workspace.active_screen)
    });
    let tab = |id: &str| read(mux, "tab.get", json!({"tab": id}));
    let screens = screens
        .into_iter()
        .map(|(tree, focused, zoomed)| name_tree(&tree, focused, zoomed, &tab))
        .collect::<Vec<_>>();
    json!({"screens": screens, "shown": active})
}

/// The split tree with each leaf's pane, tab ids and selected index.
enum Tree {
    Leaf(PaneId, Vec<String>, usize),
    Split(String, i64, Box<Tree>, Box<Tree>),
}

fn describe_with(node: &Node, panes: &impl Fn(PaneId) -> (Vec<String>, usize)) -> Tree {
    match node {
        Node::Leaf(pane) => {
            let (tabs, active) = panes(*pane);
            Tree::Leaf(*pane, tabs, active)
        }
        Node::Split { dir, ratio, a, b, .. } => Tree::Split(
            format!("{dir:?}"),
            (ratio * 100.0).round() as i64,
            Box::new(describe_with(a, panes)),
            Box::new(describe_with(b, panes)),
        ),
        Node::Stack { expanded, .. } => {
            let (tabs, active) = panes(*expanded);
            Tree::Leaf(*expanded, tabs, active)
        }
    }
}

fn name_tree(
    tree: &Tree,
    focused: PaneId,
    zoomed: Option<PaneId>,
    tab: &impl Fn(&str) -> Value,
) -> Value {
    match tree {
        Tree::Leaf(pane, tabs, active) => {
            let tabs = tabs
                .iter()
                .map(|id| {
                    let tab = tab(id);
                    let pin = if tab["extra"]["pinned"] == true { "pin:" } else { "" };
                    format!("{pin}{}", tab["name"].as_str().unwrap_or("?"))
                })
                .collect::<Vec<_>>();
            json!({
                "tabs": tabs,
                "active": active,
                "focused": *pane == focused,
                "zoomed": Some(*pane) == zoomed,
            })
        }
        Tree::Split(dir, ratio, a, b) => json!({
            "dir": dir,
            "ratio": ratio,
            "a": name_tree(a, focused, zoomed, tab),
            "b": name_tree(b, focused, zoomed, tab),
        }),
    }
}

/// A workspace `name` whose screen is
/// `[a1 a2* a3] | ([b1 b2] / [c1*])` at uneven shares, with `a3` pinned and
/// the `c` pane focused. Answers the workspace and its first tab.
fn nested_workspace(mux: &Arc<Mux>, name: &str) -> (WorkspaceId, SurfaceId) {
    let first = mux.new_workspace(Some(name.to_string()), None).unwrap().id;
    assert!(mux.rename_surface(first, "a1".into()));
    let a = pane_of(mux, first);
    named_tab(mux, a, "a2");
    let a3 = named_tab(mux, a, "a3");
    let b = split_named(mux, a, SplitDir::Right, "b1");
    named_tab(mux, b, "b2");
    let c = split_named(mux, b, SplitDir::Down, "c1");
    assert!(mux.set_ratio(a, SplitDir::Right, 0.3));
    assert!(mux.set_ratio(c, SplitDir::Down, 0.7));
    mutate(mux, "tab.pin", json!({"tab": tab_id(mux, a3)}), &format!("pin-{name}"));
    mux.select_tab(Some(a), Some(1), None);
    mux.select_tab(Some(b), Some(0), None);
    assert!(mux.focus_pane(c));
    let workspace = mux.with_state(|state| {
        let (index, _) = state.screen_of(a).unwrap();
        state.workspaces[index].id
    });
    (workspace, first)
}

fn workspace_public_id(mux: &Mux, workspace: WorkspaceId) -> String {
    mux.with_state(|state| {
        let index = state.workspace_index(workspace).unwrap();
        state.workspaces[index].public_id.to_string()
    })
}

#[test]
fn a_reopened_workspace_has_its_nested_splits_tabs_pins_selection_and_focus() {
    let mux = Mux::new_for_test("closed-layout-workspace", SurfaceOptions::default());
    mux.new_workspace(Some("keeper".into()), None).unwrap();
    let (workspace, _) = nested_workspace(&mux, "nested");
    let before = layout_of(&mux, "nested");
    // The fixture is the layout it means to be.
    let screen = &before["screens"][0];
    assert_eq!(screen["dir"], "Right", "{before}");
    assert_eq!(screen["ratio"], 30, "{before}");
    assert_eq!(screen["a"]["tabs"], json!(["pin:a3", "a1", "a2"]), "{before}");
    assert_eq!(screen["b"]["dir"], "Down", "{before}");
    assert_eq!(screen["b"]["b"]["focused"], true, "{before}");

    let id = workspace_public_id(&mux, workspace);
    mutate(&mux, "workspace.close", json!({"workspace": id}), "close");
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(layout_of(&mux, "nested"), before);
}

#[test]
fn a_reopened_workspace_shows_its_shown_screen_zoom_and_presentation() {
    let mux = Mux::new_for_test("closed-layout-screens", SurfaceOptions::default());
    mux.new_workspace(Some("keeper".into()), None).unwrap();
    let (workspace, _) = nested_workspace(&mux, "two");
    // A second screen with a zoomed split, shown when the workspace closes:
    // the first screen's focus stays as it was.
    let second = mux.new_screen(Some(workspace), None).unwrap().id;
    assert!(mux.rename_surface(second, "s1".into()));
    let s = pane_of(&mux, second);
    let t = split_named(&mux, s, SplitDir::Right, "t1");
    assert!(mux.focus_pane(s));
    mux.zoom_pane(Some(t), ZoomMode::On).unwrap();
    let id = workspace_public_id(&mux, workspace);
    let params =
        json!({"workspace": id, "title": "Two", "color": "#336699", "icon": "server.rack"});
    mutate(&mux, "workspace.update", params, "present");
    let before = layout_of(&mux, "two");
    assert_eq!(before["shown"], 1, "{before}");
    assert_eq!(before["screens"][1]["b"]["zoomed"], true, "{before}");

    mutate(&mux, "workspace.close", json!({"workspace": id}), "close");
    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(layout_of(&mux, "two"), before);
    let workspace = super::tests::snapshot(&mux)["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"] == reopened["workspace_id"])
        .cloned()
        .unwrap_or_else(|| panic!("the reopened workspace is listed: {reopened}"));
    assert_eq!(workspace["extra"]["title"], "Two", "{workspace}");
    assert_eq!(workspace["extra"]["color"], "#336699", "{workspace}");
    assert_eq!(workspace["extra"]["icon"], "server.rack", "{workspace}");
}

#[test]
fn a_reopened_screen_comes_back_in_its_splits_and_its_place() {
    let mux = Mux::new_for_test("closed-layout-screen", SurfaceOptions::default());
    let (workspace, _) = nested_workspace(&mux, "screens");
    let closing = mux.new_screen(Some(workspace), None).unwrap().id;
    assert!(mux.rename_surface(closing, "x1".into()));
    let x = pane_of(&mux, closing);
    let y = split_named(&mux, x, SplitDir::Down, "y1");
    named_tab(&mux, y, "y2");
    assert!(mux.set_ratio(y, SplitDir::Down, 0.25));
    mux.select_tab(Some(y), Some(0), None);
    // A third screen after it, so its place is in the middle.
    mux.new_screen(Some(workspace), None).unwrap();
    assert!(mux.focus_pane(y));
    let before = layout_of(&mux, "screens");
    let slot = mux.with_state(|state| {
        let (workspace, screen) = state.screen_of(x).unwrap();
        state.workspaces[workspace].screens[screen].id
    });
    assert!(mux.close_screen(slot).unwrap());
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    let after = layout_of(&mux, "screens");
    assert_eq!(after["screens"], before["screens"]);
    assert_eq!(after["shown"], 1, "the reopened screen is shown: {after}");
}

/// A closed tab whose pane is gone in between comes back in a pane split
/// off its neighbor as before, at the same share (cx-gzh.32).
#[test]
fn a_reopened_tab_whose_pane_closed_splits_its_neighbor_again() {
    let mux = Mux::new_for_test("closed-layout-tab", SurfaceOptions::default());
    mux.new_workspace(Some("keeper".into()), None).unwrap();
    nested_workspace(&mux, "tab");
    let before = layout_of(&mux, "tab");
    let c1 = mux.with_state(|state| {
        let workspace = state.workspaces.iter().find(|workspace| workspace.name == "tab").unwrap();
        let screen = &workspace.screens[0];
        screen.active_pane
    });
    let surface = mux.with_state(|state| state.panes[&c1].tabs[0]);
    assert!(mux.close_surface(surface).unwrap());
    assert_ne!(layout_of(&mux, "tab"), before, "the pane closed with its tab");
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(layout_of(&mux, "tab"), before);
}

/// `name`'s first pane holding one tab `l1`, split right into `r1`, which
/// is split down into `d1`: `l | (r / d)`, with `l` at 0.3 of the width.
fn left_of_a_stack(mux: &Arc<Mux>, name: &str) -> (SurfaceId, PaneId, PaneId, PaneId) {
    mux.new_workspace(Some("keeper".into()), None).unwrap();
    let first = mux.new_workspace(Some(name.to_string()), None).unwrap().id;
    assert!(mux.rename_surface(first, "l1".into()));
    let l = pane_of(mux, first);
    let r = split_named(mux, l, SplitDir::Right, "r1");
    let d = split_named(mux, r, SplitDir::Down, "d1");
    assert!(mux.set_ratio(l, SplitDir::Right, 0.3));
    (first, l, r, d)
}

/// A closed pane whose sibling was a split (`l` beside `r / d`) reopens
/// beside the whole split, full height at its share of the width, not
/// split off the one pane of it that it touched (`(l | r) / d`).
#[test]
fn a_reopened_pane_beside_a_split_splits_off_all_of_it_again() {
    let mux = Mux::new_for_test("closed-layout-beside-split", SurfaceOptions::default());
    let (l1, l, _, _) = left_of_a_stack(&mux, "beside");
    assert!(mux.focus_pane(l));
    let before = layout_of(&mux, "beside");
    assert!(mux.close_surface(l1).unwrap());
    assert_ne!(layout_of(&mux, "beside"), before, "the pane closed with its tab");
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(layout_of(&mux, "beside"), before);
}

/// Close a pane, then the neighbor it was split off: two reopens put the
/// neighbor back and then the first pane split off it again, not as a tab
/// of whichever pane has the focus.
#[test]
fn two_closed_panes_reopen_in_their_splits_one_after_the_other() {
    let mux = Mux::new_for_test("closed-layout-two-panes", SurfaceOptions::default());
    let (_, _, r, d) = left_of_a_stack(&mux, "two");
    let (r1, d1) = mux.with_state(|state| (state.panes[&r].tabs[0], state.panes[&d].tabs[0]));
    assert!(mux.focus_pane(d));
    let before = layout_of(&mux, "two");
    assert!(mux.close_surface(d1).unwrap());
    assert!(mux.close_surface(r1).unwrap());
    mutate(&mux, "closed.reopen", json!({}), "reopen-r");
    mutate(&mux, "closed.reopen", json!({}), "reopen-d");
    assert_eq!(layout_of(&mux, "two"), before);
}

/// A record made before layouts were kept (no `layout`) still reopens, in
/// one pane, in order.
#[test]
fn a_screen_record_without_a_layout_reopens_in_one_pane() {
    let shape = super::closed_screen_layout::Shape::of(&json!({
        "name": null,
        "tabs": [{"kind": "terminal"}, {"kind": "terminal"}],
    }));
    assert!(shape.is_none());
}

/// A pane none of whose tabs is kept drops out with its split; its
/// sibling takes the space.
#[test]
fn a_pane_with_no_kept_tab_drops_out_of_the_reopened_tree() {
    use super::closed_screen_layout::Shape;
    let screen = json!({
        "tabs": [{"kind": "terminal"}, {"kind": "terminal"}],
        "layout": {"kind": "split", "direction": "right", "ratio": 0.4,
            "first": {"kind": "leaf", "pane": "p1"},
            "second": {"kind": "split", "direction": "down", "ratio": 0.5,
                "first": {"kind": "leaf", "pane": "p2"},
                "second": {"kind": "leaf", "pane": "p3"}}},
        "panes": {"p1": {"tabs": [0], "active": 0}, "p3": {"tabs": [1], "active": 0}},
    });
    let Some(Shape::Split { edge, share, first, second }) = Shape::of(&screen) else {
        panic!("a split of two panes");
    };
    assert_eq!(edge, TabDropEdge::Right);
    assert!((share - 0.6).abs() < 1e-6, "{share}");
    assert!(matches!(*first, Shape::Leaf { ref tabs, .. } if tabs == &[0]));
    assert!(matches!(*second, Shape::Leaf { ref tabs, .. } if tabs == &[1]));
}

/// A browser tab named `name` in `pane`.
fn named_browser(mux: &Arc<Mux>, pane: PaneId, name: &str) -> SurfaceId {
    let record = crate::workspace_registry::FrontendBrowserRecord {
        engine: "cef".into(),
        url: format!("https://example.com/{name}"),
        title: None,
        favicon_url: None,
        profile_id: None,
        owner: None,
    };
    let surface = mux.new_frontend_browser_tab(Some(pane), record, None).unwrap().id;
    assert!(mux.rename_surface(surface, name.to_string()));
    surface
}

/// The terminal a reopened screen starts with stands for the first
/// terminal record. When the first pane holds only browser tabs, that
/// terminal belongs on the other side of a split: it moves there, and the
/// first pane is filled before it leaves. Pins of tabs other than that
/// terminal come back too.
#[test]
fn a_reopened_workspace_whose_first_pane_has_no_terminal_keeps_its_splits() {
    let mux = Mux::new_for_test("closed-layout-browser-first", SurfaceOptions::default());
    mux.new_workspace(Some("keeper".into()), None).unwrap();
    let terminal = mux.new_workspace(Some("web".into()), None).unwrap().id;
    assert!(mux.rename_surface(terminal, "t1".into()));
    let a = pane_of(&mux, terminal);
    let w1 = named_browser(&mux, a, "w1");
    named_browser(&mux, a, "w2");
    mux.move_tab_to_split(terminal, a, TabDropEdge::Right, Some(0.35), None).unwrap();
    let t = pane_of(&mux, terminal);
    named_tab(&mux, t, "t2");
    mutate(&mux, "tab.pin", json!({"tab": tab_id(&mux, w1)}), "pin-w1");
    mux.select_tab(Some(a), Some(1), None);
    mux.select_tab(Some(t), Some(0), None);
    assert!(mux.focus_pane(a));
    let before = layout_of(&mux, "web");
    let screen = &before["screens"][0];
    assert_eq!(screen["dir"], "Right", "{before}");
    assert_eq!(screen["a"]["tabs"], json!(["pin:w1", "w2"]), "{before}");
    assert_eq!(screen["b"]["tabs"], json!(["t1", "t2"]), "{before}");

    let workspace = mux.with_state(|state| {
        let (index, _) = state.screen_of(a).unwrap();
        state.workspaces[index].id
    });
    let id = workspace_public_id(&mux, workspace);
    mutate(&mux, "workspace.close", json!({"workspace": id}), "close");
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    assert_eq!(layout_of(&mux, "web"), before);
}

/// The splits a reopen rebuilds are not the user's moves: layout undo right
/// after it has nothing to fold back.
#[test]
fn layout_undo_after_a_reopen_leaves_the_reopened_splits() {
    let mux = Mux::new_for_test("closed-layout-undo", SurfaceOptions::default());
    mux.new_workspace(Some("keeper".into()), None).unwrap();
    let (workspace, _) = nested_workspace(&mux, "undo");
    let before = layout_of(&mux, "undo");
    let id = workspace_public_id(&mux, workspace);
    mutate(&mux, "workspace.close", json!({"workspace": id}), "close");
    mutate(&mux, "closed.reopen", json!({}), "reopen");
    let focused = mux.with_state(|state| {
        let workspace = state.workspaces.iter().find(|workspace| workspace.name == "undo").unwrap();
        workspace.screens[0].active_pane
    });
    // Unconfirmed, so a rebuilt split left on the stack would answer with a
    // confirmation preview instead of this error.
    let error = mux.undo_layout(focused, None, false).unwrap_err();
    assert_eq!(error.downcast_ref::<LayoutUndoError>(), Some(&LayoutUndoError::Unavailable));
    assert_eq!(layout_of(&mux, "undo"), before);
}
