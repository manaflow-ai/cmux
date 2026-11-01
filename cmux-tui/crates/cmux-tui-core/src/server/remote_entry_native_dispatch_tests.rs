//! Exercise production admission, connection dispatch and operation policy.
use super::*;
use crate::server::agent_session_attach_tests::{FakeAcpmux, Fixture, SESSION};

fn call(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, mut frame: Value) -> Value {
    frame["id"] = json!(71);
    send(stream, &frame.to_string());
    // Subscription/attach events can precede the corresponding reply.
    loop {
        let reply = response(reader);
        if reply["id"] == json!(71) {
            return reply;
        }
    }
}

fn ok(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, frame: Value) -> Value {
    let reply = call(stream, reader, frame);
    assert_eq!(reply["ok"], json!(true), "{reply}");
    reply["data"].clone()
}

fn provision(entry: &Entry, stream: &mut UnixStream, reader: &mut BufReader<UnixStream>) -> u64 {
    let identity = ok(stream, reader, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"].as_array().unwrap().contains(&json!("agent-session-start-v1"))
    );
    assert!(identity["generation"].is_string());
    ok(
        stream,
        reader,
        json!({"cmd":"set-client-info", "name":"native-owner", "kind":"frontend",
        "capabilities":["agent-session-presence-v1", "workspace-registry-v1", "unsupported-feature-v1"]}),
    );
    ok(stream, reader, json!({"cmd":"subscribe", "tree_events":"deltas"}));
    ok(stream, reader, json!({"cmd":"list-workspaces"}));
    let workspace =
        ok(stream, reader, json!({"cmd":"create-workspace", "name":"Native first chat"}));
    let terminal = ok(
        stream,
        reader,
        json!({"cmd":"create-terminal", "workspace":workspace["workspace"],
        "cols":80, "rows":24}),
    );
    let tab = ok(
        stream,
        reader,
        json!({"cmd":"new-conversation-tab", "pane":terminal["pane"],
        "agent_session":{"host":format!("registry:{}", entry.mux.registry_identity().0), "harness":"claude"}}),
    );
    tab["surface"].as_u64().unwrap()
}

#[test]
fn native_owner_provisions_trusts_starts_and_attaches_first_chat_over_real_entry() {
    let fake = FakeAcpmux::start_with(
        "native-first",
        Fixture { start_folder_trusted: Some(true), ..Default::default() },
    );
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &native_stamp(Some(VmKind::Owner)));
    let surface = provision(&entry, &mut stream, &mut reader);
    let cwd = entry._directory.path().to_string_lossy().into_owned();
    ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"agent-session-trust", "surface":surface, "cwd":cwd}),
    );
    let started = ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"agent-session-start", "surface":surface,
        "cwd":cwd, "harness":"claude"}),
    );
    assert_eq!(started["session"], json!(SESSION));
    let methods: Vec<_> = (0..6).map(|_| fake.frame()["method"].clone()).collect();
    assert_eq!(
        methods,
        [
            json!("acp.trust.get"),
            json!("_acpmux/web_modes"),
            json!("_acpmux/harnesses"),
            json!("acp.trust.get"),
            json!("session/new"),
            json!("_acpmux/web_modes")
        ]
    );
    ok(&mut stream, &mut reader, json!({"cmd":"agent-session-attach", "surface":surface}));
    assert_eq!(fake.frame()["method"], json!("_acpmux/attach"));
    ok(&mut stream, &mut reader, json!({"cmd":"agent-session-detach", "surface":surface}));
    // The grant never promotes this connection to a generic local one.
    for frame in [
        json!({"cmd":"shutdown-daemon"}),
        json!({"cmd":"agent-session-proxy-bind"}),
        json!({"cmd":"new-conversation-tab", "page":"settings"}),
        json!({"protocol":"cmux.protocol/2", "op":"workspace.create", "id":"forged"}),
    ] {
        assert_eq!(call(&mut stream, &mut reader, frame)["error_code"], json!(REMOTE_DENIED));
    }
    // Mark revoked without the reconciler closing the stream: a later frame
    // must still fail its own live-principal check.
    entry.mux.remote_relay().revocation.lock().unwrap().record_revoked("inst_1");
    assert_eq!(
        call(&mut stream, &mut reader, json!({"cmd":"create-workspace"}))["error_code"],
        json!(REMOTE_DENIED)
    );
}

