//! The GUI TerminalAttachment protocol through the production Native entry.
use super::*;
use base64::Engine as _;

fn terminal(entry: &Entry, stream: &mut UnixStream, reader: &mut BufReader<UnixStream>) -> u64 {
    let identity = ok(stream, reader, json!({"cmd":"identify"}));
    let capabilities = identity["capabilities"].as_array().unwrap();
    for cap in [
        "view-attachment-lease-v1",
        "view-attachment-detach-v1",
        "attach-initial-size",
        "shared-sizing-v1",
        "attach-identity-v1",
    ] {
        assert!(capabilities.contains(&json!(cap)), "missing {cap}");
    }
    ok(
        stream,
        reader,
        json!({"cmd":"set-client-info", "name":"Native terminal", "kind":"frontend",
        "device_kind":"desktop", "device_name":"Synthetic Mac",
        "capabilities":["view-attachment-lease-v1", "view-attachment-detach-v1", "shared-sizing-v1"]}),
    );
    let workspace = ok(stream, reader, json!({"cmd":"create-workspace", "name":"Native terminal"}));
    let created = ok(
        stream,
        reader,
        json!({"cmd":"create-terminal", "workspace":workspace["workspace"], "cols":80, "rows":24}),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(entry.mux.surface(surface).is_some());
    surface
}

fn attach(
    entry: &Entry,
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    surface: u64,
    snapshot: bool,
) -> Value {
    let runtime = entry.mux.surface(surface).unwrap();
    let mut frame = json!({"cmd":"attach-surface", "mode":"bytes", "cols":80, "rows":24,
        "expected_generation":entry.mux.registry_identity().1,
        "expected_terminal_id":runtime.terminal_public_id().unwrap().as_str()});
    if snapshot {
        frame["snapshot"] = json!("ghostsnp");
        frame["snapshot_version"] = json!(ghostty_vt::snapshot_version());
    }
    ok(stream, reader, frame)["lease"].clone()
}

#[test]
fn native_terminal_attaches_streams_input_and_output_resizes_and_detaches() {
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &native_stamp(Some(VmKind::Owner)));
    let surface = terminal(&entry, &mut stream, &mut reader);
    let bytes = base64::engine::general_purpose::STANDARD.encode(b"echo native-terminal\n");
    let input = json!({"cmd":"send", "surface":surface, "bytes":bytes});
    assert_eq!(
        call(&mut stream, &mut reader, input.clone())["error_code"],
        json!(REMOTE_DENIED),
        "input needs this connection's attach"
    );
    let lease = attach(&entry, &mut stream, &mut reader, surface, false);
    assert!(lease.is_string());
    ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"set-client-sizing", "surface":surface, "enabled":true, "exclusive":true}),
    );
    ok(&mut stream, &mut reader, input.clone());
    entry.mux.surface(surface).unwrap().inject_output_for_test(b"native-output-marker\r\n");
    let mut output = Vec::new();
    loop {
        let frame = response(&mut reader);
        if frame["event"] == "output" {
            output.extend(
                base64::engine::general_purpose::STANDARD
                    .decode(frame["data"].as_str().unwrap())
                    .unwrap(),
            );
            if String::from_utf8_lossy(&output).contains("native-output-marker") {
                break;
            }
        }
    }
    let resized = ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"resize-attached-view", "surface":surface, "lease":lease, "cols":100, "rows":32}),
    );
    assert_eq!(resized["accepted"], json!(true));
    ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"resize-surface", "surface":surface, "cols":101, "rows":33}),
    );
    ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"set-size-policy", "surface":surface, "policy":{"mode":"latest"}}),
    );
    for counts in [json!(false), Value::Null] {
        ok(
            &mut stream,
            &mut reader,
            json!({"cmd":"set-size-counts", "surface":surface, "lease":lease, "counts":counts}),
        );
    }
    ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"release-attached-view-size", "surface":surface, "lease":lease}),
    );
    let detach = json!({"cmd":"detach-attached-view", "surface":surface, "lease":lease});
    ok(&mut stream, &mut reader, detach.clone());
    assert_eq!(ok(&mut stream, &mut reader, detach)["outcome"], json!("superseded"));
    assert_eq!(call(&mut stream, &mut reader, input)["error_code"], json!(REMOTE_DENIED));
    let snapshot_lease = attach(&entry, &mut stream, &mut reader, surface, true);
    assert!(snapshot_lease.is_string());
    ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"snapshot-request", "surface":surface, "reason":"gap"}),
    );
    entry.mux.remote_relay().revocation.lock().unwrap().record_revoked("inst_1");
    assert_eq!(
        call(
            &mut stream,
            &mut reader,
            json!({"cmd":"send", "surface":surface, "text":"forbidden"})
        )["error_code"],
        json!(REMOTE_DENIED)
    );
}

