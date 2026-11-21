//! Part of `Peer`; see `peer.rs`. This computer's network changed (an address came or went, an
//! interface went up or down: a switch of Wi-Fi networks, a VPN, Wi-Fi back after a wake):
//! every peer link acts at once instead of waiting it out (`cmux-netwatch`, the watch the
//! machine link already uses). A live link sends a ping and is dropped and redialed when
//! nothing answers within [`NETWORK_PROBE`]; a link waiting out its backoff dials now. Before,
//! a link that rode the old route waited out its whole silence budget (6 s at least, measured
//! 7.0 s from an address change to the first answer at 1 ms RTT), and a parked one its backoff.
//!
//! Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up and load
//! faster/percievably load faster / whatever it takes / desktop gui, ios, remote, cloud, etc".

use std::sync::OnceLock;
use std::time::Duration;

use crate::no_panic::LockExt as _;
use cmux_netwatch::NetworkWatch;
use tokio::sync::watch;

/// How long a ping sent because the network changed has to go out and be answered before the link
/// is dropped and redialed. A route that survived the change answers well within it (the machine
/// link uses the same 2 s); a dead one would otherwise hold the link for its silence budget.
// timeout: a transport whose route went away with the old network never answers; a link that
// is merely slow answers late and is redialed at once, which costs one handshake.
pub const NETWORK_PROBE: Duration = Duration::from_secs(2);

static WATCH: OnceLock<NetworkWatch> = OnceLock::new();

/// The process's network watch, started on first use (one kernel socket and one thread for all
/// peers).
fn watch() -> &'static NetworkWatch {
    WATCH.get_or_init(NetworkWatch::start)
}

/// A receiver of network changes from now on: changes made before this call are not seen. Tests
/// get one that never changes (a change a test signals must not wake other tests' peers); a test
/// that wants changes gives its peer its own sender (`Peer::network`).
pub fn changes() -> watch::Receiver<u64> {
    if cfg!(test) {
        return watch::channel(0).1;
    }
    let mut receiver = watch().subscribe();
    receiver.borrow_and_update();
    receiver
}

/// Waits for the next change `changes` sees; never returns once its sender is gone.
pub async fn changed(changes: &mut watch::Receiver<u64>) {
    if changes.changed().await.is_err() {
        std::future::pending::<()>().await;
    }
    changes.borrow_and_update();
}

impl super::Peer {
    /// The next change of this computer's network after the last one this peer acted on. A wait
    /// dropped by a `select!` before it ends leaves that change to the next wait.
    pub(super) async fn network_changed(&self) {
        let mut seen = self.network.lock_or_recover().clone();
        changed(&mut seen).await;
        *self.network.lock_or_recover() = seen;
    }
}
