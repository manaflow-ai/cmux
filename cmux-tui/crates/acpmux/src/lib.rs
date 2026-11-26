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

pub mod accept_errors;
pub(crate) mod acp_key_auth;
pub mod acpmux_mcp;
pub mod acpmux_mcp_names;
pub mod adopt;
pub mod adopt_live;
pub mod adopt_replay;
pub mod adopt_tools;
pub mod agent;
pub mod agent_credentials;
pub mod agent_displays;
pub mod agent_guidance;
pub mod agent_home;
pub mod agent_host;
pub mod agent_link;
pub mod agent_login;
pub mod agent_text;
pub mod agent_tools;
mod artifacts_fs;
pub mod artifacts_sync;
pub mod attach;
pub mod author;
/// Auto mode: a chat keeps running in the Cloud when the laptop goes away (`auto_session/`).
pub mod auto_session;
pub mod beads;
pub mod bg_hook;
pub mod bg_run;
#[path = "cli/bounded_child.rs"]
pub(crate) mod bounded_child;
pub mod build_info;
pub mod byo_endpoint;
pub mod caller_stats;
pub mod capabilities;
pub mod catalog;
pub mod chat_fork;
pub mod chat_place;
pub mod chat_size_fixture;
pub mod chatgpt;
pub mod chats;
pub mod claude_auth;
mod claude_cloud_auth;
pub mod claude_inbox_relay;
pub mod claude_peers;
pub mod claude_stdio;
pub mod claude_token;
pub mod cli;
pub mod cli_caller;
pub mod client;
pub mod clock;
pub(crate) mod clock_text;
pub mod close_why;
pub mod cloud_folder;
pub mod cloud_host;
pub mod cloud_model_plane;
pub mod cloud_readme;
pub mod cloud_repo_mcp;
pub mod cloud_rewind;
/// The cmux-tui remote daemon this machine serves to its other machines (`cmux_tui_service.rs`).
#[cfg(feature = "hub-carrier")]
pub mod cmux_tui_service;
pub mod codex_app_server;
#[cfg(unix)]
mod codex_auth_file;
/// The opt-in bundled Codex app-server (Labs, off by default).
pub mod codex_bundle;
mod codex_cloud_auth;
pub mod codex_cmux_entry;
pub mod codex_desktop;
pub mod codex_repo_gate;
mod codex_signed_out;
pub mod complete;
pub mod computer_use;
pub mod config;
pub mod conn_origin;
pub mod context_inventory;
pub mod cpu_class;
pub mod customize_run;
pub mod cwd_pin;
pub mod daemon;
pub(crate) mod daemon_parts;
pub mod daemon_priority;
pub mod daemon_skew;
mod dead_temps;
pub mod death_route;
mod default_harness;
pub mod deliver;
pub mod deps;
pub mod desktop_bridge;
pub mod desktop_link;
pub mod directory_input;
pub mod disk_evict;
pub mod disk_usage;
pub(crate) mod disk_writer;
pub mod folder_instructions;
pub mod fork_place;
pub mod fork_risky;
#[cfg(all(test, unix))]
mod fork_tests;
pub mod forum;
pub mod forum_mcp;
pub mod frame_compress;
/// The always-on frame tally of the visible chat (`_acpmux/perf {op:"frames"}`).
pub mod frame_tally;
pub mod gauges;
pub mod generic_goal;
pub mod git_state;
pub mod github_app_token;
pub mod github_broker;
#[cfg(unix)]
pub mod github_lane_mint;
#[cfg(unix)]
pub mod github_mcp;
pub mod github_rest_op;
#[cfg(unix)]
pub mod github_session_env;
pub mod god_fixture;
pub mod hypervisor;
pub mod install_share;
pub mod key_check;
pub mod memory_follow;
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
/// Machines a Mac lends GitHub are unix machines (`github_session_env.rs`).
#[cfg(not(unix))]
pub mod github_session_env {
    pub fn lent() -> bool {
        false
    }
}
pub mod github_status;
pub mod goal;
pub mod hand;
pub mod happy_dial;
pub mod harness_admin;
pub mod harness_config;
pub mod harness_fixture;
pub mod harness_health;
pub mod harness_icon_set;
pub mod harness_install;
pub mod harness_limits;
pub(crate) mod harness_secret_ref;
pub(crate) mod heap_future;
pub mod heap_profile;
pub(crate) mod home_fs;
#[cfg(test)]
mod home_writers_by_path_tests;
pub(crate) mod host_fingerprint;
pub mod host_load;
pub mod host_load_watch;
pub mod host_overload;
pub mod host_pressure;
pub mod hosted_mcp;
pub mod hub;
/// The live stream to one's own machines through the platform's relay (`hub_carrier.rs`).
#[cfg(feature = "hub-carrier")]
pub mod hub_carrier;
pub mod hunk_summary;
pub mod idempotency;
#[cfg(windows)]
mod job;
mod joined_model_plane;
pub mod terminal_autocompact;
/// `cmux github` and the GitHub MCP bridge on a joined machine ask its hub (`joined_model_plane`).
#[cfg(unix)]
pub use joined_model_plane::install_github_source;
pub mod chat_secrets;
/// Hot paths for the instruction-count bench (`benches/icount.rs`); not an API.
#[doc(hidden)]
pub mod icount;
pub mod launch_credential;
pub mod launch_policy;
pub mod left_on_mac;
pub mod link_v2;
#[cfg(target_os = "linux")]
pub(crate) mod linux_sandbox;
pub mod list_bytes;
pub mod listener_record;
pub mod live_models;
pub mod local_stream;
pub mod log_keep;
pub mod log_sink;
pub mod login_env;
pub mod lossy_lines;
#[cfg(test)]
mod lost_home_race_tests;
pub mod mac_lock;
/// Calls this machine runs for the person's other machines, over the hub carrier
/// (`machine_call_service.rs`).
#[cfg(feature = "hub-carrier")]
pub mod machine_call_service;
#[path = "cli/machine_consent.rs"]
pub(crate) mod machine_consent;
/// File and command actions for another of the person's machines (`machine_call_service.rs`).
pub mod machine_files;
pub(crate) mod machine_info;
pub(crate) mod machine_record;
/// A local route to each of the person's other machines' cmux-tui session (`machine_routes.rs`).
#[cfg(feature = "hub-carrier")]
pub mod machine_routes;
pub mod machine_tunnel;
pub mod machine_wake;
pub mod mailbox;
pub mod managed_codex;
pub mod mcp_args;
/// Each chat's `cmux` MCP server over loopback HTTP, started on use and stopped when idle.
pub mod mcp_gateway;
pub mod mcp_hint;
#[cfg(unix)]
pub mod mcp_pool;
pub mod memory_mount;
pub mod mesh;
pub mod mesh_control;
pub mod mesh_gate;
pub mod mesh_http;
pub mod mesh_node_key;
pub mod mesh_relay_config;
pub mod mesh_retry;
pub mod meta_fields;
pub mod model_copies;
pub mod name_match;
#[cfg(target_os = "macos")]
mod named_files_watch;
pub mod native;
pub mod no_panic;
pub mod notice_read;
pub mod offer_mcp;
pub mod oom_rank;
pub mod opaque_agent_id;
pub(crate) mod opencode_ask;
#[path = "daemon/owner_exit.rs"]
pub(crate) mod owner_exit;
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
pub mod perf_trace;
// One host-wide gate for peer links' dials, so many dropped links do not redial in one instant.
pub mod peer_dial_gate;
pub(crate) mod peer_notice_outbox;
// The dialing side of a peer's list stream: the mirror into the index (row 8, part two).
pub mod peer_mirror;
pub mod peer_path_stats;
pub mod peer_paths;
pub(crate) mod peer_row_patch;
pub mod peer_states;
pub mod person_proof;
pub mod person_tokens;
pub mod place_move;
// A new chat's place mode (Auto, Cloud, one machine) and where it starts with it.
pub mod fleet_elastic;
pub mod place_mode;
// A chat's stored pin and the one-time migration that pins every older chat to its machine.
pub mod place_pin;
pub mod placement;
// `acpmux machine cells`: lane hosts against their caps and the registry (RFD 0181 B2).
pub mod cell_report;
pub mod plan_build_records;
#[cfg(not(unix))]
mod platform;
pub mod pr_poller;
pub mod pricing;
pub mod probe_cleanup;
pub mod probe_prompt;
pub mod proc_exit;
mod proc_start;
pub mod prompt_cache_env;
pub mod prompt_class;
pub mod prompt_context;
pub mod prompt_provenance;
pub mod prompt_uploads;
pub mod prompts;
pub mod protected_folders;
pub mod protocol;
pub mod provenance_keys;
mod provider_cloud_auth;
pub mod qos;
pub mod question_answer;
pub(crate) mod questions;
#[cfg(target_os = "linux")]
mod quiet_dirs;
pub mod race_records;
pub mod range_fetch;
pub(crate) mod rebalance;
pub mod recovery;
pub mod registry;
pub(crate) mod remote_chain_profile;
pub(crate) mod replay_rules;
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
// `acpmux run-ask`: run an accepted forum `run` ask here or through the scheduler.
pub mod run_ask;
pub mod run_elsewhere;
pub mod sccache_env;
pub mod schema;
pub mod secret_mcp;
pub mod secret_scan;
pub mod self_command;
pub mod send_fanout;
pub mod send_trace;
pub(crate) mod sender_env;
pub mod sender_harness;
pub mod sender_program;
pub mod sender_token;
pub mod sent_by;
pub mod server;
mod session_budget;
mod session_disk;
pub mod session_env;
mod session_handle;
pub mod session_icon;
pub mod session_identity;
pub mod session_liveness;
pub mod session_name;
pub mod session_order;
mod session_scope;
pub mod session_search;
/// A workspace here for the person's other machines, over the hub carrier (`session_service.rs`).
#[cfg(feature = "hub-carrier")]
pub mod session_service;
pub mod session_status;
mod session_store;
mod session_total;
pub mod sha256;
/// The approval behind Share This Mac confirmed on the owner's other device (`share_approval.rs`).
pub mod share_approval;
/// The share host: a joined Mac's daemon serves screen shares with no app running (`share_host/`).
pub mod share_host;
pub(crate) mod single_flight;
/// A hub move's pages over the hub carrier (`transfer_service.rs`, `hub/transfer_pull.rs`).
#[cfg(feature = "hub-carrier")]
pub mod transfer_service;
pub mod usage_limit;
pub(crate) mod worker_lock;
// The shadow admission verdict beside each placement and create (cmuxterm-hq#7342).
pub mod memory_inbox;
pub mod prompt_coach;
pub mod shadow_admission;
pub(crate) mod shell_readonly;
pub mod shell_words;
pub mod sidecar_census;
#[cfg(feature = "sim")]
pub mod sim_agent;
pub(crate) mod slow_notice;
// The scanner is `test_support`'s, a unix module; the scan reads the same sources anywhere.
/// Bounded journal reads reduced once into timestamped replay states.
pub mod journal_replay;
pub mod perf_watch;
pub mod scorecard;
#[cfg(all(test, unix))]
mod single_shot_list_tests;
#[cfg(test)]
mod source_scan_smoke;
pub mod sr2_cost_labels;
pub mod sr2_priority;
pub mod ssh_config_hosts;
pub(crate) mod ssh_forward;
pub(crate) mod ssh_forward_owners;
pub mod stash;
pub mod stats;
pub(crate) mod stderr;
pub mod store;
#[cfg(test)]
mod stress;
pub mod subagent_call;
pub mod subagent_notice;
pub mod subagents;
pub mod subrouter_priority;
pub mod subrouter_session;
pub mod subsession_mcp;
pub mod subsession_settings;
pub mod subsession_worktree;
pub mod suggestion_gate;
pub(crate) mod supervise;
pub mod surge_triage;
pub mod tailnet;
pub mod tailnet_carrier;
#[cfg(unix)]
#[path = "daemon/term_sender.rs"]
pub(crate) mod term_sender;
#[cfg(test)]
mod test_exec;
#[cfg(test)]
mod test_hooks_tree;
#[cfg(test)]
mod test_stack;
/// Another crate's tests' daemon (`test-support`; row 7c's `cmux-tui-core` gates). Never shipped.
#[cfg(all(unix, any(test, feature = "test-support")))]
pub mod test_support;
pub(crate) mod time_breakdown;
pub mod todo_tools;
pub(crate) mod tool_env;
pub mod tool_mentions;
pub mod tools_mcp;
pub mod touched_files;
pub mod transcript;
pub mod trust;
pub mod trust_auto;
/// Where the CLI opens a session in a terminal UI: one the process installed (acpmux-tui, in the
/// `cmux` binary), else a handoff to `cmux` (acpmux itself is headless).
pub mod tui_entry;
pub mod turn_attestation;
pub(crate) mod turn_errors;
pub(crate) mod uniichat_endpoint;
pub(crate) mod unread_records;
pub mod usage_stats;
pub mod user_settings;
pub mod vault;
pub mod web_modes;
pub mod web_tailnet;
pub mod wire_size;
pub mod wireguard;
pub mod workflow_journal;
pub mod workflow_reply;
pub mod workflow_runs;
pub mod worktree_sessions;
pub mod wrap_up_suggestion;
pub mod write_journal;
pub mod ws_auth;
pub mod xhost_audit;

pub mod model_catalog;
/// The per-host model-name hot patch (`$ACPMUX_HOME/model-aliases.json`), read by
/// `model_catalog::canonical_model`.
pub mod model_hot_patch;
