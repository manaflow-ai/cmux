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
    let identity = ok(&mut stream, &mut reader, json!({"cmd":"identify"}));
    assert!(
        identity["capabilities"].as_array().unwrap().contains(&json!("agent-session-content-v1"))
    );
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
            json!({"cmd":"set-default-colors", "fg":"#ffffff"}),
            json!({"cmd":"new-tab", "pane":1}),
            json!({"cmd":"close-surface", "surface":1}),
            json!({"cmd":"send-key", "surface":1, "key":"enter"}),
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
    entry
        .mux
        .set_agent_transfer_host(Some(agent_transfer::AgentTransferHost { cloud: true, home }));
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

/// A Cloud chat's folder copy reaches the owner's own machine over the owner's Native dial: its
/// file, seed and repo frames pass the entry (answered by fs_wire, here `fs.unavailable` with no
/// file owner installed), and identify on that carrier may list their capabilities. A team or
/// unverified Native dial is refused every one of them, as a line and as a byte-stream dial.
#[test]
fn native_data_frames_reach_only_the_owner() {
    let frames = [
        json!({"cmd":"fs.stat", "path":"/home/cmux/work"}),
        json!({"cmd":"fs.list", "path":"/home/cmux/work"}),
        json!({"cmd":"fs.write", "path":"/home/cmux/work/a", "data":""}),
    ];
    for role in [Some(VmKind::Owner), Some(VmKind::Team), None] {
        let entry = entry_with(true, Arc::new(FsGate), Some(true));
        let (mut stream, mut reader) = connect_as_link(&entry);
        send(&mut stream, &native_stamp(role));
        for frame in &frames {
            let reply = call(&mut stream, &mut reader, frame.clone());
            if role == Some(VmKind::Owner) {
                assert_ne!(reply["error_code"], json!(REMOTE_DENIED), "{role:?} {frame} {reply}");
            } else {
                assert_eq!(reply["error_code"], json!(REMOTE_DENIED), "{role:?} {frame} {reply}");
            }
        }
    }
    for frame in &frames {
        let line = frame.to_string();
        assert!(fs_wire::native_dial_admits(Some(Some(VmKind::Owner)), &line));
        assert!(fs_wire::native_dial_admits(None, &line), "a classic dial keeps its gate");
        assert!(!fs_wire::native_dial_admits(Some(Some(VmKind::Team)), &line));
        assert!(!fs_wire::native_dial_admits(Some(None), &line));
    }
    // Other frames keep the gate's answer on every dial.
    assert!(fs_wire::native_dial_admits(Some(Some(VmKind::Team)), r#"{"cmd":"identify"}"#));
    for capability in [
        crate::fs_ops::FS_CAPABILITY,
        crate::fs_ops::FS_SYMLINK_CAPABILITY,
        crate::fs_ops::FS_WRITE_DEFLATE_CAPABILITY,
        crate::fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY,
        crate::git_seed::GIT_SEED_CAPABILITY,
        crate::git_seed::GIT_SEED_EXPORT_CAPABILITY,
        crate::blob_fetch::BLOB_FETCH_CAPABILITY,
    ] {
        assert!(native_owner::carries(capability), "{capability}");
    }
}

#[path = "remote_entry_native_terminal_tests.rs"]
mod terminal;

/// Every command the app sends on connect and chat start reaches the owner: the terminal theme
/// (`set-default-colors`) was refused with remote_denied over the Native owner link (2026-11-05).
#[test]
fn native_owner_takes_the_apps_connect_commands() {
    assert!(native_owner::commands().contains(&"set-default-colors"));
    let fake = FakeAcpmux::start("native-colors");
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &native_stamp(Some(VmKind::Owner)));
    let reply = call(&mut stream, &mut reader, json!({"cmd":"set-default-colors", "fg":"#ffffff", "bg":"#000000"}));
    assert_ne!(reply["error_code"], json!(REMOTE_DENIED), "{reply}");
    assert_eq!(reply["ok"], json!(true), "{reply}");
}

/// `cmux cloud ssh` on the owner's machine: new-tab opens a terminal, and typing into it reaches it
/// (2026-11-05: "open Cloud SSH terminal: new-tab failed: remote_denied").
#[test]
fn native_owner_opens_a_terminal_tab_and_types_into_it() {
    let fake = FakeAcpmux::start("native-terminal-tab");
    let entry = entry_with(true, Arc::new(FsGate), Some(true));
    entry.mux.set_acpmux_socket(Some(fake.socket.clone()));
    entry.mux.set_agent_start_host(Arc::new(|| AgentStartHost::OwnerCloud));
    let (mut stream, mut reader) = connect_as_link(&entry);
    send(&mut stream, &native_stamp(Some(VmKind::Owner)));
    let workspace = ok(&mut stream, &mut reader, json!({"cmd":"create-workspace", "name":"ssh"}));
    let terminal = ok(
        &mut stream,
        &mut reader,
        json!({"cmd":"create-terminal", "workspace":workspace["workspace"], "cols":80, "rows":24}),
    );
    let tab = call(&mut stream, &mut reader, json!({"cmd":"new-tab", "pane":terminal["pane"]}));
    assert_ne!(tab["error_code"], json!(REMOTE_DENIED), "{tab}");
    assert_eq!(tab["ok"], json!(true), "{tab}");
    let listed = call(&mut stream, &mut reader, json!({"cmd":"list-terminals"}));
    assert_ne!(listed["error_code"], json!(REMOTE_DENIED), "{listed}");
}

/// The app's commands that the Native owner carrier does not take: each one is a decision, not an
/// omission. A command the app adds must land in `native_owner::COMMANDS` or here, else
/// `every_app_command_is_decided_for_the_owner_link` fails (2026-11-05: new-tab and
/// set-default-colors were simply missing, and `cmux cloud ssh` met remote_denied).
const NOT_OVER_NATIVE_OWNER: &[&str] = &[
    "ack-tab-notifications",
    "add-screens-to-screen-group",
    "add-tabs-to-tab-group",
    "agent-cli-update-job",
    "agent-session-share-create",
    "agent-session-share-invite",
    "agent-session-share-kick",
    "agent-session-share-list",
    "agent-session-share-revoke",
    "agent-session-share-room",
    "agent-session-share-uninvite",
    "apps-agent-inventory-changed",
    "apps-dispatch",
    "apps-link-changed",
    "apps-list",
    "apps-logs",
    "apps-mount",
    "apps-provider-register",
    "apps-provider-result",
    "apps-run",
    "apps-set",
    "apps-store",
    "apps-terminal-links",
    "apps-unmount",
    "browser-host-provider",
    "client-hello",
    "close-screen",
    "close-screen-group",
    "close-tab-group",
    "close-workspace",
    "create-bookmark",
    "create-browser-profile",
    "create-personal-group",
    "create-profile",
    "create-screen-group",
    "create-tab-group",
    "delete-bookmark",
    "delete-browser-profile",
    "delete-personal-group",
    "delete-profile",
    "delete-saved-screen-group",
    "delete-saved-tab-group",
    "delete-terminal-commands",
    "feed-local-handoff-abort",
    "feed-local-handoff-begin",
    "feed-local-handoff-done",
    "feed-local-list",
    "forget-session",
    "get-blob",
    "get-frontend-browser-history",
    "get-frontend-projection",
    "import-bookmarks",
    "import-session-organization",
    "list-agents",
    "list-bookmarks",
    "list-notifications",
    "list-personal",
    "list-saved-screen-groups",
    "list-saved-tab-groups",
    "list-tab-groups",
    "list-terminal-commands",
    "machine-catalog-publish",
    "machine-listening-tcp",
    "mobile-chat-history",
    "mobile-chat-send",
    "mobile-chat-sessions",
    "move-bookmark",
    "move-browser-profile",
    "move-column",
    "move-personal-group",
    "move-profile",
    "move-screen",
    "move-screen-group",
    "move-tab-group",
    "move-tab-group-to-column",
    "move-tab-group-to-new-workspace",
    "move-tab-group-to-split",
    "move-tab-to-column",
    "move-tab-to-new-workspace",
    "move-tab-to-split",
    "move-tab-to-workspace",
    "move-workspace",
    "new-frontend-browser-tab",
    "new-remote-terminal-tab",
    "new-screen",
    "notify",
    "page-credential",
    "pairing-response",
    "park-tabs",
    "pin-workspace",
    "process-info",
    "put-blob",
    "put-frontend-projection",
    "put-session",
    "remote-host-app",
    "remote-host-call",
    "remote-host-config",
    "remote-host-status",
    "remote-terminal-snapshot",
    "remove-screens-from-screen-group",
    "remove-tabs-from-tab-group",
    "rename-screen",
    "reopen-saved-screen-group",
    "reopen-saved-tab-group",
    "report-agent",
    "save-screen-group",
    "save-tab-group",
    "set-column-dock",
    "set-frontend-browser-history",
    "set-personal-workspace",
    "set-profile-follows",
    "set-screen-metadata",
    "set-screen-pinned",
    "set-session-icon",
    "set-terminal-command-history",
    "set-terminal-keep",
    "set-workspace-metadata",
    "shutdown-daemon",
    "terminal-resources",
    "terminal-resume-command",
    "ungroup-screen-group",
    "ungroup-tab-group",
    "unpin-workspace",
    "unsave-screen-group",
    "unsave-tab-group",
    "update-bookmark",
    "update-browser-profile",
    "update-frontend-browser-tab",
    "update-personal-group",
    "update-profile",
    "update-remote-terminal-tab",
    "update-screen-group",
    "update-tab-group",
    "wait-for",
    "ws-listen",
];

/// Contract: every command the app's daemon client declares (`static let command = "..."` under
/// CmuxNextDaemon/Requests) is either taken by the owner carrier or listed above.
#[test]
fn every_app_command_is_decided_for_the_owner_link() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Sources/CmuxNextDaemon/Requests");
    if !root.is_dir() {
        eprintln!("skipped: {} is not in this checkout", root.display());
        return;
    }
    let mut stack = vec![root];
    let mut undecided = Vec::new();
    let mut seen = 0;
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).unwrap().flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            if path.extension().is_none_or(|ext| ext != "swift") {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap();
            for line in text.lines() {
                let Some((_, rest)) = line.split_once("static let command = \"") else { continue };
                let Some((command, _)) = rest.split_once('"') else { continue };
                seen += 1;
                let decided = native_owner::commands().contains(&command)
                    || NOT_OVER_NATIVE_OWNER.contains(&command)
                    || command.starts_with("fs.");
                if !decided {
                    undecided.push(format!("{command} ({})", path.display()));
                }
            }
        }
    }
    assert!(seen > 100, "read only {seen} app commands");
    assert!(undecided.is_empty(), "decide each for the owner link: {undecided:?}");
}
