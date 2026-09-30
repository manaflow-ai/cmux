//! Wire tests for remote-terminal tabs (`remote-terminal-tabs-v1`,
//! plans/cmux-next/data-model.md sections 1.2 and 2): a tab in this
//! session's layout that references a terminal on another session. The
//! daemon stores the reference like a frontend browser record and never
//! attaches, spawns or bootstraps anything for it.

use super::*;

const SESSION: &str = "0b7f2c1e-4d3a-4f6b-9c8d-1a2b3c4d5e6f";
const TERMINAL: &str = "5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f";

fn run(mux: &Arc<Mux>, request: Value) -> anyhow::Result<Value> {
    run_as(mux, 0, request)
}

fn run_as(mux: &Arc<Mux>, client: u64, request: Value) -> anyhow::Result<Value> {
    let writer = MessageWriter::new(QueuedSink {
        outbound: Arc::new(BoundedOutbound::default()),
        control: None,
    });
    let command: Command = serde_json::from_value(request)?;
    handle_command(mux, client, command, &writer)
}

fn remote_mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}

fn tab_of(mux: &Arc<Mux>, surface: u64) -> Value {
    let tree = run(mux, json!({"cmd":"list-workspaces"})).unwrap();
    tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|workspace| workspace["screens"].as_array().unwrap().clone())
        .flat_map(|screen| screen["panes"].as_array().unwrap().clone())
        .flat_map(|pane| pane["tabs"].as_array().unwrap().clone())
        .find(|tab| tab["surface"] == json!(surface))
        .unwrap_or_else(|| panic!("tab {surface} is in the tree"))
}

fn new_remote_tab(mux: &Arc<Mux>, pane: PaneId, title: Option<&str>) -> Value {
    let mut request = json!({
        "cmd":"new-remote-terminal-tab",
        "pane": pane,
        "session_id": SESSION,
        "terminal_id": TERMINAL,
        "session_name": "build-box",
    });
    if let Some(title) = title {
        request["title"] = json!(title);
    }
    run(mux, request).unwrap()
}

#[test]
fn cmux_next_remote_terminal_tab_is_a_stored_reference() {
    let mux = remote_mux("remote-terminal-tab");
    assert!(advertised_capabilities(false).contains(&REMOTE_TERMINAL_TABS_CAPABILITY));
    let identity = run(&mux, json!({"cmd":"identify"})).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|value| value == "remote-terminal-tabs-v1")
    );
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();

    let created = new_remote_tab(&mux, pane, None);
    let surface = created["surface"].as_u64().unwrap();
    assert_eq!(created["pane"], json!(pane));
    assert!(created["tab_resource_id"].as_str().unwrap().starts_with("tab_"));

    let tab = tab_of(&mux, surface);
    assert_eq!(tab["kind"], "remote-terminal");
    assert_eq!(tab["remote"]["session_id"], SESSION);
    assert_eq!(tab["remote"]["terminal_id"], TERMINAL);
    assert_eq!(tab["remote"]["session_name"], "build-box");
    assert_eq!(tab["title"], "Terminal on build-box");
    assert!(tab.get("terminal_id").is_none(), "{tab}");
    assert!(tab.get("terminal_resource_id").is_none(), "{tab}");
    assert!(tab["url"].is_null());
    assert!(tab["browser_renderer"].is_null());
    assert!(tab.get("snapshot").is_none() && tab["remote"].get("snapshot").is_none());

    // Title and session name changes are tab changes; a snapshot is not.
    let events = mux.subscribe();
    let updated = run(
        &mux,
        json!({"cmd":"update-remote-terminal-tab","surface":surface,"title":"cargo build"}),
    )
    .unwrap();
    assert_eq!(updated, json!({"surface": surface, "changed": true}));
    assert!(events.try_iter().any(|event| matches!(
        event,
        MuxEvent::TreeDelta(delta) if delta.kind == TreeDeltaKind::TabChanged && delta.surface == Some(surface)
    )));
    let tab = tab_of(&mux, surface);
    assert_eq!(tab["title"], "cargo build");

    let unchanged = run(
        &mux,
        json!({"cmd":"update-remote-terminal-tab","surface":surface,"title":"cargo build"}),
    )
    .unwrap();
    assert_eq!(unchanged["changed"], false);

    let snapshot = "$ cargo build\n   Compiling cmux v0.1.0\n";
    let events = mux.subscribe();
    let stored = run(
        &mux,
        json!({"cmd":"update-remote-terminal-tab","surface":surface,"snapshot":snapshot}),
    )
    .unwrap();
    assert_eq!(stored["changed"], true);
    assert!(
        !events.try_iter().any(|event| matches!(
            event,
            MuxEvent::TreeDelta(delta) if delta.surface == Some(surface)
        )),
        "a snapshot-only update emits no tree event"
    );
    let read = run(&mux, json!({"cmd":"remote-terminal-snapshot","surface":surface})).unwrap();
    assert_eq!(read, json!({"surface": surface, "snapshot": snapshot}));
    assert!(tab_of(&mux, surface).get("snapshot").is_none());

    let renamed = run(
        &mux,
        json!({"cmd":"update-remote-terminal-tab","surface":surface,"session_name":"build-box-2"}),
    )
    .unwrap();
    assert_eq!(renamed["changed"], true);
    assert_eq!(tab_of(&mux, surface)["remote"]["session_name"], "build-box-2");

    // Clearing: a null title falls back to the session name; a null snapshot clears it.
    run(&mux, json!({"cmd":"update-remote-terminal-tab","surface":surface,"title":null})).unwrap();
    assert_eq!(tab_of(&mux, surface)["title"], "Terminal on build-box-2");
    run(&mux, json!({"cmd":"update-remote-terminal-tab","surface":surface,"snapshot":null}))
        .unwrap();
    let read = run(&mux, json!({"cmd":"remote-terminal-snapshot","surface":surface})).unwrap();
    assert!(read["snapshot"].is_null());

    // The daemon never streams it.
    let attach = run(&mux, json!({"cmd":"attach-surface","surface":surface,"cols":80,"rows":24}));
    assert!(attach.is_err());
    // It is not a frontend browser, and a terminal is not a remote reference.
    assert!(
        run(&mux, json!({"cmd":"update-frontend-browser-tab","surface":surface,"title":"x"}))
            .is_err()
    );
    assert!(
        run(&mux, json!({"cmd":"update-remote-terminal-tab","surface":terminal,"title":"x"}))
            .is_err()
    );
    assert!(run(&mux, json!({"cmd":"remote-terminal-snapshot","surface":terminal})).is_err());
}

