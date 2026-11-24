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
    let (asks, planned, later) =
        plan(PEER, false, &rows, &HashMap::new(), &HashMap::new(), (NOW_MS, now));
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

/// cmux#52931 recovery, `scripts/measure/fleet-recovery-bench.py --n 100`: a host this daemon keeps
/// copies of had 100 chats, and only the 24 that changed last were ever planned, so 20 moved without
/// their transcript. Its every open chat is planned; the cap bounds a round's reads, and the rest
/// come in the next round, after the settle.
#[test]
fn a_kept_peers_every_chat_is_read_a_capped_round_at_a_time() {
    let now = Instant::now();
    let rows: Vec<Value> = (0..5).map(|i| row(&format!("c{i}"), 3, 1_000 * i)).collect();
    let (asks, planned, later) =
        plan(PEER, true, &rows, &HashMap::new(), &HashMap::new(), (NOW_MS, now));
    assert_eq!(muxes(&asks), ["c0", "c1"], "WARM_PER_PEER (2 in tests) reads, newest change first");
    assert_eq!(planned.len(), 5, "every open chat is planned");
    assert_eq!(later, Some(now + WARM_SETTLE), "the rest are read in the next round");

    let covers: HashMap<_, _> =
        ["c0", "c1"].iter().map(|m| ((*m).to_owned(), (Some(42), 3))).collect();
    let (asks, ..) = plan(PEER, true, &rows, &covers, &HashMap::new(), (NOW_MS, now));
    assert_eq!(muxes(&asks), ["c2", "c3"], "a covered chat takes no read of the cap");

    // A peer kept only because a client here opened a peer chat: its newest chats alone.
    let (asks, planned, later) = plan(PEER, false, &rows, &covers, &HashMap::new(), (NOW_MS, now));
    assert!(asks.is_empty());
    assert_eq!(planned.len(), 2);
    assert_eq!(later, None);
}

#[test]
fn a_copy_is_read_past_what_it_covers_or_replaced_when_too_far_behind_or_of_another_session() {
    let now = Instant::now();
    let rows = [row("a", 500, 0), row("b", 900, 1)];
    let caught_up = HashMap::from([("a".to_owned(), (Some(42), 500))]);
    let (asks, planned, _) =
        plan(PEER, false, &rows[..1], &caught_up, &HashMap::new(), (NOW_MS, now));
    assert!(asks.is_empty(), "a copy that covers the row's last seq is not read again");
    assert!(planned.contains("a"));

    let covers =
        HashMap::from([("a".to_owned(), (Some(42), 450)), ("b".to_owned(), (Some(42), 100))]);
    let (asks, ..) = plan(PEER, false, &rows, &covers, &HashMap::new(), (NOW_MS, now));
    assert_eq!(muxes(&asks), ["a", "b"]);
    assert_eq!(asks[0].params["afterSeq"], json!(450), "within a page: only what is new");
    assert!(asks[0].params.get("beforeSeq").is_none());
    assert_eq!(asks[1].params["beforeSeq"], json!(NEWEST), "800 behind: the newest page");

    // Review of #28626 at 112a7bf: a copy past the row (a peer back on an older disk with the same
    // session) is read again from the newest page, which replaces it.
    let ahead = HashMap::from([("a".to_owned(), (Some(42), 520))]);
    let (asks, ..) = plan(PEER, false, &rows[..1], &ahead, &HashMap::new(), (NOW_MS, now));
    assert_eq!(asks[0].params["beforeSeq"], json!(NEWEST));
    assert!(asks[0].params.get("afterSeq").is_none());

    let recreated = HashMap::from([("a".to_owned(), (Some(41), 499))]);
    let (asks, ..) = plan(PEER, false, &rows[..1], &recreated, &HashMap::new(), (NOW_MS, now));
    assert_eq!(asks[0].params["beforeSeq"], json!(NEWEST), "a copy of the session before");
}

