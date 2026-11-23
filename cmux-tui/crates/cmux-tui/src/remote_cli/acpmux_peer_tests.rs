use super::*;

#[test]
fn the_lease_asks_for_the_vm_boundary_only_when_told_the_caller_owns_the_vm() {
    let tokens = Tokens { token: "dash".into(), peer_token: Some("peer".into()), port: 1 };
    for vm_boundary in [true, false] {
        let params = lease_params("cloud-a", "ws://127.0.0.1:2", &tokens, vm_boundary);
        assert_eq!(params["vmBoundary"], vm_boundary, "{params}");
        assert_eq!(params["name"], "cloud-a");
        assert_eq!(params["peerToken"], "peer");
    }
}

#[test]
fn the_listen_address_gives_the_port_only_for_a_loopback_host() {
    assert_eq!(listen_port("127.0.0.1:47811"), Some(47811));
    assert_eq!(listen_port("localhost:4000"), Some(4000));
    assert_eq!(listen_port("0.0.0.0:4000"), Some(4000));
    for refused in ["10.0.0.4:4000", "[::1]:4000", "127.0.0.1:0", "127.0.0.1:x", "4000", ""] {
        assert_eq!(listen_port(refused), None, "{refused}");
    }
}

#[test]
fn tokens_come_from_the_config_and_the_peer_token_file() {
    let cfg = br#"{"websocket": {"listen": "127.0.0.1:47811", "token": "dash"}}"#;
    let peer = acpmux::peer::peer_token_text("b".repeat(64).as_bytes());
    let tokens = tokens_from(cfg, peer.clone()).unwrap();
    assert_eq!(tokens, Tokens { token: "dash".into(), peer_token: peer, port: 47811 });
    assert!(tokens_from(b"{}", None).unwrap_err().contains("no websocket token"));
    assert!(tokens_from(b"nope", None).unwrap_err().contains("not readable"));
    let public = br#"{"websocket": {"listen": "10.1.2.3:47811", "token": "dash"}}"#;
    assert!(tokens_from(public, None).unwrap_err().contains("loopback"));
    // The errors never quote the file.
    assert!(!tokens_from(public, None).unwrap_err().contains("dash"));
}

#[test]
fn only_a_personal_vm_without_team_files_is_admitted() {
    assert_eq!(vm_admits(Some("owner"), false), Ok(()));
    assert_eq!(vm_admits(Some("team"), false), Err("it is a team VM"));
    assert_eq!(vm_admits(Some("owner"), true), Err("it is a team VM"));
    assert!(vm_admits(None, false).is_err());
    assert!(vm_admits(Some(""), false).is_err());
    assert!(vm_admits(Some("other"), false).is_err());
}

#[test]
fn the_home_comes_only_from_the_daemons_own_install_path() {
    assert_eq!(home_from_cli_path("/home/cmux/.cmux/bin/cmux-tui"), Some("/home/cmux"));
    assert_eq!(home_from_cli_path("/root/.cmux/bin/cmux-tui"), Some("/root"));
    for refused in [
        "/usr/local/bin/cmux-tui",
        "home/cmux/.cmux/bin/cmux-tui",
        "/.cmux/bin/cmux-tui",
        "/home/../etc/.cmux/bin/cmux-tui",
        "/home//cmux/.cmux/bin/cmux-tui",
    ] {
        assert_eq!(home_from_cli_path(refused), None, "{refused}");
    }
}

#[test]
fn the_peer_name_is_a_valid_acpmux_name() {
    assert_eq!(peer_name("devbox-7"), "cloud-devbox-7");
    assert_eq!(peer_name("Leo's VM"), "cloud-Leo-s-VM");
    assert_eq!(peer_name(""), "cloud-vm");
    assert_eq!(peer_name("..."), "cloud-vm");
    assert_eq!(peer_name(&"x".repeat(200)).len(), 80);
    for machine in ["devbox-7", "Leo's VM", "", "...", "a/b c", &"x".repeat(200)] {
        acpmux::session_name::validate(&peer_name(machine)).unwrap();
    }
}

#[test]
fn a_peer_served_as_web_or_failing_needs_fresh_tokens() {
    assert!(!needs_renewal(&json!({"connected": true, "servedAs": "peer"})));
    assert!(needs_renewal(&json!({"connected": true, "servedAs": "remote"})));
    assert!(!needs_renewal(&json!({"connected": false, "attempts": 1})));
    assert!(needs_renewal(&json!({"connected": false, "attempts": 3})));
}

#[test]
fn the_bridge_is_off_unless_the_gate_is_exactly_one() {
    assert!(gate_on(Some("1")));
    for off in [None, Some(""), Some("0"), Some("true"), Some("yes"), Some(" 1")] {
        assert!(!gate_on(off), "{off:?}");
    }
}

/// A stand-in VM acpmux behind a local listener: the probe connects with
/// the dashboard and peer tokens and reads `personKey`.
#[tokio::test]
async fn the_status_probe_sends_both_tokens_and_reads_the_person_key() {
    use tokio_tungstenite::tungstenite::Message as Frame;
    use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut seen = (None, None);
        #[allow(clippy::result_large_err)]
        // Required by tungstenite's handshake callback signature.
        let callback = |request: &Request, response: Response| {
            let header = |name: &str| {
                request.headers().get(name).and_then(|v| v.to_str().ok()).map(str::to_owned)
            };
            seen = (header("authorization"), header(acpmux::server::peer_auth::HEADER));
            Ok(response)
        };
        let mut ws = tokio_tungstenite::accept_hdr_async(stream, callback).await.unwrap();
        while let Some(Ok(frame)) = ws.next().await {
            let Frame::Text(text) = frame else { continue };
            let request: Value = serde_json::from_str(&text).unwrap();
            let result = if request["method"] == "_acpmux/status" {
                json!({"personKey": true})
            } else {
                json!({})
            };
            let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
            if ws.send(Frame::Text(reply.to_string().into())).await.is_err() {
                break;
            }
        }
        seen
    });
    let tokens = Tokens { token: "dash".into(), peer_token: Some("p".repeat(64)), port };
    let status = probe_status(&format!("ws://127.0.0.1:{port}"), &tokens).await.unwrap();
    assert_eq!(status["personKey"], true);
    let (authorization, peer) = server.await.unwrap();
    assert_eq!(authorization.as_deref(), Some("Bearer dash"));
    assert_eq!(peer, Some("p".repeat(64)));
}
