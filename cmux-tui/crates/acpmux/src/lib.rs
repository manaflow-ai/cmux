//! acpmux: tmux for coding-agent harnesses.
//!
//! A daemon keeps ACP agent processes alive as named sessions, records every
//! wire message, and serves the standard ACP protocol plus a small
//! `_acpmux/*` extension to any number of attached clients.

// Imported from manaflow-ai/acpmux with these structural lints already
// violated in many render and RPC signatures. Refactoring them is separate
// work from moving the crate into the cmux-tui workspace.
#![allow(clippy::too_many_arguments, clippy::type_complexity, clippy::result_large_err)]
// The generated initialize capability reply is intentionally explicit; keep json! expansion bounded.
#![recursion_limit = "256"]
// The Windows port lands in steps (src/platform.rs): until the daemon runs
// there, code only its Unix paths reach is unused on Windows.
#![cfg_attr(not(unix), allow(dead_code, unused_imports, unused_variables, unused_mut))]

pub mod acp_todo_plan;
pub mod acpmux_mcp;
pub mod adopt;
pub mod adopt_live;
pub mod adopt_replay;
pub mod adopt_tools;
pub mod agent;
pub mod agent_displays;
pub mod agent_guidance;
pub mod agent_host;
pub mod agent_link;
pub mod agent_login;
pub mod agent_text;
pub mod agent_tools;
mod artifacts_fs;
pub mod artifacts_sync;
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
mod claude_cloud_auth;
pub mod claude_peers;
pub mod claude_stdio;
pub mod cli;
pub mod cli_caller;
pub mod client;
pub mod clock;
pub mod cloud_host;
pub mod cloud_repo_mcp;
pub mod cloud_rewind;
pub mod codex_app_server;
#[cfg(unix)]
mod codex_auth_file;
mod codex_cloud_auth;
pub mod codex_desktop;
pub mod complete;
pub mod config;
pub mod context_inventory;
pub mod cpu_class;
pub mod cua_socket;
pub mod cua_v2;
pub mod cwd_pin;
pub mod daemon;
mod default_harness;
pub mod deliver;
pub mod deps;
pub mod desktop_bridge;
pub mod desktop_link;
pub mod folder_instructions;
#[cfg(all(test, unix))]
mod fork_tests;
pub mod forum;
pub mod forum_mcp;
pub mod frame_compress;
pub mod gauges;
pub mod generic_goal;
pub mod git_state;
pub mod github_app_token;
pub mod github_broker;
#[cfg(unix)]
pub mod github_mcp;
pub mod god_fixture;
/// GitHub's MCP server needs the Cloud agent's unix socket (`github_mcp.rs`): elsewhere it is
/// never offered, and the command says so.
#[cfg(not(unix))]
pub mod github_mcp {
    pub const SERVER_NAME: &str = "github";

    pub fn available() -> bool {
        false
    }

