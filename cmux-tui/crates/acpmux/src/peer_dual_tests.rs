//! Dual send while the link's path is in doubt (`peer_dual.rs`): the doubt starts it on the
//! best other path, each chat event reaches the hub once, each request is answered once, a pong
//! on the link's path stops it, and what it costs.

use super::*;
use crate::peer_paths::{Paths, Via};
use tokio::io::DuplexStream;
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::{Message as Frame, protocol::Role};

type Server = WebSocketStream<DuplexStream>;

const MS: Duration = Duration::from_millis(1);
const WAIT: Duration = Duration::from_secs(5);

#[test]
fn the_best_other_path_is_the_partner_only_while_the_links_path_is_in_doubt() {
    let mut paths = Paths::new(&[Via::Link, Via::Url, Via::Ssh]);
    paths.pong(Via::Link, 3 * MS, 0);
    paths.pong(Via::Url, 10 * MS, 0);
    paths.pong(Via::Ssh, 40 * MS, 0);
    assert_eq!(paths.dual_partner(Via::Link, 3_000), None, "the link's path answers");
    assert_eq!(paths.dual_partner(Via::Link, 3_001), Some(Via::Url), "the faster other path");
    // The other paths keep answering; Url stops.
    paths.pong(Via::Ssh, 40 * MS, 3_000);
    paths.tick(7_000);
    assert_eq!(paths.dual_partner(Via::Link, 7_000), Some(Via::Ssh), "a dead path is no partner");
    // A pong on the link's path ends the doubt.
    paths.pong(Via::Link, 3 * MS, 7_100);
    assert_eq!(paths.dual_partner(Via::Link, 7_100), None);
    // No other path answers: nothing to send on.
    let mut alone = Paths::new(&[Via::Link, Via::Ssh]);
    alone.pong(Via::Link, 3 * MS, 0);
    assert_eq!(alone.dual_partner(Via::Link, 4_000), None);
}