#[test]
fn a_chat_read_within_the_interval_waits_for_its_end_and_is_then_read() {
    let now = Instant::now();
    let rows = [row("a", 5, 0), row("b", 5, 1)];
    let read_at = HashMap::from([((PEER.to_owned(), "a".to_owned()), (42, now))]);
    let (asks, planned, later) = plan(PEER, false, &rows, &HashMap::new(), &read_at, (NOW_MS, now));
    assert_eq!(muxes(&asks), ["b"]);
    assert!(planned.contains("a"), "still planned, so its read time is kept");
    assert_eq!(later, Some(now + WARM_EVERY));
    let (asks, _, later) =
        plan(PEER, false, &rows, &HashMap::new(), &read_at, (NOW_MS, now + WARM_EVERY));
    assert_eq!(muxes(&asks), ["a", "b"]);
    assert_eq!(later, None);
    // Review of #28626 at 112a7bf: a read of the session before a recreation holds none back.
    let recreated = HashMap::from([((PEER.to_owned(), "a".to_owned()), (41, now))]);
    let (asks, _, later) = plan(PEER, false, &rows, &HashMap::new(), &recreated, (NOW_MS, now));
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
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::sessions_from_values(rows));
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
    let covers = hub.peer_snapshots.covers(PEER).unwrap();
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

/// A store behind (its queue past what reads ahead may fill): a read ahead's page is passed over
/// alone, the peer keeps the copies it has, and `covers` says the store is behind rather than
/// that there is no copy. A forwarded page still goes as before.
#[test]
fn a_read_ahead_gives_way_to_a_store_behind_and_costs_the_peer_no_copy() {
    use crate::peer::PeerNotice;
    let dir = cmux_unix_socket::short_test_dir("acpmux-pw");
    let hub = hub_at(dir.path());
    let (tx, _rx) = tokio::sync::mpsc::channel(8);
    let peer = crate::peer::Peer::new(PEER, "ws://127.0.0.1:9", None, None, tx);
    hub.peers.lock().unwrap().insert(PEER.to_owned(), peer.clone());
    let rows = vec![row("m1", 9, 0), row("m2", 9, 0)];
    hub.apply_peer_notice(PEER, peer.generation, PeerNotice::sessions_from_values(rows));
    let on = (PEER, peer.generation, peer.link_epoch(), Some(42));
    let newest = json!({"beforeSeq": NEWEST, "limit": 400, "kinds": WARM_KINDS});
    let page = |mux: &str| {
        let events: Vec<Value> = (6..=9)
            .map(|s| json!({"sessionId": mux, "seq": s, "kind": "agent_message_chunk", "msg": {}}))
            .collect();
        json!({"events": events, "hasMore": true, "lastSeq": 9, "pageThrough": 9, "createdAt": 42})
    };
    assert!(hub.capture_peer_page_ahead(on, "m1", &newest, &page("m1")));
    assert_eq!(hub.peer_snapshots.covers(PEER).unwrap().len(), 1);

    let snapshots = &hub.peer_snapshots;
    snapshots.queued.fetch_add(WARM_QUEUED_BYTES, Ordering::AcqRel);
    assert_eq!(snapshots.covers(PEER), None, "behind, not empty");
    assert!(!hub.capture_peer_page_ahead(on, "m2", &newest, &page("m2")));
    assert!(snapshots.dropped().peers.is_empty(), "no loss of the peer");
    snapshots.queued.fetch_sub(WARM_QUEUED_BYTES, Ordering::AcqRel);
    assert_eq!(
        snapshots.covers(PEER).unwrap(),
        HashMap::from([("m1".to_owned(), (Some(42), 9))]),
        "the copy it had stays; the passed-over page kept nothing"
    );
    assert!(hub.capture_peer_page_ahead(on, "m2", &newest, &page("m2")));
    assert_eq!(snapshots.covers(PEER).unwrap().len(), 2);
}

/// Process CPU time (user and system) so far.
fn cpu_time() -> Duration {
    // SAFETY: an all-zero rusage is valid, and getrusage only fills the struct it is given.
    let usage = unsafe {
        let mut usage: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut usage);
        usage
    };
    let tv = |t: libc::timeval| Duration::new(t.tv_sec as u64, t.tv_usec as u32 * 1000);
    tv(usage.ru_utime) + tv(usage.ru_stime)
}

/// What [`warm_rounds`] measured, in three phases: rounds before the store is behind, rounds
/// while it is, and rounds after.
#[derive(Debug, Default)]
struct Phase {
    /// Bytes of pages read from the peers.
    read: u64,
    /// Copies of the peers' chats there were none of after a round, summed over its rounds.
    missing: usize,
    /// Process CPU time.
    cpu: Duration,
}

