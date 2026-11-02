//! `warm.rs`: which chats a round reads ahead and how, and that a newest page is kept as a copy
//! the way an attach's page is.

use super::*;

const PEER: &str = "far-box";
const NOW_MS: u64 = 10 * WARM_WITHIN_MS;

fn row(mux: &str, last_seq: u64, updated_ago_ms: u64) -> Value {
    json!({"sessionId": mux, "name": mux, "status": "idle", "createdAt": 42,
           "lastSeq": last_seq, "updatedAt": NOW_MS - updated_ago_ms})
}

fn muxes(asks: &[Ask]) -> Vec<&str> {
    asks.iter().map(|a| a.mux.as_str()).collect()
}

#[test]
fn a_round_reads_the_peers_open_chats_that_changed_last() {
    let now = Instant::now();
    let mut closed = row("closed", 9, 0);
    closed["status"] = json!("closed");
    let mut stale = row("stale", 9, 0);
    stale["stale"] = json!(true);
    let rows = [
        row("older", 5, 3_000),
        closed,
        stale,
        row("newest", 7, 1_000),
        row("empty", 0, 0),
        row("day-old", 9, WARM_WITHIN_MS + 1),
        row("newer", 6, 2_000),
    ];
    let (asks, planned, later) = plan(PEER, &rows, &HashMap::new(), &HashMap::new(), (NOW_MS, now));
    // At most WARM_PER_PEER (2 in tests), newest change first; never a closed, stale, empty or
    // day-old one.
    assert_eq!(muxes(&asks), ["newest", "newer"]);
    assert_eq!(planned, HashSet::from(["newest".to_owned(), "newer".to_owned()]));
    assert_eq!(later, None);
    // With no copy, the newest page within the pane's bounds and kinds.
    let params = &asks[0].params;
    assert_eq!(params["beforeSeq"], json!(NEWEST));
    assert_eq!(
        (params["limit"].clone(), params["maxBytes"].clone()),
        (json!(400), json!(128 << 10))
    );
    assert!(params.get("afterSeq").is_none());
    assert_eq!(params["kinds"].as_array().unwrap().len(), WARM_KINDS.len());
    assert_eq!(asks[0].generation, 42);
}

#[test]
fn a_copy_is_read_past_what_it_covers_or_replaced_when_too_far_behind_or_of_another_session() {
    let now = Instant::now();
    let rows = [row("a", 500, 0), row("b", 900, 1)];
    let caught_up = HashMap::from([("a".to_owned(), (Some(42), 500))]);
    let (asks, planned, _) = plan(PEER, &rows[..1], &caught_up, &HashMap::new(), (NOW_MS, now));
    assert!(asks.is_empty(), "a copy that covers the row's last seq is not read again");
    assert!(planned.contains("a"));

    let covers =
        HashMap::from([("a".to_owned(), (Some(42), 450)), ("b".to_owned(), (Some(42), 100))]);
    let (asks, ..) = plan(PEER, &rows, &covers, &HashMap::new(), (NOW_MS, now));
    assert_eq!(muxes(&asks), ["a", "b"]);
    assert_eq!(asks[0].params["afterSeq"], json!(450), "within a page: only what is new");
    assert!(asks[0].params.get("beforeSeq").is_none());
    assert_eq!(asks[1].params["beforeSeq"], json!(NEWEST), "800 behind: the newest page");

    // Review of #28626 at 112a7bf: a copy past the row (a peer back on an older disk with the same
    // session) is read again from the newest page, which replaces it.
    let ahead = HashMap::from([("a".to_owned(), (Some(42), 520))]);
    let (asks, ..) = plan(PEER, &rows[..1], &ahead, &HashMap::new(), (NOW_MS, now));
    assert_eq!(asks[0].params["beforeSeq"], json!(NEWEST));
    assert!(asks[0].params.get("afterSeq").is_none());

    let recreated = HashMap::from([("a".to_owned(), (Some(41), 499))]);
    let (asks, ..) = plan(PEER, &rows[..1], &recreated, &HashMap::new(), (NOW_MS, now));
    assert_eq!(asks[0].params["beforeSeq"], json!(NEWEST), "a copy of the session before");
}

