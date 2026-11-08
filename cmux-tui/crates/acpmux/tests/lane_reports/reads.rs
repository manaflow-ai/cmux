//! Result receipts never make the parent's own tools queue a duplicate report.
use super::*;

async fn wait_registered(person: &mut Client) {
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let status = person.ok("_acpmux/status", json!({})).await;
            if status["openWaits"].as_u64().unwrap_or(0) > 0 {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("the completion waiter subscribed");
}

async fn start_running(person: &mut Client, lane: &str) {
    person
        .send(
            "session/prompt",
            json!({"sessionId": lane, "prompt": [{"type": "text", "text": "until-cancel"}]}),
        )
        .await;
    person
        .ok("_acpmux/wait", json!({"sessions": [lane], "until": ["running"], "timeoutMs": 5000}))
        .await;
}

async fn archive(person: &mut Client, parent: &str) -> Vec<Value> {
    let page = person.ok("_acpmux/events", json!({"sessionId": parent, "limit": 5000})).await;
    page["events"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|e| e["kind"] == "inbox" && e["msg"]["deliveredRead"] == true)
        .map(|e| e["msg"].clone())
        .collect()
}

#[tokio::test]
async fn lane_report_parent_completion_wait_archives_read_without_a_turn_or_queue_slot() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let lane = Client::as_session(&hub, &parent).await.new_session("waited-lane", json!({})).await;
    start_running(&mut person, &lane).await;
    let mut waiter = Client::as_session(&hub, &parent).await;
    let target = lane.clone();
    let waiting = tokio::spawn(async move {
        waiter
            .ok(
                "_acpmux/wait",
                json!({"sessions": [target], "until": ["ready"], "timeoutMs": 5000}),
            )
            .await
    });
    wait_registered(&mut person).await;
    person.ok("session/cancel", json!({"sessionId": lane})).await;
    let done = waiting.await.unwrap();
    assert_eq!(done["timedOut"], false);
    person.exactly(&parent, 0).await;
    let messages = archive(&mut person, &parent).await;
    assert_eq!(messages.len(), 1, "one durable read receipt: {messages:#?}");
    let thread = messages[0]["threadId"].as_str().unwrap();
    let mut reader = Client::as_session(&hub, &parent).await;
    let read = reader
        .ok(
            "_acpmux/inbox_thread",
            json!({"sessionId": parent, "threadId": thread, "markRead": false}),
        )
        .await;
    assert_eq!(read["messages"][0]["read"], true, "{read:#?}");
    assert_eq!(hub.session_summary(&hub.resolve(&parent).unwrap())["queued"], 0);
}

#[tokio::test]
async fn lane_report_an_unproven_waiter_does_not_consume_the_parents_result() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let lane =
        Client::as_session(&hub, &parent).await.new_session("unproven-lane", json!({})).await;
    start_running(&mut person, &lane).await;
    let mut waiter = Client::new(&hub);
    let target = lane.clone();
    let waiting = tokio::spawn(async move {
        waiter
            .ok(
                "_acpmux/wait",
                json!({"sessions": [target], "until": ["ready"], "timeoutMs": 5000}),
            )
            .await
    });
    wait_registered(&mut person).await;
    person.ok("session/cancel", json!({"sessionId": lane})).await;
    waiting.await.unwrap();
    person.exactly(&parent, 1).await;
    assert!(archive(&mut person, &parent).await.is_empty());
}

#[tokio::test]
async fn lane_report_timed_out_wait_does_not_consume_this_or_the_next_turn() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let lane = Client::as_session(&hub, &parent).await.new_session("timeout-lane", json!({})).await;
    start_running(&mut person, &lane).await;
    let mut waiter = Client::as_session(&hub, &parent).await;
    let timed_out = waiter
        .ok("_acpmux/wait", json!({"sessions": [lane], "until": ["ready"], "timeoutMs": 1}))
        .await;
    assert_eq!(timed_out["timedOut"], true);
    person.ok("session/cancel", json!({"sessionId": lane})).await;
    person.exactly(&parent, 1).await;
    Client::as_session(&hub, &parent).await.prompt(&lane, "different next result").await;
    person.exactly(&parent, 2).await;
    assert!(archive(&mut person, &parent).await.is_empty());
}

#[tokio::test]
async fn lane_report_parent_history_read_removes_only_the_matching_queued_result() {
    let hub = hub();
    let mut person = Client::new(&hub);
    let parent = person.new_session("parent", json!({})).await;
    let lane = Client::as_session(&hub, &parent).await.new_session("history-lane", json!({})).await;
    start_running(&mut person, &parent).await;
    let mut events = hub.subscribe();
    Client::as_session(&hub, &parent).await.prompt(&lane, "history result").await;
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            let event = events.recv().await.unwrap();
            if event.session_id == parent && event.record.kind == "queued" {
                break;
            }
        }
    })
    .await
    .expect("the report queued behind its busy parent");
    let mut reader = Client::as_session(&hub, &parent).await;
    reader.ok("_acpmux/history", json!({"sessionId": lane, "limit": 1})).await;
    assert_eq!(hub.session_summary(&hub.resolve(&parent).unwrap())["queued"], 0);
    let messages = archive(&mut person, &parent).await;
    assert_eq!(messages.len(), 1);
    reader.ok("_acpmux/history", json!({"sessionId": lane, "limit": 1})).await;
    assert_eq!(archive(&mut person, &parent).await.len(), 1, "a repeated read has one receipt");
    person.ok("session/cancel", json!({"sessionId": parent})).await;
    person.exactly(&parent, 0).await;
}

#[tokio::test]
async fn lane_report_transcript_reply_read_consumes_its_ended_turn_not_state_only_pages() {
    for method in ["_acpmux/attach", "_acpmux/events"] {
        let hub = hub();
        let mut person = Client::new(&hub);
        let parent = person.new_session("parent", json!({})).await;
        let lane =
            Client::as_session(&hub, &parent).await.new_session("last-lane", json!({})).await;
        start_running(&mut person, &parent).await;
        let mut events = hub.subscribe();
        Client::as_session(&hub, &parent).await.prompt(&lane, "last reply result").await;
        tokio::time::timeout(Duration::from_secs(5), async {
            loop {
                let event = events.recv().await.unwrap();
                if event.session_id == parent && event.record.kind == "queued" {
                    break;
                }
            }
        })
        .await
        .expect("the report queued behind its busy parent");
        let mut reader = Client::as_session(&hub, &parent).await;
        reader
            .ok(
                "_acpmux/events",
                json!({"sessionId": lane, "limit": 5000, "kinds": ["turn_result"]}),
            )
            .await;
        assert_eq!(hub.session_summary(&hub.resolve(&parent).unwrap())["queued"], 1);
        reader.ok(method, json!({"sessionId": lane, "limit": 5000, "kinds": ["transcript"]})).await;
        assert_eq!(hub.session_summary(&hub.resolve(&parent).unwrap())["queued"], 0);
        let messages = archive(&mut person, &parent).await;
        assert_eq!(messages.len(), 1);
        // The report's own projection; the parent's log also holds its sender copy of the
        // prompt it sent the lane (#27038), which is another message (cx-85ske2).
        let projections: Vec<_> = person
            .message_events(&parent)
            .await
            .into_iter()
            .filter(|event| event["messageId"] == messages[0]["promptId"])
            .collect();
        assert_eq!(projections.len(), 1, "the archive preserves the durable message projection");
        assert_eq!(projections[0]["sender"]["sessionId"], json!(lane), "{projections:#?}");
        person.ok("session/cancel", json!({"sessionId": parent})).await;
    }
}
