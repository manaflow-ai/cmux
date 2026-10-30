//! Launch cleanup stops only the named local agent, keeping its chat resumable.
use super::*;
use acpmux::server::{Origin, serve_connection_with};

fn connection(hub: &Arc<Hub>, origin: Origin) -> TestClient {
    let (tx, input) = mpsc::channel(64);
    let (output, rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), input, output, origin));
    TestClient { tx, rx, next: 0 }
}

#[tokio::test]
async fn warm_stop_drains_a_pending_load_and_allows_a_later_warm() {
    let gate = std::env::temp_dir().join(format!("acpmux-warm-stop-{}", uuid::Uuid::now_v7()));
    let env = BTreeMap::from([("FAKE_LOAD_GATE".to_owned(), gate.to_string_lossy().into_owned())]);
    let (hub, mut client) = setup_env(PermissionPolicy::ApproveAll, env).await;
    let made =
        client.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    let warmer = {
        let (hub, id) = (hub.clone(), id.clone());
        tokio::spawn(async move { hub.warm_sessions_report(&[id], 1, false, true, None).await })
    };
    tokio::time::timeout(Duration::from_secs(20), async {
        while !hub
            .events(&id, 0, 10_000)
            .unwrap()
            .iter()
            .any(|e| e.dir == "out" && e.kind == method::SESSION_LOAD)
        {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("warm load never started");
    // warm_stop increments the stop generation before waiting on the in-flight spawn lock.
    // Observe that fence, then release the fake load so the stale start can drain.
    let before_stop = session.stops.load(Ordering::SeqCst);
    let mut stopper = connection(&hub, Origin::Local);
    stopper.request(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
    let stopping = tokio::spawn(async move {
        stopper.request(method::MUX_WARM_STOP, json!({"sessionId": id})).await
    });
    tokio::time::timeout(Duration::from_secs(5), async {
        while session.stops.load(Ordering::SeqCst) == before_stop {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("warm_stop never installed its stop fence");
    std::fs::write(&gate, b"ready").unwrap();
    stopping.await.unwrap().unwrap();
    let (warmed, failed) = warmer.await.unwrap();
    assert!(warmed.is_empty(), "a start from before Stop succeeded");
    assert_eq!(failed.len(), 1);
    assert_eq!(hub.status().await["liveAgents"], 0);
    assert_eq!(hub.session_summary(&session)["status"], "idle");

    std::fs::write(&gate, b"ready").unwrap();
    let later = client.request(method::MUX_WARM, json!({"sessionIds": [id]})).await.unwrap();
    assert_eq!(later["warmed"][0]["sessionId"], id, "{later}");
    assert_eq!(hub.status().await["liveAgents"], 1);
    hub.shutdown_all().await;
    let _ = std::fs::remove_file(gate);
}

#[tokio::test]
async fn warm_stop_keeps_an_explicitly_closed_session_closed() {
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let made =
        client.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap();
    let session = hub.resolve(id).unwrap();
    hub.kill(&session, false).await.unwrap();
    client.request(method::MUX_WARM_STOP, json!({"sessionId": id})).await.unwrap();
    let warmed = client.request(method::MUX_WARM, json!({"sessionIds": [id]})).await.unwrap();
    assert_eq!(warmed["warmed"], json!([]));
    assert_eq!(hub.session_summary(&session)["status"], "closed");
    assert_eq!(hub.status().await["liveAgents"], 0);
}

#[tokio::test]
async fn warm_stop_uses_exact_ids_and_leaves_unrelated_agents_live() {
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let first = new_session(&mut client, "restored").await;
    let other = new_session(&mut client, "unrelated").await;
    // Missing IDs are an idempotent success; names and prefixes never select another chat.
    for id in ["missing-session", "restored", &first[..8]] {
        client.request(method::MUX_WARM_STOP, json!({"sessionId": id})).await.unwrap();
        assert_eq!(hub.status().await["liveAgents"], 2, "{id} resolved a different session");
    }
    client.request(method::MUX_WARM_STOP, json!({"sessionId": first})).await.unwrap();
    assert_eq!(hub.status().await["liveAgents"], 1);
    assert_eq!(hub.session_summary(&hub.resolve(&first).unwrap())["status"], "idle");
    let answer = client
        .request(method::SESSION_PROMPT, prompt(&other, "still running", None))
        .await
        .unwrap();
    assert_eq!(answer["stopReason"], "end_turn");
    hub.shutdown_all().await;
}

#[tokio::test]
async fn warm_stop_refuses_every_nonlocal_origin() {
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut client, "local-only").await;
    for origin in [Origin::Web, Origin::Peer, Origin::LocalApp] {
        let mut remote = connection(&hub, origin);
        remote.request(method::INITIALIZE, json!({"protocolVersion": 1})).await.unwrap();
        let refused = remote.request(method::MUX_WARM_STOP, json!({"sessionId": id})).await;
        assert!(refused.is_err(), "{origin:?} stopped a launch-restored agent: {refused:?}");
        assert_eq!(hub.status().await["liveAgents"], 1);
    }
    hub.shutdown_all().await;
}

#[tokio::test]
async fn warm_stop_settles_the_turn_and_withdraws_queued_work() {
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut client, "warm-stop-queue").await;
    let running =
        client.send(method::SESSION_PROMPT, prompt(&id, "deaf-to-cancel", Some("running"))).await;
    client
        .wait_for(method::SESSION_UPDATE, |p| p["update"]["sessionUpdate"] == "agent_message_chunk")
        .await;
    let queued =
        client.send(method::SESSION_PROMPT, prompt(&id, "must not start", Some("queued"))).await;
    client
        .wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "queued" && p["queued"] == true)
        .await;
    let mut stop = connection(&hub, Origin::Local);
    stop.request(method::MUX_WARM_STOP, json!({"sessionId": id})).await.unwrap();
    // Drain both prompt tasks so their late status writes are covered by the assertions.
    let mut pending = vec![running, queued];
    tokio::time::timeout(Duration::from_secs(20), async {
        while !pending.is_empty() {
            let line = client.rx.recv().await.expect("connection closed");
            if let Message::Response { id, .. } = Message::parse(&line).unwrap() {
                pending.retain(|expected| *expected != id);
            }
        }
    })
    .await
    .expect("stopped prompt tasks did not finish");
    let session = hub.resolve(&id).unwrap();
    assert!(session.queue().is_empty());
    assert_eq!(hub.session_summary(&session)["status"], "idle");
    assert_eq!(hub.status().await["liveAgents"], 0);
    let results: Vec<_> = hub
        .events(&id, 0, 10_000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "turn_result")
        .collect();
    assert_eq!(results.len(), 1, "{results:?}");
    assert_eq!(results[0].msg["status"], "cancelled");
    hub.shutdown_all().await;
}

/// A launch's warm that reaches the daemon after that launch's cleanup stopped the chat (a
/// detached RPC) starts nothing; the next launch's warm still starts it.
#[tokio::test]
async fn launch_token_fence_refuses_a_warm_after_its_launch_cleanup() {
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let made =
        client.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    let (warmed, failed) =
        hub.warm_sessions_report(&[id.clone()], 1, false, true, Some("launch-a")).await;
    assert_eq!((warmed.len(), failed.len()), (1, 0), "{warmed:?} {failed:?}");
    hub.warm_stop(&id, Some("launch-a")).await;
    assert_eq!(hub.status().await["liveAgents"], 0);

    let (warmed, failed) =
        hub.warm_sessions_report(&[id.clone()], 1, false, true, Some("launch-a")).await;
    assert!(warmed.is_empty(), "a cleaned-up launch started the chat again: {warmed:?}");
    assert_eq!(failed[0]["error"]["message"], "stale launch warm", "{failed:?}");
    assert_eq!(hub.status().await["liveAgents"], 0);

    let (warmed, failed) =
        hub.warm_sessions_report(&[id.clone()], 1, false, true, Some("launch-b")).await;
    assert_eq!((warmed.len(), failed.len()), (1, 0), "{warmed:?} {failed:?}");
    hub.shutdown_all().await;
}

/// A launch that ended without its cleanup (a crash or force quit) leaves the shared daemon
/// running; the next launch still starts the chats it restores.
#[tokio::test]
async fn launch_token_fence_admits_a_launch_after_one_without_cleanup() {
    let (hub, mut client) = setup(PermissionPolicy::ApproveAll).await;
    let made =
        client.request(method::SESSION_NEW, json!({"cwd": cwd(), "mcpServers": []})).await.unwrap();
    let id = made["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    hub.detach_child(&session).await;
    let (warmed, _) =
        hub.warm_sessions_report(&[id.clone()], 1, false, true, Some("crashed-launch")).await;
    assert_eq!(warmed.len(), 1, "{warmed:?}");
    hub.detach_child(&session).await;

    let (warmed, failed) =
        hub.warm_sessions_report(&[id.clone()], 1, false, true, Some("next-launch")).await;
    assert!(failed.is_empty(), "the next launch was refused: {failed:?}");
    assert_eq!(warmed.len(), 1, "{warmed:?}");
    hub.shutdown_all().await;
}
