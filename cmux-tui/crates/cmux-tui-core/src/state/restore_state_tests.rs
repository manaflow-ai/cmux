//! Pushed restore state (plans/cmux-next/reopen-closed.md 3.0): the state a
//! tab's owner holds that the daemon cannot own (a draft prompt, a page or
//! viewer scroll) is put ahead of the close, or rides on the close request,
//! and Reopen Closed hands it back. Driven through `cmux.protocol/2`
//! requests.

use serde_json::{Value, json};

use super::tests::{mutate, read, send, tab_id, terminal_tabs};
use crate::mux::*;
use crate::state::prelude::*;
use crate::surface::SurfaceOptions;

fn put(mux: &Arc<Mux>, tab: &str, version: u64, payload: Value, key: &str) -> Value {
    mutate(
        mux,
        "surface.restore_state.put",
        json!({"tab": tab, "provider": "cmux.page", "version": version, "payload": payload}),
        key,
    )
}

/// Restore-state rows the daemon keeps, by tab id.
fn stored_tabs(mux: &Mux) -> Vec<String> {
    mux.read_registry_state(|connection| {
        let mut statement =
            connection.prepare("SELECT tab_id FROM tab_restore_state ORDER BY tab_id")?;
        Ok(statement
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<Result<Vec<_>, _>>()?)
    })
    .unwrap()
}

fn newest_closed(mux: &Arc<Mux>) -> Value {
    read(mux, "closed.list", json!({}))[0]["id"].clone()
}

