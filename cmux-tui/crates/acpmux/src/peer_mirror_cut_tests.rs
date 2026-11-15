//! The dialer's cuts (d): a kill between two units of one frame and at each
//! step, random frames cut at random, a walk in a new edition, rows of another
//! origin, and a serving side that refuses `anchor: End`; with the two gates
//! `v2.pr08.dial_resume` and `v2.pr08.edition_walk`.
use super::*;
use acpmux_book::index::SummaryIndex;
use acpmux_client::wire::{Frame, FrameDecoder, FrameKind};
use acpmux_core::conn::{HubSource, Role};
use acpmux_core::hub::HubWriter;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::atomic::AtomicBool;
use std::time::Instant;

const ORIGIN: &str = "peer-a";
const WAIT: Duration = Duration::from_secs(30);

fn peer_row(id: &str, title: &str, at: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.origin = PEER_LOCAL.to_owned();
    summary.state = "running".to_owned();
    summary.title = title.to_owned();
    summary.last_activity = at;
    summary
}

fn titles(hub: &Hub, origin: &str) -> BTreeMap<String, String> {
    hub.snapshot()
        .iter()
        .filter(|row| row.origin == origin)
        .map(|row| (row.chat_id.clone(), row.title.clone()))
        .collect()
}

async fn until(what: &str, mut done: impl FnMut() -> bool) {
    let waited = tokio::time::timeout(WAIT, async {
        while !done() {
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
    })
    .await;
    assert!(waited.is_ok(), "never: {what}");
}

/// One change of a live frame, as the client hands it to the dialer.
#[derive(Clone, Debug)]
enum Op {
    Row {
        seq: u64,
        id: String,
        title: String,
    },
    Gone {
        seq: u64,
        id: String,
    },
    /// A change that moves the cursor and no row (an origin's state).
    Quiet {
        seq: u64,
    },
    /// A row and a gone that name another origin than the peer's own.
    Forged {
        seq: u64,
        id: String,
    },
}

impl Op {
    fn seq(&self) -> u64 {
        match self {
            Self::Row { seq, .. }
            | Self::Gone { seq, .. }
            | Self::Quiet { seq }
            | Self::Forged { seq, .. } => *seq,
        }
    }

    fn change(&self) -> Change<Summary> {
        let sid = "s".to_owned();
        match self {
            Self::Row { seq, id, title } => Change::Summary {
                sid,
                seq: *seq,
                summary: peer_row(id, title, *seq),
                replay: false,
            },
            Self::Gone { seq, id } => Change::Gone {
                sid,
                seq: *seq,
                origin: PEER_LOCAL.to_owned(),
                chat_id: id.clone(),
                why: None,
                replay: false,
            },
            Self::Quiet { seq } => {
                Change::ResumeEnd { sid, cursor: acpmux_client::wire::Cursor(*seq) }
            }
            Self::Forged { seq, id } if seq % 2 == 0 => {
                let mut summary = peer_row(id, "forged", *seq);
                summary.origin = "machine-z".to_owned();
                Change::Summary { sid, seq: *seq, summary, replay: false }
            }
            Self::Forged { seq, id } => Change::Gone {
                sid,
                seq: *seq,
                origin: "machine-z".to_owned(),
                chat_id: id.clone(),
                why: None,
                replay: false,
            },
        }
    }
}

/// The peer's rows after `ops`: what the uncut run ends with.
fn folded(ops: &[Op]) -> BTreeMap<String, String> {
    let mut rows = BTreeMap::new();
    for op in ops {
        match op {
            Op::Row { id, title, .. } => {
                rows.insert(id.clone(), title.clone());
            }
            Op::Gone { id, .. } => {
                rows.remove(id);
            }
            Op::Quiet { .. } | Op::Forged { .. } => {}
        }
    }
    rows
}

/// A dialer on `hub`'s subscription `s`, going on from the origin's mark in
/// edition 1, cutting units of `unit_changes`.
fn dialer<'a>(hub: &Arc<Hub>, counters: &'a DialCounters, unit_changes: usize) -> Dial<'a> {
    let mut dial = Dial::new(hub.clone(), ORIGIN, counters);
    dial.sid = "s".to_owned();
    dial.unit_changes = unit_changes;
    let mark = hub.mirror_mark(ORIGIN);
    dial.last_sent = mark;
    (dial.cursor, dial.edition, dial.whole) =
        mark.map_or((0, 1, true), |mark| (mark.cursor, mark.edition, mark.whole));
    dial
}

