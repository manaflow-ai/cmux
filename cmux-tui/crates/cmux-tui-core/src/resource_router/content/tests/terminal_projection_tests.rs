//! Terminal projections: one terminal detached from every tab, reprojected
//! and closed explicitly, its input and reads with no tab, and the raw tree
//! notice for `terminal.project` and `terminal.move`.

use super::*;

#[test]
fn one_terminal_can_be_detached_reprojected_and_closed_explicitly() {
    let (mux, original, selectors) = terminal_fixture(None);
    let terminal_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    let initial = public_session_snapshot(&mux).unwrap();
    let terminal = initial["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .unwrap();
    let original_tab = terminal["tab_ids"][0].as_str().unwrap().to_string();
    let pane_id = initial["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"] == original_tab)
        .unwrap()["pane_id"]
        .as_str()
        .unwrap()
        .to_string();
    let pane = ResourceSelectors {
        machine: Some("current".into()),
        session: Some("current".into()),
        pane: Some(pane_id.clone()),
        ..ResourceSelectors::default()
    };
    super::super::super::topology::dispatch(
        &mux,
        parsed_request("tab.create_terminal", &pane, json!({}), Some("terminal-multiview-keeper")),
    )
    .unwrap();

    let destination = public_session_snapshot(&mux).unwrap();
    let workspace_id = destination["workspaces"][0]["id"].as_str().unwrap();
    let screen_id = destination["screens"][0]["id"].as_str().unwrap();
    let active_before_projection = mux.active_surface();
    let projected = dispatch(
        &mux,
        parsed_request(
            "terminal.project",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":1,
                "name":"mirror",
            }),
            Some("terminal-multiview-project"),
        ),
    )
    .unwrap();
    assert_eq!(projected["value"]["focused"], false);
    assert_eq!(mux.active_surface(), active_before_projection);
    let projected_tab = projected["value"]["id"].as_str().unwrap().to_string();
    let placements = mux.with_state(|state| {
        state.placements_of_content(&ContentPublicId::Terminal(terminal_id.clone())).to_vec()
    });
    assert_eq!(placements.len(), 2);
    let mirror = mux.surface(placements[1]).unwrap();
    assert!(original.shares_terminal_runtime(&mirror));
    let terminal = public_session_snapshot(&mux).unwrap()["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .unwrap()
        .clone();
    assert_eq!(terminal["tab_ids"].as_array().unwrap().len(), 2);

    for (index, tab) in [original_tab, projected_tab].into_iter().enumerate() {
        let tab_selectors = ResourceSelectors {
            machine: Some("current".into()),
            session: Some("current".into()),
            tab: Some(tab),
            ..ResourceSelectors::default()
        };
        super::super::super::topology::dispatch(
            &mux,
            parsed_request(
                "tab.close",
                &tab_selectors,
                json!({}),
                Some(&format!("terminal-multiview-detach-{index}")),
            ),
        )
        .unwrap();
    }

    let detached = public_session_snapshot(&mux).unwrap();
    let terminal = detached["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .unwrap();
    assert!(terminal["tab_id"].is_null());
    assert_eq!(terminal["tab_ids"], json!([]));
    assert!(mux.surface(original.id).is_some());
    assert!(
        dispatch(&mux, parsed_request("terminal.screen.read", &selectors, json!({}), None),)
            .is_ok()
    );

    let reprojected = dispatch(
        &mux,
        parsed_request(
            "terminal.project",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":1,
            }),
            Some("terminal-multiview-reproject"),
        ),
    )
    .unwrap();
    assert_eq!(reprojected["value"]["content_id"], terminal_id.as_str());
    dispatch(
        &mux,
        parsed_request(
            "terminal.project",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":2,
                "name":"second mirror",
            }),
            Some("terminal-multiview-second-reproject"),
        ),
    )
    .unwrap();
    assert_eq!(
        mux.with_state(|state| state
            .placements_of_content(&ContentPublicId::Terminal(terminal_id.clone()))
            .len()),
        2
    );

    let before_close = mux.with_state(|state| state.resource_revision);
    dispatch(
        &mux,
        parsed_request(
            "terminal.close",
            &selectors,
            json!({}),
            Some("terminal-multiview-explicit-close"),
        ),
    )
    .unwrap();
    let close_events = mux.resource_events_after(before_close).unwrap();
    assert_eq!(close_events.batches.len(), 1);
    let close_changes = close_events.batches[0].changes.as_array().unwrap();
    assert_eq!(
        close_changes
            .iter()
            .filter(|change| {
                change["kind"] == "delete"
                    && change["resource"] == "terminal"
                    && change["id"] == terminal_id.as_str()
            })
            .count(),
        1
    );
    assert_eq!(
        close_changes
            .iter()
            .filter(|change| change["kind"] == "delete" && change["resource"] == "tab")
            .count(),
        2
    );
    assert!(
        public_session_snapshot(&mux).unwrap()["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .all(|terminal| terminal["id"] != terminal_id.as_str())
    );
    assert!(mux.surface(original.id).is_none());
}