#[test]
fn cmux_next_remote_terminal_tab_validates_its_reference() {
    let mux = remote_mux("remote-terminal-validate");
    let terminal = mux.new_workspace(None, None).unwrap().id;
    let pane = mux.with_state(|state| state.pane_of(terminal)).unwrap();
    let base = json!({
        "cmd":"new-remote-terminal-tab",
        "pane": pane,
        "session_id": SESSION,
        "terminal_id": TERMINAL,
        "session_name": "build-box",
    });
    for (field, value) in [
        ("session_id", json!("not-a-uuid")),
        ("session_id", json!(SESSION.to_uppercase())),
        ("terminal_id", json!("term_5f0c3a9e2b7d4c1a8e6f0b3d2c1a9e8f")),
        ("terminal_id", json!("5F0C3A9E2B7D4C1A8E6F0B3D2C1A9E8F")),
        ("terminal_id", json!("abc")),
        ("session_name", json!("")),
        ("session_name", json!("build\nbox")),
        ("session_name", json!("x".repeat(256))),
    ] {
        let mut request = base.clone();
        request[field] = value.clone();
        assert!(run(&mux, request).is_err(), "accepted {field}={value}");
    }
    let before = mux.with_state(|state| state.panes[&pane].tabs.len());
    assert_eq!(mux.with_state(|state| state.panes[&pane].tabs.len()), before, "nothing created");

    let surface = run(&mux, base).unwrap()["surface"].as_u64().unwrap();
    let oversized = "x".repeat(65_537);
    assert!(
        run(
            &mux,
            json!({"cmd":"update-remote-terminal-tab","surface":surface,"snapshot":oversized}),
        )
        .is_err()
    );
    let limit = "x".repeat(65_536);
    run(&mux, json!({"cmd":"update-remote-terminal-tab","surface":surface,"snapshot":limit}))
        .unwrap();
    assert!(
        run(&mux, json!({"cmd":"update-remote-terminal-tab","surface":surface,"session_name":""}))
            .is_err()
    );
}