#[test]
fn a_copy_carries_one_dual_id_and_a_frame_without_object_params_is_not_copied() {
    let line = r#"{"jsonrpc":"2.0","id":4,"method":"session/prompt","params":{"sessionId":"s","_meta":{"acpmux":{"promptId":"p"}}}}"#;
    let stamped: Value = serde_json::from_str(&dual::stamped(line, "n:1:2").unwrap()).unwrap();
    assert_eq!(stamped.pointer("/params/_meta/acpmux/dualId"), Some(&json!("n:1:2")));
    assert_eq!(stamped.pointer("/params/_meta/acpmux/promptId"), Some(&json!("p")));
    assert_eq!(dual::stamped(r#"{"jsonrpc":"2.0","id":4,"method":"m"}"#, "k"), None);
}

/// A link on path Link in doubt, Url answering, chat `s1` streamed from seq 5, and the probe of
/// Url running: the link's peer end and the probe's.
struct Rig {
    peer: Arc<Peer>,
    notices: mpsc::Receiver<(String, u64, PeerNotice)>,
    primary: Server,
    shadow: Server,
    tasks: Vec<tokio::task::JoinHandle<()>>,
}

impl Drop for Rig {
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

async fn ws_pair() -> (WebSocketStream<DuplexStream>, Server) {
    let (ours, theirs) = tokio::io::duplex(1 << 20);
    let client = WebSocketStream::from_raw_socket(ours, Role::Client, None).await;
    let server = WebSocketStream::from_raw_socket(theirs, Role::Server, None).await;
    (client, server)
}

/// The next text frame `ws` reads (answering pings as it reads), as JSON.
async fn next_text(ws: &mut Server) -> Value {
    loop {
        let frame = tokio::time::timeout(WAIT, ws.next())
            .await
            .expect("a frame comes")
            .expect("open")
            .expect("readable");
        if let Frame::Text(text) = frame {
            return serde_json::from_str(text.as_str()).unwrap();
        }
    }
}

/// Whether `ws` reads a text frame within `wait`.
async fn reads_text_within(ws: &mut Server, wait: Duration) -> Option<Value> {
    tokio::time::timeout(wait, next_text(ws)).await.ok()
}

async fn send(ws: &mut Server, v: Value) {
    ws.send(Frame::Text(v.to_string().into())).await.unwrap();
}

fn event(seq: u64) -> Value {
    json!({"jsonrpc": "2.0", "method": method::MUX_EVENT,
        "params": {"sessionId": "s1", "seq": seq, "kind": "agent_message_chunk"}})
}

/// The chat events the hub got, by seq, waiting until `count` came and then a little more for
/// any extra one.
async fn delivered(
    notices: &mut mpsc::Receiver<(String, u64, PeerNotice)>,
    count: usize,
) -> Vec<u64> {
    let mut seqs = Vec::new();
    loop {
        let wait = if seqs.len() >= count { Duration::from_millis(300) } else { WAIT };
        let Ok(Some((_, _, notice))) = tokio::time::timeout(wait, notices.recv()).await else {
            return seqs;
        };
        if let PeerNotice::Notification { method: m, params, .. } = notice
            && m == method::MUX_EVENT
            && let Some(seq) = params.get("seq").and_then(Value::as_u64)
        {
            seqs.push(seq);
        }
    }
}

async fn rig() -> Rig {
    rig_with(true).await
}

/// [`rig`], with the Url path presenting the peer token (`url_token`) or not.
async fn rig_with(url_token: bool) -> Rig {
    let (tx, notices) = mpsc::channel(1024);
    let mut peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    // The link's own pings stay out of the way: its path's doubt is set by hand.
    let timings = &mut Arc::get_mut(&mut peer).expect("only this test holds it").timings;
    timings.ping_every = Duration::from_secs(600);
    timings.handshake = Duration::from_secs(600);
    let now = crate::store::now_ms();
    let mut paths = Paths::new(&[Via::Link, Via::Url]);
    paths.pong(Via::Link, 3 * MS, now - 4_000);
    paths.pong(Via::Url, 10 * MS, now);
    *peer.paths.lock().unwrap() = Some(paths);
    peer.features.lock().unwrap().push(crate::server::dual_requests::FEATURE.to_owned());
    peer.note_token_path(Via::Link, true);
    peer.mark_attached("s1");
    peer.cursors.lock().unwrap().insert("s1".to_owned(), 5);

    let (client, mut primary) = ws_pair().await;
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let link = peer.clone();
    let serving = tokio::spawn(async move {
        let _ = link.serve(client, &mut out_rx).await;
    });
    // Its handshake's initialize goes out; the link is made ready by hand.
    assert_eq!(next_text(&mut primary).await["method"], method::INITIALIZE);
    // The handshake would replay `s1` from its cursor and then open its gate.
    peer.replay_highwater.lock().unwrap().clear();
    peer.admitting.store(false, Ordering::SeqCst);
    peer.connected.store(true, Ordering::SeqCst);
    peer.with_link(|l| l.ready(crate::store::now_ms()));
    peer.set_serving(Some(Via::Link));

    let (probe_client, shadow) = ws_pair().await;
    let probe = peer.clone();
    let probing = tokio::spawn(async move { probe.probe_link(Via::Url, probe_client, None).await });
    // The probe asks the Url path's daemon whether it is the peer principal there.
    let mut shadow = shadow;
    let hello = next_text(&mut shadow).await;
    assert_eq!(hello["method"], method::INITIALIZE);
    assert_eq!(hello.pointer("/params/_meta/acpmux/observer"), Some(&json!(true)));
    let answer = json!({"jsonrpc": "2.0", "id": hello["id"], "result": {"_meta": {"acpmux": {
        "dualPrincipal": url_token, "features": [crate::server::dual_requests::FEATURE]}}}});
    send(&mut shadow, answer).await;
    Rig { peer, notices, primary, shadow, tasks: vec![serving, probing] }
}

/// The shadow attached `s1` after its cursor; the test answers it with `events`.
async fn answer_shadow_attach(rig: &mut Rig, events: &[u64]) {
    let attach = next_text(&mut rig.shadow).await;
    assert_eq!(attach["method"], method::MUX_ATTACH);
    assert_eq!(attach["params"]["sessionId"], "s1");
    assert_eq!(attach["params"]["afterSeq"], 5);
    let events: Vec<Value> = events
        .iter()
        .map(|seq| json!({"sessionId": "s1", "seq": seq, "kind": "agent_message_chunk"}))
        .collect();
    let id = attach["id"].clone();
    send(
        &mut rig.shadow,
        json!({"jsonrpc": "2.0", "id": id, "result": {"events": events, "hasMore": false}}),
    )
    .await;
}

#[tokio::test]
async fn a_path_in_doubt_sends_on_both_and_each_event_reaches_the_hub_once() {
    let mut rig = rig().await;
    // The doubt starts dual send on Url: its probe attaches the chat after its cursor.
    answer_shadow_attach(&mut rig, &[6, 7]).await;
    assert_eq!(rig.peer.dual_via(), Some(Via::Url));
    // The shadow's live stream, then the slow link's copies of the same events, then one the
    // link brings first.
    send(&mut rig.shadow, event(8)).await;
    assert_eq!(delivered(&mut rig.notices, 3).await, vec![6, 7, 8]);
    for seq in [6, 7, 8, 9] {
        send(&mut rig.primary, event(seq)).await;
    }
    assert_eq!(delivered(&mut rig.notices, 1).await, vec![9]);
    send(&mut rig.shadow, event(9)).await;
    send(&mut rig.shadow, event(10)).await;
    send(&mut rig.primary, event(10)).await;
    assert_eq!(delivered(&mut rig.notices, 1).await, vec![10], "no event twice");
    assert_eq!(*rig.peer.cursors.lock().unwrap().get("s1").unwrap(), 10);
    assert_eq!(rig.peer.dual_stats().repeats.load(Ordering::Relaxed), 5);
}

#[tokio::test]
async fn a_request_sent_on_both_paths_is_answered_once() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    let peer = rig.peer.clone();
    let asking = tokio::spawn(async move { peer.request(method::MUX_STATS, json!({})).await });
    let on_link = next_text(&mut rig.primary).await;
    let on_shadow = next_text(&mut rig.shadow).await;
    assert_eq!(on_link["method"], method::MUX_STATS);
    assert_eq!(on_link, on_shadow, "the same frame, with one dual id, on both paths");
    let dual_id = on_link.pointer("/params/_meta/acpmux/dualId").and_then(Value::as_str);
    assert!(dual_id.is_some_and(|id| id.starts_with(&rig.peer.dual_nonce)), "{on_link}");
    // The other path answers first; the link's late answer finds no caller.
    let id = on_link["id"].clone();
    send(&mut rig.shadow, json!({"jsonrpc": "2.0", "id": id, "result": {"from": "shadow"}})).await;
    let answer = tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
    assert_eq!(answer, json!({"from": "shadow"}));
    send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": id, "result": {"from": "link"}})).await;
    tokio::time::sleep(Duration::from_millis(100)).await;
    // Only the rig's unanswered initialize is still pending.
    assert!(!rig.peer.pending.lock().await.contains_key(&id.to_string()));
    assert!(rig.peer.dual_keys.lock().unwrap().is_empty());
}

#[tokio::test]
async fn a_pong_on_the_links_path_stops_dual_send() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    assert_eq!(rig.peer.dual_via(), Some(Via::Url));
    // The link's path answers again: the shadow detaches its chats and takes no more copies.
    rig.peer.path_pong(Via::Link, 3 * MS);
    let detach = next_text(&mut rig.shadow).await;
    assert_eq!(detach["method"], method::MUX_DETACH);
    assert_eq!(detach["params"]["sessionId"], "s1");
    assert_eq!(rig.peer.dual_via(), None);
    let frames = rig.peer.dual_stats().frames.load(Ordering::Relaxed);
    let peer = rig.peer.clone();
    let asking = tokio::spawn(async move { peer.request(method::MUX_STATS, json!({})).await });
    let on_link = next_text(&mut rig.primary).await;
    assert_eq!(on_link.pointer("/params/_meta/acpmux/dualId"), None, "{on_link}");
    assert_eq!(reads_text_within(&mut rig.shadow, Duration::from_secs(1)).await, None);
    assert_eq!(rig.peer.dual_stats().frames.load(Ordering::Relaxed), frames);
    // The probe stays open, measuring the path.
    assert!(!rig.tasks[1].is_finished());
    // An event the link sends is delivered by the link alone, as before.
    send(&mut rig.primary, event(6)).await;
    assert_eq!(delivered(&mut rig.notices, 1).await, vec![6]);
    send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": on_link["id"], "result": {}})).await;
    tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
}

/// What dual send costs: the bytes that go out on the second path while the link's path is in
/// doubt, for prompts of a typical size, against the bytes the link sends anyway.
#[tokio::test]
async fn the_extra_bytes_while_in_doubt_are_one_copy_of_each_frame() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    let attach_bytes = rig.peer.dual_stats().bytes.load(Ordering::Relaxed);
    const PROMPTS: usize = 50;
    let text = "fix the failing test in the peer link and say what changed ".repeat(17);
    let mut link_bytes = 0usize;
    let mut plain_bytes = 0usize;
    for n in 0..PROMPTS {
        let params = json!({"prompt": [{"type": "text", "text": text}], "n": n});
        plain_bytes +=
            Message::request(json!(0), method::MUX_STATS, params.clone()).to_line().len() - 1;
        let peer = rig.peer.clone();
        let asking = tokio::spawn(async move { peer.request(method::MUX_STATS, params).await });
        let on_link = next_text(&mut rig.primary).await;
        let on_shadow = next_text(&mut rig.shadow).await;
        assert_eq!(on_link, on_shadow);
        link_bytes += on_link.to_string().len();
        send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": on_link["id"], "result": {}})).await;
        tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
    }
    let stats = rig.peer.dual_stats();
    let copied = stats.bytes.load(Ordering::Relaxed) - attach_bytes;
    let frames = stats.frames.load(Ordering::Relaxed);
    let per_frame_stamp = (link_bytes - plain_bytes) / PROMPTS;
    eprintln!(
        "dual-send cost: {PROMPTS} prompts of {} bytes; {copied} bytes copied to the second path \
         for {link_bytes} bytes on the link ({:.2}x the link's bytes while in doubt); dual id \
         adds {per_frame_stamp} bytes per frame; the attach of 1 chat {attach_bytes} bytes; \
         {frames} frames copied in all",
        link_bytes / PROMPTS,
        (link_bytes as f64 + copied as f64) / link_bytes as f64,
    );
    // One copy of each frame: the second path carries what the link does, nothing more.
    assert!(copied.abs_diff(link_bytes as u64) <= PROMPTS as u64 * 4, "{copied} vs {link_bytes}");
    assert!(per_frame_stamp < 100, "{per_frame_stamp}");
}

