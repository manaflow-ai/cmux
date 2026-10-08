use super::*;
use crate::SurfaceOptions;
use crate::resource::{ScreenPublicId, SplitPublicId, TabPublicId, WorkspacePublicId};
use crate::resource_screen::public_layout_document;
use crate::workspace_registry::{
    RegistryLayoutNode, RegistryPane, RegistryScreen, RegistryViewport, RegistryViewportColumn,
};

fn resource_request(
    mux: &Arc<Mux>,
    id: &str,
    operation: &str,
    params: Value,
    idempotency_key: Option<&str>,
) -> Value {
    let mut request = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params,
    });
    if let Some(idempotency_key) = idempotency_key {
        request["idempotency_key"] = Value::String(idempotency_key.to_string());
    }
    crate::resource_router::handle_resource_message(mux, &request.to_string()).unwrap()
}

#[test]
fn local_machine_service_exposes_only_public_opaque_ids() {
    let mux = Mux::new_for_test("dev", SurfaceOptions::default());
    let service = LocalResourceMachineService::new(Arc::downgrade(&mux));
    let result = service
        .dispatch(&ResourceMachineRequest {
            operation: ResourceOperation::MachineList,
            selectors: ResourceSelectors::default(),
            fields: Map::new(),
            idempotency_key: None,
            actor: crate::Actor::local_user(),
        })
        .unwrap();
    let machine = &result.as_array().unwrap()[0];
    assert!(machine["id"].as_str().unwrap().starts_with("machine_"));
    assert!(machine.get("key").is_none());
    assert!(machine.get("socket").is_none());
}

#[test]
fn injected_machine_service_is_the_router_boundary() {
    struct Fake;

    impl ResourceMachineService for Fake {
        fn dispatch(&self, request: &ResourceMachineRequest) -> Result<Value, ResourceError> {
            Ok(json!({"operation":request.operation}))
        }
    }

    let mux = Mux::new_for_test("dev", SurfaceOptions::default());
    mux.install_resource_machine_service(Arc::new(Fake)).unwrap();
    let result = mux
        .resource_machine_service()
        .dispatch(&ResourceMachineRequest {
            operation: ResourceOperation::MachineList,
            selectors: ResourceSelectors::default(),
            fields: Map::new(),
            idempotency_key: None,
            actor: crate::Actor::local_user(),
        })
        .unwrap();
    assert_eq!(result, json!({"operation":"machine.list"}));
    assert!(mux.install_resource_machine_service(Arc::new(Fake)).is_err());
}

#[test]
fn empty_session_snapshot_contains_only_public_identity_shapes() {
    let mux = Mux::new_for_test("dev", SurfaceOptions::default());
    let snapshot = public_session_snapshot(&mux).unwrap();
    assert!(snapshot["machine"]["id"].as_str().unwrap().starts_with("machine_"));
    assert!(snapshot["session"]["id"].as_str().unwrap().starts_with("session_"));
    assert_eq!(snapshot["workspaces"], json!([]));
    assert_eq!(snapshot["cursor"]["revision"], "0");
    assert!(snapshot.get("surface").is_none());
    assert!(snapshot.get("workspace_key").is_none());
}