/// A put before the close comes back on the reopen result, without the
/// URL query keys that look like secrets; the reopened tab keeps it, so a
/// second close and reopen still has it. Recently Closed never shows it.
#[test]
fn a_pushed_restore_state_comes_back_on_reopen_and_stays_with_the_reopened_tab() {
    let mux = Mux::new_for_test("restore-state-pushed", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let tab = tab_id(&mux, tabs[1]);
    let stored = put(
        &mux,
        &tab,
        3,
        json!({"route": "/settings", "scroll": 120,
               "url": "https://example.test/doc?token=abc&page=2#top"}),
        "put-1",
    );
    assert_eq!(stored["stored"], true, "{stored}");
    mutate(&mux, "tab.close", json!({"tab": tab}), "close-1");
    let listed = read(&mux, "closed.list", json!({}));
    assert!(!listed.to_string().contains("/settings"), "closed.list shows the payload: {listed}");

    let reopened =
        mutate(&mux, "closed.reopen", json!({"closed": newest_closed(&mux)}), "reopen-1");
    let again = reopened["tab_ids"][0].as_str().unwrap().to_string();
    assert_eq!(
        reopened["restore_state"],
        json!({again.clone(): {"provider": "cmux.page", "version": 3, "payload": {
            "route": "/settings", "scroll": 120, "url": "https://example.test/doc?page=2#top"}}}),
        "{reopened}"
    );
    assert_eq!(stored_tabs(&mux), vec![again.clone()]);

    mutate(&mux, "tab.close", json!({"tab": again}), "close-2");
    let second = mutate(&mux, "closed.reopen", json!({"closed": newest_closed(&mux)}), "reopen-2");
    let third = second["tab_ids"][0].as_str().unwrap().to_string();
    assert_eq!(second["restore_state"][&third]["payload"]["route"], "/settings", "{second}");
    assert_eq!(second["restore_state"][&third]["version"], 3);
}

/// The closer's inline payload wins over the pushed row; a tab with
/// neither reopens with no restore state.
#[test]
fn an_inline_close_payload_wins_over_the_pushed_row() {
    let mux = Mux::new_for_test("restore-state-inline", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 3);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    put(&mux, &ids[1], 1, json!({"draft": "old"}), "put-old");
    let group = mutate(&mux, "tab_group.create", json!({"tabs": [ids[1], ids[2]]}), "group");
    mutate(
        &mux,
        "tab_group.close",
        json!({"tab_group": group["id"], "restore_state": {
            ids[1].clone(): {"provider": "cmux.agent", "version": 2, "payload": {"draft": "new"}}}}),
        "group-close",
    );
    let reopened = mutate(&mux, "closed.reopen", json!({"closed": newest_closed(&mux)}), "reopen");
    let back = reopened["tab_ids"].as_array().unwrap();
    assert_eq!(back.len(), 2, "{reopened}");
    let first = back[0].as_str().unwrap();
    let second = back[1].as_str().unwrap();
    assert_eq!(
        reopened["restore_state"][first],
        json!({"provider": "cmux.agent", "version": 2, "payload": {"draft": "new"}}),
        "{reopened}"
    );
    assert!(reopened["restore_state"].get(second).is_none(), "{reopened}");
}

/// A put larger than 16 KiB is refused; one on a tab that is gone names
/// the tab.
#[test]
fn a_put_over_the_limit_or_on_a_closed_tab_is_refused() {
    let mux = Mux::new_for_test("restore-state-limits", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 2);
    let tab = tab_id(&mux, tabs[1]);
    let large = json!({"text": "x".repeat(16 * 1024)});
    let refused = send(
        &mux,
        "surface.restore_state.put",
        json!({"tab": tab, "provider": "cmux.page", "version": 1, "payload": large}),
        Some("too-large"),
    );
    assert_eq!(refused.expect_err("an oversized payload was stored").code, "validation.invalid");
    mutate(&mux, "tab.close", json!({"tab": tab}), "close");
    let gone = send(
        &mux,
        "surface.restore_state.put",
        json!({"tab": tab, "provider": "cmux.page", "version": 1, "payload": {}}),
        Some("gone"),
    );
    assert!(gone.is_err(), "a put on a closed tab succeeded");
    assert!(stored_tabs(&mux).is_empty());
}

/// The row leaves with its closed group: a permanent delete drops it, and a
/// partial reopen keeps the rows of the members still in the group.
#[test]
fn a_tabs_restore_state_leaves_with_its_closed_group() {
    let mux = Mux::new_for_test("restore-state-group", SurfaceOptions::default());
    let tabs = terminal_tabs(&mux, 4);
    let ids = tabs.iter().map(|tab| tab_id(&mux, *tab)).collect::<Vec<_>>();
    put(&mux, &ids[1], 1, json!({"n": 1}), "put-1");
    put(&mux, &ids[2], 1, json!({"n": 2}), "put-2");
    put(&mux, &ids[3], 1, json!({"n": 3}), "put-3");
    let group = mutate(&mux, "tab_group.create", json!({"tabs": [ids[1], ids[2]]}), "group");
    mutate(&mux, "tab_group.close", json!({"tab_group": group["id"]}), "group-close");
    let closed = newest_closed(&mux);
    assert_eq!(stored_tabs(&mux).len(), 3, "a recorded close keeps the rows");

    let partial =
        mutate(&mux, "closed.reopen", json!({"closed": closed, "members": [0]}), "reopen-one");
    let back = partial["tab_ids"][0].as_str().unwrap().to_string();
    assert_eq!(partial["restore_state"][&back]["payload"], json!({"n": 1}), "{partial}");
    let mut expected = vec![back.clone(), ids[2].clone(), ids[3].clone()];
    expected.sort();
    assert_eq!(stored_tabs(&mux), expected);

    mutate(&mux, "closed.delete", json!({"closed": closed}), "delete");
    let mut expected = vec![back, ids[3].clone()];
    expected.sort();
    assert_eq!(stored_tabs(&mux), expected, "a deleted group's rows go with it");
}

/// Incognito tabs never store restore state: a put answers `stored: false`,
/// an inline payload on the close is dropped, and nothing reaches the
/// registry.
#[test]
fn incognito_tabs_never_store_restore_state() {
    let mux = Mux::new_for_test("restore-state-incognito", SurfaceOptions::default());
    let created = mutate(
        &mux,
        "workspace.create",
        json!({"name": "incognito", "initial_content": "terminal", "ephemeral": true}),
        "create-incognito",
    );
    let workspace = created["workspace_id"].as_str().unwrap().to_string();
    let surface = mux
        .with_state(|state| {
            state.surfaces.keys().copied().find(|surface| {
                state.pane_of(*surface).and_then(|pane| state.screen_of(pane)).is_some_and(
                    |(index, _)| state.workspaces[index].public_id.to_string() == workspace,
                )
            })
        })
        .expect("the incognito workspace has a tab");
    let pane = mux.with_state(|state| state.pane_of(surface)).unwrap();
    let other = mux.new_tab(Some(pane), None, None).unwrap().id;
    let tab = tab_id(&mux, other);
    let answer = put(&mux, &tab, 1, json!({"draft": "secret"}), "put");
    assert_eq!(answer["stored"], false, "{answer}");
    mutate(
        &mux,
        "tab.close",
        json!({"tab": tab, "restore_state": {
            tab.clone(): {"provider": "cmux.agent", "version": 1, "payload": {"draft": "secret"}}}}),
        "close",
    );
    assert!(stored_tabs(&mux).is_empty());
    assert!(read(&mux, "closed.list", json!({})).as_array().unwrap().is_empty());
}

/// A live tab that closes outside the closed history (its terminal exited)
/// drops its row: nothing could reopen it.
#[cfg(unix)]
#[test]
fn a_tab_that_closes_outside_history_drops_its_restore_state() {
    const TERMINAL: &str = "0000000000004000800000000000c106";
    const INCARNATION: &str = "1000000000004000800000000000c106";
    let mux = Mux::new_for_test("restore-state-exit", SurfaceOptions::default());
    let workspace = mux
        .create_empty_workspace(
            Some("exits".into()),
            Some("018f6e21-7b70-7e70-8000-00000000c106".into()),
            None,
        )
        .unwrap();
    let exited = mux.seed_running_terminal_for_test(TERMINAL, INCARNATION, &workspace.key).unwrap();
    let pane = mux.with_state(|state| state.pane_of(exited).unwrap());
    mux.new_tab(Some(pane), None, Some((80, 24))).unwrap();
    let tab = tab_id(&mux, exited);
    put(&mux, &tab, 1, json!({"scroll": 4}), "put");
    assert_eq!(stored_tabs(&mux), vec![tab]);
    let terminal =
        mux.workspace_registry.lock().unwrap().terminal_resource_id(TERMINAL).unwrap().unwrap();
    let exit = crate::terminal_host_protocol::TerminalExit {
        outcome: crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
        exited_at_ms: 1_000,
    };
    assert!(mux.persist_terminal_exit_for_test(&terminal, &exit).unwrap());
    mux.surface_exited(exited);
    assert_eq!(read(&mux, "closed.list", json!({})), json!([]), "a process exit is not a close");
    assert!(stored_tabs(&mux).is_empty(), "the exited tab kept its restore state");
    mux.shutdown();
}
