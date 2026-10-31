//! A chat's queue has a bound (`hub/queue_admission.rs`, manaflow-ai/cmuxterm-hq#2930): a prompt
//! that would wait past `queueMaxPrompts` or `queueMaxBytes` is refused with `queue.full` or
//! `queue.bytes` before anything is written, and the prompts already waiting still run.

use super::{TestClient, connect, new_session, prompt, setup_queue};
use acpmux::config::PermissionPolicy;
use acpmux::rpc::{Message, method};
use serde_json::{Value, json};
use std::time::Duration;

/// The reply to `id`, whole: `Err` is the error object with its data.
async fn reply(c: &mut TestClient, id: i64) -> Result<Value, Value> {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), c.rx.recv())
            .await
            .expect("timeout waiting for response")
            .expect("connection closed");
        if let Message::Response { id: rid, result, error } = Message::parse(&line).unwrap()
            && rid == json!(id)
        {
            return match error {
                Some(e) => Err(serde_json::to_value(e).unwrap()),
                None => Ok(result.unwrap_or(Value::Null)),
            };
        }
    }
}

async fn stop(c: &mut TestClient, id: &str) {
    let cancel = Message::notification(method::SESSION_CANCEL, json!({"sessionId": id}));
    c.tx.send(cancel.to_line()).await.unwrap();
}

fn queued_records(hub: &acpmux::hub::Hub, id: &str) -> Vec<String> {
    let events = hub.events(id, 0, 1000).unwrap();
    events
        .iter()
        .filter(|e| e.kind == "queued")
        .map(|e| e.msg["promptId"].as_str().unwrap_or_default().to_owned())
        .collect()
}

#[tokio::test]
async fn a_prompt_past_the_count_limit_is_refused_and_nothing_is_queued_for_it() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.queue_max_prompts = Some(2);
    let id = new_session(&mut c, "full").await;

    let running = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-run"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-run").await;
    let mut waiting = Vec::new();
    for n in 1..=2 {
        let pid = format!("p-wait-{n}");
        waiting.push(c.send(method::SESSION_PROMPT, prompt(&id, "hi", Some(&pid))).await);
        let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == pid).await;
        assert_eq!(acc["queued"], true, "{acc}");
    }

    let over = c.send(method::SESSION_PROMPT, prompt(&id, "one too many", Some("p-over"))).await;
    let error = reply(&mut c, over).await.expect_err("a prompt past the limit was taken");
    assert_eq!(error["code"], -32000, "{error}");
    assert_eq!(error["data"]["reason"], "queue.full", "{error}");
    assert_eq!(error["data"]["limit"], 2, "{error}");
    assert_eq!(error["data"]["queued"], 2, "{error}");
    assert_eq!(error["data"]["retryable"], true, "{error}");
    assert_eq!(queued_records(&hub, &id), ["p-wait-1", "p-wait-2"]);

    // The prompts that waited still run, and the queue takes another once there is room.
    stop(&mut c, &id).await;
    reply(&mut c, running).await.unwrap();
    for w in waiting {
        reply(&mut c, w).await.unwrap();
    }
    let again = c.send(method::SESSION_PROMPT, prompt(&id, "now", Some("p-again"))).await;
    reply(&mut c, again).await.unwrap();
}

