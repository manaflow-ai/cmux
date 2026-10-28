//! `_acpmux/wait` on a peer session wakes on the hub events of its row and on its deadline,
//! never on a timer (`tests/daemon_idle.rs` measures the local case).

use super::*;
use crate::peer::PeerNotice;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::task::{Context, Poll, Wake, Waker};
use std::time::Duration;

/// Counts the wakes of the future it is polled with.
#[derive(Default)]
struct Wakes(AtomicUsize);

impl Wake for Wakes {
    fn wake(self: Arc<Self>) {
        self.0.fetch_add(1, Ordering::SeqCst);
    }
}

impl Wakes {
    fn count(&self) -> usize {
        self.0.load(Ordering::SeqCst)
    }
}

/// A hub made outside any runtime: no peer notice loop, so the leased peer's failed connects
/// change no row; the test applies every notice itself.
fn hub() -> Arc<Hub> {
    let mut cfg = crate::config::Config::default();
    cfg.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    Hub::new(cfg, store)
}

fn paused_runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().start_paused(true).build().unwrap()
}

fn row(status: &str) -> Value {
    json!({"sessionId": "m1", "name": "lane", "status": status, "updatedAt": 5})
}

/// A wait on a running peer session sets no timer: ten idle seconds wake it 0 times. The
/// peer's change of the row wakes it, and it answers with the row resolved.
#[test]
fn a_wait_on_a_peer_session_wakes_only_on_its_change() {
    let hub = hub();
    paused_runtime().block_on(async {
        let cfg = crate::config::Config::default();
        let (lease, _) = hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, &cfg).unwrap();
        hub.apply_peer_notice("vm", lease.generation, PeerNotice::Sessions(vec![row("running")]));
        let params = json!({"sessions": ["m1"], "until": ["ready"]});
        let wakes = Arc::new(Wakes::default());
        let waker = Waker::from(wakes.clone());
        let mut cx = Context::from_waker(&waker);
        let mut pending = std::pin::pin!(wait(&hub, &params));
        assert!(pending.as_mut().poll(&mut cx).is_pending(), "a running session is not ready");

        tokio::time::advance(Duration::from_secs(10)).await;
        assert_eq!(wakes.count(), 0, "the wait woke with nothing changed");

        let changed =
            PeerNotice::SessionChanged { session: row("idle"), kind: "status".into(), seq: 2 };
        hub.apply_peer_notice("vm", lease.generation, changed);
        assert!(wakes.count() > 0, "the row's change did not wake the wait");
        let Poll::Ready(Ok(answer)) = pending.as_mut().poll(&mut cx) else {
            panic!("the wait did not answer after the row changed")
        };
        assert_eq!(answer["timedOut"], false, "{answer}");
        assert_eq!(answer["resolved"][0]["sessionId"], "m1", "{answer}");
        hub.end_peer_lease(&lease);
    });
}

/// A peer session deleted through this daemon (`forget_remote`) wakes a wait for its close at
/// once: the row leaves with an event, not at a later read.
#[test]
fn a_peer_session_forgotten_here_wakes_a_wait_for_its_close() {
    let hub = hub();
    paused_runtime().block_on(async {
        let cfg = crate::config::Config::default();
        let (lease, _) = hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, &cfg).unwrap();
        hub.apply_peer_notice("vm", lease.generation, PeerNotice::Sessions(vec![row("idle")]));
        let params = json!({"sessions": ["m1"], "until": ["closed"]});
        let wakes = Arc::new(Wakes::default());
        let waker = Waker::from(wakes.clone());
        let mut cx = Context::from_waker(&waker);
        let mut pending = std::pin::pin!(wait(&hub, &params));
        assert!(pending.as_mut().poll(&mut cx).is_pending(), "an idle session is not closed");

        hub.forget_remote("m1");
        assert!(wakes.count() > 0, "forgetting the row did not wake the wait");
        let Poll::Ready(Ok(answer)) = pending.as_mut().poll(&mut cx) else {
            panic!("the wait did not answer after the row left")
        };
        assert_eq!(answer["resolved"][0]["status"], "closed", "{answer}");
        assert_eq!(answer["resolved"][0]["missing"], true, "{answer}");
        hub.end_peer_lease(&lease);
    });
}

/// A wait with a deadline answers at it, timed out, and not before.
#[test]
fn a_wait_on_a_peer_session_answers_at_its_deadline() {
    let hub = hub();
    paused_runtime().block_on(async {
        let cfg = crate::config::Config::default();
        let (lease, _) = hub.lease_peer("vm", "ws://127.0.0.1:9", "t".into(), None, &cfg).unwrap();
        hub.apply_peer_notice("vm", lease.generation, PeerNotice::Sessions(vec![row("running")]));
        let params = json!({"sessions": ["m1"], "until": ["ready"], "timeoutMs": 5000});
        let wakes = Arc::new(Wakes::default());
        let waker = Waker::from(wakes.clone());
        let mut cx = Context::from_waker(&waker);
        let mut pending = std::pin::pin!(wait(&hub, &params));
        assert!(pending.as_mut().poll(&mut cx).is_pending());

        tokio::time::advance(Duration::from_millis(4999)).await;
        assert_eq!(wakes.count(), 0, "the wait woke before its deadline");
        tokio::time::advance(Duration::from_millis(1)).await;
        assert_eq!(wakes.count(), 1, "the deadline did not wake the wait once");
        let Poll::Ready(Ok(answer)) = pending.as_mut().poll(&mut cx) else {
            panic!("the wait did not answer at its deadline")
        };
        assert_eq!(answer["timedOut"], true, "{answer}");
        hub.end_peer_lease(&lease);
    });
}
