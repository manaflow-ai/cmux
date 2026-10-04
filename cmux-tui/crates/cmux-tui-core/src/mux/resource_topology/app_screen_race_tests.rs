//! A screen kind commit that races a topology effect waits on the effect's
//! creation fences: it cannot land between the effect's app-rule check and
//! its commit, so the effect never changes memory that its commit check
//! then refuses. The waiting kind commit is checked on the committed rows
//! and refused, because the effect changed the screen's shape.

use std::sync::Mutex as StdMutex;
use std::thread::JoinHandle;

use super::*;
use crate::state::app_screens::AppTabTarget;
use crate::state::app_screens_store::{AppScreenKind, AppTabRecord, ScreenApp};
use crate::state::home_store::EmptyWorkspaceMark;

const APP: &str = "cmux/race";

#[test]
fn a_kind_commit_waits_for_the_effect_between_its_check_and_its_commit() {
    let mux = Mux::new_for_test("app-screen-race", SurfaceOptions::default());
    let _ = mux.new_workspace(None, Some((80, 22))).unwrap();
    // An app workspace whose screen has its app tab but no kind row yet.
    mux.resource_create_empty_workspace_selected(
        Mux::ordinary_resource_selectors(),
        Some(APP.to_string()),
        "app-race-workspace",
        None,
        &WorkspaceMutation::local("app-race"),
        EmptyWorkspaceMark::App(APP.to_string()),
    )
    .unwrap();
    let workspace = mux.with_state(|state| state.workspaces.last().unwrap().id);
    let record = AppTabRecord { app: APP.to_string(), route: None };
    let tab = mux.new_app_tab(AppTabTarget::Workspace(workspace), record, None, None).unwrap();
    let (pane, screen) = mux.with_state(|state| {
        let pane = state.pane_of(tab.surface.id).unwrap();
        let (w, s) = state.screen_of(pane).unwrap();
        (pane, state.workspaces[w].screens[s].id)
    });

    // While the split effect runs (its app-rule check already passed), a
    // kind commit for the same screen starts on another thread.
    let racer: Arc<StdMutex<Option<JoinHandle<anyhow::Result<()>>>>> = Arc::default();
    let hook_mux = mux.clone();
    let hook_racer = racer.clone();
    *mux.viewport_split_after_spawn.lock().unwrap() = Some(Arc::new(move || {
        let racing = hook_mux.clone();
        let handle = std::thread::spawn(move || {
            let app = ScreenApp { kind: AppScreenKind::App, app: APP.to_string() };
            racing.commit_screen_app(screen, app, None).map(|_| ())
        });
        *hook_racer.lock().unwrap() = Some(handle);
    }));
    mux.new_pane_right(pane, 0.5, Some((38, 22))).expect("the effect commits");
    *mux.viewport_split_after_spawn.lock().unwrap() = None;

    let handle = racer.lock().unwrap().take().expect("the hook ran");
    let raced = handle.join().unwrap();
    let error = raced.expect_err("the kind commit landed on a screen with two columns");
    assert_eq!(
        crate::state::app_screens_store::raw_error_code(&error),
        Some("app-screen-fixed"),
        "{error:#}"
    );
    mux.with_state(|state| {
        assert!(!state.resource_indexes.screen_apps.contains_key(&screen));
        let (w, s) = state.screen_of(pane).unwrap();
        assert_eq!(state.workspaces[w].screens[s].layout_columns.len(), 2);
    });
    mux.shutdown();
}