#[test]
fn cloud_cwd_snapshot_presents_the_launch_directory_until_the_shell_reports() {
    // https://github.com/manaflow-ai/cmux/issues/10756: the daemon spawned
    // the shell in a known directory, and a shell that has not reported
    // (or never will, without shell integration) still presents it.
    let mux = Mux::new_for_test(
        "cloud-cwd-launch",
        SurfaceOptions { cwd: Some("/tmp".into()), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(Some("cwd".into()), None).unwrap();
    let terminal_id = surface.terminal_public_id().unwrap();
    let cwd = |mux: &Mux| {
        public_session_snapshot(mux).unwrap()["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .unwrap()["cwd"]
            .clone()
    };
    assert_eq!(cwd(&mux), "/tmp");
    // A report replaces the launch directory; an explicit clear removes the
    // directory instead of resurrecting the launch directory.
    surface.set_test_pwd(Some("file://localhost/srv/live".into()));
    assert_eq!(cwd(&mux), "/srv/live");
    surface.set_test_pwd(None);
    assert!(cwd(&mux).is_null());
    mux.shutdown();
}

/// A shell's first directory report is recorded on the reader thread and
/// committed later. Between the two, the terminal must still present its
/// launch directory, not nothing (new_terminals_default_to_the_daemon_launch_directory
/// failed with cwd None, 1 of 20 loaded runs on a Linux Testbox).
#[test]
fn launch_directory_stays_presented_while_the_first_report_is_uncommitted() {
    let mux = Mux::new_for_test(
        "cloud-cwd-uncommitted",
        SurfaceOptions { cwd: Some("/tmp".into()), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(Some("cwd".into()), None).unwrap();
    surface.set_test_pwd(Some("file://localhost/srv/reported".into()));
    assert_eq!(surface.presented_directory().as_deref(), Some("/tmp"));
    mux.shutdown();
}

#[test]
fn cloud_cwd_snapshot_follows_reported_directory_instead_of_launch_directory() {
    let mux = Mux::new_for_test(
        "cloud-cwd",
        SurfaceOptions { cwd: Some("/tmp".into()), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(Some("cwd".into()), None).unwrap();
    let terminal_id = surface.terminal_public_id().unwrap();
    for directory in ["/srv/first", "/srv/second"] {
        surface.set_test_pwd(Some(format!("file://localhost{directory}")));
        let snapshot = public_session_snapshot(&mux).unwrap();
        let terminal = snapshot["terminals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|terminal| terminal["id"] == terminal_id.as_str())
            .unwrap();
        assert_eq!(terminal["cwd"], directory);
    }
    mux.shutdown();
}

#[test]
fn cloud_cwd_changes_publish_ordered_terminal_deltas_and_clear_untrusted_reports() {
    let mux = Mux::new_for_test("cloud-cwd-events", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("cwd".into()), None).unwrap();
    let initial = public_session_snapshot(&mux).unwrap();
    let mut revision = initial["cursor"]["revision"].as_str().unwrap().parse::<u64>().unwrap();
    for raw in [
        Some("file://localhost/srv/one"),
        Some("file://localhost/srv/two"),
        Some("file://unrelated.invalid/Users/local"),
    ] {
        surface.set_test_pwd(raw.map(str::to_string));
        let snapshot = public_session_snapshot(&mux).unwrap();
        let page = mux.resource_events_after(revision).unwrap();
        assert_eq!(page.batches.len(), 1);
        let batch = &page.batches[0];
        assert_eq!(batch.previous_revision, revision);
        assert_eq!(batch.revision, revision + 1);
        assert_eq!(batch.changes[0]["resource"], "terminal");
        assert_eq!(batch.changes[0]["value"]["cwd"], snapshot["terminals"][0]["cwd"]);
        assert_eq!(batch.changes[0]["value"], snapshot["terminals"][0]);
        assert_eq!(snapshot["tabs"], initial["tabs"]);
        revision = batch.revision;
        let _ = public_session_snapshot(&mux).unwrap();
        assert!(mux.resource_events_after(revision).unwrap().batches.is_empty());
    }
    assert!(public_session_snapshot(&mux).unwrap()["terminals"][0]["cwd"].is_null());
    mux.shutdown();
}

#[cfg(unix)]
#[test]
fn cloud_cwd_live_osc7_reaches_snapshot_and_event_feed() {
    // A real PTY: the test runtime's placeholder surfaces never run
    // their command, so no OSC 7 would reach the parser.
    let mux = Mux::new(
        "cloud-cwd-osc",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                "printf '\\033]7;file://localhost/srv/live\\007'; read value".into(),
            ]),
            ..SurfaceOptions::default()
        },
    );
    let _surface = mux.new_workspace(Some("osc".into()), None).unwrap();
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let epoch = mux.resource_event_epoch();
        let snapshot = public_session_snapshot(&mux).unwrap();
        if snapshot["terminals"][0]["cwd"] == "/srv/live" {
            break;
        }
        let remaining = deadline.saturating_duration_since(std::time::Instant::now());
        assert!(!remaining.is_zero(), "OSC 7 cwd never reached the public graph");
        mux.wait_for_resource_event(epoch, remaining);
    }
    assert!(mux.resource_events_after(0).unwrap().batches.iter().any(|batch| {
        batch
            .changes
            .as_array()
            .unwrap()
            .iter()
            .any(|change| change["resource"] == "terminal" && change["value"]["cwd"] == "/srv/live")
    }));
    mux.shutdown();
}

#[cfg(unix)]
#[test]
fn cloud_cwd_live_osc7_clear_reaches_snapshot() {
    // A shell that reports a directory and later reports none (an empty
    // OSC 7, as when it leaves the host it described) must clear the
    // published cwd through the same incremental parser path.
    // A real PTY: the test runtime's placeholder surfaces never run
    // their command, so no OSC 7 would reach the parser.
    let mux = Mux::new(
            "cloud-cwd-osc-clear",
            SurfaceOptions {
                command: Some(vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    "printf '\\033]7;file://localhost/srv/live\\007'; read value; printf '\\033]7;\\007'; read value"
                        .into(),
                ]),
                ..SurfaceOptions::default()
            },
        );
    let surface = mux.new_workspace(Some("osc-clear".into()), None).unwrap();
    let wait_for_cwd = |expected: Option<&str>, message: &str| {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let epoch = mux.resource_event_epoch();
            let cwd = &public_session_snapshot(&mux).unwrap()["terminals"][0]["cwd"];
            let reached = match expected {
                Some(directory) => cwd == directory,
                None => cwd.is_null(),
            };
            if reached {
                break;
            }
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!remaining.is_zero(), "{message}");
            mux.wait_for_resource_event(epoch, remaining);
        }
    };
    wait_for_cwd(Some("/srv/live"), "OSC 7 cwd never reached the public graph");
    surface.write_bytes(b"\n").unwrap();
    wait_for_cwd(None, "an empty OSC 7 report never cleared the published cwd");
    mux.shutdown();
}

/// OSC 7501 program status (decision OSC-7501-PROGRAM-STATUS): the shell
/// example from the decision reaches the terminal resource as
/// `extra.program_status` on the snapshot and the event feed, a later report
/// replaces the record with base64-decoded text, and a clear removes it.
#[cfg(unix)]
#[test]
fn program_status_osc7501_reaches_snapshot_and_event_feed() {
    // A real PTY: the test runtime's placeholder surfaces never run their
    // command, so no OSC 7501 would reach the parser.
    let mux = Mux::new(
        "program-status-osc7501",
        SurfaceOptions {
            command: Some(vec![
                "/bin/sh".into(),
                "-c".into(),
                concat!(
                    "printf '\\033]7501;state=working:progress=40\\033\\\\'; read value; ",
                    "printf '\\033]7501;state=done:app=make:msg=SGk=\\033\\\\'; read value; ",
                    "printf '\\033]7501;state=clear\\033\\\\'; read value",
                )
                .into(),
            ]),
            ..SurfaceOptions::default()
        },
    );
    let surface = mux.new_workspace(Some("status".into()), None).unwrap();
    let wait_for_status = |reached: &dyn Fn(&Value) -> bool, message: &str| -> Value {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
        loop {
            let epoch = mux.resource_event_epoch();
            let terminal = public_session_snapshot(&mux).unwrap()["terminals"][0].clone();
            if reached(&terminal["extra"]["program_status"]) {
                return terminal;
            }
            let remaining = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!remaining.is_zero(), "{message}: {terminal}");
            mux.wait_for_resource_event(epoch, remaining);
        }
    };
    let working = wait_for_status(
        &|status| status[0]["state"] == "working",
        "the working report never reached the public graph",
    );
    let record = &working["extra"]["program_status"][0];
    assert_eq!(working["extra"]["program_status"].as_array().unwrap().len(), 1);
    assert_eq!(record["id"], "");
    assert_eq!(record["progress"], 40);
    assert!(record["kind"].is_null() && record["msg"].is_null() && record["app"].is_null());
    assert!(mux.resource_events_after(0).unwrap().batches.iter().any(|batch| {
        batch.changes.as_array().unwrap().iter().any(|change| {
            change["resource"] == "terminal"
                && change["value"]["extra"]["program_status"][0]["state"] == "working"
        })
    }));
    let working_hook_event = mux
        .session_journal_after(0, 512)
        .unwrap()
        .records
        .into_iter()
        .find(|record| {
            record.kind == "terminal.program_status"
                && record.payload["result"]["program_status_change"]["event"] == "report"
                && record.payload["result"]["program_status_change"]["record"]["state"] == "working"
        })
        .expect("a program status report must be visible to journal hooks");
    assert_eq!(working_hook_event.payload["result"]["program_status_change"]["record"]["id"], "");

    surface.write_bytes(b"\n").unwrap();
    let done = wait_for_status(
        &|status| status[0]["state"] == "done",
        "the done report never replaced the working record",
    );
    let record = &done["extra"]["program_status"][0];
    assert_eq!(record["msg"], "Hi");
    assert_eq!(record["app"], "make");
    assert!(record["progress"].is_null(), "a report replaces the whole record");

    surface.write_bytes(b"\n").unwrap();
    wait_for_status(&|status| status.is_null(), "the clear report never removed the record");
    let clear_hook_event = mux
        .session_journal_after(0, 512)
        .unwrap()
        .records
        .into_iter()
        .find(|record| {
            record.kind == "terminal.program_status"
                && record.payload["result"]["program_status_change"]["event"] == "clear"
        })
        .expect("a clear must be visible to journal hooks");
    assert_eq!(clear_hook_event.payload["result"]["program_status_change"]["id"], "");
    mux.shutdown();
}

