use super::*;

#[test]
fn terminal_bytes_service_uses_the_versioned_wire_name() {
    let encoded = serde_json::to_value(Service::TerminalBytes).unwrap();
    assert_eq!(encoded, "terminal-bytes-v1");
    assert_eq!(serde_json::from_value::<Service>(encoded).unwrap(), Service::TerminalBytes);
}

#[test]
fn process_handle_spawn_has_a_stable_wire_shape() {
    let request = WorkspaceRequest::SpawnProcessWithHandle {
        process: ProcessId::from_u128(0x5a17),
        workspace: WorkspaceId("w".into()),
        argv: vec!["/bin/sh".into()],
        cwd: None,
        env: BTreeMap::new(),
        io: ProcessIo::Pipes { stdin: false },
        lifetime: ProcessLifetime::Workspace,
        operation: None,
        timeout_ms: None,
        retained_output_bytes: Some(1024),
        environment: ProcessEnvironment::Clean,
        output_drain_idle_timeout_ms: Some(750),
        output_drain_total_timeout_ms: Some(2_500),
    };

    let json = serde_json::to_value(request).unwrap();
    assert_eq!(json["type"], "spawn-process-with-handle");
    assert_eq!(json["process"], "00000000-0000-0000-0000-000000005a17");
    assert_eq!(json["retained_output_bytes"], 1024);
    assert_eq!(json["environment"], "clean");
    assert_eq!(json["output_drain_idle_timeout_ms"], 750);
    assert_eq!(json["output_drain_total_timeout_ms"], 2_500);
}

#[test]
fn process_catalog_and_terminal_snapshot_have_stable_wire_shapes() {
    let process = ProcessId::from_u128(0x5a17);
    let descriptor = ProcessDescriptor {
        process,
        workspace: WorkspaceId("workspace-a".into()),
        command_label: "bash".into(),
        display_argv: vec!["/bin/bash".into(), "-l".into()],
        display_argv_truncated: false,
        cwd: "/srv/project".into(),
        lifetime: ProcessLifetime::Detached,
        operation: None,
        pid: Some(42),
        io: ProcessIoKind::Pty,
        pty_size: Some(ProcessTerminalSize { cols: 120, rows: 40 }),
        state: ProcessState::Running,
        replay: ProcessReplayRange { first_available: Some(7), last_produced: 12, exited: false },
    };
    let response = WorkspaceResponse::Processes { processes: vec![descriptor] };
    let json = serde_json::to_value(response).unwrap();
    assert_eq!(json["type"], "processes");
    assert_eq!(json["processes"][0]["process"], process.to_string());
    assert_eq!(json["processes"][0]["io"], "pty");
    assert_eq!(json["processes"][0]["state"]["type"], "running");
    assert!(
        !json["processes"][0].as_object().unwrap().keys().any(|key| key.contains("env")),
        "catalog descriptors must never grow an environment field"
    );

    let snapshot = ProcessTerminalSnapshot {
        process,
        size: ProcessTerminalSize { cols: 4, rows: 1 },
        rows: vec![ProcessTerminalRow {
            row: 0,
            runs: vec![ProcessTerminalStyledRun {
                text: "cmux".into(),
                fg: Some(ProcessTerminalColor { r: 255, g: 0, b: 0 }),
                bg: None,
                attrs: 1,
                underline: Some(ProcessTerminalUnderline::Single),
                width_hint: None,
            }],
        }],
        cursor: ProcessTerminalCursor {
            x: 3,
            y: 0,
            style: ProcessTerminalCursorStyle::Block,
            blink: false,
            visible: true,
            color: None,
        },
        default_fg: ProcessTerminalColor { r: 255, g: 255, b: 255 },
        default_bg: ProcessTerminalColor { r: 0, g: 0, b: 0 },
        scrollback_rows: 2,
        through_sequence: 19,
    };
    let json =
        serde_json::to_value(WorkspaceResponse::ProcessTerminalSnapshot { snapshot }).unwrap();
    assert_eq!(json["type"], "process-terminal-snapshot");
    assert_eq!(json["snapshot"]["through_sequence"], 19);
    assert_eq!(json["snapshot"]["rows"][0]["runs"][0]["underline"], "single");

    assert_eq!(
        serde_json::to_value(WorkspaceRequest::ListProcesses).unwrap()["type"],
        "list-processes"
    );
    assert_eq!(
        serde_json::to_value(WorkspaceRequest::SnapshotProcessTerminal { process }).unwrap()["type"],
        "snapshot-process-terminal"
    );
    assert_eq!(
        serde_json::to_value(RemoteCapability::ProcessCatalogV1).unwrap(),
        "process-catalog-v1"
    );
    assert_eq!(
        serde_json::to_value(RemoteCapability::ProcessTerminalSnapshotV1).unwrap(),
        "process-terminal-snapshot-v1"
    );
}

#[test]
fn terminal_viewer_size_priority_capability_uses_its_wire_name() {
    assert_eq!(
        serde_json::to_value(RemoteCapability::TerminalViewerSizePriorityV1).unwrap(),
        "terminal-viewer-size-priority-v1"
    );
    let decoded: RemoteCapability =
        serde_json::from_value(serde_json::json!("terminal-viewer-size-priority-v1")).unwrap();
    assert_eq!(decoded, RemoteCapability::TerminalViewerSizePriorityV1);
}

#[test]
fn remote_capabilities_round_trip_known_and_unknown_wire_values() {
    let known: RemoteCapability =
        serde_json::from_value(serde_json::json!("process-catalog-v1")).unwrap();
    assert_eq!(known, RemoteCapability::ProcessCatalogV1);
    assert_eq!(serde_json::to_value(known).unwrap(), "process-catalog-v1");

    let unknown_wire_value = "workspace-files-v99";
    let unknown: RemoteCapability =
        serde_json::from_value(serde_json::json!(unknown_wire_value)).unwrap();
    assert_eq!(unknown, RemoteCapability::Unknown(unknown_wire_value.to_owned()));
    assert_eq!(serde_json::to_value(unknown).unwrap(), unknown_wire_value);

    let response: WorkspaceResponse = serde_json::from_value(serde_json::json!({
        "type": "capabilities",
        "capabilities": ["process-catalog-v1", unknown_wire_value]
    }))
    .unwrap();
    assert!(matches!(
        response,
        WorkspaceResponse::Capabilities { capabilities }
            if capabilities == vec![
                RemoteCapability::ProcessCatalogV1,
                RemoteCapability::Unknown(unknown_wire_value.to_owned())
            ]
    ));
}