/// F1: a `session/load` (and an attach) replays its chat on the connection it went on, so it
/// goes only on the link's path, never raced on the shadow: the link gets the load and its
/// replay, and the hub gets the replay. The daemon ignores a dual id on it too.
#[tokio::test]
async fn a_load_goes_on_the_links_path_alone_and_its_replay_reaches_the_hub() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    assert_eq!(rig.peer.dual_via(), Some(Via::Url));
    let peer = rig.peer.clone();
    let loading = tokio::spawn(async move {
        peer.request(method::SESSION_LOAD, json!({"sessionId": "s1", "cwd": "/"})).await
    });
    let on_link = next_text(&mut rig.primary).await;
    assert_eq!(on_link["method"], method::SESSION_LOAD);
    assert_eq!(on_link.pointer("/params/_meta/acpmux/dualId"), None, "{on_link}");
    assert_eq!(reads_text_within(&mut rig.shadow, Duration::from_millis(500)).await, None);
    // The load's history, replayed on the link, reaches the hub, seqs below the cursor too.
    for seq in [1, 2, 3] {
        send(&mut rig.primary, event(seq)).await;
    }
    assert_eq!(delivered(&mut rig.notices, 3).await, vec![1, 2, 3]);
    send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": on_link["id"], "result": {}})).await;
    tokio::time::timeout(WAIT, loading).await.unwrap().unwrap().unwrap();
    // The daemon runs a load or an attach that carries a dual id each time it comes.
    let stamped = json!({"sessionId": "s1", "_meta": {"acpmux": {"dualId": "n:1:1"}}});
    let peer_link = Some(crate::server::dual_requests::PEER_LINK);
    for m in [method::SESSION_LOAD, method::MUX_ATTACH, method::SESSION_RESUME] {
        let key = crate::server::dual_requests::key_for(peer_link, m, Some(&stamped));
        assert!(key.is_none(), "{m}");
    }
    let prompt =
        crate::server::dual_requests::key_for(peer_link, method::SESSION_PROMPT, Some(&stamped));
    assert!(prompt.is_some());
}

