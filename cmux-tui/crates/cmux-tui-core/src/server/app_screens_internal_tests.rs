//! `app-screens-v1` checks that reach inside the daemon: the authoritative
//! check in the commit against a racing plan, and creations interrupted
//! between their commits (simulated with internal steps).

use super::*;
use crate::resource_mutation::ResourceMutationPlan;

/// A racing op that skipped every pre-check (here a plan that moves a tab
/// into the app pane) is refused by the check in the commit transaction,
/// and neither the store nor the live state changes.
#[test]
fn commit_check_refuses_a_racing_op_that_skipped_the_pre_checks() {
    let mut wire = Wire::new();
    let (_, _, _, app_pane, moved, source) = store_and_terminals(&mut wire);
    let before = layout_fingerprint(&wire.tree());
    let mux = wire.mux.clone();
    let result = mux.commit_resource_mutation_plan(
        &WorkspaceMutation::local("app-screens-race"),
        "test.race",
        &json!({"race": true}),
        None,
        None,
        |state, registry| {
            let mut projected = state.clone();
            let source_pane = projected.panes.get_mut(&source).unwrap();
            source_pane.tabs.retain(|tab| *tab != moved);
            source_pane.active_tab = 0;
            projected.panes.get_mut(&app_pane).unwrap().tabs.push(moved);
            let projection =
                mux.resource_effect_projection_locked(registry, &mut projected, json!({}))?;
            Ok(ResourceMutationPlan::new(
                projection.patch,
                projection.result,
                projection.changes,
                move |state| *state = projected,
            ))
        },
    );
    let Err(error) = result else { panic!("the racing op committed into the app screen") };
    assert_eq!(
        crate::state::app_screens_store::raw_error_code(&error),
        Some("app-screen-fixed"),
        "{error:#}"
    );
    assert_eq!(layout_fingerprint(&wire.tree()), before, "the refused commit changed something");
    let stored = wire.mux.with_state(|state| state.panes[&app_pane].tabs.len());
    assert_eq!(stored, 1);
    wire.mux.shutdown();
}

/// The app workspace of `app`, created as the first step of
/// `workspace.ensure_app` (as if the daemon stopped right after it).
fn interrupted_app_workspace(wire: &Wire, app: &str, key: &str) -> (String, WorkspaceId) {
    wire.mux
        .resource_create_empty_workspace_selected(
            Mux::ordinary_resource_selectors(),
            Some(app.to_string()),
            key,
            None,
            &WorkspaceMutation::local("app-crash"),
            crate::state::home_store::EmptyWorkspaceMark::App(app.to_string()),
        )
        .unwrap();
    wire.mux.with_state(|state| {
        let workspace = state.workspaces.last().unwrap();
        (workspace.public_id.to_string(), workspace.id)
    })
}

fn app_record(app: &str) -> crate::state::app_screens_store::AppTabRecord {
    crate::state::app_screens_store::AppTabRecord { app: app.to_string(), route: None }
}

