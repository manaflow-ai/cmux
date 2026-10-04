//! The Cloud rescue shell: `cmux.terminal.backend/1`, kind `cloud-vm-rescue`
//! (cloud-app.md 3.4). Used when a machine's cmux-tui daemon is down.

mod backend;
pub mod iface;
mod transport;

pub use backend::{RESCUE_ID, RESCUE_KIND, RescueBackend};
pub(crate) use transport::MISSING_ROUTE;
pub use transport::{MissingRescueRoute, RescueTransport, StreamId, TransportEvent};
