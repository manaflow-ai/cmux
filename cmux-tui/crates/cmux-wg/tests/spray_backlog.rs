//! While datagrams go on every path, one stuck path must not hold back the
//! others: the session waits only when no path can take a datagram.

use std::io;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::task::{Context, Poll};

use cmux_wg::{Multipath, PathKind, Received, SelectorConfig, Underlay};

/// A carrier whose send queue is full while `stuck` is set.
struct Stub {
    stuck: Arc<AtomicBool>,
}

impl Underlay for Stub {
    fn send(&mut self, _datagram: &[u8]) {}
    fn backlogged(&self) -> bool {
        self.stuck.load(Ordering::Relaxed)
    }
    fn poll_recv(&mut self, _cx: &mut Context<'_>, _buffer: &mut [u8]) -> Poll<io::Result<Received>> {
        Poll::Pending
    }
    fn has_peer(&self) -> bool {
        true
    }
}

#[test]
fn a_stuck_path_does_not_hold_back_a_spray() {
    let (multipath, _control) = Multipath::new(SelectorConfig::default());
    let lan = Arc::new(AtomicBool::new(false));
    let relay = Arc::new(AtomicBool::new(true));
    multipath.add_path(PathKind::DirectLan, Stub { stuck: lan.clone() });
    multipath.add_path(PathKind::ViaCloudRegion, Stub { stuck: relay.clone() });
    // No path has answered, so datagrams go on both.
    assert!(!multipath.backlogged(), "the LAN path still takes datagrams");
    lan.store(true, Ordering::Relaxed);
    assert!(multipath.backlogged(), "no path can take one");
    relay.store(false, Ordering::Relaxed);
    assert!(!multipath.backlogged());
}
