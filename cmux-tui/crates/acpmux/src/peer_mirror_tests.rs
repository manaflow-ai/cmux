//! The dialer against a real serving connection in peer role, over a pipe.
use super::*;
use acpmux_book::index::{OriginState, SummaryIndex};
use acpmux_core::conn::{HubSource, Role};
use std::collections::BTreeMap;

const ORIGIN: &str = "peer-a";
const WAIT: Duration = Duration::from_secs(20);

fn row(id: &str, title: &str, at: u64) -> Summary {
    let mut summary = Summary::new(id);
    summary.state = "running".to_owned();
    summary.title = title.to_owned();
    summary.last_activity = at;
    summary
}

/// A hub with its writer running.
fn hub() -> Arc<Hub> {
    let (hub, writer) = Hub::new(SummaryIndex::new());
    tokio::spawn(writer.run());
    Arc::new(hub)
}

struct Link {
    counters: Arc<DialCounters>,
    dialing: tokio::task::JoinHandle<std::io::Result<DialEnd>>,
    serving: tokio::task::JoinHandle<()>,
}

/// Dials `peer` from `local` over a fresh pipe.
fn dial(peer: &Arc<Hub>, local: &Arc<Hub>) -> Link {
    let (near, far) = tokio::io::duplex(64 * 1024);
    let (far_read, far_write) = tokio::io::split(far);
    let source = Arc::new(HubSource::for_peer(peer.clone()));
    let serving = tokio::spawn(async move {
        let surfaces = ["list".to_owned()];
        let _ = acpmux_core::conn::run(far_read, far_write, source, "peer", &surfaces, Role::Peer)
            .await;
    });
    let (near_read, near_write) = tokio::io::split(near);
    let counters = Arc::new(DialCounters::default());
    let (hub, counting) = (local.clone(), counters.clone());
    let dialing =
        tokio::spawn(async move { mirror(hub, ORIGIN, near_read, near_write, &counting).await });
    Link { counters, dialing, serving }
}

impl Link {
    fn end(self) {
        self.dialing.abort();
        self.serving.abort();
    }
}

fn titles(hub: &Hub) -> BTreeMap<String, String> {
    hub.snapshot()
        .iter()
        .filter(|row| row.origin == ORIGIN)
        .map(|row| (row.chat_id.clone(), row.title.clone()))
        .collect()
}

fn expect(rows: &[(&str, &str)]) -> BTreeMap<String, String> {
    rows.iter().map(|(id, title)| ((*id).to_owned(), (*title).to_owned())).collect()
}

async fn until(what: &str, mut done: impl FnMut() -> bool) {
    let waited = tokio::time::timeout(WAIT, async {
        while !done() {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    })
    .await;
    assert!(waited.is_ok(), "never: {what}");
}

/// A first dial walks: the takeover from no source, the peer's live rows under
/// the origin, then the walk's end marks the view whole. A change after it
/// arrives as a unit that moves the cursor.
#[tokio::test]
async fn a_first_dial_walks_the_peer_and_follows_its_changes() {
    let (peer, local) = (hub(), hub());
    peer.submit(row("a", "a1", 1)).unwrap();
    peer.submit(row("b", "b1", 2)).unwrap();
    until("the peer holds its rows", || peer.snapshot().len() == 2).await;
    let link = dial(&peer, &local);
    until("the walk mirrored the rows", || titles(&local) == expect(&[("a", "a1"), ("b", "b1")]))
        .await;
    until("the walk ended whole", || local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole))
        .await;
    assert_eq!(local.source(ORIGIN), Some(Source::Mirror));
    let cursor = local.mirror_mark(ORIGIN).unwrap().cursor;
    peer.submit(row("a", "a2", 3)).unwrap();
    until("the change arrived", || titles(&local) == expect(&[("a", "a2"), ("b", "b1")])).await;
    until("the cursor moved", || local.mirror_mark(ORIGIN).unwrap().cursor > cursor).await;
    let counts = local.mirror_counts();
    assert_eq!(counts.out_of_order + counts.join_refused + counts.held, 0);
    assert_eq!(link.counters.walks.load(Ordering::Relaxed), 1);
    link.end();
}