/// Runs one frame of `ops` through `dial`, the test turning `writer`: the
/// index after each turn that wrote a unit, the start first. With `stop`, no
/// turn runs after that many units: the frame is cut there, the rest unwritten.
async fn cut(
    dial: &mut Dial<'_>,
    writer: &mut HubWriter,
    ops: &[Op],
    stop: Option<usize>,
) -> Vec<Arc<SummaryIndex>> {
    let hub = dial.hub.clone();
    let mut states = vec![hub.snapshot()];
    let full = |states: &Vec<Arc<SummaryIndex>>| stop.is_some_and(|stop| states.len() > stop);
    {
        let frame = dial.frame(ops.iter().map(Op::change).collect());
        tokio::pin!(frame);
        loop {
            if full(&states) {
                // The kill: what the writer did not write is lost with the frame.
                return states;
            }
            tokio::select! {
                biased;
                end = &mut frame => {
                    assert!(end.is_none(), "the frame ended the mirror: {end:?}");
                    break;
                }
                () = tokio::task::yield_now() => {
                    if !hub.mirror_settled(ORIGIN) {
                        writer.turn();
                        states.push(hub.snapshot());
                    }
                }
            }
        }
    }
    if !hub.mirror_settled(ORIGIN) && !full(&states) {
        writer.turn();
        states.push(hub.snapshot());
    }
    states
}

/// Turns `writer` until the index read from disk is installed.
async fn hydrate(hub: &Hub, writer: &mut HubWriter) {
    for _ in 0..10_000 {
        if tokio::time::timeout(Duration::ZERO, hub.wait_hydrated()).await.is_ok() {
            return;
        }
        writer.turn();
    }
    panic!("the index never hydrated");
}

/// After a kill the peer sends again what follows the mark: the changes past
/// its cursor, in order.
fn after_mark(hub: &Hub, ops: &[Op]) -> Vec<Op> {
    let cursor = hub.mirror_mark(ORIGIN).map_or(0, |mark| mark.cursor);
    ops.iter().filter(|op| op.seq() > cursor).cloned().collect()
}

/// A live frame of `rows` changes over `ids` chats from `seq`, with gones and
/// quiet changes among them.
fn frame_ops(rng: &mut u64, rows: usize, ids: u64, mut seq: u64) -> Vec<Op> {
    let mut next = || {
        *rng ^= *rng << 13;
        *rng ^= *rng >> 7;
        *rng ^= *rng << 17;
        *rng
    };
    (0..rows)
        .map(|n| {
            seq += 1;
            let id = format!("c{:03}", next() % ids);
            match next() % 8 {
                0 => Op::Gone { seq, id },
                1 => Op::Quiet { seq },
                _ => Op::Row { seq, id, title: format!("t{n}") },
            }
        })
        .collect()
}

/// (d) A kill between two units of one frame, and at each step: the index
/// on disk at the cut, opened again, then the peer's changes past its mark,
/// end equal to the uncut run. Three units of a frame of 1,200 changes; the
/// cut falls before the first, between each two, and after the last.
#[tokio::test]
async fn a_kill_at_each_unit_of_a_frame_ends_equal_to_the_uncut_run() {
    let ops = frame_ops(&mut 0x9e37_79b9_7f4a_7c15, 1_200, 400, 0);
    let want = folded(&ops);
    let units = ops.len().div_ceil(MAX_UNIT_CHANGES);
    assert_eq!(units, 3);
    for stop in 0..=units {
        let directory = tempfile::tempdir().unwrap();
        {
            let (hub, mut writer) = Hub::open(directory.path(), 1, || 7).unwrap();
            let hub = Arc::new(hub);
            let counters = DialCounters::default();
            let mut dial = dialer(&hub, &counters, MAX_UNIT_CHANGES);
            let states = cut(&mut dial, &mut writer, &ops, Some(stop)).await;
            assert_eq!(states.len(), stop + 1, "{stop} units written before the kill");
        }
        let (hub, mut writer) = Hub::open(directory.path(), 2, || 8).unwrap();
        let hub = Arc::new(hub);
        hydrate(&hub, &mut writer).await;
        let mark = hub.mirror_mark(ORIGIN);
        // Decision 264: a stored mark opens the origin as the mirror's, and v1's
        // rows of it stay out until the dial.
        assert_eq!(hub.source(ORIGIN), mark.map(|_| Source::Mirror), "killed after {stop}");
        if mark.is_some() {
            let mut v1_row = peer_row("v1-row", "v1's", 1);
            v1_row.origin = ORIGIN.to_owned();
            hub.submit_from(Source::V1, v1_row).unwrap();
            writer.turn();
            assert!(!titles(&hub, ORIGIN).contains_key("v1-row"), "killed after {stop}");
        }
        let counters = DialCounters::default();
        let mut dial = dialer(&hub, &counters, MAX_UNIT_CHANGES);
        dial.start();
        dial.sid = "s".to_owned();
        let whole = mark.is_some_and(|mark| mark.whole);
        assert_eq!(counters.resumes.load(Ordering::Relaxed), u64::from(whole));
        let rest = after_mark(&hub, &ops);
        if !rest.is_empty() {
            cut(&mut dial, &mut writer, &rest, None).await;
        }
        assert_eq!(titles(&hub, ORIGIN), want, "killed after {stop} units");
        assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), ops.last().map(Op::seq));
        assert_eq!(hub.mirror_counts().out_of_order, 0);
        assert_eq!(counters.walks.load(Ordering::Relaxed), 0, "killed after {stop}: no walk");
    }
}

