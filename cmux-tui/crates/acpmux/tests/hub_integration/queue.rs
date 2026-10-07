use super::*;

#[tokio::test]
async fn queued_prompts_are_accepted_queued_and_watchers_see_the_queue() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "q").await;
    let mut w = connect(&hub).await;
    let snap = w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();
    // The watch result is the session list.
    assert!(snap["sessions"].as_array().unwrap().iter().any(|s| s["sessionId"] == id));

    let first = c.send(method::SESSION_PROMPT, prompt(&id, "slow", Some("p-slow"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-slow").await;
    let second = c.send(method::SESSION_PROMPT, prompt(&id, "after", Some("p-after"))).await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-after").await;
    assert_eq!(acc["queued"], true);
    assert_eq!(acc["position"], 1);
    let queue = hub.session_summary(&hub.resolve("q").unwrap())["queue"].clone();
    assert_eq!(queue[0]["promptId"], "p-after");

    // Watchers learn about the queue on enqueue and on dequeue, with the
    // session id at the top level.
    let enq = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["kind"] == "queue" && p["recordKind"] == "queued"
        })
        .await;
    assert_eq!(enq["sessionId"], id);
    assert_eq!(enq["session"]["queued"], 1);
    let deq = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["kind"] == "queue" && p["recordKind"] == "dequeued"
        })
        .await;
    assert_eq!(deq["sessionId"], id);
    assert_eq!(deq["session"]["queued"], 0);

    assert!(c.response(first).await.0.is_ok());
    let r = c.response(second).await.0.unwrap();
    assert_eq!(r["_meta"]["acpmux"]["turnId"], acc["turnId"]);
    let events = hub.events(&id, 0, 1000).unwrap();
    let queued = find(&events, "queued")[0];
    assert_eq!(queued.msg["promptId"], "p-after");
    assert_eq!(queued.msg["turnId"], acc["turnId"]);
    assert_eq!(find(&events, "dequeued")[0].msg["turnId"], acc["turnId"]);
}

#[tokio::test]
async fn a_removed_queued_prompt_never_runs_and_watchers_see_it_leave() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "qr").await;
    let mut w = connect(&hub).await;
    w.request(method::MUX_WATCH, json!({"enabled": true})).await.unwrap();

    let first = c.send(method::SESSION_PROMPT, prompt(&id, "slow", Some("p-slow"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-slow").await;
    let gone = c.send(method::SESSION_PROMPT, prompt(&id, "drop me", Some("p-gone"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-gone").await;
    let kept = c.send(method::SESSION_PROMPT, prompt(&id, "keep me", Some("p-kept"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-kept").await;

    let mut r = connect(&hub).await;
    let removed = r
        .request(method::MUX_QUEUE_REMOVE, json!({"sessionId": id, "promptId": "p-gone"}))
        .await
        .unwrap();
    assert_eq!(removed["removed"], true);
    let s = hub.resolve("qr").unwrap();
    assert_eq!(s.queued(), 1);
    let queue = hub.session_summary(&s)["queue"].clone();
    assert_eq!(queue.as_array().unwrap().len(), 1);
    assert_eq!(queue[0]["promptId"], "p-kept");
    let left = w
        .wait_for(method::MUX_SESSION_CHANGED, |p| {
            p["kind"] == "queue" && p["recordKind"] == "queue_removed"
        })
        .await;
    assert_eq!(left["session"]["queued"], 1);

    // Removing it again, or a prompt that is not waiting, changes nothing.
    let again = r
        .request(method::MUX_QUEUE_REMOVE, json!({"sessionId": id, "promptId": "p-gone"}))
        .await
        .unwrap();
    assert_eq!(again["removed"], false);
    let running = r
        .request(method::MUX_QUEUE_REMOVE, json!({"sessionId": id, "promptId": "p-slow"}))
        .await
        .unwrap();
    assert_eq!(running["removed"], false);

    // The withdrawn prompt answers cancelled without a turn; the others run in order.
    let r_gone = c.response(gone).await.0.unwrap();
    assert_eq!(r_gone["stopReason"], "cancelled");
    assert_eq!(r_gone["_meta"]["acpmux"]["withdrawn"], true);
    assert!(c.response(first).await.0.is_ok());
    assert!(c.response(kept).await.0.is_ok());
    let events = hub.events(&id, 0, 1000).unwrap();
    let ran: Vec<_> =
        find(&events, "user_message").iter().map(|e| e.msg["promptId"].clone()).collect();
    assert_eq!(ran, vec![json!("p-slow"), json!("p-kept")]);
    assert_eq!(find(&events, "queue_removed")[0].msg["promptId"], "p-gone");
    assert!(find(&events, "dequeued").iter().all(|e| e.msg["promptId"] != "p-gone"));
    assert_eq!(s.queued(), 0);
}