/// The owner's Mac on 2026-11-22 in small: `peers` peers, each with [`WARM_PER_PEER`] chats that
/// take 3 records a round, read ahead by one thread per peer at once (their links answer at once),
/// with the store drained between rounds. Rounds 6 to 15 the store is behind: other captures
/// (25 links' replays, on the Mac) hold all but a few bytes of its queue. `old`: the read ahead
/// as before this change (a store behind reads as no copy, and its pages are admitted as a
/// forwarded page is, so a full queue costs the peer every copy); else as now.
fn warm_rounds(peers: usize, old: bool) -> [Phase; 3] {
    use crate::peer::PeerNotice;
    const ROUNDS: u64 = 20;
    let behind = 6..=15;
    let dir = cmux_unix_socket::short_test_dir("acpmux-pw");
    let hub = hub_at(dir.path());
    let names: Vec<String> = (0..peers).map(|i| format!("peer-{i}")).collect();
    let links: Vec<_> = names
        .iter()
        .map(|name| {
            let (tx, rx) = tokio::sync::mpsc::channel(8);
            std::mem::forget(rx);
            let peer = crate::peer::Peer::new(name, "ws://127.0.0.1:9", None, None, tx);
            hub.peers.lock().unwrap().insert(name.clone(), peer.clone());
            peer
        })
        .collect();
    let chats: Vec<String> = (0..WARM_PER_PEER).map(|i| format!("m{i}")).collect();
    let record = |mux: &str, seq: u64| {
        json!({"sessionId": mux, "seq": seq, "at": seq, "dir": "agent",
               "kind": "agent_message_chunk", "msg": {"text": "x"}})
    };
    let mut phases: [Phase; 3] = Default::default();
    for round in 1..=ROUNDS {
        let phase = &mut phases[if round < *behind.start() {
            0
        } else if behind.contains(&round) {
            1
        } else {
            2
        }];
        let started = cpu_time();
        let last = 100 + 3 * round;
        let now = now_ms();
        let rows: Vec<Value> = chats
            .iter()
            .map(|mux| {
                json!({"sessionId": mux, "name": mux, "status": "idle", "createdAt": 42,
                       "lastSeq": last, "updatedAt": now})
            })
            .collect();
        for peer in &links {
            let notice = PeerNotice::sessions_from_values(rows.clone());
            hub.apply_peer_notice(&peer.name, peer.generation, notice);
        }
        let held = QUEUED_BYTES - OP_BYTES;
        if behind.contains(&round) {
            hub.peer_snapshots.queued.fetch_add(held, Ordering::AcqRel);
        }
        let bytes = std::sync::atomic::AtomicU64::new(0);
        std::thread::scope(|scope| {
            for peer in &links {
                let (hub, rows, bytes) = (&hub, &rows, &bytes);
                scope.spawn(move || {
                    let name = peer.name.as_str();
                    let covers = match hub.peer_snapshots.covers(name) {
                        Some(covers) => covers,
                        None if old => HashMap::new(),
                        None => return,
                    };
                    let reads = HashMap::new();
                    let (asks, ..) =
                        plan(name, false, rows, &covers, &reads, (now_ms(), Instant::now()));
                    for ask in asks {
                        let from = match ask.params.get("afterSeq").and_then(Value::as_u64) {
                            Some(after) => after + 1,
                            None => last.saturating_sub(SESSION_EVENTS as u64 - 1).max(1),
                        };
                        let events: Vec<Value> =
                            (from..=last).map(|s| record(&ask.mux, s)).collect();
                        let page = json!({"events": events, "hasMore": from > 1, "lastSeq": last,
                                          "pageThrough": last, "createdAt": 42});
                        bytes.fetch_add(record_bytes(&page), Ordering::Relaxed);
                        let on = (name, peer.generation, peer.link_epoch(), Some(ask.generation));
                        if old {
                            hub.capture_peer_page(on, (&ask.mux, true), &ask.params, &page);
                        } else if !hub.capture_peer_page_ahead(on, &ask.mux, &ask.params, &page) {
                            return;
                        }
                    }
                });
            }
        });
        if behind.contains(&round) {
            hub.peer_snapshots.queued.fetch_sub(held, Ordering::AcqRel);
        }
        // The interval between rounds: the store takes what it was sent.
        hub.peer_snapshots.flush_now();
        phase.read += bytes.into_inner();
        for name in &names {
            let covers = hub.peer_snapshots.covers(name).unwrap_or_default();
            phase.missing += chats.len() - covers.len().min(chats.len());
        }
        phase.cpu += cpu_time() - started;
    }
    phases
}

