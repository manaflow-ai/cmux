//! The machine link's side of the network watch (`cmux-netwatch`): every change it sees reaches the
//! link ([`ClientConnection::network_changed`]): a parked recovery dials now, a dial on the old
//! network is dropped, and a live link is probed at once.

use std::sync::Weak;

use tokio::sync::watch;

pub use cmux_netwatch::{NetworkWatch, SETTLE};

use crate::connection::ClientConnection;

/// Tell `connection` about every change `changes` sees, until the watch or the connection is
/// gone. `changes` should come from before the connection's first dial: a change made since
/// then is passed on at once, so the new link is probed instead of riding a route that went
/// away while it was being set up.
pub async fn forward(mut changes: watch::Receiver<u64>, connection: Weak<ClientConnection>) {
    while changes.changed().await.is_ok() {
        changes.borrow_and_update();
        let Some(connection) = connection.upgrade() else { return };
        // The system's proxy answer belongs to the old network (a new Wi-Fi's PAC file, a VPN's
        // proxy, leaving the office): the redial asks again.
        cmux_proxy::proxy::forget();
        connection.network_changed();
    }
}