/// Decision 264: a hub opened again from its store (not the same object)
/// holds the origin as the mirror's while its mark is on. Between the open
/// and the dial no v1 row of the origin goes in, and the dial resumes from
/// the whole mark with no walk, ending equal to the peer.
#[tokio::test]
async fn a_hub_opened_from_its_store_resumes_its_mirror_with_no_walk() {
    let peer = peer_hub();
    peer_rows(&peer, 3 * MAX_UNIT_CHANGES, 1).await;
    let directory = tempfile::tempdir().unwrap();
    {
        let (local, writer) = Hub::open(directory.path(), 1, || 7).unwrap();
        let writing = tokio::spawn(writer.run());
        let local = Arc::new(local);
        let link = dial(&peer, &local);
        until("the walk ended whole", || {
            local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole)
                && titles(&local, ORIGIN).len() == 3 * MAX_UNIT_CHANGES
        })
        .await;
        link.end();
        local.close();
        writing.await.unwrap().unwrap();
    }
    peer.submit(peer_row("r00000", "changed while down", 1_000_000)).unwrap();
    let (local, writer) = Hub::open(directory.path(), 2, || 8).unwrap();
    tokio::spawn(writer.run());
    let local = Arc::new(local);
    local.wait_hydrated().await.unwrap();
    assert_eq!(
        local.source(ORIGIN),
        Some(Source::Mirror),
        "the stored mark opens it as the mirror's"
    );
    let mut v1_row = peer_row("v1-row", "v1's", 1);
    v1_row.origin = ORIGIN.to_owned();
    // What v1's tee would submit: the writer refuses it for the mirror's origin.
    local.submit_from(Source::V1, v1_row).unwrap();
    let mut mine = peer_row("mine", "a later local row", 2);
    mine.origin = "local".to_owned();
    local.submit(mine).unwrap();
    until("the writer took both", || titles(&local, "local").contains_key("mine")).await;
    assert!(
        !titles(&local, ORIGIN).contains_key("v1-row"),
        "no v1 row of the mirror's origin went in"
    );
    let link = dial(&peer, &local);
    until("the resume brought the change", || {
        titles(&local, ORIGIN).get("r00000").map(String::as_str) == Some("changed while down")
    })
    .await;
    assert_eq!(link.counters.walks.load(Ordering::Relaxed), 0, "a resume, not a walk");
    assert_eq!(link.counters.resumes.load(Ordering::Relaxed), 1);
    assert_eq!(titles(&local, ORIGIN), titles(&peer, PEER_LOCAL));
    assert!(!titles(&local, ORIGIN).contains_key("v1-row"));
    link.end();
}

/// (d) 10,000 random runs: a random live frame cut into units of a random
/// size, killed after a random unit, then the changes past the mark; each
/// run ends equal to the uncut run. The index the writer published is what a
/// kill leaves (it publishes after its sync).
#[tokio::test]
async fn ten_thousand_random_cuts_end_equal_to_the_uncut_run() {
    let mut rng = 0x2545_f491_4f6c_dd1d_u64;
    for run in 0..10_000 {
        let seed = rng;
        let rows = 1 + (rng % 40) as usize;
        let unit_changes = 1 + (rng >> 8) as usize % 7;
        let ops = frame_ops(&mut rng, rows, 12, 0);
        let want = folded(&ops);
        let (hub, mut writer) = Hub::new(SummaryIndex::new());
        let hub = Arc::new(hub);
        let counters = DialCounters::default();
        let states = cut(&mut dialer(&hub, &counters, unit_changes), &mut writer, &ops, None).await;
        assert_eq!(titles(&hub, ORIGIN), want, "run {run} (seed {seed:#x}) uncut");
        let stop = (rng >> 16) as usize % states.len();
        let (killed, mut writer) = Hub::new((*states[stop]).clone());
        let killed = Arc::new(killed);
        let rest = after_mark(&killed, &ops);
        if !rest.is_empty() {
            let counters = DialCounters::default();
            cut(&mut dialer(&killed, &counters, unit_changes), &mut writer, &rest, None).await;
        }
        assert_eq!(
            titles(&killed, ORIGIN),
            want,
            "run {run} (seed {seed:#x}): {rows} changes in units of {unit_changes}, killed after {stop}"
        );
        assert_eq!(killed.mirror_counts().out_of_order, 0, "run {run}");
    }
}

