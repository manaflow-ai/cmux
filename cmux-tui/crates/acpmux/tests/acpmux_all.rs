//! Consolidated integration-test binary for acpmux.
//!
//! Each former top-level test that does not require process isolation remains a module so its
//! test names, feature gates, helper paths, and nested fixtures are preserved while Cargo links
//! acpmux once.

// The per-home and baseline `json!` of delta_cost and god_daemon have more keys than the
// default limit expands; the attribute counts only at the crate root.
#![recursion_limit = "256"]

#[path = "support/daemon_env.rs"]
mod daemon_env;

// The one process of every module below: stand-in agents and a hermetic PATH. Child commands
// still pick `Agents::Deny` or `Agents::StandIn` themselves. A module that needs a process
// variable set (`Process::with_env`) cannot share one process with the rest and stays its own
// test binary (Cargo.toml); every other module's kept host variables and tools are here, each a
// test-runner knob, never a credential. Modules use this through `crate::daemon_env` and
// `crate::HERMETIC`, so the helper (and its types) is compiled once.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in()
    .keep(KEEP)
    // web_image_attachments runs node itself.
    .tools(&["node"]);

/// The host variables the modules' tests read (each group names its module).
const KEEP: &[&str] = &[
    // chats_search_bench.
    "CHAT_SEARCH_BENCH_CHATS",
    "CHAT_SEARCH_BENCH_MIB",
    // codex_app_server_live.
    "ACPMUX_CODEX_LIVE",
    "CODEX_HOME",
    // daemon_memory (BENCH_VARS).
    "ACPMUX_MEMORY_BENCH_BINARY",
    "ACPMUX_MEMORY_BENCH_LEFTOVERS",
    "ACPMUX_MEMORY_BENCH_CHATS",
    "ACPMUX_MEMORY_BUDGET_MB",
    "ACPMUX_WAIT_BENCH_SECS",
    "ACPMUX_PEER_SNAPSHOT_PEAK_MB",
    "ACPMUX_PEER_SNAPSHOT_CPU_MS",
    "ACPMUX_SCALE_CHATS",
    "ACPMUX_SCALE_TURNS",
    "ACPMUX_SCALE_CATALOGS",
    "ACPMUX_SCALE_DHAT_DIR",
    // daemon_summary_tools.
    "ACPMUX_SUMMARY_TOOLS_OUTPUT",
    // delta_cost, god_daemon.
    "ACPMUX_GOD_SHAPES",
    "ACPMUX_GOD_SCALE",
    "ACPMUX_DELTA_N",
    "ACPMUX_DELTA_ROUNDS",
    // durable_agents (restart_reattach.rs).
    "ACPMUX_REATTACH_LIVE",
    "ACPMUX_REATTACH_IDLE",
    "ACPMUX_REATTACH_CLOSED",
    "ACPMUX_REATTACH_RECORDS",
    "ACPMUX_REATTACH_SCAN_DELAY_MS",
    "ACPMUX_REATTACH_BUDGET_MS",
    "ACPMUX_REATTACH_OPEN_BUDGET_MS",
    "ACPMUX_IDLE_SUBS",
    "ACPMUX_IDLE_SUBS_WINDOW_S",
    "ACPMUX_IDLE_SUBS_OUT",
    // duress_daemon.
    "ACPMUX_DURESS",
    "ACPMUX_DURESS_LEGS",
    "ACPMUX_DURESS_SECS",
    "ACPMUX_DURESS_CAP_SECS",
    "ACPMUX_DURESS_CPU_X",
    "ACPMUX_DURESS_SESSIONS",
    "ACPMUX_DURESS_N",
    "ACPMUX_DURESS_PEERS",
    "ACPMUX_DURESS_MEMORY_HIGH",
    "ACPMUX_DURESS_STARVE_CORES",
    "ACPMUX_DURESS_STARVE_X",
    "ACPMUX_DURESS_STARVE_IDLE",
    "ACPMUX_DURESS_STARVE_MEMORY_HIGH",
    "ACPMUX_DURESS_STARVE_CPU_MAX",
    "ACPMUX_DURESS_STARVE_DELAY_MS",
    "ACPMUX_DURESS_STARVE_JITTER_MS",
    "ACPMUX_DURESS_STARVE_STALL_MS",
    "ACPMUX_DURESS_STARVE_STALL_EVERY_S",
    "ACPMUX_DURESS_BIG_RECORDS",
    // duress_daemon, god_daemon: the commit under test and the fleet's output directory, not credentials.
    "GITHUB_SHA",
    "FAST_CHECKS_OUT",
    // duress_daemon, host_scope: how `systemd-run --user` reaches the user's manager.
    "XDG_RUNTIME_DIR",
    "DBUS_SESSION_BUS_ADDRESS",
    // file_put_window_bench.
    "FPW_BYTES",
    "FPW_PROFILES",
    "FPW_LOADS",
    "FPW_WINDOWS",
    "FPW_RUNS",
    "FPW_DURESS_TURNS",
    // fuzz_crash_durable.
    "CMUX_CI_STEP_KEY",
    "ACPMUX_FUZZ_SEED",
    "ACPMUX_FUZZ_ROUNDS",
    // god_daemon (chat size sweep, dhat, control binary, peer row batches, churn and growth labs).
    "ACPMUX_CHAT_SIZES",
    "ACPMUX_CHAT_SIM_BIN",
    "ACPMUX_GOD_DHAT",
    "ACPMUX_GOD_DHAT_TOP",
    "ACPMUX_GOD_DAEMON_BIN",
    "ACPMUX_GOD_PEER_ROW_BATCHES",
    "ACPMUX_CHURN_ROWS",
    "ACPMUX_CHURN_SECS",
    "ACPMUX_CHURN_EVERY_MS",
    "ACPMUX_CHURN_CPUS",
    "ACPMUX_CHURN_BUSY",
    "ACPMUX_CHURN_FOLLOW",
    "ACPMUX_CHURN_ARENAS",
    "ACPMUX_GROWTH_SECS",
    "ACPMUX_GROWTH_ROWS",
    "ACPMUX_GROWTH_STABLE",
    "ACPMUX_GROWTH_CHURN",
    "ACPMUX_GROWTH_SSH_DOWN",
    "ACPMUX_GROWTH_CUT_MS",
    "ACPMUX_GROWTH_CHATS",
    "ACPMUX_GROWTH_CLIENTS",
    "ACPMUX_GROWTH_CLIENT_MS",
    "ACPMUX_GROWTH_SLOW",
    "ACPMUX_GROWTH_STACKS",
    // linux_sandbox_keeper, remote_sandbox_linux.
    "ACPMUX_REQUIRE_BWRAP",
    // machine_join, person_allow.
    "ACPMUX_TEST_BINARY",
    // mobile_link_conditions.
    "NETCOND_PROFILES",
    "NETCOND_PROFILES_FILE",
    "NETCOND_RELAY",
    "NETCOND_SCALES",
    "NETCOND_RUNS",
    "NETCOND_SEED_BASE",
    "NETCOND_BW_PROFILE",
    "NETCOND_BW_TURNS",
    "NETCOND_BW_SECS",
    "NETCOND_BW_APPS",
    "NETCOND_AWAY",
    "NETCOND_LOADS",
    "NETCOND_CHAT_MAX_TURNS",
    "NETCOND_DEBUG",
    // published_bench.
    "PUBLISHED_BENCH_SAMPLES",
    "PUBLISHED_BENCH_FORK_TURNS",
    "PUBLISHED_BENCH_SOAK_SECS",
    "PUBLISHED_BENCH_SOAK_LOAD",
    "PUBLISHED_BENCH_SOAK_PROBE_SECS",
    "PUBLISHED_BENCH_SOAK_WINDOW_SECS",
    "PUBLISHED_BENCH_SOAK_TICKED",
    "PUBLISHED_BENCH_SOAK_CALIBRATE_SECS",
    // peer_cold_connect_bench.
    "COLD_RTT_MS",
    "COLD_RUNS",
    "NO_EARLY",
    // rc_faults.
    "CMUX_FAULT_RUNS",
    "CMUX_FAULT_SEED",
    "CMUX_FAULT_SEED_BASE",
    "CMUX_FAULT_PARALLEL",
    // session_tail_orphan.
    "ACPMUX_TAIL_BIN",
    "ACPMUX_TAIL_MEASURE_ONLY",
    "ACPMUX_TAIL_LOG_MB",
    // start_under_load_bench.
    "START_BENCH_LOAD",
    "START_BENCH_SAMPLES",
    "START_BENCH_LOAD_NICE",
    "START_BENCH_SPARE",
    "START_BENCH_ASSERT",
    // startup_accept_bench.
    "ACPMUX_BENCH_GOD_MB",
    "ACPMUX_BENCH_CHATS",
    "ACPMUX_BENCH_ROUNDS",
    // startup_load.
    "ACPMUX_STARTUP_BENCH_SESSIONS",
    "ACPMUX_STARTUP_BENCH_EVENTS",
    "ACPMUX_STARTUP_BUDGET_MS",
    // stop_watchdog.
    "ACPMUX_WATCHDOG_RUNS",
    "ACPMUX_WATCHDOG_GOD_SCALE",
    // subsessions_live (CODEX_HOME also codex_app_server_live).
    "ACPMUX_SUBSESSIONS_LIVE_CLAUDE",
    "ACPMUX_SUBSESSIONS_LIVE_CODEX",
    "ANTHROPIC_BASE_URL",
];

