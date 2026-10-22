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

/// The permission asks `id` recorded, once there are `n` of them.
async fn asks(hub: &Hub, id: &str, n: usize) -> Vec<Value> {
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    loop {
        let asked: Vec<Value> = hub
            .events(id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.dir == "mux" && e.kind == "permission_request")
            .map(|e| e.msg)
            .collect();
        if asked.len() >= n {
            return asked;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "Claude asked {} times, not {n}",
            asked.len()
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

fn option_kinds(ask: &Value) -> Vec<&str> {
    ask["request"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|o| o["kind"].as_str())
        .collect()
}

/// A restricted chat (`hub/restricted.rs`) asks before every call: its ask offers no "Allow for
/// this session" (Claude Code would keep the rule it suggested and stop asking), an answer
/// naming it is refused, and Claude asks again for the same command.
#[tokio::test]
async fn a_restricted_chat_offers_no_allow_for_this_session() {
    let root =
        std::env::temp_dir().join(format!("acpmux-restricted-always-{}", uuid::Uuid::now_v7()));
    // Claude's config folder outside the chat's folder: one inside it is refused.
    let (claude, work) = (root.join("claude"), root.join("work"));
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::create_dir_all(&work).unwrap();
    let (hub, _agent) = claude_setup(&claude, &[]).await;
    hold_person_key(&hub);
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection(hub.clone(), in_rx, out_tx));
    let mut person = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    person.become_person().await;

    let session = hub
        .new_session(acpmux::hub::NewRequest {
            cwd: Some(work.clone()),
            restricted: true,
            ..Default::default()
        })
        .await
        .unwrap();
    let id = session.id.clone();
    person.next += 1;
    let prompt = json!({"sessionId": id, "prompt": [{"type": "text", "text": "always-ask"}]});
    person
        .tx
        .send(Message::request(person.next, method::SESSION_PROMPT, prompt).to_line())
        .await
        .unwrap();

    let first = asks(&hub, &id, 1).await.remove(0);
    assert_eq!(option_kinds(&first), ["allow_once", "reject_once"], "{first}");
    let pid = first["permissionId"].as_str().unwrap().to_owned();
    let refused = person
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": "allow_always"}),
        )
        .await
        .unwrap_err();
    assert!(refused.contains("not uniquely offered"), "{refused}");
    person
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": "allow_once"}),
        )
        .await
        .unwrap();
    // Allow once keeps no rule: the second run of the command asks too.
    let second = asks(&hub, &id, 2).await.remove(1);
    assert_eq!(option_kinds(&second), ["allow_once", "reject_once"], "{second}");
    let pid = second["permissionId"].as_str().unwrap().to_owned();
    person
        .request(
            method::MUX_PERMISSION_RESPOND,
            json!({"sessionId": id, "permissionId": pid, "optionId": "allow_once"}),
        )
        .await
        .unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while !hub.events(&id, 0, 10_000).unwrap().iter().any(|e| e.kind == "turn_end") {
        assert!(std::time::Instant::now() < deadline, "the turn never ended");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    assert_eq!(hub.session_summary(&session)["preview"], "asked twice []");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}
