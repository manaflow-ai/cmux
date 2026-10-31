//! `create-workspace {places_by_setting, current}` over the wire: the creating
//! window's current workspace (or none) places the new one by
//! `workspaces.newPlacement`, not the session's active workspace.

use super::*;
use crate::user_settings::NewWorkspacePlacement;

/// The personal sidebar order of `keys`.
fn order(mux: &Arc<Mux>, keys: &[&str]) -> Vec<String> {
    mux.personal_state_read(|connection| {
        let ids = crate::state::personal_order::sidebar_workspace_ids(connection)?;
        let mut keyed = Vec::new();
        for key in keys {
            if let Some(id) = crate::state::values::workspace_public_id_for_key(connection, key)? {
                keyed.push((id, key.to_string()));
            }
        }
        Ok(ids
            .iter()
            .filter_map(|id| {
                keyed.iter().find(|(public, _)| public == id).map(|(_, key)| key.clone())
            })
            .collect())
    })
    .unwrap()
}

fn create(mux: &Arc<Mux>, name: &str, extra: Value) -> String {
    let mut request = json!({"cmd":"create-workspace","name":name,"origin":"test","mutation_id":format!("create-{name}")});
    request.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
    run_json_command(mux, request).unwrap()["key"].as_str().unwrap().to_string()
}

#[test]
fn create_workspace_places_against_the_clients_current_workspace() {
    let mux = test_mux();
    let bottom = NewWorkspacePlacement::Bottom.set_for_test();
    let a = create(&mux, "a", json!({}));
    let b = create(&mux, "b", json!({}));
    drop(bottom);
    // The session's active workspace is b, the last created one.
    let _after = NewWorkspacePlacement::AfterCurrent.set_for_test();
    let c = create(&mux, "c", json!({"places_by_setting": true, "current": a}));
    assert_eq!(
        order(&mux, &[&a, &b, &c]),
        [a.clone(), c.clone(), b.clone()],
        "after the client's current workspace a"
    );
    // A window on a top page: no current workspace, so the top, not after the active one.
    let d = create(&mux, "d", json!({"places_by_setting": true}));
    assert_eq!(order(&mux, &[&a, &b, &c, &d]), [d.clone(), a.clone(), c.clone(), b.clone()]);
    // A current that is no workspace key counts as none.
    let e = create(&mux, "e", json!({"places_by_setting": true, "current": "not-a-key"}));
    assert_eq!(order(&mux, &[&a, &b, &c, &d, &e])[0], e, "no current workspace: the top");
    drop(_after);
    // The client's own value wins over this daemon's file: `top` here, `afterCurrent` sent.
    let _top = NewWorkspacePlacement::Top.set_for_test();
    let f = create(
        &mux,
        "f",
        json!({"places_by_setting": true, "current": a, "placement": "afterCurrent"}),
    );
    let shown = order(&mux, &[&a, &b, &c, &d, &e, &f]);
    let index = shown.iter().position(|key| key == &a).unwrap();
    assert_eq!(shown.get(index + 1), Some(&f), "after a by the client's value: {shown:?}");
}