/// `workspace.ensure_app` resumes a creation interrupted after any of its
/// commits, and replaces a workspace whose screen changed between them.
#[test]
fn ensure_app_resumes_or_replaces_an_interrupted_creation() {
    use crate::state::app_screens::AppTabTarget;
    let mut wire = Wire::new();
    let _ = wire.terminal_pane();

    // Stopped after the workspace commit.
    let (first, _) = interrupted_app_workspace(&wire, STORE, "crash-1");
    let resumed = wire.ensure_app(STORE, "app", "resume-1");
    assert_eq!(resumed["value"]["workspace_id"], first.as_str(), "{resumed}");
    let raw = wire.screen(resumed["value"]["screen_id"].as_str().unwrap());
    assert_eq!(raw["kind"], "app", "{raw}");

    // Stopped after the app tab commit.
    let (second, slot) = interrupted_app_workspace(&wire, HOME, "crash-2");
    let tab = wire.mux.new_app_tab(AppTabTarget::Workspace(slot), app_record(HOME), None, None);
    let surface = tab.unwrap().surface.id;
    let screen = wire.mux.with_state(|state| {
        let (w, s) = state.screen_of(state.pane_of(surface).unwrap()).unwrap();
        state.workspaces[w].screens[s].public_id.to_string()
    });
    let resumed = wire.ensure_app(HOME, "app", "resume-2");
    assert_eq!(resumed["value"]["workspace_id"], second.as_str(), "{resumed}");
    assert_eq!(resumed["value"]["screen_id"], screen.as_str(), "{resumed}");
    assert_eq!(wire.screen(&screen)["kind"], "app");

    // The screen changed between the commits: a second tab joined the app
    // pane. The old workspace stays ordinary with both tabs; the app gets a
    // new workspace.
    let other = "cmux/other";
    let (third, slot) = interrupted_app_workspace(&wire, other, "crash-3");
    let tab = wire.mux.new_app_tab(AppTabTarget::Workspace(slot), app_record(other), None, None);
    let app_pane = wire.pane_of(tab.unwrap().surface.id);
    wire.ok(json!({"cmd": "new-tab", "pane": app_pane}));
    let replaced = wire.ensure_app(other, "app", "resume-3");
    assert_ne!(replaced["value"]["workspace_id"], third.as_str(), "{replaced}");
    let raw = wire.screen(replaced["value"]["screen_id"].as_str().unwrap());
    assert_eq!(raw["kind"], "app", "{raw}");
    let _ = app_tab(&raw);
    let tree = wire.tree();
    let old = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["resource_id"] == third.as_str())
        .cloned()
        .expect("the old workspace stays");
    assert_eq!(old["kind"], "normal", "{old}");
    assert_eq!(tabs(&old["screens"][0]).len(), 2, "{old}");
    wire.mux.shutdown();
}

/// The Home migration resumes after a stop between its steps: after the
/// screens moved into the companion, and after the app tab commit.
#[test]
fn home_migration_resumes_after_an_interrupted_step() {
    use crate::state::app_screens::AppTabTarget;
    let mut wire = Wire::new();
    let home = wire.v2_ok("workspace.ensure_home", json!({}), Some("connect-1"));
    let home_id = home["value"]["workspace_id"].as_str().unwrap().to_string();
    let home_slot = wire.workspace_slot(&home_id);
    // Stopped after the app tab commit: the home is one screen with only
    // the Home app tab, without its kind row.
    let tab =
        wire.mux.new_app_tab(AppTabTarget::Workspace(home_slot), app_record(HOME), None, None);
    let app = tab.unwrap().surface.id;
    wire.v2_ok("workspace.ensure_home", json!({"app": HOME}), Some("connect-2"));
    let screen = wire.mux.with_state(|state| {
        let (w, s) = state.screen_of(state.pane_of(app).unwrap()).unwrap();
        state.workspaces[w].screens[s].public_id.to_string()
    });
    let raw = wire.screen(&screen);
    assert_eq!(raw["kind"], "app", "{raw}");
    assert_eq!(app_tab(&raw).0, app, "the interrupted app tab is reused");
    assert!(companion_of(&wire, HOME).is_none(), "nothing needed a companion");
    wire.mux.shutdown();
}

/// A raw client's FIRST delta for a companion that a routed new tab
/// creates already shows its kind: `kind: "app_tabs"`, `app`, and
/// `extra.default_title: true` (no `normal` moment for a client or a sync
/// replica to record).
#[test]
fn the_first_delta_of_a_routed_companion_has_its_kind() {
    let mut wire = Wire::new();
    let created = wire.ensure_app(STORE, "app", "open-store");
    let store_slot = wire.workspace_slot(created["value"]["workspace_id"].as_str().unwrap());
    let events = wire.mux.subscribe();
    wire.ok(json!({"cmd": "new-app-tab", "workspace": store_slot, "app": "cmux.agent"}));
    let companion = companion_of(&wire, STORE).expect("the new tab made the companion");
    let companion_slot = wire.workspace_slot(&companion);
    let mut first = None;
    while let Ok(event) = events.try_recv() {
        if let MuxEvent::TreeDelta(delta) = event
            && delta.workspace == companion_slot
        {
            first = Some(delta);
            break;
        }
    }
    let first = first.expect("the companion's creation emitted a tree delta");
    assert_eq!(first.kind, TreeDeltaKind::WorkspaceAdded, "{:?}", first.entity);
    let entity = &first.entity;
    assert_eq!(entity["kind"], "app_tabs", "{entity}");
    assert_eq!(entity["app"], STORE, "{entity}");
    assert_eq!(entity["extra"]["default_title"], true, "{entity}");
    wire.mux.shutdown();
}
