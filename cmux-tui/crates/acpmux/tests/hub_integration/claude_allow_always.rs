//! Claude's "Allow for this session" (`allow_always`): the answer carries the
//! rules Claude Code suggested back as session permission updates, so Claude
//! stops asking for the same command in that chat. Before, acpmux answered a
//! plain allow, Claude kept no rule, and the option worked like Allow once.

use super::*;

#[tokio::test]
async fn allow_for_this_session_stops_claude_asking_again() {
    let root = std::env::temp_dir().join(format!("acpmux-always-{}", uuid::Uuid::now_v7()));
    let claude = root.join("claude");
    std::fs::create_dir_all(&claude).unwrap();
    let (hub, _agent) = claude_setup(&claude, &[]).await;
    // The person answers at the app, on a connection that proved the key.
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut person = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    person.become_person().await;

    let s =
        person.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    hub.set_policy(&hub.resolve(&id).unwrap(), PermissionPolicy::Ask).await;
    person.next += 1;
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "always-ask"}]});
    person
        .tx
        .send(Message::request(person.next, method::SESSION_PROMPT, prompt).to_line())
        .await
        .unwrap();

    let pending = person.wait_for(method::MUX_PERMISSION_PENDING, |_| true).await;
    let pid = pending["permissionId"].as_str().unwrap().to_owned();
    person
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": "allow_always"}),
        )
        .await
        .unwrap();
    // The turn ends without a second ask for the call the session allowed.
    let session = hub.resolve(&id).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let again: Vec<String> = session
            .pending_permissions()
            .into_iter()
            .map(|(p, _)| p)
            .filter(|p| *p != pid)
            .collect();
        assert!(again.is_empty(), "Claude asked again after Allow for this session: {again:?}");
        if hub.events(&id, 0, 10_000).unwrap().iter().any(|e| e.kind == "turn_end") {
            break;
        }
        assert!(std::time::Instant::now() < deadline, "the turn never ended");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    // Asked once, and the rule went to this session only, never to the
    // project's settings file Claude's suggestion named.
    assert_eq!(hub.session_summary(&session)["preview"], r#"asked once ["session"]"#);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
