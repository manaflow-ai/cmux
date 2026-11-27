//! LAST-TAB-CLOSES-WORKSPACE (cmux-next-spec decisions.md, 2026-10-06):
//! closing the only tab of a workspace closes the workspace, by every close
//! path, in the same commit as the tab. The owner decides it, so every client
//! (Mac, iOS, GPUI, CLI, plain cmux-tui) sees one change and no client infers
//! a close from its mirror (OWNERSHIP-PRINCIPLES: destructive policy at the
//! owner). Reopen restores the workspace with its tab, name, group and place.
//! The home workspace, a provider-managed (Cloud VM) session and a host loss
//! never close a workspace.

use serde_json::json;

use super::tests::{
    Session, changes_after, mutate, placements_by_id, read, replayed_placements, revision, send,
    tab_id,
};
use crate::mux::*;
use crate::state::prelude::*;

/// The public id of the workspace that shows `surface`.
fn workspace_of(mux: &Mux, surface: SurfaceId) -> String {
    mux.with_state(|state| {
        let pane = state.pane_of(surface).expect("tab is placed");
        let (workspace, _) = state.screen_of(pane).expect("pane is on a screen");
        state.workspaces[workspace].public_id.to_string()
    })
}

fn workspace_ids(mux: &Mux) -> Vec<String> {
    mux.with_state(|state| {
        state.workspaces.iter().map(|workspace| workspace.public_id.to_string()).collect()
    })
}

/// The live workspaces in the personal sidebar order, with their group.
fn personal_order(mux: &Arc<Mux>) -> Vec<(String, Option<String>)> {
    let live = workspace_ids(mux);
    read(mux, "workspace.placement.list", json!({}))
        .as_array()
        .expect("placement list is an array")
        .iter()
        .filter_map(|placement| {
            let id = placement["workspace"]["workspace_id"].as_str()?.to_string();
            live.contains(&id).then(|| (id, placement["group_id"].as_str().map(str::to_string)))
        })
        .collect()
}

/// A named way to close the tab `SurfaceId`.
type ClosePath<'a> = (&'a str, &'a dyn Fn(&Arc<Mux>, SurfaceId));

fn deleted(changes: &[Value], resource: &str) -> Vec<String> {
    changes
        .iter()
        .filter(|change| change["kind"] == "delete" && change["resource"] == resource)
        .filter_map(|change| change["id"].as_str().map(str::to_string))
        .collect()
}

/// The last tab's close removes its workspace in the same commit: one
/// resource revision tombstones the tab and the workspace, and the closed
/// history holds one workspace group with that tab, not a tab group.
#[test]
fn closing_the_last_tab_closes_its_workspace_in_the_same_commit() {
    let session = Session::new("last-tab-commit");
    let mux = session.open();
    let keep = mux.new_workspace(None, None).unwrap();
    let last = mux.new_workspace(None, None).unwrap();
    let workspace = workspace_of(&mux, last.id);
    let tab = tab_id(&mux, last.id);
    let before = revision(&mux);

    assert!(mux.close_surface(last.id).unwrap());

    assert!(!workspace_ids(&mux).contains(&workspace), "an empty workspace was kept");
    assert_eq!(revision(&mux), before + 1, "the tab and its workspace closed in two commits");
    let changes = changes_after(&mux, before);
    assert_eq!(deleted(&changes, "workspace"), [workspace]);
    assert!(deleted(&changes, "tab").contains(&tab));
    let closed = read(&mux, "closed.list", json!({}));
    let groups = closed.as_array().expect("closed list is an array");
    assert_eq!(groups.len(), 1, "one close gesture, one group: {closed}");
    assert_eq!(groups[0]["kind"], "workspace", "the group is the workspace: {closed}");
    assert_eq!(workspace_of(&mux, keep.id), workspace_ids(&mux)[0]);
    mux.shutdown();
}

/// A tab that is not the last one closes alone.
#[test]
fn closing_a_tab_that_is_not_the_last_keeps_the_workspace() {
    let session = Session::new("not-last-tab");
    let mux = session.open();
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id)).unwrap();
    let second = mux.new_tab(Some(pane), None, None).unwrap();
    let workspace = workspace_of(&mux, first.id);

    assert!(mux.close_surface(second.id).unwrap());

    assert!(workspace_ids(&mux).contains(&workspace));
    assert_eq!(read(&mux, "closed.list", json!({}))[0]["kind"], "tab");
    mux.shutdown();
}