#[path = "additional_directories.rs"]
mod additional_directories;
#[path = "admission.rs"]
mod admission;
#[path = "agent_launch_deny.rs"]
mod agent_launch_deny;
#[path = "app_orphan_exit.rs"]
mod app_orphan_exit;
#[path = "bg_resume_blocked.rs"]
mod bg_resume_blocked;
#[path = "binary_build_stamp.rs"]
mod binary_build_stamp;
#[path = "build_harness_isolation.rs"]
mod build_harness_isolation;
#[path = "byoh_cli.rs"]
mod byoh_cli;
#[path = "caller_declared_cli.rs"]
mod caller_declared_cli;
#[path = "cancel_list_reply.rs"]
mod cancel_list_reply;
#[path = "cancel_owner.rs"]
mod cancel_owner;
#[path = "cancel_peer_link.rs"]
mod cancel_peer_link;
#[path = "cancel_request.rs"]
mod cancel_request;
#[path = "carrier_team.rs"]
mod carrier_team;
#[path = "catalog_rpc.rs"]
mod catalog_rpc;
#[path = "chats.rs"]
mod chats;
#[path = "chats_activity.rs"]
mod chats_activity;
#[path = "chats_deltas.rs"]
mod chats_deltas;
#[path = "chats_open.rs"]
mod chats_open;
#[path = "chats_search.rs"]
mod chats_search;
#[path = "chats_search_bench.rs"]
mod chats_search_bench;
#[path = "chats_settings.rs"]
mod chats_settings;
#[path = "chats_transcript.rs"]
mod chats_transcript;
#[path = "chats_window.rs"]
mod chats_window;
#[path = "chief_builtin_presets.rs"]
mod chief_builtin_presets;
#[path = "claude_auth_env.rs"]
mod claude_auth_env;
#[path = "claude_auth_settings.rs"]
mod claude_auth_settings;
#[path = "claude_native_messaging.rs"]
mod claude_native_messaging;
#[path = "claude_reasoning.rs"]
mod claude_reasoning;
#[path = "claude_stream_budget.rs"]
mod claude_stream_budget;
#[path = "claude_stream_timing.rs"]
mod claude_stream_timing;
#[path = "cli_agent.rs"]
mod cli_agent;
#[path = "cli_disk_writes.rs"]
mod cli_disk_writes;
#[path = "cli_ergonomics.rs"]
mod cli_ergonomics;
#[path = "cli_help_reload.rs"]
mod cli_help_reload;
#[path = "cli_parse_errors.rs"]
mod cli_parse_errors;
#[path = "client_sender_token.rs"]
mod client_sender_token;
#[path = "cmux_tools_answer.rs"]
mod cmux_tools_answer;
#[path = "codex_app_server_live.rs"]
mod codex_app_server_live;
#[path = "codex_bridge_budget.rs"]
mod codex_bridge_budget;
#[path = "codex_bridge_config.rs"]
mod codex_bridge_config;
#[path = "codex_live_catalog.rs"]
mod codex_live_catalog;
#[path = "conn_auth.rs"]
mod conn_auth;
#[path = "connection_work_limit.rs"]
mod connection_work_limit;
#[path = "created_by.rs"]
mod created_by;
#[path = "cross_host_send_cli.rs"]
mod cross_host_send_cli;
#[path = "cwd_pin.rs"]
mod cwd_pin;
#[path = "daemon_chat_open.rs"]
mod daemon_chat_open;
#[path = "daemon_idle.rs"]
mod daemon_idle;
#[path = "daemon_idle_chat_roots.rs"]
mod daemon_idle_chat_roots;
#[path = "daemon_idle_chats.rs"]
mod daemon_idle_chats;
#[path = "daemon_lifecycle.rs"]
mod daemon_lifecycle;
#[path = "daemon_list_guard.rs"]
mod daemon_list_guard;
#[path = "daemon_list_order_start.rs"]
mod daemon_list_order_start;
#[path = "daemon_listener_handover.rs"]
mod daemon_listener_handover;
#[path = "daemon_log_blocked.rs"]
mod daemon_log_blocked;
#[path = "daemon_log_reads.rs"]
mod daemon_log_reads;
#[path = "daemon_memory.rs"]
mod daemon_memory;
#[path = "daemon_open_file_limit.rs"]
mod daemon_open_file_limit;
#[path = "daemon_page_memory.rs"]
mod daemon_page_memory;
#[path = "daemon_restart_close.rs"]
mod daemon_restart_close;
#[path = "daemon_single_owner.rs"]
mod daemon_single_owner;
#[path = "daemon_start_race.rs"]
mod daemon_start_race;
#[path = "daemon_summary_tools.rs"]
mod daemon_summary_tools;
#[path = "daemon_take_over.rs"]
mod daemon_take_over;
#[path = "daemon_unused_exit.rs"]
mod daemon_unused_exit;
#[path = "delta_cost.rs"]
mod delta_cost;
#[path = "disallowed_tools.rs"]
mod disallowed_tools;
#[path = "dispatch_durable.rs"]
mod dispatch_durable;
#[path = "document_prompt.rs"]
mod document_prompt;
#[path = "durable_agents.rs"]
mod durable_agents;
#[path = "durable_watch_lifecycle.rs"]
mod durable_watch_lifecycle;
#[path = "durable_watch_rpc.rs"]
mod durable_watch_rpc;
#[path = "duress_daemon.rs"]
mod duress_daemon;
#[path = "elevation_leak.rs"]
mod elevation_leak;
#[path = "ephemeral_run.rs"]
mod ephemeral_run;
#[path = "file_put.rs"]
mod file_put;
#[path = "file_put_window_bench.rs"]
mod file_put_window_bench;
#[path = "folder_harness.rs"]
mod folder_harness;
#[path = "follower_once.rs"]
mod follower_once;
#[path = "forum.rs"]
mod forum;
#[path = "full_access_children.rs"]
mod full_access_children;
#[path = "fuzz_crash_durable.rs"]
mod fuzz_crash_durable;
#[path = "fuzz_g_prompt_accept_race.rs"]
mod fuzz_g_prompt_accept_race;
#[path = "generated_titles.rs"]
mod generated_titles;
#[path = "god_daemon.rs"]
mod god_daemon;
#[path = "hand_json_cli.rs"]
mod hand_json_cli;
#[path = "harness_breadth_matrix.rs"]
mod harness_breadth_matrix;
#[path = "harness_bun_binding.rs"]
mod harness_bun_binding;
#[path = "harness_bytes.rs"]
mod harness_bytes;
#[path = "harness_enable.rs"]
mod harness_enable;
#[path = "harness_fixture.rs"]
mod harness_fixture;
#[path = "harness_health.rs"]
mod harness_health;
#[path = "harness_helpers.rs"]
mod harness_helpers;
#[path = "harness_list_folder.rs"]
mod harness_list_folder;
#[path = "harness_rediscovered_at_start.rs"]
mod harness_rediscovered_at_start;
#[path = "harness_restart.rs"]
mod harness_restart;
#[path = "harness_startup.rs"]
mod harness_startup;
#[path = "harness_update_prefix.rs"]
mod harness_update_prefix;
#[path = "harnesses_changed.rs"]
mod harnesses_changed;
#[path = "hermetic_daemon_guard.rs"]
mod hermetic_daemon_guard;
#[path = "host_deadlines.rs"]
mod host_deadlines;
#[path = "host_lifetime.rs"]
mod host_lifetime;
#[path = "host_scope.rs"]
mod host_scope;
#[path = "host_start_wave.rs"]
mod host_start_wave;
#[path = "inherit_start.rs"]
mod inherit_start;
#[path = "inventory_watch.rs"]
mod inventory_watch;
#[path = "lane_reports.rs"]
mod lane_reports;
#[path = "launch_roots.rs"]
mod launch_roots;
#[path = "launcher_modes.rs"]
mod launcher_modes;
#[path = "linux_sandbox_init.rs"]
mod linux_sandbox_init;
#[path = "linux_sandbox_keeper.rs"]
mod linux_sandbox_keeper;
#[path = "live_models.rs"]
mod live_models;
#[path = "local_app_origin.rs"]
mod local_app_origin;
#[path = "local_app_presets.rs"]
mod local_app_presets;
#[path = "local_app_trust_gate.rs"]
mod local_app_trust_gate;
#[path = "ls_selection.rs"]
mod ls_selection;
#[path = "machine_join.rs"]
mod machine_join;
#[path = "machine_move_journey.rs"]
mod machine_move_journey;
#[path = "mcp_control_tools.rs"]
mod mcp_control_tools;
#[path = "media_read.rs"]
mod media_read;
#[path = "mesh_control_send.rs"]
mod mesh_control_send;
#[path = "mesh_relay.rs"]
mod mesh_relay;
#[path = "meta_save_kill_point.rs"]
mod meta_save_kill_point;
#[path = "meta_save_order.rs"]
mod meta_save_order;
#[path = "mobile_link_conditions.rs"]
mod mobile_link_conditions;
#[path = "native_store_move.rs"]
mod native_store_move;
#[path = "new_across_restart.rs"]
mod new_across_restart;
#[path = "new_non_tty.rs"]
mod new_non_tty;
#[path = "new_relay_cli.rs"]
mod new_relay_cli;
#[path = "no_keychain.rs"]
mod no_keychain;
#[path = "one_command.rs"]
mod one_command;
#[path = "opencode_policy.rs"]
mod opencode_policy;
#[path = "opencode_task_subagents.rs"]
mod opencode_task_subagents;
#[path = "pairing.rs"]
mod pairing;
#[path = "pairing_join_stdin.rs"]
mod pairing_join_stdin;
#[path = "panic_log.rs"]
mod panic_log;
#[path = "parent_deadline.rs"]
mod parent_deadline;
#[path = "peer_briefs_origin.rs"]
mod peer_briefs_origin;
#[path = "peer_canonical_endpoint.rs"]
mod peer_canonical_endpoint;
#[path = "peer_cold_connect_bench.rs"]
mod peer_cold_connect_bench;
#[path = "peer_fork.rs"]
mod peer_fork;
#[path = "peer_harness_catalog.rs"]
mod peer_harness_catalog;
#[path = "peer_integration.rs"]
mod peer_integration;
#[path = "peer_last_read.rs"]
mod peer_last_read;
#[path = "peer_lease.rs"]
mod peer_lease;
#[path = "peer_message_replay.rs"]
mod peer_message_replay;
#[path = "peer_origin.rs"]
mod peer_origin;
#[path = "peer_person_stop.rs"]
mod peer_person_stop;
#[path = "peer_prompt_exactly_once.rs"]
mod peer_prompt_exactly_once;
#[path = "peer_queue_approval.rs"]
mod peer_queue_approval;
#[path = "peer_restart.rs"]
mod peer_restart;
#[path = "peer_send_filtered_attach.rs"]
mod peer_send_filtered_attach;
#[path = "peer_session_resume.rs"]
mod peer_session_resume;
#[path = "peer_state_events.rs"]
mod peer_state_events;
#[path = "peer_state_origin.rs"]
mod peer_state_origin;
#[path = "peer_token_race.rs"]
mod peer_token_race;
#[path = "peer_transport.rs"]
mod peer_transport;
#[path = "peer_warm_copy.rs"]
mod peer_warm_copy;
#[path = "permission_json_cli.rs"]
mod permission_json_cli;
#[path = "permission_matrix.rs"]
mod permission_matrix;
#[path = "person_allow.rs"]
mod person_allow;
#[path = "person_auto_start.rs"]
mod person_auto_start;
#[path = "person_policy_grant.rs"]
mod person_policy_grant;
#[path = "person_prompt_activity.rs"]
mod person_prompt_activity;
#[path = "process_budget.rs"]
mod process_budget;
#[path = "process_census_rpc.rs"]
mod process_census_rpc;
#[path = "prompt_images.rs"]
mod prompt_images;
#[path = "prompt_local_video_links.rs"]
mod prompt_local_video_links;
#[path = "prompt_uploads.rs"]
mod prompt_uploads;
#[path = "published_bench.rs"]
mod published_bench;
#[path = "question_replies.rs"]
mod question_replies;
#[path = "rc_faults.rs"]
mod rc_faults;
#[path = "remote_floor.rs"]
mod remote_floor;
#[path = "remote_group_cli.rs"]
mod remote_group_cli;
#[path = "remote_guard.rs"]
mod remote_guard;
#[path = "remote_guard_codex_bridge.rs"]
mod remote_guard_codex_bridge;
#[path = "remote_guard_modes.rs"]
mod remote_guard_modes;
#[path = "remote_guard_peer.rs"]
mod remote_guard_peer;
#[path = "remote_guard_refused_families.rs"]
mod remote_guard_refused_families;
#[path = "remote_guard_roots.rs"]
mod remote_guard_roots;
#[path = "remote_local_claude.rs"]
mod remote_local_claude;
#[path = "remote_local_claude_peer.rs"]
mod remote_local_claude_peer;
#[path = "remote_new_hints.rs"]
mod remote_new_hints;
#[path = "remote_peer_scratch_trust.rs"]
mod remote_peer_scratch_trust;
#[path = "remote_sandbox_canary.rs"]
mod remote_sandbox_canary;
#[path = "remote_sandbox_linux.rs"]
mod remote_sandbox_linux;
#[path = "request_stack.rs"]
mod request_stack;
#[path = "review_queue_peers.rs"]
mod review_queue_peers;
#[path = "rolling_summaries.rs"]
mod rolling_summaries;
#[path = "router_free_tier.rs"]
mod router_free_tier;
#[path = "router_install_secret.rs"]
mod router_install_secret;
#[path = "router_lifetime.rs"]
mod router_lifetime;
#[path = "router_no_keychain.rs"]
mod router_no_keychain;
#[path = "scratch_guard.rs"]
mod scratch_guard;
#[path = "send_across_restart.rs"]
mod send_across_restart;
#[path = "send_async.rs"]
mod send_async;
#[path = "send_attach.rs"]
mod send_attach;
#[path = "send_attach_cli.rs"]
mod send_attach_cli;
#[path = "send_from_agent_harness.rs"]
mod send_from_agent_harness;
#[path = "send_no_wait_old_daemon.rs"]
mod send_no_wait_old_daemon;
#[path = "send_prompt_file.rs"]
mod send_prompt_file;
#[path = "send_queued_cli.rs"]
mod send_queued_cli;
#[path = "send_relay_cli.rs"]
mod send_relay_cli;
#[path = "send_relay_sender_cli.rs"]
mod send_relay_sender_cli;
#[path = "send_sender_token_cli.rs"]
mod send_sender_token_cli;
#[path = "send_steer.rs"]
mod send_steer;
#[path = "session_auth.rs"]
mod session_auth;
#[path = "session_delete_disk.rs"]
mod session_delete_disk;
#[path = "session_env.rs"]
mod session_env;
#[path = "session_pool.rs"]
mod session_pool;
#[path = "session_queue_cli.rs"]
mod session_queue_cli;
#[path = "session_resume_cli.rs"]
mod session_resume_cli;
#[path = "session_tail_orphan.rs"]
mod session_tail_orphan;
#[path = "slow_notice.rs"]
mod slow_notice;
#[path = "socket_owner.rs"]
mod socket_owner;
#[path = "socket_ready.rs"]
mod socket_ready;
#[path = "ssh_fallback_cli.rs"]
mod ssh_fallback_cli;
#[path = "ssh_peer_injection.rs"]
mod ssh_peer_injection;
#[path = "start_defaults.rs"]
mod start_defaults;
#[path = "start_mode.rs"]
mod start_mode;
#[path = "start_priority.rs"]
mod start_priority;
#[path = "start_under_load_bench.rs"]
mod start_under_load_bench;
#[path = "startup_accept_bench.rs"]
mod startup_accept_bench;
#[path = "startup_load.rs"]
mod startup_load;
#[path = "stats.rs"]
mod stats;
#[path = "stop_condition.rs"]
mod stop_condition;
#[path = "stop_watchdog.rs"]
mod stop_watchdog;
#[path = "stuck_liveness_cli.rs"]
mod stuck_liveness_cli;
#[path = "stuck_liveness_peer.rs"]
mod stuck_liveness_peer;
#[path = "stuck_liveness_restore.rs"]
mod stuck_liveness_restore;
#[path = "subsession_asks_below.rs"]
mod subsession_asks_below;
#[path = "subsessions_live.rs"]
mod subsessions_live;
#[path = "suggestion_gate_per_person.rs"]
mod suggestion_gate_per_person;
#[path = "supervisor_faults.rs"]
mod supervisor_faults;
#[path = "surgery.rs"]
mod surgery;
#[path = "tailnet_embedded_logout.rs"]
mod tailnet_embedded_logout;
#[path = "tools_mcp.rs"]
mod tools_mcp;
#[path = "transfer_cli.rs"]
mod transfer_cli;
#[path = "transfer_limits.rs"]
mod transfer_limits;
#[path = "trigger_chat_cli.rs"]
mod trigger_chat_cli;
#[path = "typed_errors.rs"]
mod typed_errors;
#[path = "unattended_presets.rs"]
mod unattended_presets;
#[path = "uniichat_agent.rs"]
mod uniichat_agent;
#[path = "upload_frames.rs"]
mod upload_frames;
#[path = "upload_resume.rs"]
mod upload_resume;
#[path = "v2_chat_recorded_stream.rs"]
mod v2_chat_recorded_stream;
#[path = "v2_connection.rs"]
mod v2_connection;
#[path = "v2_gate_home.rs"]
mod v2_gate_home;
#[path = "vm_host.rs"]
mod vm_host;
#[path = "wait_peer_retry.rs"]
mod wait_peer_retry;
#[path = "watch_cli.rs"]
mod watch_cli;
#[path = "web_image_attachments.rs"]
mod web_image_attachments;
#[path = "web_listener_auth.rs"]
mod web_listener_auth;
#[path = "web_listener_network.rs"]
mod web_listener_network;
#[path = "web_mode_current.rs"]
mod web_mode_current;
#[path = "web_mode_drift.rs"]
mod web_mode_drift;
#[path = "web_modes_op.rs"]
mod web_modes_op;
#[path = "web_token_exposure.rs"]
mod web_token_exposure;
#[path = "web_token_rotation.rs"]
mod web_token_rotation;
#[path = "web_token_rotation_connections.rs"]
mod web_token_rotation_connections;
#[path = "wireguard_ssh_credentials.rs"]
mod wireguard_ssh_credentials;
#[path = "workspace_roots.rs"]
mod workspace_roots;
