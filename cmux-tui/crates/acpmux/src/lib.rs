//! acpmux: tmux for coding-agent harnesses.
//!
//! A daemon keeps ACP agent processes alive as named sessions, records every
//! wire message, and serves the standard ACP protocol plus a small
//! `_acpmux/*` extension to any number of attached clients.

// Imported from manaflow-ai/acpmux with these structural lints already
// violated in many render and RPC signatures. Refactoring them is separate
// work from moving the crate into the cmux-tui workspace.
#![allow(clippy::too_many_arguments, clippy::type_complexity, clippy::result_large_err)]

pub mod adopt;
pub mod adopt_live;
pub mod agent;
#[cfg(test)]
mod agent_exit_tests;
pub mod agent_host;
#[cfg(test)]
mod agent_replay_tests;
pub mod agent_tools;
pub mod catalog;
pub mod chats;
pub mod claude_stdio;
pub mod cli;
pub mod client;
pub mod clock;
pub mod config;
pub mod cua_socket;
pub mod daemon;
#[cfg(test)]
mod git_short_sha;
pub mod hub;
pub mod login_env;
pub mod native;
pub mod peer;
pub mod protected_folders;
pub mod question_answer;
#[cfg(test)]
mod question_answer_tests;
pub mod render_mcp;
pub mod rpc;
pub mod schema;
pub mod server;
pub mod session_env;
pub mod session_name;
pub mod sha256;
#[cfg(test)]
mod source_date_epoch;
pub mod store;
pub mod subagents;
#[cfg(test)]
mod subagents_tests;
pub mod transcript;
pub mod trust;
pub mod tui;
pub mod web_modes;

pub mod model_catalog;