/// A hub whose writer the test's task turns, checking `check` after each
/// turn: a published index it fails sets `broken`.
fn watched_hub(
    check: impl Fn(&SummaryIndex) -> bool + Send + 'static,
) -> (Arc<Hub>, Arc<AtomicBool>) {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    let broken = Arc::new(AtomicBool::new(false));
    let (watching, flag) = (hub.clone(), broken.clone());
    tokio::spawn(async move {
        loop {
            writer.turn();
            if !check(&watching.snapshot()) {
                flag.store(true, Ordering::Release);
            }
            tokio::time::sleep(Duration::from_micros(200)).await;
        }
    });
    (hub, broken)
}

fn peer_hub() -> Arc<Hub> {
    let (hub, writer) = Hub::new(SummaryIndex::new());
    tokio::spawn(writer.run());
    Arc::new(hub)
}

struct Link {
    counters: Arc<DialCounters>,
    dialing: tokio::task::JoinHandle<std::io::Result<DialEnd>>,
    serving: tokio::task::JoinHandle<()>,
}

impl Link {
    fn end(self) {
        self.dialing.abort();
        self.serving.abort();
    }
}

fn serve(peer: &Arc<Hub>, far: tokio::io::DuplexStream) -> tokio::task::JoinHandle<()> {
    let (far_read, far_write) = tokio::io::split(far);
    let source = Arc::new(HubSource::for_peer(peer.clone()));
    tokio::spawn(async move {
        let surfaces = ["list".to_owned()];
        let _ = acpmux_core::conn::run(far_read, far_write, source, "peer", &surfaces, Role::Peer)
            .await;
    })
}

fn dial_over(
    local: &Arc<Hub>,
    near: tokio::io::DuplexStream,
    serving: tokio::task::JoinHandle<()>,
) -> Link {
    let (near_read, near_write) = tokio::io::split(near);
    let counters = Arc::new(DialCounters::default());
    let (hub, counting) = (local.clone(), counters.clone());
    let dialing =
        tokio::spawn(async move { mirror(hub, ORIGIN, near_read, near_write, &counting).await });
    Link { counters, dialing, serving }
}

fn dial(peer: &Arc<Hub>, local: &Arc<Hub>) -> Link {
    let (near, far) = tokio::io::duplex(64 * 1024);
    dial_over(local, near, serve(peer, far))
}

/// Writes the mark again in an edition the peer does not hold, as a restart
/// of the peer's index leaves it: the next dial is answered with a window.
async fn another_edition(local: &Hub) {
    let mark = local.mirror_mark(ORIGIN).expect("a mark");
    let moved = MirrorMark { edition: 999_999, ..mark };
    local
        .submit_unit(
            Source::Mirror,
            MirrorUnit {
                origin: ORIGIN.to_owned(),
                after: Some(mark),
                changes: Vec::new(),
                mark: moved,
            },
        )
        .unwrap();
    until("the mark is in the other edition", || local.mirror_mark(ORIGIN) == Some(moved)).await;
}

/// The peer's rows `r00000..` live, with `at` their activity.
async fn peer_rows(peer: &Hub, rows: usize, at: u64) {
    for n in 0..rows {
        peer.submit(peer_row(&format!("r{n:05}"), "live", at + n as u64)).unwrap();
    }
    until("the peer holds its rows", || peer.snapshot().len() == rows).await;
}

