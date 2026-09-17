//! acpmux: tmux for ACP agents.
//!
//! A daemon keeps ACP agent processes alive as named sessions, records every
//! wire message, and serves the standard ACP protocol plus a small
//! `_acpmux/*` extension to any number of attached clients.

pub mod agent;
pub mod claude_stdio;
pub mod client;
pub mod config;
pub mod daemon;
pub mod hub;
pub mod native;
pub mod peer;
pub mod rpc;
pub mod server;
pub mod session_name;
pub mod store;
pub mod transcript;
pub mod tui;
