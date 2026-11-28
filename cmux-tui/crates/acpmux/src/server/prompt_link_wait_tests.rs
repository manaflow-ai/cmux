//! A prompt for a peer's chat sent while the peer's link is down for a moment (a daemon restart,
//! a Wi-Fi blip) waits a short time for the link and goes once it is back
//! (`peer_forward::PROMPT_LINK_WAIT`), instead of being refused at once. A link still down at the
//! end of the wait, and a peer that was removed, refuse as before.
//!
//! The tests run on paused tokio time: the link comes back at a virtual instant, and the times
//! measured are virtual ones.

use super::*;
use crate::config::{Config, StoreMode};
use std::time::Duration;

const CHAT: &str = "0190f2a4-7c1e-7d3a-9f00-00000000b11b";

/// A hub with peer `far` listing one chat, its link down.
fn hub_with_peer() -> (Arc<Hub>, Arc<crate::peer::Peer>) {
    let mut config = Config::default();
    config.store.mode = StoreMode::Memory;
    let store = crate::store::open(&config.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(config, store);
    let peer = hub.seed_down_peer("far", vec![row()]);
    (hub, peer)
}

fn row() -> Value {
    json!({"sessionId": CHAT, "name": "lane", "status": "idle", "turnCount": 1, "updatedAt": 5})
}

fn prompt(prompt_id: &str) -> Value {
    json!({
        "sessionId": format!("far/{CHAT}"),
        "prompt": [{"type": "text", "text": "through the blip"}],
        "_meta": {"acpmux": {"promptId": prompt_id}},
    })
}

/// `session/prompt` on a new unix-socket connection to `hub`: its result or its error, and how
/// long after it was sent the answer came.
async fn send(hub: &Arc<Hub>, params: Value) -> (Result<Value, Value>, Duration) {
    let (input, incoming) = mpsc::channel(8);
    let (output, mut outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let sent = tokio::time::Instant::now();
    input.send(Message::request(2, method::SESSION_PROMPT, params).to_line()).await.unwrap();
    loop {
        let line = tokio::time::timeout(Duration::from_secs(60), outgoing.recv()).await;
        let reply: Value = serde_json::from_str(&line.unwrap().unwrap()).unwrap();
        if reply.get("id") == Some(&json!(2)) {
            let took = sent.elapsed();
            return match reply.get("error") {
                Some(e) => (Err(e.clone()), took),
                None => (Ok(reply["result"].clone()), took),
            };
        }
    }
}

/// `peer`'s link back as a finished handshake leaves it: ready, its chats listed, and the hub
/// told, so that link's restores are decided (`restore_peer_journals`) and the restore gate lets
/// a prompt go.
async fn link_up(hub: &Arc<Hub>, peer: &crate::peer::Peer) {
    peer.open_link_for_tests();
    hub.seed_peer_back(peer, vec![row()]);
    let notice = (peer.name.clone(), peer.generation, crate::peer::PeerNotice::Connected);
    let _ = hub.peer_notices.send(notice).await;
}

/// The link comes back `after` from now, as a finished handshake leaves it, and the far daemon
/// answers the prompt it then takes: the prompt's line, or None when none came.
fn link_back_after(
    hub: &Arc<Hub>,
    peer: &Arc<crate::peer::Peer>,
    after: Duration,
) -> tokio::task::JoinHandle<Value> {
    let (hub, peer) = (hub.clone(), peer.clone());
    tokio::spawn(async move {
        tokio::time::sleep(after).await;
        link_up(&hub, &peer).await;
        let answer = json!({"stopReason": "end_turn"});
        peer.answer_until_for_tests(method::SESSION_PROMPT, answer).await
    })
}

fn reason(e: &Value) -> Option<&str> {
    e.pointer("/data/reason").and_then(Value::as_str)
}

/// (1) A prompt sent while the link is down for 3 s goes once the link is back, exactly once,
/// and its caller gets the far daemon's answer.
#[tokio::test(start_paused = true)]
async fn a_prompt_sent_while_the_link_blips_goes_once_it_is_back() {
    let (hub, peer) = hub_with_peer();
    let back = link_back_after(&hub, &peer, Duration::from_secs(3));
    let (reply, took) = send(&hub, prompt("prompt-blip")).await;
    let reply = reply.expect("refused while the link came back within the wait");
    assert_eq!(reply["stopReason"], "end_turn", "{reply}");
    assert!(took >= Duration::from_secs(3) && took < PROMPT_LINK_WAIT, "{took:?}");
    let line = back.await.unwrap();
    assert_eq!(line.pointer("/params/_meta/acpmux/promptId"), Some(&json!("prompt-blip")));
    assert_eq!(peer.queued_for_tests(method::SESSION_PROMPT).await, 0, "sent twice");
}

/// (2) A link still down when the wait ends refuses as before: the same unreachable error, its
/// data saying it was not sent and may be tried again, and nothing reaches the link after.
#[tokio::test(start_paused = true)]
async fn a_link_down_past_the_wait_refuses_as_before() {
    let (hub, peer) = hub_with_peer();
    let (reply, took) = send(&hub, prompt("prompt-long-outage")).await;
    let e = reply.expect_err("a link down past the wait took the prompt");
    assert_eq!(reason(&e), Some("peer_unreachable"), "{e}");
    assert_eq!(e.pointer("/data/retryable"), Some(&json!(true)), "{e}");
    assert!(took >= PROMPT_LINK_WAIT, "refused before the wait ended: {took:?}");
    // The link coming back later does not send the refused prompt.
    link_up(&hub, &peer).await;
    tokio::time::sleep(Duration::from_secs(30)).await;
    assert_eq!(peer.queued_for_tests(method::SESSION_PROMPT).await, 0, "sent after its refusal");
}

/// (3) A peer that is removed while a prompt waits for it refuses at once: no wait out.
#[tokio::test(start_paused = true)]
async fn a_removed_peer_refuses_a_waiting_prompt_at_once() {
    let (hub, peer) = hub_with_peer();
    let stopper = peer.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        stopper.stop();
    });
    let (reply, took) = send(&hub, prompt("prompt-removed")).await;
    let e = reply.expect_err("a stopped peer took the prompt");
    assert_eq!(reason(&e), Some("peer_unreachable"), "{e}");
    assert!(took < Duration::from_secs(1), "waited {took:?} on a stopped peer");
    // A peer stopped before the prompt came refuses it with no wait at all.
    let (reply, took) = send(&hub, prompt("prompt-removed-before")).await;
    assert!(reply.is_err() && took < Duration::from_millis(50), "{reply:?} after {took:?}");
}

