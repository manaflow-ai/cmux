//! `browser-open-caller-v1`: an agent's browser open lands in the rightmost
//! pane of its own workspace, and no browser open makes a workspace; with
//! no caller and no focused workspace it lands in the home workspace.
//! Driven through `cmux.protocol/2` requests (`tab.create_browser`,
//! `browser.profile.open`, `workspace.open_url`) and through
//! `new_browser_tab_with_fields_as`.

use std::collections::HashSet;
use std::path::PathBuf;

use serde_json::{Map, Value, json};

use super::*;
use crate::resource_router::handle_resource_message;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspaceRegistry;

/// A session with an on-disk registry, so `workspace.ensure_home` works.
struct Session {
    root: PathBuf,
    name: &'static str,
}

impl Session {
    fn new(name: &'static str) -> Self {
        let root = std::env::temp_dir()
            .join(format!("cmux-browser-caller-{name}-{}", WorkspacePublicId::random().unwrap()));
        Self { root, name }
    }

    fn open(&self) -> Arc<Mux> {
        let registry = WorkspaceRegistry::open(&self.root, self.name).unwrap();
        Mux::from_workspace_registry(
            self.name.into(),
            SurfaceOptions::default(),
            registry,
            ProviderWorkspaceState::default(),
            true,
        )
        .unwrap()
    }
}