/// A prompt that carries a cloud turn runs only on the connection that prepared it: it goes
/// on the link's path alone, with no dual id, and runs there (the daemon takes it as any
/// prompt, `dual_requests::dual_safe`). A plain prompt still goes on both, and one a client
/// stamped with a dual id of its own carries this link's instead.
#[tokio::test]
async fn a_cloud_turn_prompt_goes_on_one_path_and_runs_there() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    let params = json!({"sessionId": "s1", "prompt": [],
        "cloud_turn": {"purpose": "execute", "session": "s1", "turn": "t1"},
        "_meta": {"acpmux": {"promptId": "t1"}}});
    let peer = rig.peer.clone();
    let asking = tokio::spawn(async move { peer.request(method::SESSION_PROMPT, params).await });
    let on_link = next_text(&mut rig.primary).await;
    assert_eq!(on_link["method"], method::SESSION_PROMPT);
    assert_eq!(on_link.pointer("/params/_meta/acpmux/dualId"), None, "{on_link}");
    assert_eq!(reads_text_within(&mut rig.shadow, Duration::from_millis(500)).await, None);
    let peer_link = Some(crate::server::dual_requests::PEER_LINK);
    let params = on_link.get("params");
    let key = crate::server::dual_requests::key_for(peer_link, method::SESSION_PROMPT, params);
    assert!(key.is_none(), "the daemon runs it as it comes");
    let done = json!({"jsonrpc": "2.0", "id": on_link["id"], "result": {"stopReason": "end_turn"}});
    send(&mut rig.primary, done).await;
    let answer = tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
    assert_eq!(answer["stopReason"], "end_turn");
    let params = json!({"sessionId": "s1", "prompt": [],
        "_meta": {"acpmux": {"promptId": "t2", "dualId": "forged"}}});
    let peer = rig.peer.clone();
    let asking = tokio::spawn(async move { peer.request(method::SESSION_PROMPT, params).await });
    let on_link = next_text(&mut rig.primary).await;
    let on_shadow = next_text(&mut rig.shadow).await;
    assert_eq!(on_link, on_shadow);
    let dual_id = on_link.pointer("/params/_meta/acpmux/dualId").and_then(Value::as_str);
    assert!(dual_id.is_some_and(|id| id.starts_with(&rig.peer.dual_nonce)), "{on_link}");
    send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": on_link["id"], "result": {}})).await;
    tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
}