/// (d) A walk in a new edition, with the origin's rows still live on the
/// peer: no index the writer publishes in the walk lacks one of them or holds
/// it closed, so a subscriber sees no `gone` or `left` for a row still live.
/// The walk spans several units; a row the peer dropped while the link was
/// down goes at the walk's end.
#[tokio::test]
async fn a_walk_in_a_new_edition_drops_no_live_row() {
    let rows = 3 * MAX_UNIT_CHANGES;
    let peer = peer_hub();
    peer_rows(&peer, rows, 1).await;
    peer.submit(peer_row("dropped", "live", 1)).unwrap();
    let armed = Arc::new(AtomicBool::new(false));
    let checking = armed.clone();
    let (local, broken) = watched_hub(move |index| {
        !checking.load(Ordering::Acquire)
            || (0..rows).all(|n| {
                index
                    .get_row(&acpmux_book::index::RowKey::new(ORIGIN, format!("r{n:05}")))
                    .is_some_and(|row| row.state == "running")
            })
    });
    let first = dial(&peer, &local);
    until("the first walk ended whole", || {
        local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole)
            && titles(&local, ORIGIN).len() == rows + 1
    })
    .await;
    first.end();
    peer.remove(PEER_LOCAL, "dropped").unwrap();
    another_edition(&local).await;
    armed.store(true, Ordering::Release);
    let second = dial(&peer, &local);
    until("the walk in the new edition ended whole", || {
        local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole && mark.edition != 999_999)
            && titles(&local, ORIGIN).len() == rows
    })
    .await;
    assert!(!broken.load(Ordering::Acquire), "a published index lacked a live row");
    assert_eq!(second.counters.walks.load(Ordering::Relaxed), 1);
    assert!(!titles(&local, ORIGIN).contains_key("dropped"));
    second.end();
}

/// (d) Rows of another origin than the peer's own (a forged origin, or a
/// machine the peer itself mirrors) are not mirrored. The peer's own key
/// names `local`, and lands under the peer's origin: this daemon's own row of
/// the same chat id is never written or removed.
#[tokio::test]
async fn a_forged_origin_and_a_key_naming_local_stay_off_this_daemons_rows() {
    let peer = peer_hub();
    peer.submit(peer_row("mine", "the peer's", 1)).unwrap();
    let mut forged = peer_row("forged", "another machine's", 2);
    forged.origin = "machine-z".to_owned();
    peer.submit_from(Source::V1, forged).unwrap();
    until("the peer holds both rows", || peer.snapshot().len() == 2).await;
    let local = peer_hub();
    let mut own = peer_row("mine", "this daemon's", 3);
    own.origin = "local".to_owned();
    local.submit(own).unwrap();
    until("the local row is in", || titles(&local, "local").len() == 1).await;
    let link = dial(&peer, &local);
    until("the walk ended whole", || local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole))
        .await;
    assert_eq!(titles(&local, ORIGIN), BTreeMap::from([("mine".into(), "the peer's".into())]));
    assert!(titles(&local, "machine-z").is_empty(), "a third machine's row is not mirrored");
    peer.remove(PEER_LOCAL, "mine").unwrap();
    until("the peer's row went", || titles(&local, ORIGIN).is_empty()).await;
    assert_eq!(
        titles(&local, "local"),
        BTreeMap::from([("mine".into(), "this daemon's".into())]),
        "this daemon's own row is untouched"
    );
    link.end();
}

/// (d) A forged origin: a peer that sends a row or a gone under another
/// origin than its own (the serving side above never does). The dialer
/// mirrors neither and counts both; the peer's own rows around them land.
#[tokio::test]
async fn a_frame_with_a_forged_origin_mirrors_only_the_peers_own_rows() {
    let ops = vec![
        Op::Row { seq: 1, id: "a".into(), title: "the peer's".into() },
        Op::Forged { seq: 2, id: "mine".into() },
        Op::Forged { seq: 3, id: "a".into() },
        Op::Row { seq: 4, id: "b".into(), title: "the peer's".into() },
    ];
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let hub = Arc::new(hub);
    let mut own = peer_row("mine", "this daemon's", 1);
    own.origin = "local".to_owned();
    hub.submit(own).unwrap();
    writer.turn();
    let counters = DialCounters::default();
    cut(&mut dialer(&hub, &counters, 2), &mut writer, &ops, None).await;
    assert_eq!(titles(&hub, ORIGIN), folded(&ops));
    assert!(titles(&hub, "machine-z").is_empty());
    assert_eq!(titles(&hub, "local"), BTreeMap::from([("mine".into(), "this daemon's".into())]));
    assert_eq!(counters.foreign_rows.load(Ordering::Relaxed), 2);
    assert_eq!(hub.mirror_mark(ORIGIN).map(|mark| mark.cursor), Some(4));
}

