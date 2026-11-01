//! Leak 8 of the incognito audit: after an app-only crash (the daemon kept
//! running), the app's incognito workspaces came back in a new incognito
//! window, terminals included (design/spaces.md "Incognito": deleted after
//! a crash). The daemon now closes the ephemeral workspaces an app process
//! created once that process has no connection left and another app process
//! reads the session. The peer keys here name pids above every pid_max, so
//! their processes have exited.

use super::*;

/// An app connection: role main, its socket peer `peer_key`.
fn app(mux: &Arc<Mux>, peer_key: &str) -> (u64, MessageWriter, Arc<BoundedOutbound>) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    origin_gate::set_peer_identity_at_accept(mux, client, Some(peer_key.to_string()), None);
    assert!(origin_gate::set_hello(
        mux,
        client,
        crate::request_origin::HelloRole::Main,
        Some(peer_key.to_string()),
        false,
        None
    ));
    (client, writer, outbound)
}

fn send(
    mux: &Arc<Mux>,
    (client, writer, outbound): &(u64, MessageWriter, Arc<BoundedOutbound>),
    id: &str,
    operation: &str,
    mut params: Value,
) -> Value {
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    // Only mutations take an idempotency key.
    let key = operation.ends_with(".create").then_some(id);
    let request = resource_request(id, operation, params, key);
    assert!(handle_connection_message(mux, *client, &request, writer, &scheduler));
    let response = pop_json(outbound);
    assert_eq!(response["ok"], true, "{response}");
    response
}

fn create(mux: &Arc<Mux>, client: &(u64, MessageWriter, Arc<BoundedOutbound>), name: &str, ephemeral: bool) -> String {
    let mut params = json!({"name": name, "initial_content": "empty"});
    if ephemeral {
        params["ephemeral"] = json!(true);
    }
    create_with(mux, client, params)
}

fn create_with(mux: &Arc<Mux>, client: &(u64, MessageWriter, Arc<BoundedOutbound>), params: Value) -> String {
    let name = params["name"].as_str().unwrap_or("workspace").to_string();
    let response = send(mux, client, &format!("create-{name}"), "workspace.create", params);
    response["result"]["value"]["workspace_id"]
        .as_str()
        .or_else(|| response["result"]["workspace_id"].as_str())
        .unwrap_or_else(|| panic!("no workspace id: {response}"))
        .to_string()
}

/// The workspace ids `client`'s session snapshot lists.
fn listed(mux: &Arc<Mux>, client: &(u64, MessageWriter, Arc<BoundedOutbound>), id: &str) -> Vec<String> {
    let response = send(
        mux,
        client,
        id,
        "session.snapshot",
        json!({}),
    );
    response["result"]["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|workspace| workspace["id"].as_str().map(str::to_string))
        .collect()
}

fn persistent(name: &'static str) -> (Arc<Mux>, PathBuf) {
    let root = std::env::temp_dir()
        .join(format!("cmux-incognito-orphans-{name}-{}", crate::workspace_registry::new_uuid_v4()));
    (Mux::open_persistent(name, SurfaceOptions::default(), &root).unwrap(), root)
}

#[test]
fn a_crashed_apps_incognito_workspaces_close_when_the_next_app_reads_the_session() {
    let (mux, root) = persistent("crash");
    let crashed = app(&mux, "token:999999101.1");
    let private = create(&mux, &crashed, "private", true);
    let normal = create(&mux, &crashed, "normal", false);
    // The app crashes: its connection goes, the daemon keeps running.
    assert!(disconnect_client(&mux, crashed.0, false));
    let relaunched = app(&mux, "token:999999102.1");
    let workspaces = listed(&mux, &relaunched, "after-crash");
    assert!(workspaces.contains(&normal), "a normal workspace stays: {workspaces:?}");
    assert!(
        !workspaces.contains(&private),
        "a crashed app's incognito workspace must be closed: {workspaces:?}"
    );
    // And it leaves no closed-history record.
    let closed = send(&mux, &relaunched, "closed", "closed.list", json!({}));
    assert!(
        closed["result"]["value"].as_array().or(closed["result"].as_array()).is_none_or(Vec::is_empty),
        "{closed}"
    );
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn incognito_workspaces_stay_while_their_app_lives_or_reconnects() {
    let (mux, root) = persistent("alive");
    let first = app(&mux, "token:999999201.1");
    let private = create(&mux, &first, "private", true);
    // Another app process reads while the creator is still connected.
    let other = app(&mux, "token:999999202.1");
    assert!(listed(&mux, &other, "creator-alive").contains(&private));
    // The creator's connection drops and the same process reconnects.
    assert!(disconnect_client(&mux, first.0, false));
    let again = app(&mux, "token:999999201.1");
    assert!(listed(&mux, &again, "same-process").contains(&private));
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// A tab moved out of an incognito workspace makes another incognito
/// workspace (`state::ephemeral_moves`); a crash closes it too.
#[test]
fn a_workspace_a_crashed_app_moved_incognito_tabs_into_closes_too() {
    let (mux, root) = persistent("moved");
    let crashed = app(&mux, "token:999999301.1");
    let mut params = json!({"name": "private", "initial_content": "terminal", "ephemeral": true});
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let private = create_with(&mux, &crashed, params);
    let first = mux
        .with_state(|state| {
            state.surfaces.keys().copied().find(|surface| {
                state.pane_of(*surface).and_then(|pane| state.screen_of(pane)).is_some_and(
                    |(index, _)| state.workspaces[index].public_id.to_string() == private,
                )
            })
        })
        .expect("the private workspace has a tab");
    let pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    mux.new_tab(Some(pane), None, None).unwrap();
    let moved = handle_command(
        &mux,
        crashed.0,
        Command::MoveTabToNewWorkspace {
            surface: first,
            group: None,
            index: None,
            name: None,
            transaction: None,
        },
        &crashed.1,
    )
    .unwrap();
    let moved_to = mux.with_state(|state| {
        let pane = state.pane_of(first).unwrap();
        let (workspace, _) = state.screen_of(pane).unwrap();
        state.workspaces[workspace].public_id.to_string()
    });
    assert_ne!(moved_to, private, "{moved}");
    assert!(listed(&mux, &crashed, "before-crash").contains(&moved_to));
    assert!(disconnect_client(&mux, crashed.0, false));
    let relaunched = app(&mux, "token:999999302.1");
    let after = listed(&mux, &relaunched, "after-crash");
    for workspace in [&private, &moved_to] {
        assert!(
            !after.contains(workspace),
            "every incognito workspace of a crashed app must close: {workspace} in {after:?}"
        );
    }
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}

/// A creator whose connection dropped while its process still runs may
/// come back at any moment: its workspaces stay, so no close races its
/// reconnect.
#[test]
fn a_creator_whose_process_still_runs_keeps_its_workspaces() {
    let (mux, root) = persistent("running");
    let running = format!("token:{}.1", std::process::id());
    let first = app(&mux, &running);
    let private = create(&mux, &first, "private", true);
    assert!(disconnect_client(&mux, first.0, false));
    let other = app(&mux, "token:999999402.1");
    assert!(
        listed(&mux, &other, "creator-running").contains(&private),
        "a running app's incognito workspace stays"
    );
    mux.shutdown();
    drop(mux);
    let _ = std::fs::remove_dir_all(root);
}