#[test]
fn cmux_next_remote_terminal_tab_moves_pins_and_closes_like_any_tab() {
    let mux = remote_mux("remote-terminal-moves");
    let first = mux.new_workspace(None, None).unwrap().id;
    let first_pane = mux.with_state(|state| state.pane_of(first)).unwrap();
    let second = mux.new_workspace(None, None).unwrap().id;
    let second_pane = mux.with_state(|state| state.pane_of(second)).unwrap();
    let second_workspace = surface_placement(&mux, second).0.unwrap();

    let surface = new_remote_tab(&mux, first_pane, Some("htop"))["surface"].as_u64().unwrap();
    run(&mux, json!({"cmd":"update-remote-terminal-tab","surface":surface,"snapshot":"load"}))
        .unwrap();

    run(&mux, json!({"cmd":"move-tab","surface":surface,"pane":second_pane,"index":0})).unwrap();
    assert_eq!(mux.with_state(|state| state.pane_of(surface)), Some(second_pane));
    assert_eq!(tab_of(&mux, surface)["kind"], "remote-terminal");

    run(&mux, json!({"cmd":"move-tab","surface":surface,"pane":first_pane,"index":1})).unwrap();
    let moved = run(
        &mux,
        json!({"cmd":"move-tab-to-workspace","surface":surface,"workspace":second_workspace}),
    )
    .unwrap();
    assert_eq!(moved["workspace"], json!(second_workspace));
    let tab = tab_of(&mux, surface);
    assert_eq!(tab["kind"], "remote-terminal");
    assert_eq!(tab["title"], "htop");
    let read = run(&mux, json!({"cmd":"remote-terminal-snapshot","surface":surface})).unwrap();
    assert_eq!(read["snapshot"], "load", "a move keeps the reference and its snapshot");

    run(&mux, json!({"cmd":"set-tab-pinned","surface":surface,"pinned":true})).unwrap();
    assert_eq!(tab_of(&mux, surface)["pinned"], true);

    let split = run(
        &mux,
        json!({"cmd":"move-tab-to-split","surface":surface,"pane":second_pane,"edge":"right"}),
    )
    .unwrap();
    assert_eq!(tab_of(&mux, surface)["kind"], "remote-terminal");
    assert_ne!(split["pane"], json!(second_pane));

    run(&mux, json!({"cmd":"close-surface","surface":surface})).unwrap();
    assert!(run(&mux, json!({"cmd":"remote-terminal-snapshot","surface":surface})).is_err());
    // The reference goes with its tab: a restart's presentation load skips
    // references whose placeholder content is tombstoned.
}

/// A terminal whose only view lives in another session's layout has no tab
/// on its own session: it is kept (`set-terminal-keep`) and attached by
/// identity. The app relies on this for remote-terminal tabs.
#[test]
fn cmux_next_kept_unplaced_terminal_attaches_by_identity_and_takes_geometry() {
    let mux = remote_mux("remote-terminal-unplaced");
    let _scratch = mux.new_workspace(Some("scratch".into()), Some((80, 24))).unwrap();
    let detached = mux.new_workspace(Some("detached".into()), Some((80, 24))).unwrap();
    let public_id = detached.terminal_public_id().cloned().expect("hosted terminal").to_string();
    // A remote-terminal reference names the terminal by its 32-hex host id;
    // keeping it by that id reports the public id the attach needs.
    let host_id = mux.resource_terminal_host_identity(&detached).unwrap().terminal_id;
    let kept =
        run(&mux, json!({"cmd":"set-terminal-keep","terminal_id":host_id,"keep":true})).unwrap();
    assert_eq!(kept["keep"], true);
    assert_eq!(kept["terminal_id"], json!(host_id));
    assert_eq!(kept["terminal_resource_id"], json!(public_id));
    let workspace = surface_placement(&mux, detached.id).0.unwrap();
    assert!(mux.close_workspace_at_revision(workspace, None).unwrap().is_some());
    assert!(mux.with_state(|state| state.pane_of(detached.id).is_none()), "no tab placement");

    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    // As the app does: a frontend with attach leases.
    run_as(
        &mux,
        client,
        json!({"cmd":"set-client-info","kind":"frontend","capabilities":["view-attachment-lease-v1"]}),
    )
    .unwrap();
    let attached = handle_command(
        &mux,
        client,
        Command::AttachSurface {
            surface: None,
            mode: None,
            cols: Some(100),
            rows: Some(30),
            expected_generation: Some(mux.registry_identity().1),
            expected_terminal_id: Some(public_id.clone()),
        },
        &writer,
    )
    .expect("a kept unplaced terminal attaches by identity");
    let initial: Value = serde_json::from_str(&outbound.try_pop().expect("vt-state")).unwrap();
    assert_eq!(initial["event"], "vt-state");
    let surface = initial["surface"].as_u64().expect("vt-state names a numeric surface");
    assert_eq!(
        Some(surface),
        mux.resource_surface_for_terminal(&TerminalPublicId::parse(public_id).unwrap())
    );

    run_as(
        &mux,
        client,
        json!({"cmd":"set-client-sizing","surface":surface,"enabled":true,"exclusive":true}),
    )
    .expect("the attached client claims geometry of the unplaced terminal");
    let lease = attached["lease"].as_str().expect("the attach returns a lease").to_string();
    run_as(
        &mux,
        client,
        json!({"cmd":"resize-attached-view","surface":surface,"lease":lease,"cols":120,"rows":40}),
    )
    .expect("the attached view resizes the unplaced terminal");
    let size = mux.surface(surface).unwrap().size();
    assert_eq!(size, (120, 40));
    disconnect_client(&mux, client, false);
    mux.shutdown();
}