/// Root-fix of the read-ahead loop on the owner's Mac (2026-11-22: 25 peers, "captures fell
/// behind; this peer's copies go" for each, every round). While the store is behind, a read
/// ahead reads nothing and costs no copy; after, it reads only what changed. The old read ahead
/// is measured beside it, by the same harness, for the PR's numbers. Two peers: more copies are
/// past the test build's bounds on them (`TOTAL_BYTES`), which would evict copies either way.
#[test]
fn a_read_ahead_gives_way_while_the_store_is_behind_and_then_reads_what_changed() {
    let old = warm_rounds(2, true);
    let new = warm_rounds(2, false);
    eprintln!("warm-rounds old [before, behind, after]: {old:?}");
    eprintln!("warm-rounds new [before, behind, after]: {new:?}");
    assert_eq!(new[1].read, 0, "nothing is read while the store is behind");
    assert_eq!(new[1].missing + new[2].missing, 0, "a read ahead cost a copy: {new:?}");
    // The 10 rounds behind put 30 records a chat behind: after, one page of those a chat.
    let changed = (2 * WARM_PER_PEER * 33) as u64 * 200;
    assert!(new[2].read <= changed, "after, {} bytes read, past what changed", new[2].read);
}

/// fleet-dogfoods-remote move 2: a daemon with no clients of its own (the fleet watcher) reads
/// ahead the chats of a peer its config names as its own machine (`githubBroker`) or as a dedicated
/// agent VM (`vmBoundary`), so a move from its copy can start when that machine dies; a peer it
/// names as neither is read ahead only once a client here opens a peer chat, as before.
#[tokio::test]
async fn a_daemon_with_no_client_reads_ahead_the_peers_whose_copies_it_keeps() {
    let dir = cmux_unix_socket::short_test_dir("acpmux-pw");
    let hub = hub_at(dir.path());
    let add = |name: &str, url: &str| {
        let (tx, rx) = tokio::sync::mpsc::channel(8);
        std::mem::forget(rx);
        let peer = crate::peer::Peer::new(name, url, None, None, tx);
        hub.peers.lock().unwrap().insert(name.to_owned(), peer.clone());
        peer
    };
    let plain = add("plain", "ws://127.0.0.1:9");
    let lane = add("lane-vm", "ws://127.0.0.1:9");
    lane.set_vm_boundary(true);
    let mine = add("own-mac", "ssh://own-mac");
    mine.set_github_broker(true);
    assert!(!keeps_copies(&plain) && keeps_copies(&lane) && keeps_copies(&mine));
    for name in ["plain", "lane-vm", "own-mac"] {
        hub.warm_peer_copies(name);
    }
    {
        let s = hub.peer_snapshots.warm.state();
        assert!(!s.due.contains_key("plain"), "no client asked, and the config keeps none");
        assert!(s.due.contains_key("lane-vm") && s.due.contains_key("own-mac"));
    }
    assert!(hub.peer_snapshots.warm.started.load(Ordering::SeqCst));
    // Turned off by a reload: its next change reads nothing ahead.
    lane.set_vm_boundary(false);
    hub.peer_snapshots.warm.state().due.clear();
    hub.warm_peer_copies("lane-vm");
    assert!(hub.peer_snapshots.warm.state().due.is_empty());
    hub.stop_idle_reaper();
}

