//! A peer costs nothing until something needs it (`peer_demand.rs`): run loops in ticked time,
//! every dial recorded and failing at once (`peer::test_dial`), so no socket or ssh is opened.

use super::*;
use crate::peer::{LinkEnd, PeerNotice, test_dial};
use crate::peer_link::Backoff;
use crate::protocol::peer_state::PeerLinkState;
use std::sync::Arc;
use tokio::sync::mpsc;

const URL: &str = "ws://127.0.0.1:9";

/// A peer whose notices go nowhere.
fn built(name: &str) -> Arc<Peer> {
    let (tx, rx) = mpsc::channel(1);
    drop(rx);
    Peer::new(name, URL, None, None, tx)
}

/// 130 saved peers at daemon start (the Mac that panicked had about that many): none dials, each
/// reads `idle`, and a use dials exactly the one used, at once.
#[tokio::test(start_paused = true)]
async fn a_hundred_and_thirty_peers_started_lazily_dial_none_until_one_is_used() {
    test_dial::refuse_all();
    let peers: Vec<Arc<Peer>> = (0..130).map(|i| lazily(|| built(&format!("m{i}")))).collect();
    let runs: Vec<_> = peers.iter().map(|p| tokio::spawn(p.clone().run())).collect();
    tokio::time::sleep(Duration::from_secs(6 * 60 * 60)).await;
    assert_eq!(test_dial::attempts().len(), 0, "a peer nobody used dialed");
    for peer in &peers {
        let summary = peer.summary();
        assert_eq!(summary["link"], "idle", "{}: {summary}", peer.name);
        assert_eq!(summary["attempts"], 0, "{}", peer.name);
        assert!(summary["nextRetryAt"].is_null(), "no attempt is scheduled: {summary}");
        // An older app reads it as a machine it may pick; the pick connects it.
        assert_eq!(peer.state().wire().folded(), PeerLinkState::Connected);
    }

    peers[42].want();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(test_dial::attempts().len(), 1, "the use dials its peer once, at once");
    assert!(!peers[42].idle_parked());
    for (i, peer) in peers.iter().enumerate() {
        assert_eq!(peer.idle_parked(), i != 42, "{}", peer.name);
    }
    for peer in &peers {
        peer.stop();
    }
    for run in runs {
        run.await.unwrap();
    }
    test_dial::clear();
}

/// A peer neither saved nor started lazily (a lease, a test's) dials at once, as before.
#[tokio::test(start_paused = true)]
async fn a_peer_not_started_lazily_dials_at_once() {
    test_dial::refuse_all();
    let peer = built("leased");
    let run = tokio::spawn(peer.clone().run());
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert_eq!(test_dial::attempts().len(), 1);
    // A saved one (an add, a reconnect) too.
    let added = saved(|| built("added"));
    assert!(!added.idle_parked());
    let added_run = tokio::spawn(added.clone().run());
    tokio::time::sleep(Duration::from_millis(10)).await;
    assert_eq!(test_dial::attempts().len(), 2);
    peer.stop();
    added.stop();
    run.await.unwrap();
    added_run.await.unwrap();
    test_dial::clear();
}

/// A saved peer's link is due to close once unused for the bound; a chat's activity, a client's
/// use or an ask holds it; a peer this daemon lends GitHub, and one not saved, never close.
#[tokio::test(start_paused = true)]
async fn an_unused_link_is_due_to_close_after_the_bound_and_any_use_holds_it() {
    let peer = saved(|| built("box"));
    assert!(!peer.idle_due());
    tokio::time::advance(IDLE_CLOSE_AFTER - Duration::from_secs(1)).await;
    assert!(!peer.idle_due());
    tokio::time::advance(Duration::from_secs(1)).await;
    assert!(peer.idle_due());

    peer.note_link_activity(crate::rpc::method::MUX_EVENT);
    assert!(!peer.idle_due(), "a chat's event is a use");
    tokio::time::advance(IDLE_CLOSE_AFTER).await;
    peer.note_link_activity("_acpmux/not_a_chat");
    assert!(peer.idle_due(), "other traffic is no use");
    peer.note_use();
    assert!(!peer.idle_due(), "a client's request is a use");
    tokio::time::advance(IDLE_CLOSE_AFTER).await;
    peer.want();
    assert!(!peer.idle_due(), "an ask holds it");

    let broker = saved(|| built("lends-github"));
    broker.set_github_broker(true);
    let leased = built("leased");
    tokio::time::advance(IDLE_CLOSE_AFTER * 4).await;
    assert!(!broker.idle_due(), "that peer asks over this link alone");
    assert!(!leased.idle_due());
}

/// The link closes unused: no outage, no failed attempt, no error, no ask, and the peer waits to
/// be used.
#[tokio::test]
async fn a_link_closed_unused_is_idle_with_no_outage() {
    let peer = saved(|| built("box"));
    let now = crate::store::now_ms();
    peer.with_link(|link| {
        link.opened(now - 1);
        link.ready(now);
    });
    peer.open.store(true, Ordering::SeqCst);
    peer.connected.store(true, Ordering::SeqCst);
    let epoch = peer.link_epoch();
    let mut backoff = Backoff::default();
    let notice = peer.finish_link(Ok(LinkEnd::Idle), &mut backoff);
    assert!(matches!(notice, Some(PeerNotice::Idle)), "{notice:?}");
    assert_eq!(peer.link_epoch(), epoch + 1, "the link's epoch moved");
    let summary = peer.summary();
    assert_eq!(summary["link"], "idle", "{summary}");
    assert_eq!(summary["connected"], false);
    assert_eq!(summary["attempts"], 0);
    assert!(summary["downSince"].is_null(), "{summary}");
    assert!(summary["error"].is_null(), "{summary}");
    assert_eq!(summary["lastSeen"], now);
    assert!(peer.idle_parked());
    assert!(!peer.is_wanted(), "closing unused asks for nothing");
}

/// A link that is down while nothing uses it stops redialing once unused for the bound: it reads
/// `offline` (it reconnects on use), and a use dials it again.
#[tokio::test(start_paused = true)]
async fn a_down_link_nobody_uses_stops_redialing_and_a_use_dials_again() {
    test_dial::refuse_all();
    let peer = saved(|| built("gone"));
    let run = tokio::spawn(peer.clone().run());
    tokio::time::sleep(IDLE_CLOSE_AFTER + Duration::from_secs(120)).await;
    let tried = test_dial::attempts().len();
    assert!(tried > 1, "it redials while it may be wanted: {tried}");
    assert!(peer.idle_parked(), "unused and down: it waits to be used");
    tokio::time::sleep(Duration::from_secs(6 * 60 * 60)).await;
    assert_eq!(test_dial::attempts().len(), tried, "no redial nobody waits on");
    let summary = peer.summary();
    assert_eq!(summary["link"], "offline", "down when last tried: {summary}");
    assert!(summary["nextRetryAt"].is_null(), "{summary}");

    peer.want();
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert_eq!(test_dial::attempts().len(), tried + 1, "a use dials it at once");
    peer.stop();
    run.await.unwrap();
    test_dial::clear();
}

/// A lazy start inside `saved` stays lazy, and the thread's start is restored after each scope.
#[test]
fn the_start_scopes_nest_and_restore() {
    lazily(|| {
        assert_eq!(START.with(Cell::get), Start::Lazy);
        saved(|| assert_eq!(START.with(Cell::get), Start::Lazy));
    });
    assert_eq!(START.with(Cell::get), Start::Dial);
    saved(|| assert_eq!(START.with(Cell::get), Start::Saved));
    assert_eq!(START.with(Cell::get), Start::Dial);
}