#[test]
fn a_chat_read_within_the_interval_waits_for_its_end_and_is_then_read() {
    let now = Instant::now();
    let rows = [row("a", 5, 0), row("b", 5, 1)];
    let read_at = HashMap::from([((PEER.to_owned(), "a".to_owned()), (42, now))]);
    let (asks, planned, later) = plan(PEER, &rows, &HashMap::new(), &read_at, (NOW_MS, now));
    assert_eq!(muxes(&asks), ["b"]);
    assert!(planned.contains("a"), "still planned, so its read time is kept");
    assert_eq!(later, Some(now + WARM_EVERY));
    let (asks, _, later) = plan(PEER, &rows, &HashMap::new(), &read_at, (NOW_MS, now + WARM_EVERY));
    assert_eq!(muxes(&asks), ["a", "b"]);
    assert_eq!(later, None);
    // Review of #28626 at 112a7bf: a read of the session before a recreation holds none back.
    let recreated = HashMap::from([((PEER.to_owned(), "a".to_owned()), (41, now))]);
    let (asks, _, later) = plan(PEER, &rows, &HashMap::new(), &recreated, (NOW_MS, now));
    assert_eq!((muxes(&asks), later), (vec!["a", "b"], None));
}

#[test]
fn rounds_are_due_after_the_settle_and_one_runs_at_a_time_per_peer() {
    let warm = Warm::default();
    let now = Instant::now();
    warm.due_by(PEER, now + WARM_SETTLE);
    // A later change does not put the round off.
    warm.due_by(PEER, now + 2 * WARM_SETTLE);
    assert_eq!(warm.take_due(now), (vec![], Some(now + WARM_SETTLE)));
    assert_eq!(warm.take_due(now + WARM_SETTLE), (vec![PEER.to_owned()], None));
    // A change while the round runs waits for it to end.
    warm.due_by(PEER, now);
    assert_eq!(warm.take_due(now + WARM_SETTLE), (vec![], None));
    warm.state().running.remove(PEER);
    assert_eq!(warm.take_due(now + WARM_SETTLE), (vec![PEER.to_owned()], None));
}

fn hub_at(dir: &Path) -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Local;
    let store = crate::store::open(&cfg.store, dir).unwrap();
    Hub::new(cfg, store)
}

/// The newest page a read ahead (or the pane's read-ahead) asks for is kept as an attach's page is,
/// and the store says what it covers; an older page (`beforeSeq` short of the newest) is not.
#[test]
fn a_newest_page_is_kept_and_the_store_says_what_it_covers() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-pw");
    let hub = hub_at(dir.path());
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(PEER, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(PEER.to_owned(), peer.clone());
    let rows = vec![row("m1", 9, 0), row("m2", 9, 0)];
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::Sessions(rows));
    let records = |mux: &str, seqs: std::ops::RangeInclusive<u64>| -> Vec<Value> {
        seqs.map(|s| json!({"sessionId": mux, "seq": s, "kind": "agent_message_chunk", "msg": {}}))
            .collect()
    };
    let on = (PEER, peer.generation, peer.link_epoch(), Some(42));
    let newest = json!({"beforeSeq": NEWEST, "limit": 400, "kinds": WARM_KINDS});
    let page = json!({"events": records("m1", 6..=9), "hasMore": true, "lastSeq": 9,
                      "pageThrough": 9, "createdAt": 42});
    hub.capture_peer_page(on, ("m1", true), &newest, &page);
    let older = json!({"beforeSeq": 6, "limit": 400});
    let page = json!({"events": records("m2", 1..=5), "hasMore": false, "lastSeq": 9,
                      "pageThrough": 5, "createdAt": 42});
    hub.capture_peer_page(on, ("m2", true), &older, &page);
    // A page past the newest one's last seq joins it.
    let after = json!({"afterSeq": 9, "limit": 400});
    let page = json!({"events": records("m1", 10..=11), "hasMore": false, "lastSeq": 11,
                      "pageThrough": 11, "createdAt": 42});
    hub.capture_peer_page(on, ("m1", true), &after, &page);
    // Review of #28626 at a2cc1e2: the newest records after a seq need not start right after it, so
    // a page asked with both cursors is not kept (it would claim the seqs it skipped).
    let both = json!({"afterSeq": 2, "beforeSeq": NEWEST, "limit": 2});
    let page = json!({"events": records("m2", 8..=9), "hasMore": true, "lastSeq": 9,
                      "pageThrough": 9, "createdAt": 42});
    hub.capture_peer_page(on, ("m2", true), &both, &page);
    let covers = hub.peer_snapshots.covers(PEER);
    assert_eq!(covers, HashMap::from([("m1".to_owned(), (Some(42), 11))]));
    let got = hub.peer_snapshot(&json!({"sessionId": "far-box/m1"})).unwrap();
    let seqs: Vec<u64> =
        got["events"].as_array().unwrap().iter().map(|e| e["seq"].as_u64().unwrap()).collect();
    assert_eq!(seqs, (6..=11).collect::<Vec<_>>());
    assert_eq!(got["hasMore"], json!(true), "older records lie before the newest page");
}

