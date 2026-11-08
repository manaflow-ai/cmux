//! A prompt to a chat on a peer that is down waits in the outbox (`prompt_outbox.rs`): the sender
//! hears it waits instead of an error, the wait is bounded by count and age, and its failures say
//! which bound it hit.

use super::*;
use crate::config::{Config, StoreMode};
use crate::hub::outbox::{INTERACTIVE_FULL, INTERACTIVE_MAX_PER_PEER};
use std::time::Duration;

/// The id huge-blue's last list gave its session `lane`.
const LANE: &str = "0190f2a4-7c1e-7d3a-9f00-0123456789ab";

/// This daemon, and huge-blue a peer that is down after it listed `lane`.
fn setup() -> Arc<Hub> {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let row = json!({"sessionId": LANE, "name": "lane", "status": "idle", "turnCount": 1,
                     "updatedAt": 5});
    hub.seed_down_peer("huge-blue", vec![row]);
    hub
}

/// A unix-socket connection that sent `session/prompt` with `params`: its lines, and the sender
/// that keeps it open.
async fn prompting(
    hub: &Arc<Hub>,
    params: Value,
) -> (mpsc::Receiver<String>, mpsc::Sender<String>) {
    let (input, incoming) = mpsc::channel(8);
    let (output, outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    for line in [
        Message::request(1, method::INITIALIZE, hello),
        Message::request(2, method::SESSION_PROMPT, params),
    ] {
        input.send(line.to_line()).await.unwrap();
    }
    (outgoing, input)
}

/// The next line on `out` that is the prompt's answer or `_acpmux/prompt_accepted`.
async fn next(out: &mut mpsc::Receiver<String>) -> Value {
    loop {
        let line = tokio::time::timeout(Duration::from_secs(20), out.recv()).await;
        let v: Value = serde_json::from_str(&line.unwrap().unwrap()).unwrap();
        if v.get("id") == Some(&json!(2)) || v["method"] == method::MUX_PROMPT_ACCEPTED {
            return v;
        }
    }
}

fn prompt(prompt_id: Option<&str>) -> Value {
    let mut p = json!({"sessionId": "huge-blue/lane", "prompt": [{"type": "text", "text": "hi"}]});
    if let Some(id) = prompt_id {
        p["_meta"] = json!({"acpmux": {"promptId": id}});
    }
    p
}

#[tokio::test]
async fn a_prompt_to_a_down_peer_is_kept_and_the_sender_hears_it_waits() {
    let hub = setup();
    let (mut out, _open) = prompting(&hub, prompt(None)).await;
    let waiting = next(&mut out).await;
    assert_eq!(waiting["method"], method::MUX_PROMPT_ACCEPTED, "{waiting}");
    let p = &waiting["params"];
    assert_eq!(p["state"], prompt_outbox::OUTBOX_STATE);
    assert_eq!(p["peer"], "huge-blue");
    assert_eq!(p["sessionId"], LANE);
    // A prompt with no id got one, and the kept copy goes under it.
    let prompt_id = p["promptId"].as_str().unwrap();
    assert!(!prompt_id.is_empty());
    let kept = hub.outbox.get(p["deliveryId"].as_str().unwrap()).unwrap();
    assert_eq!(kept.prompt_id(), prompt_id);
    assert_eq!(kept.target, "huge-blue/lane");
    let waits = kept.interactive.as_ref().unwrap();
    assert_eq!(waits.peer, "huge-blue");
    assert_eq!(p["expiresAt"], json!(waits.expires_at));
    // The request stays open while it waits: no answer, no error.
    assert!(
        tokio::time::timeout(Duration::from_millis(300), next(&mut out)).await.is_err(),
        "the prompt answered while its peer is down"
    );
    assert!(!kept.settled());
}

#[tokio::test]
async fn a_prompt_past_the_peers_bound_is_refused_and_not_kept() {
    let hub = setup();
    let now = crate::store::now_ms();
    for n in 0..INTERACTIVE_MAX_PER_PEER {
        let (mut out, open) = prompting(&hub, prompt(Some(&format!("p-{n}")))).await;
        assert_eq!(next(&mut out).await["params"]["state"], prompt_outbox::OUTBOX_STATE);
        drop(open);
    }
    let (mut out, _open) = prompting(&hub, prompt(Some("p-over"))).await;
    let refused = next(&mut out).await;
    let error = &refused["error"];
    assert_eq!(error["data"]["reason"], INTERACTIVE_FULL, "{refused}");
    assert_eq!(error["data"]["waiting"], INTERACTIVE_MAX_PER_PEER);
    assert_eq!(error["data"]["peer"], "huge-blue");
    assert!(error["message"].as_str().unwrap().contains("this one was not sent"), "{refused}");
    let (kept, _) = hub.outbox.list(None, 100);
    assert_eq!(kept.len(), INTERACTIVE_MAX_PER_PEER);
    assert!(kept.iter().all(|d| d.prompt_id() != "p-over" && d.created_at >= now));
    // The same prompt id again is the one already waiting, never refused as one more.
    let (mut out, _open) = prompting(&hub, prompt(Some("p-0"))).await;
    assert_eq!(next(&mut out).await["params"]["state"], prompt_outbox::OUTBOX_STATE);
}

#[tokio::test]
async fn a_prompt_that_waited_past_its_wait_fails_as_expired() {
    let hub = setup();
    let (mut out, _open) = prompting(&hub, prompt(Some("p-old"))).await;
    let id = next(&mut out).await["params"]["deliveryId"].as_str().unwrap().to_owned();
    // Its wait ran out: the next attempt fails it instead of sending it.
    hub.outbox.update(&id, |d| {
        if let Some(waits) = d.interactive.as_mut() {
            waits.expires_at = 0;
        }
    });
    hub.outbox.end_delivery(&id);
    outbox::resume(&hub, vec![hub.outbox.get(&id).unwrap()]);
    let failed = next(&mut out).await;
    let error = &failed["error"];
    assert_eq!(error["data"]["reason"], "outbox.expired", "{failed}");
    assert_eq!(error["data"]["peer"], "huge-blue");
    assert!(
        error["message"]
            .as_str()
            .unwrap()
            .starts_with("not delivered: huge-blue stayed unreachable"),
        "{failed}"
    );
    assert_eq!(hub.outbox.get(&id).unwrap().status()["reason"], "outbox.expired");
}