/// F1: a load whose link switched paths before it answered is sent again on the next link,
/// with its caller still waiting; one whose link just dropped fails as before.
#[tokio::test]
async fn a_load_the_switch_cut_off_is_sent_again_on_the_next_link() {
    let (tx, _notices) = mpsc::channel(16);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let line = r#"{"jsonrpc":"2.0","id":7,"method":"session/load","params":{"sessionId":"s1"}}"#;
    for switched in [true, false] {
        let (reply, mut waiting) = oneshot::channel();
        peer.pending.lock().await.insert("7".to_owned(), reply);
        peer.switch_retry.lock().unwrap().insert("7".to_owned(), (line.to_owned(), 2));
        peer.switched.store(switched, Ordering::SeqCst);
        peer.fail_link_requests(&mut out_rx).await;
        assert_eq!(peer.pending.lock().await.contains_key("7"), switched);
        peer.resend_switched(3).await;
        match out_rx.try_recv() {
            Ok(again) => {
                assert!(switched);
                assert_eq!(
                    (again.epoch, again.key.as_deref(), again.line.as_str()),
                    (3, Some("7"), line)
                );
                assert!(waiting.try_recv().is_err(), "its caller still waits");
            }
            Err(_) => {
                assert!(!switched);
                assert!(waiting.try_recv().unwrap().is_err(), "it failed");
            }
        }
        peer.pending.lock().await.clear();
    }
}

/// F2: the shadow missed seq 6 and brought 7. The 7 waits; the link's 6 lets both through, in
/// order, and the cursor never skips 6.
#[tokio::test]
async fn an_event_past_a_gap_on_the_shadow_waits_for_the_seq_before_it() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    send(&mut rig.shadow, event(7)).await;
    assert_eq!(delivered(&mut rig.notices, 0).await, Vec::<u64>::new(), "7 waits for 6");
    assert_eq!(*rig.peer.cursors.lock().unwrap().get("s1").unwrap(), 5);
    send(&mut rig.primary, event(6)).await;
    send(&mut rig.primary, event(7)).await;
    assert_eq!(delivered(&mut rig.notices, 2).await, vec![6, 7]);
    assert_eq!(*rig.peer.cursors.lock().unwrap().get("s1").unwrap(), 7);
}