/// Nothing is read ahead on a daemon none of whose clients opened a peer chat.
#[tokio::test]
async fn a_daemon_whose_clients_open_no_peer_chat_reads_nothing_ahead() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pw");
    let hub = hub_at(dir.path());
    hub.warm_peer_copies(PEER);
    assert!(hub.peer_snapshots.warm.state().due.is_empty());
    assert!(!hub.peer_snapshots.warm.started.load(Ordering::SeqCst));
    hub.want_peer_copies();
    hub.warm_peer_copies(PEER);
    assert!(hub.peer_snapshots.warm.state().due.contains_key(PEER));
    hub.stop_idle_reaper();
}

/// Review of #28626 at a2cc1e2 and 599fcb1: new records past a copy that do not fit one page are
/// read on after the interval, one page a round; a newest page, a page that held all there was, or
/// one that held nothing new is not cut short.
#[test]
fn a_page_past_the_copy_that_did_not_fit_is_cut_short() {
    let after = json!({"sessionId": "m1", "afterSeq": 10, "limit": 400, "maxBytes": 1});
    let page = |more: bool, seqs: &[u64]| {
        let events: Vec<Value> = seqs.iter().map(|s| json!({"seq": s, "kind": "k"})).collect();
        json!({"events": events, "hasMore": more})
    };
    assert!(cut_short(&after, &page(true, &[11, 14, 12])));
    assert!(!cut_short(&after, &page(false, &[11, 14])), "it held all there was");
    assert!(!cut_short(&after, &page(true, &[])), "nothing new: no loop");
    assert!(!cut_short(&after, &page(true, &[9, 10])));
    let newest = json!({"sessionId": "m1", "beforeSeq": NEWEST});
    assert!(!cut_short(&newest, &page(true, &[11, 14])), "a newest page is the tail");
}

/// Review of #28626 at a2cc1e2: a stopping daemon starts no round and aborts those running.
#[tokio::test]
async fn a_stopping_daemon_starts_no_round_and_ends_the_ones_running() {
    let warm = Warm::default();
    let now = Instant::now();
    let running = tokio::spawn(std::future::pending::<()>());
    warm.state().rounds.push(running.abort_handle());
    warm.due_by(PEER, now);
    warm.stop();
    assert_eq!(warm.take_due(now), (vec![], None));
    assert!(running.await.unwrap_err().is_cancelled());
}

/// Review of #28626 at a2cc1e2: a read the link refused ends the round; one the peer refused for
/// the chat alone passes over to the next chat.
#[test]
fn only_a_refusal_of_the_link_ends_a_round() {
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(PEER, "ws://127.0.0.1:9", None, None, tx);
    peer.connected.store(true, Ordering::SeqCst);
    let unreachable =
        RpcError::internal("peer_unreachable: x").with_data(json!({"reason": "peer_unreachable"}));
    assert!(link_down(&peer, &unreachable));
    assert!(!link_down(&peer, &RpcError::invalid_params("no session m1")));
    peer.connected.store(false, Ordering::SeqCst);
    assert!(link_down(&peer, &RpcError::internal("peer far-box timed out after 30s")));
}