/// A client that leaves while its prompt waits gets no late send: its wait ends with it.
#[tokio::test(start_paused = true)]
async fn a_caller_that_leaves_while_its_prompt_waits_gets_no_late_send() {
    let (hub, peer) = hub_with_peer();
    let (input, incoming) = mpsc::channel(8);
    let (output, outgoing) = mpsc::channel(64);
    tokio::spawn(serve_connection_with(hub.clone(), incoming, output, Origin::Local));
    let hello = json!({"protocolVersion": 1, "clientCapabilities": {}});
    input.send(Message::request(1, method::INITIALIZE, hello).to_line()).await.unwrap();
    let line = Message::request(2, method::SESSION_PROMPT, prompt("prompt-gone")).to_line();
    input.send(line).await.unwrap();
    tokio::time::sleep(Duration::from_secs(1)).await;
    drop((input, outgoing));
    tokio::time::sleep(Duration::from_secs(1)).await;
    link_up(&hub, &peer).await;
    tokio::time::sleep(Duration::from_secs(30)).await;
    assert_eq!(peer.queued_for_tests(method::SESSION_PROMPT).await, 0, "sent for a caller gone");
}

/// The duress table for the PR: the same prompt against a link cut for 1 s, 3 s and 10 s, 20
/// times each with a seeded jitter of up to 250 ms on the cut, on paused (virtual) tokio time.
/// It prints, per cut, the share delivered and refused, and the p50/p95 time to the answer.
/// It asserts nothing, so the same harness measures the build before the change too.
#[tokio::test(start_paused = true)]
async fn duress_table_prompt_through_a_cut_link() {
    const REPS: usize = 20;
    let mut seed: u64 = 0x5eed_b11b;
    let mut jitter = move || {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        Duration::from_millis(seed % 250)
    };
    let mut table = String::from(
        "| link cut | delivered | refused | delivered p50 / p95 | refused p50 / p95 |\n|---|---|---|---|---|\n",
    );
    for cut in [1u64, 3, 10] {
        let (mut ok, mut refused) = (Vec::new(), Vec::new());
        for rep in 0..REPS {
            let (hub, peer) = hub_with_peer();
            let back = link_back_after(&hub, &peer, Duration::from_secs(cut) + jitter());
            let (reply, took) = send(&hub, prompt(&format!("prompt-{cut}-{rep}"))).await;
            match reply {
                Ok(_) => ok.push(took),
                Err(_) => refused.push(took),
            }
            back.abort();
        }
        let pct = |mut v: Vec<Duration>, q: f64| -> String {
            if v.is_empty() {
                return "-".into();
            }
            v.sort();
            let at = ((v.len() as f64 - 1.0) * q).round() as usize;
            format!("{:.2} s", v[at].as_secs_f64())
        };
        let (n_ok, n_refused) = (ok.len(), refused.len());
        table.push_str(&format!(
            "| {cut} s | {n_ok}/{REPS} | {n_refused}/{REPS} | {} / {} | {} / {} |\n",
            pct(ok.clone(), 0.5),
            pct(ok, 0.95),
            pct(refused.clone(), 0.5),
            pct(refused, 0.95),
        ));
    }
    println!("{table}");
}
