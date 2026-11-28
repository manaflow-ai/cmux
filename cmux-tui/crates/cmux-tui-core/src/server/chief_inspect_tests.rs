//! `chief-inspect`: the Chief memory inspector's read-only API, forwarded to
//! the brain host's tools socket, for the owner's trusted connection only
//! (a local Unix client, or the link's owner_session splice). Memory holds
//! private conversations: a link-stamped, relayed, unregistered or
//! agent-bound connection is refused before anything is forwarded.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::super::*;
use super::{CAPABILITY, Params, inspect_with};

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

/// A fake brain tools socket: answers each `inspect` line with `reply` and
/// counts the requests it got.
fn tools_socket(reply: Value) -> (cmux_unix_socket::TestDir, PathBuf, Arc<AtomicUsize>) {
    let dir = cmux_unix_socket::short_test_dir("chinsp");
    let path = dir.path().join("tools.sock");
    let listener = UnixListener::bind(&path).unwrap();
    let seen = Arc::new(AtomicUsize::new(0));
    let counter = seen.clone();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let mut out = conn.try_clone().unwrap();
            let mut line = String::new();
            if BufReader::new(conn).read_line(&mut line).is_ok() {
                let req: Value = serde_json::from_str(&line).unwrap_or(Value::Null);
                assert_eq!(req["tool"], "inspect");
                counter.fetch_add(1, Ordering::SeqCst);
                let _ = writeln!(out, "{reply}");
            }
        }
    });
    (dir, path, seen)
}

fn params(path: &str) -> Params {
    serde_json::from_value(json!({"path": path, "query": {"name": "0+8"}})).unwrap()
}

#[test]
fn the_owner_connection_gets_the_brain_answer() {
    let mux = Mux::new_for_test("chief-inspect", crate::SurfaceOptions::default());
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    let (_dir, sock, seen) = tools_socket(json!({"status": 200, "body": {"name": "0+8"}}));
    let got = inspect_with(&mux, owner, params("/api/node"), Some(&sock)).unwrap();
    assert_eq!(got, json!({"status": 200, "body": {"name": "0+8"}}));
    assert_eq!(seen.load(Ordering::SeqCst), 1);
}

#[test]
fn a_link_stamped_or_relayed_connection_is_refused_before_any_forward() {
    let mux = Mux::new_for_test("chief-inspect", crate::SurfaceOptions::default());
    let remote = mux.control_clients.register(ClientTransport::Remote, writer());
    let socket = mux.control_clients.register(ClientTransport::WebSocket, writer());
    let (_dir, sock, seen) = tools_socket(json!({"status": 200, "body": {}}));
    for client in [remote, socket, 9_999] {
        let error = inspect_with(&mux, client, params("/api/status"), Some(&sock)).unwrap_err();
        assert_eq!(response_error_code(&error).as_deref(), Some("origin.forbidden"), "{error}");
    }
    assert_eq!(seen.load(Ordering::SeqCst), 0, "nothing reached the brain");
}

#[test]
fn an_agent_bound_connection_is_refused() {
    let mux = Mux::new_for_test("chief-inspect", crate::SurfaceOptions::default());
    let user = mux.control_clients.register(ClientTransport::Unix, writer());
    let minted = handle_command(
        &mux,
        user,
        serde_json::from_value(json!({"cmd":"conversation-agent-token","participant":"agent_mux"}))
            .unwrap(),
        &writer(),
    )
    .unwrap();
    let agent = mux.control_clients.register(ClientTransport::Unix, writer());
    handle_command(
        &mux,
        agent,
        serde_json::from_value(
            json!({"cmd":"conversation-bind","participant":"agent_mux","token":minted["token"]}),
        )
        .unwrap(),
        &writer(),
    )
    .unwrap();
    let (_dir, sock, seen) = tools_socket(json!({"status": 200, "body": {}}));
    let error = inspect_with(&mux, agent, params("/api/status"), Some(&sock)).unwrap_err();
    assert_eq!(response_error_code(&error).as_deref(), Some("origin.forbidden"));
    assert_eq!(seen.load(Ordering::SeqCst), 0);
}

