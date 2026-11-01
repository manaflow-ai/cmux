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
pub mod agent_login;
pub mod agent_tools;
pub mod attach;
pub mod author;
pub mod beads;
pub mod bg_hook;
pub mod bg_run;
pub mod byo_endpoint;
pub mod capabilities;
pub mod catalog;
pub mod chat_fork;
pub mod chats;
pub mod claude_auth;
pub mod claude_stdio;
pub mod cli;
pub mod client;
pub mod clock;
pub mod cloud_repo_mcp;
pub mod cloud_rewind;
pub mod codex_app_server;
#[cfg(unix)]
mod codex_auth_file;
pub mod complete;
pub mod config;
pub mod cpu_class;
pub mod cua_socket;
pub mod cua_v2;
pub mod cwd_pin;
pub mod daemon;
mod default_harness;
pub mod deliver;
pub mod forum;
pub mod forum_mcp;
pub mod frame_compress;
pub mod git_state;
pub mod github_app_token;
pub mod github_broker;
pub mod hand;
pub mod harness_admin;
pub mod harness_config;
pub mod harness_fixture;
pub mod harness_health;
pub mod harness_icon_set;
pub mod harness_limits;
pub mod host_load;
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
pub mod machine_wake;
pub mod mailbox;
pub mod managed_codex;
pub mod mcp_hint;
pub mod mesh;
pub mod mesh_control;
pub mod mesh_http;
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
pub mod peer_states;
pub mod placement;
#[cfg(not(unix))]
mod platform;
pub mod probe_cleanup;
pub mod probe_prompt;
pub mod prompt_class;
pub mod prompt_context;
pub mod prompt_provenance;
pub mod prompt_uploads;
pub mod protected_folders;
pub mod protocol;
pub mod qos;
pub mod question_answer;
pub mod recovery;
pub mod registry;
pub mod review_box;
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
pub mod session_liveness;
pub mod session_name;
mod session_scope;
pub mod sha256;
pub mod sr2_cost_labels;
pub(crate) mod ssh_forward;
pub mod stats;
pub(crate) mod stderr;
pub mod store;
pub mod subagents;
pub mod subrouter_session;
pub mod subsession_mcp;
pub mod subsession_worktree;
pub mod tailnet;
#[cfg(test)]
mod test_exec;
#[cfg(test)]
mod test_stack;
pub mod transcript;
pub mod trust;
pub mod trust_auto;
pub mod tui;
pub mod turn_attestation;
pub mod usage_stats;
pub mod user_settings;
pub mod watch_delta;
pub mod web_modes;
pub mod wire_size;
pub mod wireguard;
pub mod worktree_sessions;

pub mod model_catalog;