#[test]
fn snapshot_uses_durable_terminal_state_before_runtime_adoption() {
    let mux = Mux::new_for_test("snapshot-before-adoption", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("restoring".into()), None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();

    mux.remove_surface_runtime_for_test(surface.id).unwrap();
    mux.remove_terminal_catalog_for_test(&terminal_id).unwrap();

    let snapshot = public_session_snapshot(&mux).unwrap();
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .expect("durable terminal remains visible while its runtime is not adopted");
    assert_eq!(terminal["cols"], 80);
    assert_eq!(terminal["rows"], 24);
    assert_eq!(terminal["lifecycle"], "running");

    // The daemon owns terminal lifecycle. A renderer snapshot must expose
    // each durable terminal exactly once even when its runtime is absent.
    let terminal_ids = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .map(|terminal| terminal["id"].as_str().expect("terminal id"))
        .collect::<HashSet<_>>();
    assert_eq!(terminal_ids.len(), snapshot["terminals"].as_array().unwrap().len());
}

#[test]
fn snapshot_keeps_exited_terminal_receipt_after_its_last_view_detaches() {
    let mux = Mux::new_for_test("snapshot-exited-receipt", SurfaceOptions::default());
    let surface = mux.new_workspace(Some("exiting".into()), None).unwrap();
    let terminal_id = surface.terminal_public_id().cloned().unwrap();

    surface.record_process_end_for_test(crate::terminal_host_protocol::TerminalExit::now(
        crate::terminal_host_protocol::TerminalExitOutcome::Exit { code: 0 },
    ));
    mux.surface_exited(surface.id);

    let snapshot = public_session_snapshot(&mux).unwrap();
    let terminal = snapshot["terminals"]
        .as_array()
        .unwrap()
        .iter()
        .find(|terminal| terminal["id"] == terminal_id.as_str())
        .expect("durable exit receipt remains publicly addressable until terminal.close");
    assert_eq!(terminal["lifecycle"], "exited");
    assert_eq!(terminal["tab_id"], Value::Null);
    assert_eq!(terminal["tab_ids"], json!([]));
    assert!(terminal["exit"].is_object());
    mux.shutdown();
}

#[test]
fn snapshot_cursor_and_auxiliary_values_share_one_durable_cut() {
    let mux = Mux::new_for_test("snapshot-cut", SurfaceOptions::default());
    let created = resource_request(
        &mux,
        "create",
        "workspace.create",
        json!({
            "machine":"current",
            "session":"current",
            "name":"snapshot cut",
            "initial_content":"terminal",
        }),
        Some("snapshot-cut-create"),
    );
    let terminal_id = created["result"]["value"]["terminal_id"].as_str().unwrap().to_string();
    resource_request(
        &mux,
        "agent-old",
        "agent.report",
        json!({
            "machine":"current",
            "session":"current",
            "terminal_id":terminal_id,
            "state":"working",
            "source":"hook",
            "source_session":"before",
        }),
        Some("snapshot-cut-agent-old"),
    );

    let (entered_tx, entered_rx) = std::sync::mpsc::sync_channel(0);
    let (release_tx, release_rx) = std::sync::mpsc::sync_channel(0);
    let snapshot_mux = mux.clone();
    let snapshot_thread = std::thread::spawn(move || {
        set_snapshot_before_projection_hook(move || {
            entered_tx.send(()).unwrap();
            release_rx.recv().unwrap();
        });
        public_session_snapshot(&snapshot_mux)
    });
    entered_rx.recv().unwrap();

    let agent = resource_request(
        &mux,
        "agent-new",
        "agent.report",
        json!({
            "machine":"current",
            "session":"current",
            "terminal_id":terminal_id,
            "state":"blocked",
            "source":"hook",
            "source_session":"after",
        }),
        Some("snapshot-cut-agent-new"),
    );
    let notification = resource_request(
        &mux,
        "notification",
        "notification.create",
        json!({
            "machine":"current",
            "session":"current",
            "title":"new durable notification",
            "body":"after snapshot entered",
            "level":"info",
            "terminal_id":terminal_id,
        }),
        Some("snapshot-cut-notification"),
    );
    resource_request(
        &mux,
        "defaults",
        "session.terminal_defaults.update",
        json!({
            "machine":"current",
            "session":"current",
            "foreground":"#123456",
            "complete":true,
        }),
        Some("snapshot-cut-defaults"),
    );
    let projection = resource_request(
        &mux,
        "projection",
        "frontend_projection.put",
        json!({
            "machine":"current",
            "session":"current",
            "frontend_projection":"projection_00000000000000000000000000000001",
            "frontend_id":"cmux-test",
            "window_id":"window-snapshot-cut",
            "generation":"launch-snapshot-cut",
            "projection":{"cut":"after"},
        }),
        Some("snapshot-cut-projection"),
    );
    let expected_revision = projection["result"]["revision"].clone();

    release_tx.send(()).unwrap();
    let snapshot = snapshot_thread.join().unwrap().unwrap();
    assert_eq!(snapshot["cursor"]["revision"], expected_revision);
    assert_eq!(snapshot["session"]["revision"], expected_revision);
    assert!(snapshot["agents"].as_array().unwrap().contains(&agent["result"]["value"]));
    assert!(
        snapshot["notifications"].as_array().unwrap().contains(&notification["result"]["value"])
    );
    assert!(
        snapshot["frontend_projections"]
            .as_array()
            .unwrap()
            .contains(&projection["result"]["value"])
    );
}

#[test]
fn layout_projection_preserves_nested_splits_stacks_and_viewport_columns() {
    let workspace_id = public_id::<WorkspacePublicId>("ws", 1);
    let screen_id = public_id::<ScreenPublicId>("screen", 2);
    let pane_a = public_id::<PanePublicId>("pane", 3);
    let pane_b = public_id::<PanePublicId>("pane", 4);
    let pane_c = public_id::<PanePublicId>("pane", 5);
    let tab_a = public_id::<TabPublicId>("tab", 6);
    let split_a = public_id::<SplitPublicId>("split", 7);
    let split_b = public_id::<SplitPublicId>("split", 8);
    let column_a = public_id::<SplitPublicId>("split", 9);
    let column_b = public_id::<SplitPublicId>("split", 10);
    let nested = RegistryLayoutNode::Split {
        split: split_a,
        direction: "right".into(),
        ratio: 0.4,
        first: Box::new(RegistryLayoutNode::Leaf { pane: pane_a.clone() }),
        second: Box::new(RegistryLayoutNode::Split {
            split: split_b,
            direction: "right".into(),
            ratio: 0.6,
            first: Box::new(RegistryLayoutNode::Leaf { pane: pane_b.clone() }),
            second: Box::new(RegistryLayoutNode::Stack {
                panes: vec![pane_c.clone()],
                expanded: pane_c.clone(),
            }),
        }),
    };
    let screen = RegistryScreen {
        public_id: screen_id.clone(),
        workspace_id,
        position: 0,
        name: Some("layout".into()),
        layout: nested.clone(),
        active_pane: pane_b.clone(),
        zoomed_pane: Some(pane_c.clone()),
        auto_layout: None,
        viewport: RegistryViewport {
            base_width: Some(0.4),
            columns: vec![
                RegistryViewportColumn::new(column_a.clone(), 0.4, nested, None, None),
                RegistryViewportColumn::new(
                    column_b.clone(),
                    0.6,
                    RegistryLayoutNode::Stack {
                        panes: vec![pane_c.clone()],
                        expanded: pane_c.clone(),
                    },
                    None,
                    None,
                ),
            ],
        },
    };
    let panes = [
        RegistryPane {
            public_id: pane_a.clone(),
            screen_id: screen_id.clone(),
            name: None,
            active_tab: Some(tab_a.clone()),
            creation_ordinal: 0,
        },
        RegistryPane {
            public_id: pane_b,
            screen_id: screen_id.clone(),
            name: None,
            active_tab: None,
            creation_ordinal: 1,
        },
        RegistryPane {
            public_id: pane_c.clone(),
            screen_id,
            name: None,
            active_tab: None,
            creation_ordinal: 2,
        },
    ];
    let tabs = vec![RegistryTab {
        name_source: Default::default(),
        name_revision: 0,
        public_id: tab_a.clone(),
        pane_id: pane_a,
        position: 0,
        content_id: ContentPublicId::Terminal(TerminalPublicId::random().unwrap()),
        name: None,
        browser_url: None,
        terminal_id: Some("hosted".into()),
    }];
    let tabs_by_pane = tabs_by_pane(&tabs);
    let panes_by_id = panes.iter().map(|pane| (&pane.public_id, pane)).collect::<HashMap<_, _>>();
    let layout = public_layout_document(&screen, &tabs_by_pane, &panes_by_id).unwrap();

    assert_eq!(layout["active_pane_id"], json!(screen.active_pane));
    assert_eq!(layout["zoomed_pane_id"], json!(pane_c));
    assert_eq!(layout["root"]["kind"], "viewport");
    assert_eq!(layout["root"]["columns"][0]["column_id"], json!(column_a));
    assert_eq!(layout["root"]["columns"][1]["column_id"], json!(column_b));
    assert_eq!(layout["root"]["columns"][0]["root"]["second"]["kind"], "split");
    assert_eq!(layout["root"]["columns"][0]["root"]["first"]["tab_ids"], json!([tab_a]));
    assert_eq!(layout["root"]["columns"][1]["root"]["kind"], "stack");
}

fn public_id<T>(prefix: &str, value: u128) -> T
where
    T: serde::de::DeserializeOwned,
{
    serde_json::from_value(json!(format!("{prefix}_{value:032x}"))).unwrap()
}