/// F2: the shadow says it lagged and brings 7 without 6: its stream is not trusted until it is
/// attached again from the cursor, and that attach brings 6 before 7. The same for a gap that
/// outlives its bound without a word from the daemon.
#[tokio::test]
async fn a_shadow_that_lagged_or_kept_a_gap_is_attached_again_from_the_cursor() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    send(
        &mut rig.shadow,
        json!({"jsonrpc": "2.0", "method": "_acpmux/lagged", "params": {"dropped": 1}}),
    )
    .await;
    send(&mut rig.shadow, event(7)).await;
    answer_shadow_attach(&mut rig, &[6, 7]).await;
    assert_eq!(delivered(&mut rig.notices, 2).await, vec![6, 7]);
    // Live again: 9 past a gap waits, and past the bound the chat is attached again after 7.
    send(&mut rig.shadow, event(9)).await;
    assert_eq!(delivered(&mut rig.notices, 0).await, Vec::<u64>::new());
    let attach =
        tokio::time::timeout(dual::GAP_BOUND + WAIT, next_text(&mut rig.shadow)).await.unwrap();
    assert_eq!(attach["method"], method::MUX_ATTACH);
    assert_eq!(attach["params"]["afterSeq"], 7);
    let id = attach["id"].clone();
    let events: Vec<Value> = [8, 9]
        .iter()
        .map(|seq| json!({"sessionId": "s1", "seq": seq, "kind": "agent_message_chunk"}))
        .collect();
    send(&mut rig.shadow, json!({"jsonrpc": "2.0", "id": id, "result": {"events": events}})).await;
    assert_eq!(delivered(&mut rig.notices, 2).await, vec![8, 9]);
}

/// F3: a fast shadow and a slow link race on every event: the hub gets each seq once, strictly
/// in order, with no gap.
#[tokio::test]
async fn a_fast_shadow_and_a_slow_link_deliver_strictly_in_order() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    const LAST: u64 = 300;
    let mut primary = std::mem::replace(&mut rig.primary, ws_pair().await.1);
    let slow = tokio::spawn(async move {
        for seq in 6..=LAST {
            send(&mut primary, event(seq)).await;
            if seq % 7 == 0 {
                tokio::time::sleep(Duration::from_millis(1)).await;
            }
        }
        primary
    });
    for seq in 6..=LAST {
        send(&mut rig.shadow, event(seq)).await;
    }
    let got = delivered(&mut rig.notices, (LAST - 5) as usize).await;
    let _primary = slow.await.unwrap();
    assert_eq!(got, (6..=LAST).collect::<Vec<_>>());
    assert_eq!(*rig.peer.cursors.lock().unwrap().get("s1").unwrap(), LAST);
}

/// Answers the shadow's next attach of `s1`, which must be after `after`, with `events` and
/// `hasMore`.
async fn answer_attach_page(rig: &mut Rig, after: u64, events: &[u64], more: bool) {
    let attach = next_text(&mut rig.shadow).await;
    assert_eq!(attach["method"], method::MUX_ATTACH, "{attach}");
    assert_eq!(attach["params"]["sessionId"], "s1");
    assert_eq!(attach["params"]["afterSeq"], after, "{attach}");
    let events: Vec<Value> = events
        .iter()
        .map(|seq| json!({"sessionId": "s1", "seq": seq, "kind": "agent_message_chunk"}))
        .collect();
    let page = json!({"events": events, "hasMore": more});
    send(&mut rig.shadow, json!({"jsonrpc": "2.0", "id": attach["id"], "result": page})).await;
}

