//! The stable per-user tailnet node's proxy front.
//!
//! Leo, 2026-11-24: "perhaps we moreso have a single stable one or a few per user, idk, and the
//! rest underlying shifts beneath their feet with none the wiser". The user's tailnet sees one
//! node per user (`cmux` by default, optionally `cmux-<slug>` per workspace) whose name, tailnet
//! IP, SSH host key and tags never change. That node is a proxy front: it terminates connections
//! on the tailnet and forwards each one to wherever the workspace runs now.
//!
//! This crate is the part of that front that does not need tsnet:
//!
//! - [`placement`]: the placement table, workspace slug -> current backend (SSH target and
//!   preview port targets), swapped atomically on a move. A connection resolves its target once,
//!   when it is accepted, so open connections keep their old target until they close and new
//!   ones go to the new target.
//! - [`messages`]: the versioned wire messages ("placement set / moved / removed") that acpmux
//!   and cmux protocols carry to update the table.
//! - [`front`]: the TCP front. A port map on the stable node (port 22 -> the default workspace's
//!   SSH, 2201.. -> other workspaces, other ports -> previews) and a forwarder that splices raw
//!   TCP to the current placement. The listener and the dialer are traits, so the tsnet node
//!   plugs in later and tests use loopback TCP.
//!
//! Nothing here starts on its own: [`front::FrontConfig`] is off by default. acpmux serves the
//! front on its embedded tailnet node only when the `tailnet.stableNode.enabled` setting is on.

pub mod front;
pub mod messages;
pub mod placement;
#[cfg(all(unix, feature = "tsnet"))]
pub mod tsnet;

pub use front::{Dialer, Front, FrontConfig, FrontListener, PortMap, Route, TcpDialer};
pub use messages::{
    PLACEMENT_MESSAGE_VERSION, PLACEMENT_METHOD, PlacementMessage, PlacementReply, PlacementResult,
};
pub use placement::{Backend, Placement, PlacementTable};
