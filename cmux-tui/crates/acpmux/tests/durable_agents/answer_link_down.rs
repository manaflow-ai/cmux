//! CROSS-LANE Q3 from c-turns: a permission answer the person gives while the daemon's link to the
//! agent host is down (another owner took the host over and left) reaches the agent, once. Before,
//! the answer's write went down with the link (`respond_answer` dropped its error), nothing reached
//! the host again until another request did, and the agent waited for ever on the ask the person
//! had answered.

use super::*;

#[tokio::test]
async fn a_permission_answer_given_while_the_host_link_is_down_reaches_the_agent_once() {
    let daemon = Daemon::new("permdown", "ask");
    let session = new_session(&daemon).await;
    let mut client = daemon.rpc().await;
    client
        .send(
            "session/prompt",
            json!({"sessionId": session, "prompt": [{"type": "text", "text": "ask: deploy"}]}),
        )
        .await;
    let asked =
        daemon.wait_event(&session, "permission_request", |e| e["kind"] == "permission_request");
    let first = asked["msg"]["permissionId"].as_str().unwrap().to_owned();
    // Another owner takes the host over and leaves: the daemon's link is down.
    let record: acpmux::agent_host::HostRecord =
        serde_json::from_value(daemon.host_record(&session)).unwrap();
    match acpmux::agent_host::link::connect(record, 0).await.expect("take over") {
        acpmux::agent_host::link::Connect::Ready(link, _) => drop(link),
        _ => panic!("the host refused a same-build owner"),
    }
    // The person answers while the link is down. A cut answer is asked again under the bound now
    // (answered the same way here); any other is sent again once the host is reached.
    let mut rpc = daemon.rpc().await;
    let mut answered = std::collections::HashSet::new();
    let deadline = Instant::now() + Duration::from_secs(30);
    let mut pending = vec![first];
    loop {
        for id in pending.drain(..) {
            if answered.insert(id.clone()) {
                rpc.call(
                    "_acpmux/permission_respond",
                    json!({"sessionId": session, "permissionId": id, "optionId": "no"}),
                )
                .await;
            }
        }
        let events = daemon.events(&session);
        if events.iter().any(|e| chunk(e, "chose no")) {
            break;
        }
        assert!(
            Instant::now() < deadline,
            "the answer never reached the agent: {:#}",
            json!(events)
        );
        pending = events
            .iter()
            .filter(|e| e["kind"] == "permission_request" || e["kind"] == "permission_reissued")
            .filter_map(|e| e["msg"]["permissionId"].as_str().map(str::to_owned))
            .filter(|id| !answered.contains(id))
            .collect();
        std::thread::sleep(Duration::from_millis(100));
    }
    // Not checked: how the turn ends. The reader of the lost link fails the open prompt with
    // "agent process closed" before the reattach (`ChildAgent::start_reader`), a separate case.
    // Test-only fixed wait: a second answer would come right behind the first.
    std::thread::sleep(Duration::from_secs(2));
    let events = daemon.events(&session);
    let chose = events.iter().filter(|e| chunk(e, "chose no")).count();
    assert_eq!(chose, 1, "the agent read the answer {chose} times: {:#}", json!(events));
    drop(client);
}
