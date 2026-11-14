//! The dialer against a real serving connection in peer role, over a pipe.
use super::*;
use acpmux_book::index::SummaryIndex;
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
