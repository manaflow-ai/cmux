//! Embedded Tailscale node, tailnet TCP streams, and authenticated LocalAPI access.
//! Blocking operations belong on a background thread.

#![cfg(unix)]

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