#[tokio::test]
async fn a_prompt_past_the_byte_limit_is_refused_and_a_smaller_one_still_queues() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.queue_max_bytes = Some(64 << 10);
    let id = new_session(&mut c, "bytes").await;

    let running = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-run"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-run").await;
    let big = "x".repeat(40 << 10);
    let first = c.send(method::SESSION_PROMPT, prompt(&id, &big, Some("p-big-1"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-big-1").await;

    let over = c.send(method::SESSION_PROMPT, prompt(&id, &big, Some("p-big-2"))).await;
    let error = reply(&mut c, over).await.expect_err("a prompt past the byte limit was taken");
    assert_eq!(error["data"]["reason"], "queue.bytes", "{error}");
    assert_eq!(error["data"]["limit"], 64 << 10, "{error}");
    assert!(error["data"]["queuedBytes"].as_u64().unwrap() >= 40 << 10, "{error}");
    assert_eq!(error["data"]["retryable"], true, "{error}");

    let small = c.send(method::SESSION_PROMPT, prompt(&id, "small", Some("p-small"))).await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-small").await;
    assert_eq!(acc["queued"], true, "{acc}");
    assert_eq!(queued_records(&hub, &id), ["p-big-1", "p-small"]);

    stop(&mut c, &id).await;
    for r in [running, first, small] {
        reply(&mut c, r).await.unwrap();
    }
}

/// A prompt that replaces its sender's queued one under a supersede key adds nothing to the
/// queue, so a full queue still takes it; another prompt is still refused.
#[tokio::test]
async fn a_full_queue_still_takes_a_prompt_that_replaces_a_queued_one() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.queue_max_prompts = Some(1);
    let id = new_session(&mut c, "replace").await;
    let keyed = |pid: &str, text: &str| {
        let mut p = prompt(&id, text, Some(pid));
        p["_meta"]["acpmux"]["supersede"] = json!("status");
        p
    };

    let running = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-run"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-run").await;
    let first = c.send(method::SESSION_PROMPT, keyed("p-status-1", "status one")).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-status-1").await;

    let second = c.send(method::SESSION_PROMPT, keyed("p-status-2", "status two")).await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-status-2").await;
    assert_eq!(acc["queued"], true, "{acc}");
    assert_eq!(acc["replaced"], 1, "{acc}");
    reply(&mut c, first).await.unwrap();

    let other = c.send(method::SESSION_PROMPT, prompt(&id, "other", Some("p-other"))).await;
    let error = reply(&mut c, other).await.expect_err("a prompt past the limit was taken");
    assert_eq!(error["data"]["reason"], "queue.full", "{error}");

    stop(&mut c, &id).await;
    reply(&mut c, running).await.unwrap();
    reply(&mut c, second).await.unwrap();
}

/// The messages an inbox digest took leave the queue but wait with it, so they still count
/// against the byte limit, after the person edits the digest's text too.
#[tokio::test]
async fn the_messages_a_digest_took_still_count_against_the_byte_limit() {
    let (hub, mut c) = setup_queue(PermissionPolicy::ApproveAll).await;
    hub.config.write().await.queue_max_bytes = Some(96 << 10);
    let mut agents = connect(&hub).await;
    let id = new_session(&mut c, "digest").await;

    let running = c.send(method::SESSION_PROMPT, prompt(&id, "until-cancel", Some("p-run"))).await;
    c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-run").await;
    let report = "r".repeat(30 << 10);
    let mut sent = Vec::new();
    for (pid, from) in [("p-a", "lane-a"), ("p-b", "lane-b")] {
        let msg = json!({"sessionId": id, "prompt": [{"type": "text", "text": report}],
                         "_meta": {"acpmux": {"promptId": pid, "fromAgent": from}}});
        sent.push(agents.send(method::SESSION_PROMPT, msg).await);
        agents.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == pid).await;
    }
    let made = c.request("_acpmux/inbox_digest", json!({"sessionId": id})).await.unwrap();
    assert_eq!(made["delivery"], "queued", "{made}");
    let digest = made["promptId"].as_str().unwrap().to_owned();
    let edit = json!({"sessionId": id, "promptId": digest, "op": "update", "text": "short"});
    c.request(method::MUX_QUEUE_EDIT, edit).await.unwrap();

    // The digest's text is short now; the 60 KiB it took still wait.
    let over =
        c.send(method::SESSION_PROMPT, prompt(&id, &"x".repeat(40 << 10), Some("p-over"))).await;
    let error = reply(&mut c, over).await.expect_err("the digest's messages were not counted");
    assert_eq!(error["data"]["reason"], "queue.bytes", "{error}");
    assert!(error["data"]["queuedBytes"].as_u64().unwrap() >= 60 << 10, "{error}");
    let small = c.send(method::SESSION_PROMPT, prompt(&id, "small", Some("p-small"))).await;
    let acc = c.wait_for(method::MUX_PROMPT_ACCEPTED, |p| p["promptId"] == "p-small").await;
    assert_eq!(acc["queued"], true, "{acc}");

    stop(&mut c, &id).await;
    reply(&mut c, running).await.unwrap();
    reply(&mut c, small).await.unwrap();
}
