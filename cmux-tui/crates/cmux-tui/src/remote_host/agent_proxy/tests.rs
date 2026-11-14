use super::*;
use cmux_tui_core::platform::transport;
use std::net::TcpListener;

#[test]
fn proxy_wire_refuses_then_forwards_and_closes_both_sides() {
    let dir = tempfile::tempdir().unwrap();
    config::set_dir(dir.path().to_path_buf());
    let local = transport::listen(&dir.path().join("daemon.sock")).unwrap();
    let daemon = transport::connect(&dir.path().join("daemon.sock")).unwrap();
    let mut host = local.accept().unwrap();
    host.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let fake = std::thread::spawn(move || {
        let mut reader = BufReader::new(host.try_clone_box().unwrap());
        let bind: Value =
            serde_json::from_slice(&line(&mut reader, MAX_FRAME).unwrap().unwrap()).unwrap();
        assert_eq!(bind["cmd"], "agent-session-proxy-bind");
        assert_eq!(bind["author"]["login"], "lawrence@manaflow.ai");
        send(
            &mut host,
            &json!({"id":"host-bind", "ok":true, "data":{"protocol":12,"generation":"boot-1"}}),
        )
        .unwrap();
        let forwarded: Value =
            serde_json::from_slice(&line(&mut reader, MAX_FRAME).unwrap().unwrap()).unwrap();
        assert_eq!(forwarded["cmd"], "agent-session-observe");
        assert_eq!(forwarded["_host_author"], bind["author"]);
        assert_eq!(forwarded["_host_session"], "acp_a");
        assert!(forwarded.get("author").is_none());
        send(&mut host, &json!({"id":3,"ok":true})).unwrap();
        assert!(line(&mut reader, MAX_FRAME).unwrap().is_none());
    });
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let mut client = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
    client.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let tcp = listener.accept().unwrap().0;
    let config: config::Config = serde_json::from_value(json!({"version":1,"enabled":true,
            "teammate_access":true,"grants":[{"login":"lawrence@manaflow.ai","scopes":["agents"],"consented_at":"now"}],
            "shares":[{"surface":42,"login":"lawrence@manaflow.ai","role":"guest","shared_at":"now","generation":"boot-1","session":"acp_a"}]})).unwrap();
    let proxy = std::thread::spawn(move || {
        run_with_config(
            tcp,
            daemon,
            Identity {
                login: Some("lawrence@manaflow.ai".into()),
                node: "laptop".into(),
                tags: vec![],
                shared: false,
            },
            "100.80.2.2".parse().unwrap(),
            || Ok(config.clone()),
        )
    });
    let mut reader = BufReader::new(client.try_clone().unwrap());
    // The attach client's handshake is answered here, from the bind reply alone: no
    // inventory, no role, and nothing reaches the daemon (its next line is the observe).
    for (id, cmd, data) in [
        (10, "identify", json!({"protocol":12,"generation":"boot-1"})),
        (11, "set-client-info", json!({})),
    ] {
        send(&mut client, &json!({"id":id,"cmd":cmd,"machine_metadata":true,"kind":"app"}))
            .unwrap();
        let reply: Value =
            serde_json::from_slice(&line(&mut reader, MAX_FRAME).unwrap().unwrap()).unwrap();
        assert_eq!(reply, json!({"id":id,"ok":true,"data":data}), "{cmd}");
    }
    for (id, cmd, surface, code) in [
        (1, "send", 42, "scope_not_granted"),
        (2, "agent-session-observe", 43, "agent_session.not_shared"),
        (4, "agent-session-prompt", 42, "scope_not_granted"),
    ] {
        send(&mut client, &json!({"id":id,"cmd":cmd,"surface":surface})).unwrap();
        let reply: Value =
            serde_json::from_slice(&line(&mut reader, MAX_FRAME).unwrap().unwrap()).unwrap();
        assert_eq!(reply["id"], id);
        assert_eq!(reply["error_code"], code);
    }
    send(
        &mut client,
        &json!({"id":3,"cmd":"agent-session-observe","surface":42,"author":"spoof",
                "_host_session":"acp_b"}),
    )
    .unwrap();
    assert!(line(&mut reader, MAX_FRAME).unwrap().is_some());
    client.shutdown(Shutdown::Both).unwrap();
    proxy.join().unwrap().unwrap();
    fake.join().unwrap();
    let audit = std::fs::read_to_string(dir.path().join(audit::FILE)).unwrap();
    assert_eq!(audit.lines().count(), 3);
}