    pub async fn run() -> anyhow::Result<()> {
        anyhow::bail!("acpmux github-mcp runs only on a cmux Cloud machine")
    }
}
pub mod github_status;
pub mod goal;
pub mod hand;
pub mod harness_admin;
pub mod harness_config;
pub mod harness_fixture;
pub mod harness_health;
pub mod harness_icon_set;
pub mod harness_install;
pub mod harness_limits;
pub(crate) mod heap_future;
pub mod heap_profile;
pub(crate) mod home_fs;
#[cfg(test)]
mod home_writers_by_path_tests;
pub mod host_load;
pub mod host_pressure;
pub mod hosted_mcp;
pub mod hub;
/// The live stream to one's own machines through the platform's relay (`hub_carrier.rs`).
#[cfg(feature = "hub-carrier")]
pub mod hub_carrier;
pub mod hunk_summary;
#[cfg(windows)]
mod job;
pub mod launch_credential;
pub mod launch_policy;
pub mod link_v2;
#[cfg(target_os = "linux")]
pub(crate) mod linux_sandbox;
pub mod list_bytes;
pub mod listener_record;
pub mod live_models;
pub mod local_stream;
pub mod log_sink;
pub mod login_env;
pub mod lossy_lines;
#[cfg(test)]
mod lost_home_race_tests;
pub(crate) mod machine_info;
pub mod machine_tunnel;
pub mod machine_wake;
pub mod mailbox;
pub mod managed_codex;
pub mod mcp_hint;
pub mod mesh;
pub mod mesh_control;
pub mod mesh_http;
pub mod model_copies;
pub mod name_match;
#[cfg(target_os = "macos")]
mod named_files_watch;
pub mod native;
pub mod no_panic;
pub mod offer_mcp;
pub mod oom_rank;
pub mod opaque_agent_id;
pub(crate) mod opencode_ask;
#[cfg(windows)]
mod owner_only;
pub mod pairing;
pub mod parent_watch;
pub mod parse_budget;
pub mod path_canon;
pub mod peer;
pub mod peer_kept_tokens;
pub mod peer_last_good;
pub mod peer_link;
// The dialing side of a peer's list stream: the mirror into the index (row 8, part two).
pub mod peer_mirror;
pub mod peer_paths;
pub mod peer_states;
pub mod placement;
#[cfg(not(unix))]
mod platform;
pub mod pricing;
pub mod probe_cleanup;
pub mod probe_prompt;
pub mod prompt_cache_env;
pub mod prompt_class;
pub mod prompt_context;
pub mod prompt_provenance;
pub mod prompt_uploads;
pub mod protected_folders;
pub mod protocol;
pub mod qos;
pub mod question_answer;
#[cfg(target_os = "linux")]
mod quiet_dirs;
pub mod recovery;
pub mod registry;
pub mod request_cancel;
pub mod resume;
pub mod review_box;
pub mod review_brief;
pub mod route_account;
mod route_probe;
pub mod route_shadow;
mod router_socket;
pub mod routes;
pub mod rows;
pub mod rpc;
pub mod run_elsewhere;
pub mod schema;
pub mod secret_mcp;
pub mod secret_scan;
pub mod self_command;
pub mod sender_harness;
pub mod sender_program;
pub mod sender_token;
pub mod server;
pub mod session_env;
pub mod session_identity;
pub mod session_liveness;
pub mod session_name;
mod session_scope;
pub mod session_search;
pub mod session_status;
pub mod sha256;
// The shadow admission verdict beside each placement and create (cmuxterm-hq#7342).
pub mod memory_inbox;
pub mod prompt_coach;
pub mod shadow_admission;
pub mod shell_words;
#[cfg(feature = "sim")]
pub mod sim_agent;
#[cfg(test)]
mod single_shot_list_tests;
#[cfg(test)]
mod source_scan_smoke;
pub mod sr2_cost_labels;
pub(crate) mod ssh_forward;
pub mod stats;
pub(crate) mod stderr;
pub mod store;
#[cfg(test)]
mod stress;
pub mod subagent_call;
pub mod subagent_notice;
pub mod subagents;
pub mod subrouter_session;
pub mod subsession_mcp;
pub mod subsession_worktree;
pub mod suggestion_gate;
pub(crate) mod supervise;
pub mod tailnet;
#[cfg(test)]
mod test_exec;
#[cfg(test)]
mod test_hooks_tree;
#[cfg(test)]
mod test_stack;
pub mod tools_mcp;
pub mod touched_files;
pub mod transcript;
pub mod trust;
pub mod trust_auto;
pub mod tui;
pub mod turn_attestation;
pub mod usage_stats;
pub mod user_settings;
pub mod vault;
pub mod web_modes;
pub mod wire_size;
pub mod wireguard;
pub mod workflow_journal;
pub mod workflow_reply;
pub mod workflow_runs;
pub mod worktree_sessions;
pub mod wrap_up_suggestion;
pub mod write_journal;
pub mod xhost_audit;

pub mod model_catalog;