/// A dial with the mark on resumes from it and sends no takeover: what the
/// peer changed while the link was down arrives, and no walk runs.
#[tokio::test]
async fn a_resume_from_the_mark_sends_no_takeover() {
    let (peer, local) = (hub(), hub());
    peer.submit(row("a", "a1", 1)).unwrap();
    until("the peer holds its row", || peer.snapshot().len() == 1).await;
    let first = dial(&peer, &local);
    until("the walk ended whole", || local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole))
        .await;
    first.end();
    peer.submit(row("a", "a2", 2)).unwrap();
    peer.submit(row("c", "c1", 3)).unwrap();
    let second = dial(&peer, &local);
    until("the resume brought both changes", || {
        titles(&local) == expect(&[("a", "a2"), ("c", "c1")])
    })
    .await;
    assert_eq!(second.counters.resumes.load(Ordering::Relaxed), 1);
    assert_eq!(second.counters.takeovers.load(Ordering::Relaxed), 0);
    assert_eq!(second.counters.walks.load(Ordering::Relaxed), 0);
    assert_eq!(local.mirror_counts().out_of_order, 0);
    second.end();
}

/// Decision 222: the mark is on, but its edition is one the peer left, so the
/// resume is answered with a window. The dialer sends its takeover, which
/// writes the mark off, and the walk's first unit (`after: None`) applies; no
/// unit is refused out of order.
#[tokio::test]
async fn a_window_answer_to_a_resume_takes_over_before_the_walk() {
    let (peer, local) = (hub(), hub());
    peer.submit(row("a", "a1", 1)).unwrap();
    until("the peer holds its row", || peer.snapshot().len() == 1).await;
    let stale = MirrorMark { cursor: 7, edition: 999_999, whole: true };
    local
        .submit_unit(
            Source::Mirror,
            MirrorUnit { origin: ORIGIN.to_owned(), after: None, changes: Vec::new(), mark: stale },
        )
        .unwrap();
    until("the stale mark is on", || local.mirror_mark(ORIGIN) == Some(stale)).await;
    let link = dial(&peer, &local);
    until("the walk mirrored the row", || titles(&local) == expect(&[("a", "a1")])).await;
    until("the walk ended whole", || {
        local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole && mark != stale)
    })
    .await;
    assert_eq!(link.counters.resumes.load(Ordering::Relaxed), 1, "it asked to resume");
    assert_eq!(link.counters.takeovers.load(Ordering::Relaxed), 1);
    assert_eq!(link.counters.walks.load(Ordering::Relaxed), 1);
    assert_eq!(local.mirror_counts().out_of_order, 0);
    link.end();
}

/// The break rule: a takeover writes the mark off under a running mirror, so
/// the mark is no longer the last one the dialer sent. Settled, it reads no
/// further frame of that subscription and starts again from the mark (off: a
/// walk), and the peer's next change still arrives.
#[tokio::test]
async fn a_mark_that_moved_under_the_dialer_starts_it_again_from_the_mark() {
    let (peer, local) = (hub(), hub());
    peer.submit(row("a", "a1", 1)).unwrap();
    until("the peer holds its row", || peer.snapshot().len() == 1).await;
    let link = dial(&peer, &local);
    until("the walk ended whole", || local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole))
        .await;
    local.takeover(ORIGIN, Source::Mirror).unwrap();
    until("the mark went off", || local.mirror_mark(ORIGIN).is_none()).await;
    peer.submit(row("a", "a2", 2)).unwrap();
    until("the change arrived after the restart", || titles(&local) == expect(&[("a", "a2")]))
        .await;
    until("the new walk ended whole", || local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole))
        .await;
    assert!(link.counters.restarts.load(Ordering::Relaxed) >= 1);
    assert_eq!(local.mirror_counts().out_of_order, 0, "no unit named the old mark");
    link.end();
}

/// A walk larger than a unit arrives in units of at most `MAX_UNIT_CHANGES`,
/// each following the last: every row is mirrored, and none is refused.
#[tokio::test]
async fn a_walk_larger_than_a_unit_arrives_in_bounded_units() {
    let (peer, local) = (hub(), hub());
    let rows = MAX_UNIT_CHANGES * 2 + 100;
    for n in 0..rows {
        peer.submit(row(&format!("r{n:05}"), "t", n as u64 + 1)).unwrap();
    }
    until("the peer holds its rows", || peer.snapshot().len() == rows).await;
    let link = dial(&peer, &local);
    until("the walk ended whole", || local.mirror_mark(ORIGIN).is_some_and(|mark| mark.whole))
        .await;
    assert_eq!(titles(&local).len(), rows);
    assert!(link.counters.units.load(Ordering::Relaxed) >= 3);
    let counts = local.mirror_counts();
    assert_eq!(counts.out_of_order + counts.join_refused + counts.held + counts.full, 0);
    assert_eq!(counts.rows_over_bound, 0);
    link.end();
}