#[test]
fn native_terminal_keeps_foreign_leases_browser_and_other_client_controls_denied() {
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let (mut first, mut first_reader) = connect_as_link(&entry);
    send(&mut first, &native_stamp(Some(VmKind::Owner)));
    let surface = terminal(&entry, &mut first, &mut first_reader);
    let foreign = attach(&entry, &mut first, &mut first_reader, surface, false);
    let (mut second, mut second_reader) = connect_as_link(&entry);
    send(&mut second, &native_stamp(Some(VmKind::Owner)));
    ok(
        &mut second,
        &mut second_reader,
        json!({"cmd":"set-client-info", "capabilities":["view-attachment-lease-v1"]}),
    );
    let _own = attach(&entry, &mut second, &mut second_reader, surface, false);
    for frame in [
        json!({"cmd":"resize-attached-view", "surface":surface, "lease":foreign, "cols":2, "rows":2}),
        json!({"cmd":"detach-attached-view", "surface":surface, "lease":foreign}),
        json!({"cmd":"set-size-counts", "surface":surface, "lease":foreign, "counts":false}),
        json!({"cmd":"set-client-sizing", "surface":surface, "client":1, "enabled":true, "exclusive":true}),
        json!({"cmd":"set-size-policy", "workspace":1, "policy":{"mode":"latest"}}),
        json!({"cmd":"resize-attached-view", "surface":surface, "view":"other", "cols":2, "rows":2}),
        json!({"cmd":"attach-surface", "surface":surface, "mode":"render"}),
    ] {
        assert_eq!(call(&mut second, &mut second_reader, frame)["ok"], json!(false));
    }
    for policy in [
        Value::Null,
        json!({}),
        json!({"mode":"smallest"}),
        json!({"mode":"largest"}),
        json!({"mode":"priority", "priority":["another-participant"]}),
        json!({"mode":"fixed", "fixed":{"cols":2, "rows":2}}),
        json!({"mode":"latest", "priority":["another-participant"]}),
        json!({"mode":"latest", "fixed":{"cols":2, "rows":2}}),
        json!({"mode":"latest", "participant":"another-participant"}),
        json!({"mode":"latest", "client":1}),
        json!({"mode":"latest", "candidates":["another-participant"]}),
    ] {
        let frame = json!({"cmd":"set-size-policy", "surface":surface, "policy":policy});
        assert_eq!(
            call(&mut second, &mut second_reader, frame)["error_code"],
            json!(REMOTE_DENIED)
        );
    }
    assert_eq!(
        call(
            &mut second,
            &mut second_reader,
            json!({"cmd":"set-size-policy", "surface":surface, "client":1, "policy":{"mode":"latest"}})
        )["error_code"],
        json!(REMOTE_DENIED)
    );
    // An actual agent browser surface is not a terminal attachment target.
    let tab = crate::server::agent_session_attach_tests::agent_tab(&entry.mux, None);
    assert_eq!(
        call(
            &mut second,
            &mut second_reader,
            json!({"cmd":"attach-surface", "surface":tab, "mode":"bytes"})
        )["error_code"],
        json!(REMOTE_DENIED)
    );
}

#[test]
fn native_terminal_team_missing_and_legacy_cannot_attach_or_write_with_owner_claim() {
    for stamp in [native_stamp(None), native_stamp(Some(VmKind::Team)), STAMP.into()] {
        let entry = entry_with(true, Arc::new(FsGate), Some(true));
        entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
        let surface = entry.mux.new_workspace(None, None).unwrap().id;
        let (mut stream, mut reader) = connect_as_link(&entry);
        send(&mut stream, &stamp);
        for mut frame in [
            json!({"cmd":"attach-surface", "surface":surface, "mode":"bytes"}),
            json!({"cmd":"send", "surface":surface, "text":"forbidden"}),
            json!({"cmd":"resize-surface", "surface":surface, "cols":2, "rows":2}),
            json!({"cmd":"set-client-sizing", "surface":surface, "enabled":true, "exclusive":true}),
        ] {
            frame["vm_kind"] = json!("owner");
            assert_eq!(call(&mut stream, &mut reader, frame)["error_code"], json!(REMOTE_DENIED));
        }
    }
}
