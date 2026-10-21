//! `stash.restore` is all or nothing (`stash-v1`): when one member cannot
//! reopen, the pages this call already opened close again and every member
//! stays in the stash, so a retry never opens a page twice.

use serde_json::json;

use super::tests::{mutate, read, send};
use crate::mux::*;
use crate::state::commit::StateEffects;
use crate::state::prelude::*;
use crate::state::store::StateChanges;
use crate::surface::SurfaceOptions;
use crate::workspace_registry::WorkspaceMutation;

fn import(mux: &Arc<Mux>, urls: &[&str], key: &str) -> String {
    let tabs = urls.iter().map(|url| json!({"url": url})).collect::<Vec<_>>();
    let imported =
        mutate(mux, "stash.import", json!({"source": "onetab", "groups": [{"tabs": tabs}]}), key);
    imported["stash_ids"][0].as_str().unwrap().to_string()
}

/// Make member `index` of `stash` fail to reopen (a conversation record it
/// cannot parse), or reopen again with `broken` false.
fn set_broken(mux: &Arc<Mux>, stash: &str, index: usize, broken: bool, key: &str) {
    let path = format!("$.members[{index}].screens[0].tabs[0].conversation");
    let mutation = WorkspaceMutation::new(key, "test", crate::Actor::local_user()).unwrap();
    mux.commit_state(&mutation, "test.stash", &json!({"key": key}), None, StateEffects::EVENTS_ONLY, |transaction, _| {
        let sql = if broken {
            "UPDATE stashed_groups SET record_json = json_set(record_json, ?1, json('{\"bad\":1}')) WHERE stash_id = ?2"
        } else {
            "UPDATE stashed_groups SET record_json = json_remove(record_json, ?1) WHERE stash_id = ?2"
        };
        transaction.execute(sql, rusqlite::params![path, stash])?;
        Ok(StateChanges::new(json!({}), Vec::new()))
    })
    .unwrap();
}

fn member_count(mux: &Arc<Mux>) -> usize {
    read(mux, "stash.list", json!({}))[0]["members"].as_array().unwrap().len()
}

fn counts(mux: &Arc<Mux>) -> (usize, usize) {
    mux.with_state(|state| (state.resource_indexes.tab_ids.len(), state.workspaces.len()))
}

#[test]
fn stash_restore_that_fails_partway_opens_nothing_and_keeps_every_member() {
    let mux = Mux::new_for_test("stash-restore-atomic", SurfaceOptions::default());
    mux.new_workspace(Some("One".into()), None).unwrap();
    let stash =
        import(&mux, &["https://a.example/", "https://b.example/", "https://c.example/"], "import");
    set_broken(&mux, &stash, 1, true, "break");
    let before = counts(&mux);

    for (target, key) in [("here", "restore-here"), ("new_workspace", "restore-new")] {
        let failed =
            send(&mux, "stash.restore", json!({"stash": stash, "target": target}), Some(key));
        assert!(failed.is_err(), "{target}: the broken member fails the restore");
        assert_eq!(counts(&mux), before, "{target}: the pages it opened closed again");
        assert_eq!(member_count(&mux), 3, "{target}: every member stays in the stash");
    }

    // Fixed, a retry opens each page once.
    set_broken(&mux, &stash, 1, false, "fix");
    let restored = mutate(&mux, "stash.restore", json!({"stash": stash}), "restore-again");
    assert_eq!(restored["tab_ids"].as_array().unwrap().len(), 3);
    assert_eq!(counts(&mux).0, before.0 + 3, "each page once");
    assert!(read(&mux, "stash.list", json!({})).as_array().unwrap().is_empty());
    mux.shutdown();
}