#[test]
fn only_the_seven_read_only_paths_and_a_configured_socket() {
    let mux = Mux::new_for_test("chief-inspect", crate::SurfaceOptions::default());
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    let (_dir, sock, seen) = tools_socket(json!({"status": 200, "body": {}}));
    for path in ["/", "/api/ticket", "/api/write", "/api/../x", "api/status"] {
        assert!(inspect_with(&mux, owner, params(path), Some(&sock)).is_err(), "{path}");
    }
    assert_eq!(seen.load(Ordering::SeqCst), 0);
    let error = inspect_with(&mux, owner, params("/api/status"), None).unwrap_err();
    assert!(error.to_string().contains("no Chief tools socket"), "{error}");
}

#[test]
fn an_oversized_brain_answer_is_refused_not_cut() {
    let mux = Mux::new_for_test("chief-inspect", crate::SurfaceOptions::default());
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    let huge = "x".repeat(super::MAX_REPLY_BYTES + 10);
    let (_dir, sock, _) = tools_socket(json!({"status": 200, "body": huge}));
    assert!(inspect_with(&mux, owner, params("/api/turn"), Some(&sock)).is_err());
}

#[test]
fn the_remote_relay_never_admits_it() {
    let gate = remote_relay::gate::ALLOWED_COMMANDS;
    assert!(!gate.iter().any(|(name, _)| *name == "chief-inspect"));
    assert_eq!(CAPABILITY, "chief-inspect-v1");
}

/// A Unix connection that carries a link peer stamp (a stamped stream, not the
/// owner_session splice) is not the owner either.
#[test]
fn a_stamped_unix_connection_is_refused() {
    let mux = Mux::new_for_test("chief-inspect", crate::SurfaceOptions::default());
    mux.record_remote_check("inst_1").unwrap();
    let stamped = mux.control_clients.register(ClientTransport::Unix, writer());
    let peer = crate::remote_relay_state::LinkPeer {
        install: "inst_1".into(),
        user: "user_1".into(),
        team: "team_a".into(),
    };
    mux.bind_remote_peer(stamped, &peer).unwrap();
    let (_dir, sock, seen) = tools_socket(json!({"status": 200, "body": {}}));
    let error = inspect_with(&mux, stamped, params("/api/status"), Some(&sock)).unwrap_err();
    assert_eq!(response_error_code(&error).as_deref(), Some("origin.forbidden"));
    assert_eq!(seen.load(Ordering::SeqCst), 0);
}

/// A capability says the daemon speaks the command, not that it is
/// configured: a daemon with no tools socket still advertises
/// `chief-inspect-v1` (the app requires it of its bundled daemon) and answers
/// the owner with the typed `chief.not_configured`, forwarding nothing.
#[test]
fn an_unconfigured_daemon_advertises_it_and_answers_not_configured() {
    assert!(!super::configured(), "the test environment sets no tools socket");
    let mux = Mux::new_for_test("chief-inspect", crate::SurfaceOptions::default());
    assert!(identify_capabilities(&mux).contains(&CAPABILITY));
    let owner = mux.control_clients.register(ClientTransport::Unix, writer());
    let error = inspect_with(&mux, owner, params("/api/status"), None).unwrap_err();
    assert_eq!(response_error_code(&error).as_deref(), Some("chief.not_configured"), "{error}");
    // The owner gate still comes first: a non-owner learns nothing more.
    let remote = mux.control_clients.register(ClientTransport::Remote, writer());
    let error = inspect_with(&mux, remote, params("/api/status"), None).unwrap_err();
    assert_eq!(response_error_code(&error).as_deref(), Some("origin.forbidden"));
}