/// A serving side of an older build: any `sub` that names an anchor is
/// refused with `invalid_params`; every other frame goes to the real one.
fn refusing_anchors(
    peer: &Arc<Hub>,
    near_far: tokio::io::DuplexStream,
) -> tokio::task::JoinHandle<()> {
    let (inner, far) = tokio::io::duplex(64 * 1024);
    let serving = serve(peer, far);
    let (mut from_dialer, to_dialer) = tokio::io::split(near_far);
    let (mut from_server, mut to_server) = tokio::io::split(inner);
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Vec<u8>>();
    let replies = tx.clone();
    tokio::spawn(async move {
        let mut to_dialer = to_dialer;
        while let Some(bytes) = rx.recv().await {
            if to_dialer.write_all(&bytes).await.is_err() {
                break;
            }
        }
    });
    tokio::spawn(async move {
        let mut buf = vec![0_u8; 16 * 1024];
        while let Ok(n) = from_server.read(&mut buf).await {
            if n == 0 || tx.send(buf[..n].to_vec()).is_err() {
                break;
            }
        }
    });
    tokio::spawn(async move {
        let mut decoder = FrameDecoder::default();
        let mut buf = vec![0_u8; 16 * 1024];
        while let Ok(n) = from_dialer.read(&mut buf).await {
            if n == 0 {
                break;
            }
            for frame in decoder.push(&buf[..n]).unwrap() {
                let request = frame.decode_json::<Value>().unwrap_or_default();
                if request["method"] == "sub" && !request["params"]["anchor"].is_null() {
                    let sid = request["params"]["sid"].clone();
                    let error = json!({"method": "sub", "sid": sid, "code": "invalid_params"});
                    let _ = replies.send(Frame::json(FrameKind::Error, &error).unwrap().encode());
                } else if to_server.write_all(&frame.encode()).await.is_err() {
                    return;
                }
            }
        }
    });
    serving
}

/// (d) A serving side that refuses `anchor: End` (an older build) ends the
/// mirror, closed, before any takeover: v1's tee keeps the origin and its
/// rows. With the origin the mirror's from an earlier link, the peer's hand
/// back (`peer_dialer.rs`) gives it to v1's tee on that end
/// (`hub/list_tee/handback_tests.rs`).
#[tokio::test]
async fn a_serving_side_that_refuses_anchor_end_leaves_v1_on_the_origin() {
    let peer = peer_hub();
    peer_rows(&peer, 3, 1).await;
    let local = peer_hub();
    let mut v1_row = peer_row("v1-row", "v1's", 1);
    v1_row.origin = ORIGIN.to_owned();
    local.submit_from(Source::V1, v1_row).unwrap();
    until("v1's row is in", || titles(&local, ORIGIN).len() == 1).await;
    let (near, far) = tokio::io::duplex(64 * 1024);
    let link = dial_over(&local, near, refusing_anchors(&peer, far));
    let end = tokio::time::timeout(WAIT, link.dialing).await.expect("the mirror ended").unwrap();
    assert!(matches!(end, Ok(DialEnd::Closed(_))), "{end:?}");
    assert_eq!(link.counters.takeovers.load(Ordering::Relaxed), 0);
    assert_eq!(local.source(ORIGIN), Some(Source::V1));
    assert_eq!(titles(&local, ORIGIN), BTreeMap::from([("v1-row".into(), "v1's".into())]));
    assert_eq!(local.mirror_mark(ORIGIN), None);
    link.serving.abort();
}

fn emit(name: &str, more: Value) {
    let mut line = json!({"name": name, "unit": "ns"});
    if let (Some(line), Value::Object(more)) = (line.as_object_mut(), more) {
        line.extend(more);
    }
    let line = line.to_string();
    eprintln!("V2_GATE {line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        use std::io::Write;
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(file, "{line}");
        }
    }
}

fn p95(values: &mut [u128]) -> u128 {
    values.sort_unstable();
    values[(values.len() * 95).div_ceil(100).saturating_sub(1)]
}

/// What a counting link saw: bytes each way, and when the first frame toward
/// the dialer that ends a resume (`replay: "end"`) or carries a window passed.
#[derive(Default)]
struct Wire {
    bytes: std::sync::atomic::AtomicU64,
    frames: std::sync::Mutex<Vec<Value>>,
    ended_at: std::sync::Mutex<Option<Instant>>,
}