/// The cost of keeping every working chat of a fleet: `peers` peers whose chats each take
/// `per_round` records between two rounds ([`WARM_EVERY`], 30 s), every chat read each round past
/// its copy, the store flushed between rounds. Prints records paged and CPU per read; a minute is
/// two rounds, so 26 peers x 12 working chats is 624 reads a minute at most.
/// `cargo test -p acpmux --release --lib peer_copies_follow_bench -- --ignored --nocapture`
#[test]
#[ignore = "bench: prints records paged and CPU per read"]
fn peer_copies_follow_bench() {
    use crate::peer::PeerNotice;
    let (peers, per_round, rounds) = (26usize, 20u64, 20u64);
    let dir = cmux_unix_socket::short_test_dir("acpmux-pw");
    let hub = hub_at(dir.path());
    let links: Vec<_> = (0..peers)
        .map(|i| {
            let (tx, rx) = tokio::sync::mpsc::channel(8);
            std::mem::forget(rx);
            let name = format!("lane-{i}");
            let peer = crate::peer::Peer::new(&name, "ws://127.0.0.1:9", None, None, tx);
            peer.set_vm_boundary(true);
            hub.peers.lock().unwrap().insert(name, peer.clone());
            peer
        })
        .collect();
    let chats: Vec<String> = (0..WARM_PER_PEER).map(|i| format!("m{i}")).collect();
    let record = |mux: &str, seq: u64| {
        json!({"sessionId": mux, "seq": seq, "at": seq, "dir": "agent",
               "kind": "agent_message_chunk", "msg": {"text": "a line of a working turn"}})
    };
    let (mut reads, mut records, mut bytes, mut cpu) = (0u64, 0u64, 0u64, Duration::ZERO);
    let mut steady = (0u64, 0u64, Duration::ZERO);
    // Reads past a held copy (afterSeq), and cold reads of a chat the store could not keep: the
    // test-size store (TOTAL_BYTES, 40 KiB) holds a few of these chats, not all.
    let (mut follow_reads, mut follow_records, mut cold_reads) = (0u64, 0u64, 0u64);
    for round in 1..=rounds {
        let started = cpu_time();
        let last = per_round * round;
        let now = now_ms();
        let rows: Vec<Value> = chats
            .iter()
            .map(|mux| {
                json!({"sessionId": mux, "name": mux, "status": "running", "createdAt": 42,
                       "lastSeq": last, "updatedAt": now})
            })
            .collect();
        let (mut round_reads, mut round_records) = (0u64, 0u64);
        for peer in &links {
            let name = peer.name.as_str();
            hub.apply_peer_notice(
                name,
                peer.generation,
                PeerNotice::sessions_from_values(rows.clone()),
            );
            let covers = hub.peer_snapshots.covers(name).unwrap_or_default();
            let (asks, ..) =
                plan(name, false, &rows, &covers, &HashMap::new(), (now_ms(), Instant::now()));
            for ask in asks {
                let after = ask.params.get("afterSeq").and_then(Value::as_u64);
                let from = match after {
                    Some(after) => after + 1,
                    None => last.saturating_sub(WARM_LIMIT - 1).max(1),
                };
                let events: Vec<Value> = (from..=last).map(|s| record(&ask.mux, s)).collect();
                round_records += events.len() as u64;
                if round > 1 {
                    if after.is_some() {
                        (follow_reads, follow_records) =
                            (follow_reads + 1, follow_records + events.len() as u64);
                    } else {
                        cold_reads += 1;
                    }
                }
                let page = json!({"events": events, "hasMore": from > 1, "lastSeq": last,
                                  "pageThrough": last, "createdAt": 42});
                bytes += record_bytes(&page);
                let on = (name, peer.generation, peer.link_epoch(), Some(ask.generation));
                hub.capture_peer_page_ahead(on, &ask.mux, &ask.params, &page);
                round_reads += 1;
            }
        }
        hub.peer_snapshots.flush_now();
        let spent = cpu_time() - started;
        (reads, records, cpu) = (reads + round_reads, records + round_records, cpu + spent);
        if round > 1 {
            steady = (steady.0 + round_reads, steady.1 + round_records, steady.2 + spent);
        }
    }
    let held: usize =
        links.iter().map(|p| hub.peer_snapshots.covers(&p.name).unwrap_or_default().len()).sum();
    let per_read = steady.2 / u32::try_from(steady.0.max(1)).unwrap_or(u32::MAX);
    eprintln!(
        "peer-copies-follow: {peers} peers x {} chats, {per_round} records/chat/round, {rounds} rounds: \
         {reads} reads, {records} records, {bytes} bytes, cpu {cpu:?}; after the first round \
         {} reads, {} records, cpu {:?} ({per_read:?}/read); copies held {held}; \
         {follow_reads} reads past a copy took {follow_records} records, {cold_reads} cold",
        chats.len(),
        steady.0,
        steady.1,
        steady.2
    );
    assert!(follow_reads > 0, "some chats are followed past their copy");
    assert!(
        follow_records <= follow_reads * per_round,
        "a read past a copy takes only new records"
    );
}