/// A hub whose writer turns only while `open` is set: a test holds the
/// writer between two pieces of work so both land in one turn.
fn gated_hub() -> (Arc<Hub>, Arc<std::sync::atomic::AtomicBool>) {
    let (hub, mut writer) = Hub::new(SummaryIndex::new());
    let open = Arc::new(std::sync::atomic::AtomicBool::new(true));
    let turning = open.clone();
    tokio::spawn(async move {
        loop {
            if turning.load(Ordering::Acquire) {
                writer.turn();
            }
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    });
    (Arc::new(hub), open)
}

/// A stale mark the peer's edition does not hold, so the dial is answered
/// with a window and the dialer sends a takeover.
async fn put_stale_mark(local: &Hub, rows: usize) -> MirrorMark {
    let mut after = None;
    let mut mark = MirrorMark { cursor: 0, edition: 999_999, whole: false };
    for start in (0..rows.max(1)).step_by(MAX_UNIT_CHANGES) {
        mark.cursor += 1;
        mark.whole = start + MAX_UNIT_CHANGES >= rows;
        let changes = (start..rows.min(start + MAX_UNIT_CHANGES))
            .map(|n| {
                let mut stale = row(&format!("stale-{n:05}"), "stale", 1);
                stale.origin = ORIGIN.to_owned();
                UnitChange::Summary(Box::new(stale))
            })
            .collect();
        let unit = MirrorUnit { origin: ORIGIN.to_owned(), after, changes, mark };
        local.submit_unit(Source::Mirror, unit).unwrap();
        let want = mark;
        until("the stale unit applied", || local.mirror_mark(ORIGIN) == Some(want)).await;
        after = Some(mark);
    }
    mark
}

/// The way out of the takeover wait (c): another source's takeover queued right
/// behind the dialer's replaces it, and the origin is that source's. The
/// dialer does not wait for a mark that will not go off under its source: it
/// ends, refused, and v1 keeps the origin.
#[tokio::test]
async fn another_sources_takeover_behind_the_dialers_ends_the_mirror() {
    let peer = hub();
    let (local, open) = gated_hub();
    peer.submit(row("a", "a1", 1)).unwrap();
    until("the peer holds its row", || peer.snapshot().len() == 1).await;
    put_stale_mark(&local, 0).await;
    open.store(false, Ordering::Release);
    let link = dial(&peer, &local);
    until("the dialer sent its takeover", || link.counters.takeovers.load(Ordering::Relaxed) == 1)
        .await;
    local.takeover(ORIGIN, Source::V1).unwrap();
    open.store(true, Ordering::Release);
    let end = tokio::time::timeout(WAIT, link.dialing).await.expect("the dialer ended").unwrap();
    assert!(
        matches!(end, Ok(DialEnd::Refused(HubError::SourceRefused { owner: Source::V1, .. }))),
        "refused for v1: {end:?}"
    );
    assert_eq!(local.source(ORIGIN), Some(Source::V1));
    assert_eq!(local.mirror_counts().out_of_order, 0, "no unit went in");
    link.serving.abort();
}

/// The way out (c) for a held takeover: the origin's removal lands in the
/// same writer turn, before it, so the origin is leaving and the writer holds
/// the takeover. The dialer starts again rather than waiting on a mark that
/// stays where it is; the start again waits the leaving out and walks.
#[tokio::test]
async fn a_takeover_held_with_a_leaving_origin_starts_the_dialer_again() {
    let peer = hub();
    let (local, open) = gated_hub();
    peer.submit(row("a", "a1", 1)).unwrap();
    until("the peer holds its row", || peer.snapshot().len() == 1).await;
    // Enough rows that leaving takes many turns.
    put_stale_mark(&local, MAX_UNIT_CHANGES * 8).await;
    open.store(false, Ordering::Release);
    let link = dial(&peer, &local);
    until("the dialer sent its takeover", || link.counters.takeovers.load(Ordering::Relaxed) == 1)
        .await;
    local.origin(ORIGIN, OriginState::Removed, 1).unwrap();
    open.store(true, Ordering::Release);
    until("the takeover was held", || local.takeover_turns(ORIGIN).held >= 1).await;
    until("the dialer started again", || link.counters.restarts.load(Ordering::Relaxed) >= 1).await;
    until("the leaving ended", || !local.snapshot().is_origin_leaving(ORIGIN)).await;
    until("a second walk began", || link.counters.walks.load(Ordering::Relaxed) >= 2).await;
    assert!(!link.dialing.is_finished(), "the mirror runs on");
    assert_eq!(local.mirror_counts().out_of_order, 0);
    link.end();
}

/// A takeover refused at the bound on origins ends the mirror, refused,
/// instead of leaving the dialer waiting for a takeover that never applies.
#[tokio::test]
async fn a_takeover_refused_at_the_origin_bound_ends_the_mirror() {
    let peer = hub();
    let local = hub();
    peer.submit(row("a", "a1", 1)).unwrap();
    until("the peer holds its row", || peer.snapshot().len() == 1).await;
    for n in 0..acpmux_core::hub::MAX_ORIGINS {
        local.takeover(&format!("full-{n:03}"), Source::V1).unwrap();
    }
    until("the origins are full", || {
        local.source(&format!("full-{:03}", acpmux_core::hub::MAX_ORIGINS - 1)).is_some()
    })
    .await;
    let link = dial(&peer, &local);
    let end = tokio::time::timeout(WAIT, link.dialing).await.expect("the dialer ended").unwrap();
    assert!(matches!(end, Ok(DialEnd::Refused(HubError::OriginLimit))), "{end:?}");
    assert_eq!(local.takeover_turns(ORIGIN).refused, 1);
    assert!(titles(&local).is_empty());
    link.serving.abort();
}

/// A mirror's end sorts by what it means: the stream's end is a clean close, a
/// served code goes by the code, a hub refusal by the hub's own class.
#[test]
fn dial_end_eof_is_clean_close() {
    assert_eq!(DialEnd::Eof.resume_class(), ResumeErrorClass::CleanClose);
    assert_eq!(DialEnd::Closed("cursor_gone".into()).resume_class(), ResumeErrorClass::GapTooOld);
    assert_eq!(DialEnd::Closed("stale_edition".into()).resume_class(), ResumeErrorClass::GapTooOld);
    assert_eq!(DialEnd::Closed("mailbox_full".into()).resume_class(), ResumeErrorClass::Transient);
    assert_eq!(
        DialEnd::Closed("the client closed".into()).resume_class(),
        ResumeErrorClass::Unknown
    );
    assert_eq!(DialEnd::Refused(HubError::CursorGone).resume_class(), ResumeErrorClass::GapTooOld);
    assert_eq!(DialEnd::Refused(HubError::OriginLimit).resume_class(), ResumeErrorClass::Unknown);
}

/// Restarts in a row with no unit going in end the mirror once the Transient
/// budget is spent, after the same back-off as before; a unit going in gives
/// the whole budget back.
#[tokio::test(start_paused = true)]
async fn mirror_restarts_stop_at_the_transient_bound() {
    let local = hub();
    let counters = DialCounters::default();
    let mut dial = Dial::new(local, ORIGIN, &counters);
    dial.start();
    let bound = ResumeErrorClass::Transient.policy().attempts;
    let began = tokio::time::Instant::now();
    for _ in 0..bound {
        assert!(dial.restart().await.is_ok());
    }
    // 100ms, 200ms, ... up to the 5s cap: the waits are unchanged.
    let waited: Duration = (1..bound)
        .map(|n| Duration::from_millis(50).saturating_mul(1 << n.min(7)).min(MAX_RESTART_BACKOFF))
        .sum();
    assert!(began.elapsed() >= waited, "{:?} < {waited:?}", began.elapsed());
    assert_eq!(counters.restarts.load(Ordering::Relaxed), u64::from(bound));
    let end = dial.restart().await;
    assert!(
        matches!(
            end,
            Err(DialEnd::Restarts { class: ResumeErrorClass::Transient, attempts }) if attempts == bound
        ),
        "{end:?}"
    );
    assert_eq!(counters.restarts.load(Ordering::Relaxed), u64::from(bound));
    dial.restarts.on_success();
    assert!(dial.restart().await.is_ok());
}