/// A real serving side behind a proxy that counts the link's bytes both ways
/// and decodes the frames toward the dialer.
fn counted(peer: &Arc<Hub>, local: &Arc<Hub>) -> (Link, Arc<Wire>) {
    let (near, near_far) = tokio::io::duplex(64 * 1024);
    let (inner, far) = tokio::io::duplex(64 * 1024);
    let serving = serve(peer, far);
    let wire = Arc::new(Wire::default());
    let (mut from_dialer, mut to_dialer) = tokio::io::split(near_far);
    let (mut from_server, mut to_server) = tokio::io::split(inner);
    let up = wire.clone();
    tokio::spawn(async move {
        let mut buf = vec![0_u8; 16 * 1024];
        while let Ok(n) = from_dialer.read(&mut buf).await {
            if n == 0 || to_server.write_all(&buf[..n]).await.is_err() {
                break;
            }
            up.bytes.fetch_add(n as u64, Ordering::Relaxed);
        }
    });
    let down = wire.clone();
    tokio::spawn(async move {
        let mut decoder = FrameDecoder::default();
        let mut buf = vec![0_u8; 16 * 1024];
        while let Ok(n) = from_server.read(&mut buf).await {
            if n == 0 {
                break;
            }
            down.bytes.fetch_add(n as u64, Ordering::Relaxed);
            for frame in decoder.push(&buf[..n]).unwrap_or_default() {
                let value = frame.decode_json::<Value>().unwrap_or_default();
                let ends = (frame.kind == FrameKind::Delta && value["replay"] == "end")
                    || frame.kind == FrameKind::Window;
                if ends {
                    down.ended_at.lock().unwrap().get_or_insert_with(Instant::now);
                }
                if frame.kind != FrameKind::Hello {
                    down.frames.lock().unwrap().push(value);
                }
            }
            if to_dialer.write_all(&buf[..n]).await.is_err() {
                break;
            }
        }
    });
    (dial_over(local, near, serving), wire)
}

/// A peer with `live` running rows and `closed` closed rows beside them.
async fn shaped_peer(live: usize, closed: usize) -> Arc<Hub> {
    let peer = peer_hub();
    for n in 0..closed {
        let mut row = peer_row(&format!("closed-{n:05}"), "closed", 1 + n as u64);
        row.state = "closed".to_owned();
        peer.submit(row).unwrap();
    }
    for n in 0..live {
        peer.submit(peer_row(&format!("r{n:05}"), "live", 100_000 + n as u64)).unwrap();
    }
    until("the peer holds its rows", || peer.snapshot().len() == live + closed).await;
    peer
}

const LIVE: usize = 500;
const CLOSED: usize = 11_000;

/// A hub of its own store that mirrored `peer`'s live view whole, closed and
/// opened again from the store (decision 264: it opens as the mirror's).
async fn reopened_mirror(peer: &Arc<Hub>, directory: &std::path::Path) -> Arc<Hub> {
    {
        let (local, writer) = Hub::open(directory, 1, || 7).unwrap();
        let writing = tokio::spawn(writer.run());
        let local = Arc::new(local);
        let link = dial(peer, &local);
        until("the walk ended whole", || {
            local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole)
                && titles(&local, ORIGIN).len() == LIVE
        })
        .await;
        link.end();
        local.close();
        writing.await.unwrap().unwrap();
    }
    let (local, writer) = Hub::open(directory, 2, || 8).unwrap();
    tokio::spawn(writer.run());
    let local = Arc::new(local);
    local.wait_hydrated().await.unwrap();
    assert_eq!(local.source(ORIGIN), Some(Source::Mirror));
    local
}

/// A mirror reopened from its store over a peer of 500 live rows with
/// `closed` closed rows beside them, for dials with nothing missed.
struct Resumed {
    peer: Arc<Hub>,
    local: Arc<Hub>,
    _directory: tempfile::TempDir,
}

impl Resumed {
    async fn new(closed: usize) -> Self {
        let peer = shaped_peer(LIVE, closed).await;
        let directory = tempfile::tempdir().unwrap();
        let local = reopened_mirror(&peer, directory.path()).await;
        Self { peer, local, _directory: directory }
    }

    /// One dial: the time from the dial to the frame that ends the resume,
    /// and the link's bytes. It is one empty frame marked `end`, and no walk.
    async fn dial(&self) -> (u128, u128) {
        let started = Instant::now();
        let (link, wire) = counted(&self.peer, &self.local);
        until("the resume ended", || wire.ended_at.lock().unwrap().is_some()).await;
        let ended = wire.ended_at.lock().unwrap().unwrap();
        let time = ended.duration_since(started).as_nanos();
        until("the dialer read the end", || link.counters.resumes.load(Ordering::Relaxed) == 1)
            .await;
        tokio::time::sleep(Duration::from_millis(20)).await;
        let bytes = u128::from(wire.bytes.load(Ordering::Relaxed));
        let frames = wire.frames.lock().unwrap().clone();
        assert_eq!(frames.len(), 1, "one frame to the dialer: {frames:?}");
        assert_eq!(frames[0]["replay"], "end", "{frames:?}");
        assert!(
            frames[0]["ops"].as_array().is_none_or(Vec::is_empty),
            "nothing missed: {frames:?}"
        );
        assert_eq!(link.counters.walks.load(Ordering::Relaxed), 0, "a resume, not a walk");
        link.end();
        (time, bytes)
    }