/// The link's path is in doubt again, with Url answering: the next check starts a shadow.
async fn doubt_again(rig: &Rig) {
    let now = crate::store::now_ms();
    if let Some(paths) = rig.peer.paths.lock().unwrap().as_mut() {
        paths.pong(Via::Link, 3 * MS, now - 4_000);
        paths.pong(Via::Url, 10 * MS, now);
    }
    let started = tokio::time::Instant::now();
    while rig.peer.dual_via().is_none() {
        assert!(started.elapsed() < WAIT, "a shadow starts");
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// A load's replay is below the chat's cursor and no repeat: a shadow that starts while the
/// load is in flight leaves the chat alone, and the whole history reaches the hub, then the
/// live events in order.
#[tokio::test]
async fn a_shadow_that_starts_during_a_load_leaves_its_replay_whole() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    // The doubt clears: the shadow detaches.
    rig.peer.path_pong(Via::Link, 3 * MS);
    assert_eq!(next_text(&mut rig.shadow).await["method"], method::MUX_DETACH);
    let peer = rig.peer.clone();
    let loading = tokio::spawn(async move {
        peer.request(method::SESSION_LOAD, json!({"sessionId": "s1", "cwd": "/"})).await
    });
    let load = next_text(&mut rig.primary).await;
    assert_eq!(load["method"], method::SESSION_LOAD);
    // In doubt again before the replay comes: the new shadow does not take the chat.
    doubt_again(&rig).await;
    assert_eq!(reads_text_within(&mut rig.shadow, Duration::from_millis(700)).await, None);
    for seq in 1..=5 {
        send(&mut rig.primary, event(seq)).await;
    }
    send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": load["id"], "result": {}})).await;
    tokio::time::timeout(WAIT, loading).await.unwrap().unwrap().unwrap();
    for seq in [6, 7] {
        send(&mut rig.primary, event(seq)).await;
    }
    assert_eq!(delivered(&mut rig.notices, 7).await, vec![1, 2, 3, 4, 5, 6, 7]);
    assert_eq!(*rig.peer.cursors.lock().unwrap().get("s1").unwrap(), 7);
    assert!(rig.peer.replaying.lock().unwrap().is_empty());
}

/// A chat longer than one page: the shadow attaches it again from the cursor after each page
/// until one covers it, then streams it live. A page that moves nothing is tried again after a
/// wait.
#[tokio::test]
async fn a_chat_longer_than_one_page_is_attached_again_until_the_shadow_streams_it() {
    let mut rig = rig().await;
    answer_attach_page(&mut rig, 5, &[], true).await;
    answer_attach_page(&mut rig, 5, &[6, 7], true).await;
    answer_attach_page(&mut rig, 7, &[8], false).await;
    assert_eq!(delivered(&mut rig.notices, 3).await, vec![6, 7, 8]);
    send(&mut rig.shadow, event(9)).await;
    assert_eq!(delivered(&mut rig.notices, 1).await, vec![9], "live on the shadow");
}

/// The Url path's daemon serves its connection as the Web (a stale peer token: it restarted
/// with a new one) while it still lists `dualSend`: its `initialize` answer on that connection
/// says it is not the peer principal, so the path is never the shadow, and a request that would
/// be copied goes on the link alone, once.
#[tokio::test]
async fn a_path_the_daemon_serves_as_the_web_is_never_the_shadow() {
    let mut rig = rig_with(false).await;
    assert!(rig.peer.takes_dual(), "the daemon lists dualSend");
    assert_eq!(reads_text_within(&mut rig.shadow, Duration::from_millis(1_500)).await, None);
    assert_eq!(rig.peer.dual_via(), None);
    let params = json!({"sessionId": "s1", "prompt": [], "_meta": {"acpmux": {"promptId": "a1"}}});
    let peer = rig.peer.clone();
    let asking = tokio::spawn(async move { peer.request(method::SESSION_PROMPT, params).await });
    let on_link = next_text(&mut rig.primary).await;
    assert_eq!(on_link.pointer("/params/_meta/acpmux/dualId"), None, "{on_link}");
    assert_eq!(reads_text_within(&mut rig.shadow, Duration::from_millis(300)).await, None);
    let done = json!({"jsonrpc": "2.0", "id": on_link["id"], "result": {"stopReason": "end_turn"}});
    send(&mut rig.primary, done).await;
    let answer = tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
    assert_eq!(answer["stopReason"], "end_turn");
    assert_eq!(rig.peer.dual_stats().frames.load(Ordering::Relaxed), 0, "nothing copied");
}

/// An error from the shadow never settles a call sent on both paths: the caller keeps waiting,
/// and the link's later success is its answer.
#[tokio::test]
async fn an_error_from_the_shadow_leaves_the_caller_to_the_links_answer() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    let peer = rig.peer.clone();
    let asking = tokio::spawn(async move { peer.request(method::MUX_STATS, json!({})).await });
    let on_link = next_text(&mut rig.primary).await;
    let on_shadow = next_text(&mut rig.shadow).await;
    assert_eq!(on_link, on_shadow);
    let id = on_link["id"].clone();
    let refused = json!({"jsonrpc": "2.0", "id": id,
        "error": {"code": -32602, "message": "refused", "data": {"reason": "author.origin_refused"}}});
    send(&mut rig.shadow, refused).await;
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert!(rig.peer.pending.lock().await.contains_key(&id.to_string()), "still waiting");
    assert!(!asking.is_finished());
    send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": id, "result": {"from": "link"}})).await;
    let answer = tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
    assert_eq!(answer, json!({"from": "link"}));
}