/// Every explicit close of the workspace's last tab closes the workspace:
/// the last pane, the last screen, `close-tabs`, the resource API's
/// `tab.close` and `pane.close`.
#[test]
fn every_explicit_close_path_closes_the_emptied_workspace() {
    let session = Session::new("every-close-path");
    let mux = session.open();
    let _keep = mux.new_workspace(None, None).unwrap();
    let paths: [ClosePath<'_>; 5] = [
        ("close-pane", &|mux, surface| {
            let pane = mux.with_state(|state| state.pane_of(surface)).unwrap();
            assert!(mux.close_pane(pane).unwrap());
        }),
        ("close-screen", &|mux, surface| {
            let screen = mux.with_state(|state| {
                let (workspace, screen) = state.screen_of(state.pane_of(surface).unwrap()).unwrap();
                state.workspaces[workspace].screens[screen].id
            });
            assert!(mux.close_screen(screen).unwrap());
        }),
        ("close-tabs", &|mux, surface| {
            let mutation = WorkspaceMutation::daemon("close-tabs-last", "test").unwrap();
            mux.close_tabs_for(vec![surface], false, None, &mutation).unwrap();
        }),
        ("tab.close", &|mux, surface| {
            let tab = tab_id(mux, surface);
            send(mux, "tab.close", json!({"tab": tab}), Some("tab-close-last")).unwrap();
        }),
        ("pane.close", &|mux, surface| {
            let pane = super::tests::pane_id(mux, surface);
            send(mux, "pane.close", json!({"pane": pane}), Some("pane-close-last")).unwrap();
        }),
    ];
    for (name, close) in paths {
        let surface = mux.new_workspace(None, None).unwrap();
        let workspace = workspace_of(&mux, surface.id);
        close(&mux, surface.id);
        assert!(!workspace_ids(&mux).contains(&workspace), "{name} kept an empty workspace");
    }
    mux.shutdown();
}

/// The active workspace after the cascade is the one an explicit
/// close-workspace selects (the existing close-workspace rule).
#[test]
fn selection_after_the_cascade_follows_the_close_workspace_rule() {
    let pick = |close_tab: bool| {
        let session = Session::new(if close_tab { "select-tab" } else { "select-workspace" });
        let mux = session.open();
        let surfaces = (0..3).map(|_| mux.new_workspace(None, None).unwrap()).collect::<Vec<_>>();
        let middle = surfaces[1].id;
        let (index, id) = mux.with_state(|state| {
            let (index, _) = state.screen_of(state.pane_of(middle).unwrap()).unwrap();
            (index, state.workspaces[index].id)
        });
        mux.select_workspace(Some(index), None);
        if close_tab {
            assert!(mux.close_surface(middle).unwrap());
        } else {
            assert!(mux.close_workspace(id));
        }
        let result = (workspace_ids(&mux).len(), mux.with_state(|state| state.active_workspace));
        mux.shutdown();
        result
    };
    assert_eq!(pick(true), pick(false));
}

/// Reopen (Cmd-Shift-T, History) restores the workspace with its tab, its
/// name, its group and its place in the personal sidebar order.
#[test]
fn reopen_restores_the_workspace_with_its_tab_name_group_and_place() {
    let session = Session::new("last-tab-reopen");
    let mux = session.open();
    // Made in sidebar order; the reopen below runs with the default (top).
    let bottom = crate::user_settings::NewWorkspacePlacement::Bottom.set_for_test();
    let a = mux.new_workspace(None, None).unwrap();
    let b = mux.new_workspace(Some("build".into()), None).unwrap();
    let c = mux.new_workspace(None, None).unwrap();
    drop(bottom);
    let (a, b_id, c) =
        (workspace_of(&mux, a.id), workspace_of(&mux, b.id), workspace_of(&mux, c.id));
    let group =
        mutate(&mux, "workspace_group.create", json!({"name": "Work"}), "group-work")["id"].clone();
    mutate(&mux, "workspace.place", json!({"workspace": b_id, "group": group}), "b-in-work");
    mutate(
        &mux,
        "workspace_group.update",
        json!({"workspace_group": group, "top_index": 1}),
        "slot",
    );
    let order = personal_order(&mux);
    assert_eq!(order.iter().map(|(id, _)| id.as_str()).collect::<Vec<_>>(), [&a, &b_id, &c]);

    assert!(mux.close_surface(b.id).unwrap());
    assert!(!workspace_ids(&mux).contains(&b_id), "an empty workspace was kept");
    let (start, before) = (placements_by_id(&mux), revision(&mux));
    let reopened = mutate(&mux, "closed.reopen", json!({}), "reopen-b");
    assert_eq!(
        replayed_placements(&mux, start, before),
        placements_by_id(&mux),
        "session.events placements differ from the store after reopen"
    );

    assert_eq!(reopened["kind"], "workspace", "reopen restored {reopened}");
    let new_id = reopened["workspace_id"].as_str().expect("a workspace was reopened").to_string();
    assert_eq!(reopened["tab_ids"].as_array().map(Vec::len), Some(1), "its tab came back");
    let name = mux.with_state(|state| {
        let item = state.workspaces.iter().find(|item| item.public_id.as_str() == new_id);
        item.map(|item| item.name.clone())
    });
    assert_eq!(name.as_deref(), Some("build"));
    let order = personal_order(&mux);
    assert_eq!(
        order,
        [(a, None), (new_id, group.as_str().map(str::to_string)), (c, None)],
        "the reopened workspace lost its group or place"
    );
    mux.shutdown();
}

