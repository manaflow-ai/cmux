//! Orchestrator tags with expiry, permission rules and the unread flag.

use super::*;

#[tokio::test]
async fn tags_rules_and_unread() {
    let (hub, mut c) = setup(PermissionPolicy::Ask).await;
    let s = c
        .request(
            method::SESSION_NEW,
            json!({"cwd": cwd(), "mcpServers": [], "_meta": {"acpmux": {"name": "t"}}}),
        )
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // Tags with and without expiry.
    let v = c.request(method::MUX_TAG, json!({"sessionId": id, "set": {"task": "review", "owner": "orchestrator"}, "ttlSeconds": 3600})).await.unwrap();
    assert_eq!(v["tags"]["task"], "review");
    let v =
        c.request(method::MUX_TAG, json!({"sessionId": id, "remove": ["owner"]})).await.unwrap();
    assert!(v["tags"].get("owner").is_none());
    assert_eq!(v["tags"]["task"], "review");
    // Rules: deny rm under an ask policy answers without a client.
    assert!(
        c.request(method::MUX_SET_RULES, json!({"sessionId": id, "rules": {"bogus": 1}}))
            .await
            .is_err()
    );
    let v = c
        .request(
            method::MUX_SET_RULES,
            json!({"sessionId": id, "rules": {"autoDeny": ["rm"], "autoApprove": ["ls"]}}),
        )
        .await
        .unwrap();
    assert_eq!(v["rules"], true);
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": "ask: rm -rf /"}]}),
    )
    .await
    .unwrap();
    let session = hub.resolve(&id).unwrap();
    assert_eq!(hub.session_summary(&session)["preview"], "chose no");
    let autos: Vec<Value> = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "permission_auto")
        .map(|e| e.msg)
        .collect();
    assert_eq!(autos.last().unwrap()["rule"], "deny");
    // This client saw that turn end: not unread.
    assert_eq!(hub.session_summary(&session)["unread"], false);
    // Detach, then a second client sends a slow prompt and disconnects
    // mid-turn, like `acpmux send --no-wait`, so nobody is attached when it ends.
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    {
        let (in_tx2, in_rx2) = mpsc::channel(64);
        let (out_tx2, _out_rx2) = mpsc::channel(4096);
        tokio::spawn(serve_connection(hub.clone(), in_rx2, out_tx2));
        in_tx2
            .send(
                Message::request(
                    1,
                    method::SESSION_PROMPT,
                    json!({"sessionId": id, "prompt": [{"type": "text", "text": "slow"}]}),
                )
                .to_line(),
            )
            .await
            .unwrap();
        tokio::time::sleep(Duration::from_millis(150)).await;
        drop(in_tx2);
    }
    let w = c.request(method::MUX_WAIT, json!({"sessions": [id.clone()], "until": ["ready"], "afterSeq": {id.clone(): hub.session_summary(&session)["stateSeq"].as_u64().unwrap()}, "timeoutMs": 10000})).await.unwrap();
    assert_eq!(w["timedOut"], false, "{w}");
    // Unread: nobody was attached when the turn ended.
    assert_eq!(hub.session_summary(&session)["unread"], true);
    assert_eq!(hub.session_summary(&session)["attached"], 0);
    let w = c
        .request(
            method::MUX_WAIT,
            json!({"sessions": [id.clone()], "until": ["done"], "timeoutMs": 2000}),
        )
        .await
        .unwrap();
    assert_eq!(w["resolved"][0]["unread"], true, "{w}");
    c.request(method::MUX_ATTACH, json!({"sessionId": id, "limit": 0})).await.unwrap();
    assert_eq!(hub.session_summary(&session)["unread"], false);
    assert_eq!(hub.session_summary(&session)["attached"], 1);
    c.request(method::MUX_DETACH, json!({"sessionId": id})).await.unwrap();
    assert_eq!(hub.session_summary(&session)["attached"], 0);
    // Clearing rules returns to the policy.
    let v =
        c.request(method::MUX_SET_RULES, json!({"sessionId": id, "rules": null})).await.unwrap();
    assert_eq!(v["rules"], false);
}