impl Drop for Session {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn send(mux: &Arc<Mux>, operation: &str, mut params: Value, key: &str) -> Value {
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let envelope = json!({
        "protocol": "cmux.protocol/2",
        "type": "request",
        "id": format!("{operation}-test"),
        "operation": operation,
        "params": params,
        "idempotency_key": key,
    });
    let response = handle_resource_message(mux, &serde_json::to_string(&envelope).unwrap())
        .unwrap_or_else(|error| panic!("{operation} failed: {error:?}"));
    assert_eq!(response["ok"], true, "{operation}: {response}");
    response["result"]["value"].clone()
}

/// The caller's workspace: one pane on the left and one split off to its
/// right. Returns the workspace, its key in the app's uppercase UUID form
/// (as `CMUX_WORKSPACE_ID` carries it), and the right pane.
fn caller_workspace(mux: &Arc<Mux>) -> (WorkspaceId, String, PaneId) {
    let left = mux.new_workspace(Some("agent".into()), None).unwrap().id;
    let left_pane = mux.with_state(|state| state.pane_of(left)).unwrap();
    let right = mux.split(left_pane, SplitDir::Right, None).unwrap().id;
    mux.with_state(|state| {
        let right_pane = state.pane_of(right).unwrap();
        let (index, _) = state.screen_of(right_pane).unwrap();
        let workspace = &state.workspaces[index];
        (workspace.id, workspace.key.to_uppercase(), right_pane)
    })
}

/// No workspace has the focus (the person looks at none).
fn unfocus(mux: &Arc<Mux>) {
    mux.state.lock().unwrap().active_workspace = usize::MAX;
}

fn workspace_count(mux: &Arc<Mux>) -> usize {
    mux.with_state(|state| state.workspaces.len())
}

fn surfaces(mux: &Arc<Mux>) -> HashSet<SurfaceId> {
    mux.with_state(|state| state.surfaces.keys().copied().collect())
}

/// The pane and workspace of the one surface not in `before`.
fn opened(mux: &Arc<Mux>, before: &HashSet<SurfaceId>) -> (PaneId, WorkspaceId) {
    let new = surfaces(mux).into_iter().filter(|surface| !before.contains(surface));
    let new = new.collect::<Vec<_>>();
    assert_eq!(new.len(), 1, "one new tab: {new:?}");
    mux.with_state(|state| {
        let pane = state.pane_of(new[0]).unwrap();
        let (index, _) = state.screen_of(pane).unwrap();
        (pane, state.workspaces[index].id)
    })
}

fn home(mux: &Arc<Mux>) -> WorkspaceId {
    send(mux, "workspace.ensure_home", json!({}), "home");
    mux.with_state(|state| mux.home_workspace_in_state(state)).expect("a live home")
}

fn kill_surfaces(mux: &Arc<Mux>) {
    for surface in mux.with_state(|state| state.surfaces.values().cloned().collect::<Vec<_>>()) {
        surface.kill();
    }
}

#[test]
fn tab_create_browser_from_an_agent_lands_in_its_rightmost_pane() {
    let session = Session::new("create-caller");
    let mux = session.open();
    mux.attach_test_browser_provider(1);
    let (workspace, key, right) = caller_workspace(&mux);
    // The person looks at another workspace, then at none.
    mux.new_workspace(Some("elsewhere".into()), None).unwrap();
    for (attempt, focused) in [(1, true), (2, false)] {
        if !focused {
            unfocus(&mux);
        }
        let (before, count) = (surfaces(&mux), workspace_count(&mux));
        let params = json!({"url": "https://example.com", "caller": {"workspace": key}});
        let created = send(&mux, "tab.create_browser", params, &format!("create-{attempt}"));
        assert!(created["browser_id"].is_string(), "{created}");
        assert_eq!(opened(&mux, &before), (right, workspace), "focused elsewhere: {focused}");
        assert_eq!(workspace_count(&mux), count, "no workspace was made");
    }
    kill_surfaces(&mux);
}

#[test]
fn tab_create_browser_with_no_caller_and_no_focus_lands_in_home() {
    let session = Session::new("create-home");
    let mux = session.open();
    mux.attach_test_browser_provider(1);
    let home = home(&mux);
    caller_workspace(&mux);
    unfocus(&mux);
    let (before, count) = (surfaces(&mux), workspace_count(&mux));
    send(&mux, "tab.create_browser", json!({"url": "https://example.com"}), "create");
    assert_eq!(opened(&mux, &before).1, home);
    assert_eq!(workspace_count(&mux), count, "no workspace was made");
    kill_surfaces(&mux);
}

#[test]
fn browser_profile_open_from_an_agent_lands_in_its_rightmost_pane() {
    let session = Session::new("profile-caller");
    let mux = session.open();
    let (workspace, key, right) = caller_workspace(&mux);
    mux.new_workspace(Some("elsewhere".into()), None).unwrap();
    for (attempt, focused) in [(1, true), (2, false)] {
        if !focused {
            unfocus(&mux);
        }
        let (before, count) = (surfaces(&mux), workspace_count(&mux));
        let params = json!({
            "profile": "default",
            "url": "https://example.com",
            "caller": {"workspace": key},
        });
        let opened_tab = send(&mux, "browser.profile.open", params, &format!("open-{attempt}"));
        let pane = mux.with_state(|state| state.resource_indexes.pane_ids[&right].to_string());
        assert_eq!(opened_tab["pane_id"], pane, "focused elsewhere: {focused}");
        assert_eq!(opened(&mux, &before), (right, workspace));
        assert_eq!(workspace_count(&mux), count, "no workspace was made");
    }
    kill_surfaces(&mux);
}

#[test]
fn browser_profile_open_with_no_caller_and_no_focus_lands_in_home() {
    let session = Session::new("profile-home");
    let mux = session.open();
    let home = home(&mux);
    caller_workspace(&mux);
    unfocus(&mux);
    let (before, count) = (surfaces(&mux), workspace_count(&mux));
    let params = json!({"profile": "default", "url": "https://example.com"});
    send(&mux, "browser.profile.open", params, "open");
    assert_eq!(opened(&mux, &before).1, home);
    assert_eq!(workspace_count(&mux), count, "no workspace was made");
    kill_surfaces(&mux);
}

#[test]
fn new_browser_tab_with_a_caller_lands_in_its_rightmost_pane_and_else_in_home() {
    let session = Session::new("fields");
    let mux = session.open();
    mux.attach_test_browser_provider(1);
    let home = home(&mux);
    let (workspace, key, right) = caller_workspace(&mux);
    let url = || "https://example.com".to_string();

    // An agent caller, by its workspace's `ws_…` id this time.
    let public = mux.with_state(|state| state.resource_indexes.workspace_ids[&workspace].clone());
    for caller in [json!({"workspace": key}), json!({"workspace": public.to_string()})] {
        unfocus(&mux);
        let (before, count) = (surfaces(&mux), workspace_count(&mux));
        let fields = Map::from_iter([("caller".to_string(), caller.clone())]);
        mux.new_browser_tab_with_fields(url(), None, None, fields).unwrap();
        assert_eq!(opened(&mux, &before), (right, workspace), "{caller}");
        assert_eq!(workspace_count(&mux), count, "no workspace was made");
    }

    // No caller and no focus: home, not a new workspace.
    unfocus(&mux);
    let (before, count) = (surfaces(&mux), workspace_count(&mux));
    mux.new_browser_tab_with_fields(url(), None, None, Map::new()).unwrap();
    assert_eq!(opened(&mux, &before).1, home);
    assert_eq!(workspace_count(&mux), count, "no workspace was made");
    kill_surfaces(&mux);
}

#[test]
fn rightmost_pane_skips_to_the_left_of_a_split_and_prefers_the_row_focused_last() {
    let mux = Mux::new_for_test("rightmost", SurfaceOptions::default());
    let (workspace, _, right) = caller_workspace(&mux);
    assert_eq!(mux.with_state(|state| rightmost_pane(state, workspace)), Some(right));
    // Split the right column into two rows; the row focused last wins.
    let below = mux.split(right, SplitDir::Down, None).unwrap().id;
    let below = mux.with_state(|state| state.pane_of(below)).unwrap();
    let focused = mux.with_state(|state| {
        let at = |pane: PaneId| state.panes[&pane].focused_at;
        if at(below) > at(right) { below } else { right }
    });
    assert_eq!(mux.with_state(|state| rightmost_pane(state, workspace)), Some(focused));
    kill_surfaces(&mux);
}
