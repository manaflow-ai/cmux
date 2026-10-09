use super::*;
use crate::SurfaceOptions;

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