/// A load made on the new link right after a switch (registered before the handshake resends
/// what the old link left) goes out once: only a load the old link carried is sent again, and
/// once only.
#[tokio::test]
async fn a_load_made_right_after_a_switch_is_sent_once() {
    let (tx, _notices) = mpsc::channel(16);
    let peer = Peer::new("p", "ws://127.0.0.1:9", None, None, tx);
    let mut out_rx = peer.out_rx.lock().await.take().unwrap();
    let old = r#"{"jsonrpc":"2.0","id":7,"method":"session/load","params":{"sessionId":"s1"}}"#;
    let new = r#"{"jsonrpc":"2.0","id":8,"method":"session/load","params":{"sessionId":"s2"}}"#;
    for key in ["7", "8"] {
        let (reply, _waiting) = oneshot::channel();
        std::mem::forget(_waiting);
        peer.pending.lock().await.insert(key.to_owned(), reply);
    }
    {
        let mut retry = peer.switch_retry.lock().unwrap();
        retry.insert("7".to_owned(), (old.to_owned(), 2));
        // Sent on link 3 already, by its caller.
        retry.insert("8".to_owned(), (new.to_owned(), 3));
    }
    peer.resend_switched(3).await;
    let again = out_rx.try_recv().expect("the old link's load goes again");
    assert_eq!(again.key.as_deref(), Some("7"));
    assert!(out_rx.try_recv().is_err(), "the new link's load is not sent twice");
    // A second resend on the same link sends nothing more.
    peer.resend_switched(3).await;
    assert!(out_rx.try_recv().is_err());
}

/// A resume sends no history and an attach answers with its history in its reply: neither
/// takes its chat out of dedup, so the link's late copies of what the shadow delivered are
/// still dropped.
#[tokio::test]
async fn a_resume_or_attach_keeps_its_chat_in_dedup() {
    assert!(dual::replays(method::SESSION_LOAD));
    assert!(!dual::replays(method::SESSION_RESUME));
    assert!(!dual::replays(method::MUX_ATTACH));
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[6, 7]).await;
    assert_eq!(delivered(&mut rig.notices, 2).await, vec![6, 7]);
    for m in [method::SESSION_RESUME, method::MUX_ATTACH] {
        let peer = rig.peer.clone();
        let asking = tokio::spawn(async move { peer.request(m, json!({"sessionId": "s1"})).await });
        let sent = next_text(&mut rig.primary).await;
        assert_eq!(sent["method"], m);
        send(&mut rig.primary, json!({"jsonrpc": "2.0", "id": sent["id"], "result": {}})).await;
        tokio::time::timeout(WAIT, asking).await.unwrap().unwrap().unwrap();
        assert!(rig.peer.replaying.lock().unwrap().is_empty(), "{m}");
    }
    for seq in [6, 7, 8] {
        send(&mut rig.primary, event(seq)).await;
    }
    assert_eq!(delivered(&mut rig.notices, 1).await, vec![8], "6 and 7 were the shadow's");
}

/// A pong ends the shadow while it holds 7 past a gap (cursor 5): the link's 6 brings 6 and
/// 7, its own 7 is a repeat, and only then does the link alone stream the chat: 6, 7, 8 once.
#[tokio::test]
async fn a_shadow_that_ends_with_events_held_leaves_no_repeat() {
    let mut rig = rig().await;
    answer_shadow_attach(&mut rig, &[]).await;
    send(&mut rig.shadow, event(7)).await;
    assert_eq!(delivered(&mut rig.notices, 0).await, Vec::<u64>::new(), "7 waits");
    rig.peer.path_pong(Via::Link, 3 * MS);
    assert_eq!(next_text(&mut rig.shadow).await["method"], method::MUX_DETACH);
    assert_eq!(rig.peer.dual_via(), None);
    for seq in [6, 7, 8] {
        send(&mut rig.primary, event(seq)).await;
    }
    assert_eq!(delivered(&mut rig.notices, 3).await, vec![6, 7, 8]);
    assert!(!rig.peer.dual_sessions.lock().unwrap().contains("s1"), "the link alone again");
}
