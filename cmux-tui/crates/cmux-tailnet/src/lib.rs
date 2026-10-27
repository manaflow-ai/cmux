//!   TCP listen and dial on the tailnet, and WhoIs for a peer address;
//! - [`Access`]: who may connect (default: the node's owner only), checked
//!   on the WhoIs answer before any application byte is read.
//!
//! The network decides reachability (Tailscale ACLs); [`Access`] decides
//! which identities this host serves; the application's own gates (for the
//! screen host: no browser origins, then the consent prompt) come after both.

mod ffi;
mod localapi;
mod node;
mod types;

pub use localapi::Watch;
pub use node::{Listener, Node, NodeConfig};
pub use types::{
    BackendState, Notify, PeerStatus, Status, TailnetInfo, UserProfile, WhoIs, WhoIsNode,
};

/// An error from libtailscale or the node's LocalAPI.
#[derive(Debug)]
pub struct Error(pub String);

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for Error {}

pub type Result<T> = std::result::Result<T, Error>;

#[cfg(test)]
mod tests;
