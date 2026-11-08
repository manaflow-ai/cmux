//! A keyed `create-terminal` (the app's create, with a `mutation_id`)
//! projects only the workspace it created in: its journal record, and so
//! each `session.events` delta, does not grow with the session. It restated
//! every live workspace, screen, pane, tab and terminal (about 1500 upserts
//! per create at 290 workspaces in the classic import).

use super::*;

#[test]
fn a_keyed_create_terminal_restates_no_other_workspace() {
    let mux = Mux::new_for_test("keyed-create-terminal-scope", crate::SurfaceOptions::default());
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound, control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let run = |request: Value| {
        let command: Command = serde_json::from_value(request).unwrap();
        handle_command(&mux, client, command, &writer).unwrap()
    };
    for name in ["a", "b", "c"] {
        mux.new_workspace(Some(name.into()), Some((80, 24))).unwrap();
    }
    let workspaces = mux.with_state(|state| {
        state
            .workspaces
            .iter()
            .map(|workspace| {
                (workspace.name.clone(), workspace.key.clone(), workspace.public_id.to_string())
            })
            .collect::<Vec<_>>()
    });
    let key = |name: &str| workspaces.iter().find(|w| w.0 == name).unwrap().1.clone();
    let public = |name: &str| workspaces.iter().find(|w| w.0 == name).unwrap().2.clone();
    let create = |index: usize, key: String| {
        run(json!({"cmd": "create-terminal", "key": key, "cols": 80, "rows": 24,
                   "origin": "test", "mutation_id": format!("keyed-create-{index}")}))
    };
    // The session's first keyed create may run full: it seeds the public fold.
    create(0, key("c"));

    for (index, name) in ["b", "c", "b"].into_iter().enumerate() {
        let before = mux.with_state(|state| state.resource_revision);
        create(index + 1, key(name));
        let page = mux.workspace_registry.lock().unwrap().resource_events_after(before).unwrap();
        assert!(!page.batches.is_empty(), "the create in {name} committed no resource revision");
        for change in page.batches.iter().flat_map(|batch| batch.changes.as_array().unwrap()) {
            let (resource, id) = (change["resource"].as_str(), change["id"].as_str());
            let workspace = match resource {
                Some("workspace") => id,
                Some("screen") => change["value"]["workspace_id"].as_str(),
                _ => None,
            };
            assert!(
                workspace != Some(public("a").as_str()),
                "a create in {name} restated workspace a's {resource:?} {id:?} (fold seeded {}, \
                 projections {}, batches {:?})",
                mux.workspace_registry.lock().unwrap().public_fold_seeded(),
                serde_json::to_value(mux.resource_projection_stats()).unwrap(),
                page.batches
                    .iter()
                    .map(|batch| batch.changes.as_array().map_or(0, Vec::len))
                    .collect::<Vec<_>>()
            );
        }
    }
}