/// A kept terminal with no tab (the only view of it lives in another
/// session's layout, cmux-next remote-terminal tabs) takes input and
/// reads by its public id, and projecting it back tells raw v12 tree
/// subscribers, like `move-tab` does. Before, `terminal.project` and
/// `terminal.move` published only the resource journal, so a frontend
/// subscribed with `tree_events` never learned about the new tab.
#[test]
fn cmux_next_unplaced_terminal_io_and_projection_reach_raw_subscribers() {
    let (mux, original, selectors) = terminal_fixture(None);
    let terminal_id = TerminalPublicId::parse(selectors.terminal.as_deref().unwrap()).unwrap();
    let initial = public_session_snapshot(&mux).unwrap();
    let original_tab = initial["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .unwrap()["tab_ids"][0]
        .as_str()
        .unwrap()
        .to_string();
    let pane_id = initial["tabs"]
        .as_array()
        .unwrap()
        .iter()
        .find(|tab| tab["id"] == original_tab)
        .unwrap()["pane_id"]
        .as_str()
        .unwrap()
        .to_string();
    let current = |pane: Option<String>, tab: Option<String>| ResourceSelectors {
        machine: Some("current".into()),
        session: Some("current".into()),
        pane,
        tab,
        ..ResourceSelectors::default()
    };
    // A second tab keeps the pane alive once the original tab closes.
    super::super::super::topology::dispatch(
        &mux,
        parsed_request(
            "tab.create_terminal",
            &current(Some(pane_id.clone()), None),
            json!({}),
            Some("unplaced-keeper"),
        ),
    )
    .unwrap();
    super::super::super::topology::dispatch(
        &mux,
        parsed_request(
            "tab.close",
            &current(None, Some(original_tab)),
            json!({}),
            Some("unplaced-detach"),
        ),
    )
    .unwrap();
    assert!(mux.surface(original.id).is_some(), "the terminal outlives its tab");

    // Terminal I/O by public id with no tab.
    dispatch(
        &mux,
        parsed_request(
            "terminal.input.write",
            &selectors,
            json!({"text":"x"}),
            Some("unplaced-write"),
        ),
    )
    .expect("terminal.input.write works on a terminal with no tab");
    dispatch(
        &mux,
        parsed_request(
            "terminal.input.keys",
            &selectors,
            json!({"keys":["enter"]}),
            Some("unplaced-keys"),
        ),
    )
    .expect("terminal.input.keys works on a terminal with no tab");
    original.try_with_terminal(|terminal| terminal.vt_write(b"mk42")).unwrap();
    let screen =
        dispatch(&mux, parsed_request("terminal.screen.read", &selectors, json!({}), None))
            .expect("terminal.screen.read works on a terminal with no tab");
    assert!(screen["text"].as_str().unwrap().contains("mk42"), "{screen}");
    dispatch(&mux, parsed_request("terminal.history.read", &selectors, json!({"limit":5}), None))
        .expect("terminal.history.read works on a terminal with no tab");

    let snapshot = public_session_snapshot(&mux).unwrap();
    let workspace_id = snapshot["workspaces"][0]["id"].as_str().unwrap().to_string();
    let screen_id = snapshot["screens"][0]["id"].as_str().unwrap().to_string();
    let events = mux.subscribe();
    let tree_events = |events: &crate::MuxEventReceiver| {
        events
            .try_iter()
            .filter(|event| {
                matches!(
                    event,
                    crate::mux::MuxEvent::TreeChanged | crate::mux::MuxEvent::TreeDelta(_)
                )
            })
            .count()
    };
    let projected = dispatch(
        &mux,
        parsed_request(
            "terminal.project",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":0,
            }),
            Some("unplaced-project"),
        ),
    )
    .unwrap();
    assert!(tree_events(&events) > 0, "terminal.project must notify raw tree subscribers");

    assert!(projected["value"]["id"].as_str().unwrap().starts_with("tab_"));
    dispatch(
        &mux,
        parsed_request(
            "terminal.move",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":1,
            }),
            Some("unplaced-move"),
        ),
    )
    .unwrap();
    assert!(tree_events(&events) > 0, "terminal.move must notify raw tree subscribers");
    // A replayed projection commits nothing new and stays quiet.
    dispatch(
        &mux,
        parsed_request(
            "terminal.move",
            &selectors,
            json!({
                "destination_workspace":workspace_id,
                "destination_screen":screen_id,
                "destination_pane":pane_id,
                "index":1,
            }),
            Some("unplaced-move"),
        ),
    )
    .unwrap();
    assert_eq!(tree_events(&events), 0, "a replay emits nothing");
    original.kill();
}
