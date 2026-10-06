//! The cloud conversation source: the brain answers the chief's cloud main
//! conversation (ConversationDO) through the daemon's
//! `cloud-conversations-v1` proxy, as the chief principal.

pub mod auth;
pub mod events;
pub mod idmap;
pub mod link;
pub mod port;
pub mod wire;

/// The daemon capability the cloud source needs.
pub const CAPABILITY: &str = "cloud-conversations-v1";