    /// The digits of the cursor the dial resumes from.
    fn cursor_digits(&self) -> u128 {
        let cursor = self.local.mirror_mark(ORIGIN).map_or(0, |mark| mark.cursor);
        cursor.to_string().len() as u128
    }
}

#[ignore = "Linux gate: a resume with nothing missed, 500 live with 11k closed beside them against none"]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn v2_pr08_dial_resume() {
    let (small_rig, god_rig) = (Resumed::new(0).await, Resumed::new(CLOSED).await);
    let (mut small, mut god, mut small_bytes, mut god_bytes) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    // Rounds alternate, so drift on the runner falls on both sides alike.
    for _ in 0..60 {
        let (time, bytes) = small_rig.dial().await;
        small.push(time);
        small_bytes.push(bytes);
        let (time, bytes) = god_rig.dial().await;
        god.push(time);
        god_bytes.push(bytes);
    }
    let (small_p95, god_p95) = (p95(&mut small), p95(&mut god));
    let (small_b, god_b) = (p95(&mut small_bytes), p95(&mut god_bytes));
    emit(
        "v2.pr08.dial_resume",
        json!({"small_p95": small_p95, "god_p95": god_p95, "small_bytes": small_b, "god_bytes": god_b}),
    );
    assert!(god_p95 * 10 <= small_p95 * 12, "resume p95 {small_p95} -> {god_p95} ns");
    // The closed rows put no row on the link: the bytes differ only by the
    // cursor's longer number, named in the sub and in the `end`.
    let digits = god_rig.cursor_digits() - small_rig.cursor_digits();
    assert!(
        god_b <= small_b + 2 * digits,
        "closed rows put bytes on the link: {small_b} -> {god_b}"
    );
}

/// One walk in a new edition of a peer's 500 live rows with `closed` closed
/// rows beside them: its time from the dial to whole and the link's bytes,
/// each published index checked to hold every live row.
async fn edition_walk(closed: usize) -> (u128, u128) {
    let peer = shaped_peer(LIVE, closed).await;
    let armed = Arc::new(AtomicBool::new(false));
    let checking = armed.clone();
    let (local, broken) = watched_hub(move |index| {
        !checking.load(Ordering::Acquire)
            || index.origin_rows(ORIGIN).filter(|row| row.state == "running").count() == LIVE
    });
    let first = dial(&peer, &local);
    until("the first walk ended whole", || {
        local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole)
            && titles(&local, ORIGIN).len() == LIVE
    })
    .await;
    first.end();
    another_edition(&local).await;
    armed.store(true, Ordering::Release);
    let started = Instant::now();
    let (link, wire) = counted(&peer, &local);
    until("the walk ended whole", || {
        local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole && mark.edition != 999_999)
    })
    .await;
    let elapsed = started.elapsed().as_nanos();
    let bytes = u128::from(wire.bytes.load(Ordering::Relaxed));
    assert!(!broken.load(Ordering::Acquire), "a published index lacked a live row");
    assert_eq!(link.counters.walks.load(Ordering::Relaxed), 1);
    link.end();
    (elapsed, bytes)
}

#[ignore = "Linux gate: a walk in a new edition of 500 live rows, 11k closed beside them against none"]
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn v2_pr08_edition_walk() {
    let (mut small, mut god, mut small_bytes, mut god_bytes) =
        (Vec::new(), Vec::new(), Vec::new(), Vec::new());
    for _ in 0..5 {
        let (time, bytes) = edition_walk(0).await;
        small.push(time);
        small_bytes.push(bytes);
        let (time, bytes) = edition_walk(CLOSED).await;
        god.push(time);
        god_bytes.push(bytes);
    }
    let (small_p95, god_p95) = (p95(&mut small), p95(&mut god));
    let (small_b, god_b) = (p95(&mut small_bytes), p95(&mut god_bytes));
    emit(
        "v2.pr08.edition_walk",
        json!({"small_p95": small_p95, "god_p95": god_p95, "small_bytes": small_b, "god_bytes": god_b}),
    );
    assert!(god_b < 200 * 1024, "the walk put {god_b} bytes on the link");
    assert!(god_p95 * 10 <= small_p95 * 12, "walk p95 {small_p95} -> {god_p95} ns");
}