#[test]
fn native_owner_start_preserves_folder_trust() {
    let fake = FakeAcpmux::start_with(
        "native-untrusted",
        Fixture { start_folder_trusted: Some(false), ..Default::default() },
    );
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &native_stamp(Some(VmKind::Owner)));
    let surface = provision(&entry, &mut stream, &mut reader);
    let start = json!({"cmd":"agent-session-start", "surface":surface,
        "cwd":entry._directory.path().to_string_lossy(), "harness":"claude"});
    assert_eq!(
        call(&mut stream, &mut reader, start)["error_code"],
        json!("agent_session.untrusted_folder")
    );
    let methods: Vec<_> = (0..3).map(|_| fake.frame()["method"].clone()).collect();
    assert_eq!(
        methods,
        [json!("_acpmux/web_modes"), json!("_acpmux/harnesses"), json!("acp.trust.get")]
    );
}

#[test]
fn team_missing_role_and_legacy_stamps_cannot_enter_native_owner_dispatch() {
    let issued_at_ms =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis()
            as u64;
    let legacy = cmux_link::stamp::encode(
        &LinkPeer { install: "inst_1".into(), user: "42".into(), team: "team_a".into() },
        Some(StampCheck::LinkToken { issued_at_ms }),
    )
    .unwrap();
    for stamp in [native_stamp(None), native_stamp(Some(VmKind::Team)), legacy, STAMP.into()] {
        let fake = FakeAcpmux::start("native-denied");
        let entry = entry_with(true, Arc::new(FsGate), Some(true));
        entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
        entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
        let (mut stream, mut reader) = connect_as_link(&entry);
        send(&mut stream, &stamp);
        for frame in [
            json!({"cmd":"identify"}),
            json!({"cmd":"set-client-info", "vm_kind":"owner"}),
            json!({"cmd":"subscribe", "tree_events":"deltas"}),
            json!({"cmd":"list-workspaces"}),
            json!({"cmd":"create-workspace", "vm_kind":"owner"}),
            json!({"cmd":"create-terminal"}),
            json!({"cmd":"new-conversation-tab"}),
            json!({"cmd":"agent-inventory"}),
            json!({"cmd":"agent-session-start", "surface":1, "cwd":"/tmp", "vm_kind":"owner"}),
            json!({"cmd":"agent-session-trust", "surface":1, "cwd":"/tmp", "vm_kind":"owner"}),
            json!({"cmd":"agent-session-attach", "surface":1}),
            json!({"cmd":"agent-transfer-receive", "cwd":"/tmp", "manifest":{}, "vm_kind":"owner"}),
            json!({"cmd":"agent-transfer-finish", "receive_id":"fake", "vm_kind":"owner"}),
        ] {
            assert_eq!(call(&mut stream, &mut reader, frame)["error_code"], json!(REMOTE_DENIED));
        }
        fake.no_connection();
    }
}

#[test]
fn native_owner_transfer_uses_existing_guard() {
    let fake = FakeAcpmux::start("native-transfer");
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let home = entry._directory.path().to_path_buf();
    let cwd = home.join("work/project");
    std::fs::create_dir_all(&cwd).unwrap();
    entry.mux.set_agent_transfer_host(Some(agent_transfer::AgentTransferHost {
        cloud: true,
        home,
    }));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &native_stamp(Some(VmKind::Owner)));
    let manifest = json!({"schema":"acpmux.transfer.v1", "transferId":"xfer_src", "sessionId":"acp_moving",
        "files":[{"path":"events/0.ndjson", "size":3}], "session":{"sessionId":"acp_moving", "harness":"claude"}});
    let receive = json!({"cmd":"agent-transfer-receive", "cwd":cwd, "manifest":manifest});
    let mut forged = receive.clone();
    forged["guard"] = json!({"roots":["/"]});
    assert_eq!(
        call(&mut stream, &mut reader, forged)["error_code"],
        json!("agent_transfer.bad_request")
    );
    let received = ok(&mut stream, &mut reader, receive);
    assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_receive"));
    let finish = json!({"cmd":"agent-transfer-finish", "receive_id":received["receive_id"], "vm_kind":"owner"});
    ok(&mut stream, &mut reader, finish);
    assert_eq!(fake.frame()["method"], json!("_acpmux/transfer_finish"));
}

#[path = "remote_entry_native_terminal_tests.rs"]
mod terminal;