/// The store's home workspace is never closed (`home_not_closable`); its
/// last tab closes alone.
#[test]
fn the_home_workspace_survives_its_last_tab() {
    let session = Session::new("home-last-tab");
    let mux = session.open();
    let home = send(&mux, "workspace.ensure_home", json!({}), Some("home")).unwrap()["value"]
        ["workspace_id"]
        .as_str()
        .unwrap()
        .to_string();
    let home_id = mux.with_state(|state| {
        state.workspaces.iter().find(|item| item.public_id.as_str() == home).map(|item| item.id)
    });
    let placement = mux.create_terminal_in_workspace(home_id.unwrap(), None, None, None, None);
    let surface = placement.unwrap().surface;

    assert!(mux.close_surface(surface).unwrap());

    assert!(workspace_ids(&mux).contains(&home));
    mux.shutdown();
}

/// A provider-managed session (a Cloud VM's daemon) owns workspace
/// lifecycle through the provider: a tab close never closes its workspace,
/// so the VM is never stopped or deleted by it.
#[test]
fn a_provider_managed_session_keeps_the_emptied_workspace() {
    let mux = Mux::new_provider_managed_for_test(
        "provider-last-tab",
        crate::surface::SurfaceOptions::default(),
        ProviderWorkspaceAuthority::new("provider-authority-for-last-tab-tests-0000001").unwrap(),
    );
    let surface = mux.new_workspace(None, None).unwrap();
    let workspace = workspace_of(&mux, surface.id);

    assert!(mux.close_surface(surface.id).unwrap());

    assert!(workspace_ids(&mux).contains(&workspace));
    mux.shutdown();
}

fn terminal_hex(prefix: &str, index: usize) -> String {
    format!("{prefix}000000000040008000{index:012x}")
}

/// A process end of the workspace's only terminal closes the workspace
/// with the detach (the tab would close); an explicit terminal close does
/// too. A host loss leaves the tab dead and the workspace open (invariant
/// 3). The registry agrees after a restart.
#[cfg(unix)]
#[test]
fn a_process_end_or_terminal_close_closes_the_workspace_and_a_host_loss_keeps_it() {
    use crate::terminal_host_protocol::{TerminalExit, TerminalExitOutcome};
    let root = std::env::temp_dir()
        .join(format!("cmux-last-tab-exit-{}", crate::workspace_registry::new_uuid_v4()));
    let session = "last-tab-exit";
    let options = crate::surface::SurfaceOptions {
        terminal_host_root: Some(crate::terminal_host_runtime::terminal_host_root(&root, session)),
        ..crate::surface::SurfaceOptions::default()
    };
    let mux = Mux::open_persistent(session, options.clone(), &root).unwrap();
    let seed = |index: usize| {
        let workspace = mux.create_empty_workspace(None, None, None).unwrap();
        let surface = mux
            .seed_running_terminal_with_on_exit_for_test(
                &terminal_hex("00", index),
                &terminal_hex("10", index),
                &workspace.key,
                crate::workspace_registry::TerminalOnExit::Close,
            )
            .unwrap();
        (surface, workspace_of(&mux, surface))
    };
    let (ended, ended_workspace) = seed(1);
    let (lost, lost_workspace) = seed(2);
    let (_, closed_workspace) = seed(3);

    mux.surface(ended)
        .unwrap()
        .record_process_end_for_test(TerminalExit::now(TerminalExitOutcome::Exit { code: 0 }));
    mux.surface_exited(ended);
    mux.surface_exited(lost);
    mux.close_terminal(&terminal_hex("00", 3), &terminal_hex("10", 3)).unwrap();

    let live = workspace_ids(&mux);
    assert!(!live.contains(&ended_workspace), "a process end kept an empty workspace");
    assert!(!live.contains(&closed_workspace), "a terminal close kept an empty workspace");
    assert!(live.contains(&lost_workspace), "a host loss closed a workspace");
    mux.shutdown();
    drop(mux);

    let reopened = Mux::open_persistent(session, options, &root).unwrap();
    let live = workspace_ids(&reopened);
    assert!(!live.contains(&ended_workspace) && !live.contains(&closed_workspace));
    assert!(live.contains(&lost_workspace));
    reopened.shutdown();
    drop(reopened);
    let _ = std::fs::remove_dir_all(root);
}
