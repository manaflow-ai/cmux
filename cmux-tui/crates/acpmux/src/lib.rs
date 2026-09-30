//! acpmux: tmux for coding-agent harnesses.
//!
//! A daemon keeps ACP agent processes alive as named sessions, records every
//! wire message, and serves the standard ACP protocol plus a small
//! `_acpmux/*` extension to any number of attached clients.

// Imported from manaflow-ai/acpmux with these structural lints already
// violated in many render and RPC signatures. Refactoring them is separate
// work from moving the crate into the cmux-tui workspace.
#![allow(clippy::too_many_arguments, clippy::type_complexity, clippy::result_large_err)]

pub mod agent;
pub mod claude_stdio;
pub mod client;
pub mod config;
pub mod daemon;
pub mod hub;
pub mod login_env;
pub mod native;
pub mod peer;
pub mod rpc;
pub mod schema;
pub mod server;
pub mod session_name;
pub mod store;
pub mod transcript;
pub mod tui;

pub mod model_catalog;
