//! acpmux: tmux for coding-agent harnesses.
//!
//! A daemon keeps ACP agent processes alive as named sessions, records every
//! wire message, and serves the standard ACP protocol plus a small
//! `_acpmux/*` extension to any number of attached clients.

// Imported from manaflow-ai/acpmux with these structural lints already
// violated in many render and RPC signatures. Refactoring them is separate
// work from moving the crate into the cmux-tui workspace.
#![allow(clippy::too_many_arguments, clippy::type_complexity, clippy::result_large_err)]
// The Windows port lands in steps (src/platform.rs): until the daemon runs
// there, code only its Unix paths reach is unused on Windows.
#![cfg_attr(not(unix), allow(dead_code, unused_imports, unused_variables, unused_mut))]

pub mod acpmux_mcp;
pub mod adopt;
pub mod adopt_live;
pub mod adopt_replay;
pub mod adopt_tools;
pub mod agent;
pub mod agent_displays;
pub mod agent_host;
pub mod agent_link;
pub mod agent_tools;
pub mod attach;
pub mod author;
pub mod beads;
pub mod byo_endpoint;
pub mod capabilities;
pub mod catalog;
pub mod chats;
pub mod claude_auth;
pub mod claude_stdio;
pub mod cli;
pub mod client;
pub mod clock;
pub mod codex_app_server;
pub mod complete;
pub mod config;
pub mod cua_socket;
pub mod cua_v2;
pub mod cwd_pin;
pub mod daemon;
pub mod deliver;
pub mod forum;
pub mod forum_mcp;
pub mod git_state;
pub mod hand;
pub mod harness_admin;
pub mod harness_config;
pub mod harness_health;
pub mod harness_icon_set;
pub mod harness_limits;
pub mod host_pressure;
pub mod hub;
#[cfg(windows)]
mod job;
pub mod launch_credential;
pub mod launch_policy;
#[cfg(target_os = "linux")]
pub(crate) mod linux_sandbox;
pub mod live_models;
pub mod local_stream;
pub mod login_env;
pub mod mailbox;
pub mod model_copies;
pub mod native;
pub mod no_panic;
pub mod offer_mcp;
pub(crate) mod opencode_ask;
#[cfg(windows)]
mod owner_only;
pub mod pairing;
pub mod path_canon;
pub mod peer;
pub mod peer_link;
pub mod placement;
#[cfg(not(unix))]
mod platform;
pub mod probe_cleanup;
pub mod probe_prompt;
pub mod prompt_context;
pub mod prompt_provenance;
pub mod prompt_uploads;
pub mod protected_folders;
pub mod protocol;
pub mod question_answer;
pub mod recovery;
pub mod registry;
pub mod route_account;
mod route_probe;
mod router_socket;
pub mod routes;
pub mod rpc;
pub mod schema;
pub mod secret_mcp;
pub mod secret_scan;
pub mod self_command;
pub mod server;
pub mod session_env;
pub mod session_identity;
pub mod session_name;
mod session_scope;
pub mod sha256;
pub mod sr2_cost_labels;
pub mod stats;
pub mod store;
pub mod subagents;
pub mod subrouter_session;
pub mod subsession_mcp;
pub mod subsession_worktree;
pub mod tailnet;
pub mod transcript;
pub mod trust;
pub mod trust_auto;
pub mod tui;
pub mod user_settings;
pub mod web_modes;
pub mod worktree_sessions;

pub mod model_catalog;
