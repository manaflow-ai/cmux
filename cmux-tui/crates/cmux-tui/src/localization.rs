use std::io::{Cursor, Write};
use std::sync::OnceLock;

use cmux_tui_core::BrowserFailure;
use cmux_tui_machine_protocol::provider_action_id;
use unicode_width::UnicodeWidthStr;

use crate::config::Action;

const FOREIGN_VIEWPORT_HINT_CAPACITY: usize = 64;

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct PairingMessages {
    pub title: &'static str,
    pub confirm: &'static str,
    pub peer_prefix: &'static str,
    pub deny: &'static str,
    pub approve: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ForeignViewportMessages {
    pub terminal_grid: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct GraphicsMessages {
    pub output_failed: &'static str,
    pub parser_recovery_failed: &'static str,
    kitty_image_budget_worker_start_failed: &'static str,
    kitty_image_budget_update_retrying: &'static str,
    kitty_image_budget_update_exhausted: &'static str,
    cell_pixel_update_retries_exhausted: &'static str,
    browser_surface_resize_failed: &'static str,
}

impl GraphicsMessages {
    pub(crate) fn kitty_image_budget_worker_start_failed(&self, error: &str) -> String {
        self.kitty_image_budget_worker_start_failed.replace("{error}", error)
    }

    #[cfg_attr(test, allow(dead_code))]
    pub(crate) fn kitty_image_budget_update_failed(
        &self,
        retry_exhausted: bool,
        summary: &str,
    ) -> String {
        let template = if retry_exhausted {
            self.kitty_image_budget_update_exhausted
        } else {
            self.kitty_image_budget_update_retrying
        };
        template.replace("{summary}", summary)
    }

    pub(crate) fn cell_pixel_update_retries_exhausted(
        &self,
        attempts: u8,
        remaining: usize,
        cell_pixels: (u16, u16),
    ) -> String {
        self.cell_pixel_update_retries_exhausted
            .replace("{attempts}", &attempts.to_string())
            .replace("{remaining}", &remaining.to_string())
            .replace("{width}", &cell_pixels.0.to_string())
            .replace("{height}", &cell_pixels.1.to_string())
    }

    pub(crate) fn browser_surface_resize_failed(
        &self,
        surface: u64,
        cols: u16,
        rows: u16,
        error: &str,
    ) -> String {
        self.browser_surface_resize_failed
            .replace("{surface}", &surface.to_string())
            .replace("{cols}", &cols.to_string())
            .replace("{rows}", &rows.to_string())
            .replace("{error}", error)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct TerminalMessages {
    pub clear_history_help: &'static str,
    pub clear_history_failed: &'static str,
    pub clear_history_outcome_unknown: &'static str,
    pub clear_history_unsupported: &'static str,
    pub clear_history_fallback_unrepresentable: &'static str,
    pub clear_history_preservation_impossible: &'static str,
    pub clear_history_stream_timeout: &'static str,
    pub clear_history_fallback_write_timeout: &'static str,
    pub clear_history_host_unsupported: &'static str,
    pub clear_history_host_exited: &'static str,
    pub clear_history_host_failed: &'static str,
    pub clear_history_host_malformed_response: &'static str,
    pub clear_history_host_no_response: &'static str,
    pub clear_history_remote_no_response: &'static str,
    pub clear_history_remote_disconnected: &'static str,
    pub clear_history_remote_rejected: &'static str,
    pub clear_history_unexpected: &'static str,
    pub keyboard_text_too_large: &'static str,
    pub paste_text_too_large: &'static str,
    pub deferred_input_destination_changed: &'static str,
    pub pointer_input_discarded_during_layout_change: &'static str,
    pub deferred_input_queue_full: &'static str,
    pub pty_input_too_large: &'static str,
    pub pty_input_queue_full: &'static str,
    pub pty_input_unavailable: &'static str,
    pub pty_input_exited: &'static str,
    pub attach_outcome_unknown: &'static str,
    pub operation_failed: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SessionMessages {
    pub creation_reconciling: &'static str,
    pub operation_reconciling: &'static str,
    pub operation_failed: &'static str,
    pub operation_canceled: &'static str,
    pub mux_subscription_recovered: &'static str,
    mux_subscription_recovery_failed: &'static str,
}

impl SessionMessages {
    pub(crate) fn mux_subscription_recovery_failed(&self, error: &str) -> String {
        self.mux_subscription_recovery_failed.replace("{error}", error)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SessionResetMessages {
    pub help: &'static str,
    pub exact_name_required: &'static str,
    pub non_empty_name_required: &'static str,
    pub no_state_root: &'static str,
    pub confirmation_required: &'static str,
    pub confirmation_recovery: &'static str,
    routing_options_unsupported: &'static str,
    reset_failed: &'static str,
    pub reason_session_running: &'static str,
    pub recovery_session_running: &'static str,
    pub reason_terminal_hosts_live: &'static str,
    pub recovery_terminal_hosts_live: &'static str,
    pub reason_terminal_hosts_unsupported: &'static str,
    pub recovery_terminal_hosts_unsupported: &'static str,
    pub reason_reset_unsupported: &'static str,
    pub recovery_reset_unsupported: &'static str,
    pub reason_invalid_state_path: &'static str,
    pub recovery_invalid_state_path: &'static str,
    pub reason_state_changed: &'static str,
    pub recovery_state_changed: &'static str,
    pub reason_state_too_large: &'static str,
    pub recovery_state_too_large: &'static str,
    pub reason_filesystem: &'static str,
    pub recovery_filesystem: &'static str,
    pub retry_after_preview: &'static str,
}

impl SessionResetMessages {
    pub(crate) fn routing_options_unsupported(&self, options: &str) -> String {
        self.routing_options_unsupported.replace("{options}", options)
    }

    pub(crate) fn reset_failed(&self, session: &str) -> String {
        self.reset_failed.replace("{session}", session)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MachineAgentMessages {
    pub help: &'static str,
    pub usage: &'static str,
    pub pairing_code: &'static str,
    pub registered: &'static str,
    pub retrying: &'static str,
    pub migration_failed: &'static str,
    pub pairing_code_unavailable: &'static str,
    pub runtime_failed: &'static str,
    pub invalid_session: &'static str,
    pub identity_unavailable: &'static str,
    pub registration_already_running: &'static str,
    pub cloud_configuration_invalid: &'static str,
    pub argument_needs_value: &'static str,
    pub invalid_cloud_port: &'static str,
    pub cloud_port_cannot_be_zero: &'static str,
    pub unknown_argument: &'static str,
}

impl MachineAgentMessages {
    pub(crate) fn retrying_message(&self, milliseconds: u128) -> String {
        self.retrying.replace("{milliseconds}", &milliseconds.to_string())
    }

    pub(crate) fn argument_needs_value_message(&self, argument: &str) -> String {
        self.argument_needs_value.replace("{argument}", argument)
    }

    pub(crate) fn invalid_cloud_port_message(&self, value: &str) -> String {
        self.invalid_cloud_port.replace("{value}", value)
    }

    pub(crate) fn unknown_argument_message(&self, argument: &str) -> String {
        self.unknown_argument.replace("{argument}", argument)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct MenuMessages {
    pub copy_message: &'static str,
    pub copy_workspace_id: &'static str,
    pub copy_tab_id: &'static str,
    pub copy_pane_id: &'static str,
    pub copy_url: &'static str,
    pub show_in_chrome: &'static str,
    pub connected_clients: &'static str,
    pub this_client: &'static str,
    pub excluded: &'static str,
    pub no_grid: &'static str,
    pub use_client_size: &'static str,
    pub use_only_client_size: &'static str,
    pub include_client_size: &'static str,
    pub restore_all_client_sizing: &'static str,
    pub disconnect_client: &'static str,
    pub copied: &'static str,
    pub copied_url: &'static str,
    pub rename: &'static str,
    pub maximize_pane: &'static str,
    pub restore_pane_layout: &'static str,
    pub show_sidebar: &'static str,
    pub hide_sidebar: &'static str,
    pub compact_sidebar: &'static str,
    pub full_sidebar: &'static str,
    pub focus_sidebar: &'static str,
    pub sidebar_layout: &'static str,
    pub sidebar_profiles: &'static str,
    pub show_sidebar_view: &'static str,
    pub hide_sidebar_view: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ShortcutMessages {
    pub title: &'static str,
    pub close_button: &'static str,
    pub footer: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct BrowserMessages {
    failed_prefix: &'static str,
    control_failed: &'static str,
    not_responding: &'static str,
    resize_recovery: &'static str,
    new_page_verification_prefix: &'static str,
    updated_page_verification_prefix: &'static str,
    verification_suffix: &'static str,
    pub starting: &'static str,
    pub attach_unsupported: &'static str,
    pub graphics_unsupported: &'static str,
    pub loading: &'static str,
    pub busy: &'static str,
    pub no_active_surface: &'static str,
    pub not_browser: &'static str,
    pub unknown_surface: &'static str,
}

impl BrowserMessages {
    pub(crate) fn control_failed(&self, error: &str) -> String {
        self.control_failed.replace("{error}", error)
    }

    pub(crate) fn loading(&self, url: &str) -> String {
        self.loading.replace("{url}", url)
    }
    pub(crate) fn failure_message(&self, failure: BrowserFailure<'_>) -> String {
        match failure {
            BrowserFailure::NotResponding => self.not_responding.to_string(),
            BrowserFailure::ResizeRecovery => self.resize_recovery.to_string(),
            BrowserFailure::NewPageVerification(detail) => {
                format!("{}{detail}{}", self.new_page_verification_prefix, self.verification_suffix)
            }
            BrowserFailure::UpdatedPageVerification(detail) => format!(
                "{}{detail}{}",
                self.updated_page_verification_prefix, self.verification_suffix
            ),
            BrowserFailure::Other(detail) => format!("{}{detail}", self.failed_prefix),
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct LayoutMessages {
    pub startup_shortcuts: &'static str,
    pub verb_help_heading: &'static str,
    pub new_pane_right_help: &'static str,
    pub set_viewport_pane_width_help: &'static str,
    pub undo_layout_help: &'static str,
    pub create_viewport_pane_operation: &'static str,
    pub undo_layout_operation: &'static str,
    pub resize_exact_split_operation: &'static str,
    pub split_id_subject: &'static str,
    pub resize_viewport_pane_operation: &'static str,
    pub viewport_pane_subject: &'static str,
    pub remote_viewport_panes_unsupported: &'static str,
    pub ratio_must_be_number: &'static str,
    pub ratio_must_be_finite: &'static str,
    pub viewport_width_must_be_number: &'static str,
    pub viewport_width_must_be_finite: &'static str,
    pub viewport_width_out_of_range: &'static str,
    surface_size_release_failed: &'static str,
    pane_without_resizable_column: &'static str,
    pub remote_viewport_resize_unsupported: &'static str,
    pub remote_layout_undo_unsupported: &'static str,
    pub layout_undo_missing_screen: &'static str,
    pub layout_undo_missing_revision: &'static str,
    pub layout_undo_missing_closes_panes: &'static str,
    pub layout_undo_invalid_pane: &'static str,
    pub layout_undo_missing_outcome: &'static str,
    pub layout_undo_confirmation_flags_together: &'static str,
    pub layout_changed_before_undo: &'static str,
    unknown_split: &'static str,
    unknown_pane_split: &'static str,
    unrepresentable_viewport_width: &'static str,
    unrepresentable_viewport_ratio: &'static str,
    pub viewport_ratio_target_missing: &'static str,
    pub viewport_ratio_out_of_range: &'static str,
    pub viewport_column_missing: &'static str,
    unsupported_server_command: &'static str,
    layout_undo_applied: &'static str,
    layout_undo_confirmation_required: &'static str,
}

impl LayoutMessages {
    pub(crate) fn surface_size_release_failed(&self, surface: u64, error: &str) -> String {
        self.surface_size_release_failed
            .replace("{surface}", &surface.to_string())
            .replace("{error}", error)
    }

    pub(crate) fn pane_without_resizable_column(&self, pane: u64) -> String {
        self.pane_without_resizable_column.replace("{pane}", &pane.to_string())
    }

    pub(crate) fn unknown_split(&self, split: u64) -> String {
        self.unknown_split.replace("{split}", &split.to_string())
    }

    pub(crate) fn unknown_pane_split(&self, pane: u64) -> String {
        self.unknown_pane_split.replace("{pane}", &pane.to_string())
    }

    pub(crate) fn unrepresentable_viewport_width(
        &self,
        split: u64,
        ratio: f32,
        width: f32,
    ) -> String {
        self.unrepresentable_viewport_width
            .replace("{split}", &split.to_string())
            .replace("{ratio}", &ratio.to_string())
            .replace("{width}", &width.to_string())
    }

    pub(crate) fn unrepresentable_viewport_ratio(&self, split: u64, ratio: f32) -> String {
        self.unrepresentable_viewport_ratio
            .replace("{split}", &split.to_string())
            .replace("{ratio}", &ratio.to_string())
    }

    #[cfg(test)]
    pub(crate) fn unsupported_server_command(&self, command: &str) -> String {
        self.unsupported_server_command.replace("{command}", command)
    }

    #[cfg(test)]
    pub(crate) fn layout_undo_applied(&self, screen: u64, revision: u64) -> String {
        self.layout_undo_applied
            .replace("{screen}", &screen.to_string())
            .replace("{revision}", &revision.to_string())
    }

    #[cfg(test)]
    pub(crate) fn layout_undo_confirmation_required(&self, revision: u64, panes: &str) -> String {
        self.layout_undo_confirmation_required
            .replace("{revision}", &revision.to_string())
            .replace("{panes}", panes)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RuntimeMessages {
    pub unknown_panic: &'static str,
    pub terminal_capacity_exhausted: &'static str,
    renderer_panicked: &'static str,
    host_input_failed: &'static str,
    signal_handlers_failed: &'static str,
    terminal_restore_also_failed: &'static str,
}

impl RuntimeMessages {
    pub(crate) fn renderer_panicked(&self, message: &str) -> String {
        self.renderer_panicked.replace("{message}", message)
    }

    pub(crate) fn host_input_failed(&self, error: &str) -> String {
        self.host_input_failed.replace("{error}", error)
    }

    pub(crate) fn signal_handlers_failed(&self, error: &str) -> String {
        self.signal_handlers_failed.replace("{error}", error)
    }

    pub(crate) fn terminal_restore_also_failed(&self, error: &str, restore_error: &str) -> String {
        self.terminal_restore_also_failed
            .replace("{error}", error)
            .replace("{restore_error}", restore_error)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RemoteClientMessages {
    pub connect_help: &'static str,
    pub ssh_help: &'static str,
    pub forward_help: &'static str,
    pub rpc_help: &'static str,
    pub enroll_help: &'static str,
    pub known_daemons_help: &'static str,
    pub remote_probe_help: &'static str,
    pub remote_link_help: &'static str,
    pub install_self_help: &'static str,
    pub command_help: &'static str,
    pub remote_lifecycle_help: &'static str,
    option_needs_value: &'static str,
    invalid_option_value: &'static str,
    option_must_be_positive: &'static str,
    unknown_option: &'static str,
    unknown_option_for_command: &'static str,
    option_once: &'static str,
    unknown_action: &'static str,
    enroll_arity: &'static str,
    option_create_only: &'static str,
    pub inline_invitation_rejected: &'static str,
    pub invitation_path_invalid: &'static str,
    pub invitation_input_read_failed: &'static str,
    pub invitation_input_empty: &'static str,
    invitation_input_too_large: &'static str,
    pub invitation_input_multiline: &'static str,
    pub invitation_input_invalid_utf8: &'static str,
    pub inline_relay_ticket_rejected: &'static str,
    pub inline_enroll_relay_ticket_rejected: &'static str,
    pub relay_command_arg_order: &'static str,
    pub relay_credentials_require_explicit_route: &'static str,
    relay_shorthand_requires_relay_route: &'static str,
    pub relay_credential_pair_required: &'static str,
    pub multiple_relay_credentials_require_routes: &'static str,
    pub route_scoped_relay_credential_pair_required: &'static str,
    relay_credential_limit: &'static str,
    relay_route_not_relay: &'static str,
    relay_route_repeated: &'static str,
    invitation_relay_route_repeated: &'static str,
    relay_route_limit: &'static str,
    invitation_daemon_mismatch: &'static str,
    pub invitation_no_routes: &'static str,
    daemon_no_routes: &'static str,
    pub known_daemon_key_unavailable: &'static str,
    carrier_daemon_requires_carrier: &'static str,
    pub upgrade_requires_ssh: &'static str,
    relay_route_not_candidate: &'static str,
    daemon_key_changed: &'static str,
    pub known_daemon_refresh_missing: &'static str,
    pub positional_invitation_rejected: &'static str,
    pub connect_one_route: &'static str,
    pub reconnect_policy_invalid: &'static str,
    pub upgrade_no_install: &'static str,
    pub json_requires_headless: &'static str,
    pub help_invalid_options: &'static str,
    pub ssh_destination_required: &'static str,
    pub ssh_destination_invalid: &'static str,
    pub forward_workspace_required: &'static str,
    pub forward_port_required: &'static str,
    pub rpc_request_invalid: &'static str,
    pub rpc_input_invalid: &'static str,
    rpc_stdin_too_large: &'static str,
    pub rpc_stdin_invalid_utf8: &'static str,
    pub known_forget_arity: &'static str,
    pub known_state_dir_unavailable: &'static str,
    known_daemon_not_known: &'static str,
    known_daemon_forgotten: &'static str,
    pub known_daemons_empty: &'static str,
    pub known_daemon_auth_enrolled: &'static str,
    pub known_daemon_auth_carrier: &'static str,
}

impl RemoteClientMessages {
    pub(crate) fn option_needs_value(&self, option: &str) -> String {
        self.option_needs_value.replace("{option}", option)
    }

    pub(crate) fn invalid_option_value(&self, option: &str, expected: &str) -> String {
        self.invalid_option_value.replace("{option}", option).replace("{expected}", expected)
    }

    pub(crate) fn option_must_be_positive(&self, option: &str) -> String {
        self.option_must_be_positive.replace("{option}", option)
    }

    pub(crate) fn unknown_option(&self, option: &str) -> String {
        self.unknown_option.replace("{option}", &format!("{option:?}"))
    }

    pub(crate) fn unknown_option_for_command(&self, option: &str, command: &str) -> String {
        self.unknown_option_for_command
            .replace("{option}", &format!("{option:?}"))
            .replace("{command}", command)
    }

    pub(crate) fn option_once(&self, option: &str) -> String {
        self.option_once.replace("{option}", option)
    }

    pub(crate) fn unknown_action(&self, command: &str, action: &str) -> String {
        self.unknown_action
            .replace("{command}", command)
            .replace("{action}", &format!("{action:?}"))
    }

    pub(crate) fn enroll_arity(&self, action: &str, expected: usize) -> String {
        self.enroll_arity.replace("{action}", action).replace("{expected}", &expected.to_string())
    }

    pub(crate) fn option_create_only(&self, option: &str) -> String {
        self.option_create_only.replace("{option}", option)
    }

    pub(crate) fn invitation_input_too_large(&self, maximum: usize) -> String {
        self.invitation_input_too_large.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn relay_shorthand_requires_relay_route(&self, route: &str) -> String {
        self.relay_shorthand_requires_relay_route.replace("{route}", route)
    }

    pub(crate) fn relay_credential_limit(&self, maximum: usize) -> String {
        self.relay_credential_limit.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn relay_route_not_relay(&self, route: &str) -> String {
        self.relay_route_not_relay.replace("{route}", route)
    }

    pub(crate) fn relay_route_repeated(&self, route: &str) -> String {
        self.relay_route_repeated.replace("{route}", route)
    }

    pub(crate) fn invitation_relay_route_repeated(&self, route: &str) -> String {
        self.invitation_relay_route_repeated.replace("{route}", route)
    }

    pub(crate) fn relay_route_limit(&self, maximum: usize) -> String {
        self.relay_route_limit.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn invitation_daemon_mismatch(&self, fingerprint: &str) -> String {
        self.invitation_daemon_mismatch.replace("{fingerprint}", &format!("{fingerprint:?}"))
    }

    pub(crate) fn daemon_no_routes(&self, fingerprint: &str) -> String {
        self.daemon_no_routes.replace("{fingerprint}", fingerprint)
    }

    pub(crate) fn carrier_daemon_requires_carrier(&self, fingerprint: &str) -> String {
        self.carrier_daemon_requires_carrier.replace("{fingerprint}", fingerprint)
    }

    pub(crate) fn relay_route_not_candidate(&self, route: &str) -> String {
        self.relay_route_not_candidate.replace("{route}", route)
    }

    pub(crate) fn daemon_key_changed(&self, name: &str) -> String {
        self.daemon_key_changed.replace("{name}", name)
    }

    pub(crate) fn rpc_stdin_too_large(&self, maximum: usize) -> String {
        self.rpc_stdin_too_large.replace("{maximum}", &maximum.to_string())
    }

    pub(crate) fn known_daemon_not_known(&self, fingerprint: &str) -> String {
        self.known_daemon_not_known.replace("{fingerprint}", &format!("{fingerprint:?}"))
    }

    pub(crate) fn known_daemon_forgotten(&self, fingerprint: &str) -> String {
        self.known_daemon_forgotten.replace("{fingerprint}", fingerprint)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct RemoteMessages {
    pub remote_stop_help: &'static str,
    remote_stop_unknown_option: &'static str,
    pub remote_stop_no_positional: &'static str,
    pub remote_stop_acknowledgements_mutually_exclusive: &'static str,
    invalid_runtime_metadata: &'static str,
    inspect_runtime_metadata: &'static str,
    pub inactive_legacy_needs_migration: &'static str,
    pub refuse_live_invalid_lifecycle: &'static str,
    pub embedded_daemon_stop_refused: &'static str,
    pub daemon_shutdown_failed: &'static str,
    pub observe_daemon_exit: &'static str,
    pub daemon_stop_timeout: &'static str,
    verify_previous_finalization_path: &'static str,
    pub verify_previous_finalization: &'static str,
    pub previous_finalization_failed_ack: &'static str,
    pub verify_finalization: &'static str,
    pub finalization_wrong_lifecycle: &'static str,
    pub finalization_failed: &'static str,
    pub verify_lifecycle_fence: &'static str,
    pub confirm_lifecycle_fence_durability: &'static str,
    pub inspect_authorization_state: &'static str,
    pub inspect_authorization_schema: &'static str,
    pub legacy_authorization_requires_migration: &'static str,
    pub prepare_lifecycle_state: &'static str,
    pub verify_previous_lifecycle_metadata: &'static str,
    pub modern_predecessor_missing_outcome: &'static str,
    pub runtime_empty_lifecycle: &'static str,
    pub state_predates_lifecycle_fence: &'static str,
    pub state_missing_lifecycle_fence: &'static str,
    pub authorization_finalization_failed: &'static str,
    lifecycle_fence_version_unsupported: &'static str,
    pub inspect_stopped_authorization_state: &'static str,
    pub acquire_stopped_authorization_lease: &'static str,
    pub finalize_stopped_authorization_migration: &'static str,
    pub snapshot_runtime_for_recovery: &'static str,
    pub snapshot_finalization_for_recovery: &'static str,
    pub acquire_recovery_authorization_lease: &'static str,
    pub resnapshot_runtime_for_recovery: &'static str,
    pub resnapshot_finalization_for_recovery: &'static str,
    pub lifecycle_evidence_changed_before_recovery: &'static str,
    pub complete_authorization_recovery: &'static str,
    pub verify_runtime_for_recovery: &'static str,
    pub refuse_failed_ack_with_legacy_runtime: &'static str,
    pub no_failed_finalization_recorded: &'static str,
    pub finalization_succeeded_no_ack: &'static str,
    pub inspect_legacy_authorization_state: &'static str,
    pub no_legacy_authorization_state: &'static str,
    pub snapshot_legacy_runtime: &'static str,
    pub snapshot_legacy_shutdown: &'static str,
    pub acquire_legacy_recovery_authorization_lease: &'static str,
    pub resnapshot_legacy_runtime: &'static str,
    pub resnapshot_legacy_shutdown: &'static str,
    pub lifecycle_evidence_changed_before_legacy_recovery: &'static str,
    pub complete_legacy_authorization_recovery: &'static str,
    pub failed_finalization_label: &'static str,
    pub legacy_finalization_label: &'static str,
    refuse_active_socket: &'static str,
    verify_socket_inactive: &'static str,
    pub lifecycle_runtime_requires_failed_ack: &'static str,
    pub shutdown_evidence_requires_failed_ack: &'static str,
    pub lifecycle_evidence_changed_during_legacy_recovery: &'static str,
    pub lifecycle_evidence_changed_during_recovery: &'static str,
}

impl RemoteMessages {
    pub(crate) fn remote_stop_unknown_option(&self, option: &str) -> String {
        self.remote_stop_unknown_option.replace("{option}", &format!("{option:?}"))
    }

    pub(crate) fn invalid_runtime_metadata(&self, path: &str) -> String {
        self.invalid_runtime_metadata.replace("{path}", path)
    }

    pub(crate) fn inspect_runtime_metadata(&self, path: &str) -> String {
        self.inspect_runtime_metadata.replace("{path}", path)
    }

    pub(crate) fn verify_previous_finalization_path(&self, path: &str) -> String {
        self.verify_previous_finalization_path.replace("{path}", path)
    }

    pub(crate) fn lifecycle_fence_version_unsupported(&self, version: u32) -> String {
        self.lifecycle_fence_version_unsupported.replace("{version}", &version.to_string())
    }

    pub(crate) fn refuse_active_socket(&self, finalization: &str, path: &str) -> String {
        self.refuse_active_socket.replace("{finalization}", finalization).replace("{path}", path)
    }

    pub(crate) fn verify_socket_inactive(&self, path: &str) -> String {
        self.verify_socket_inactive.replace("{path}", path)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ConfigMessages {
    invalid_macos_option_as_alt: &'static str,
    invalid_section: &'static str,
    unknown_field: &'static str,
    invalid_root: &'static str,
}

impl ConfigMessages {
    pub(crate) fn invalid_macos_option_as_alt(&self, value: &str) -> String {
        self.invalid_macos_option_as_alt.replace("{value}", value)
    }
    pub(crate) fn invalid_section(&self, value: &str) -> String {
        self.invalid_section.replace("{section}", value)
    }
    pub(crate) fn unknown_field(&self, value: &str) -> String {
        self.unknown_field.replace("{field}", value)
    }
    pub(crate) fn invalid_root(&self) -> &'static str {
        self.invalid_root
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct AttachMessages {
    pub filtered_subscription_unavailable: &'static str,
    pub remote_attach_queue_full: &'static str,
    remote_attach_workers_failed_template: &'static str,
    surface_sync_failed_template: &'static str,
    surface_sync_unknown_template: &'static str,
    surface_sync_attach: &'static str,
    surface_sync_resize: &'static str,
    surface_sync_operation: &'static str,
    unknown_terminal_prefix: &'static str,
    unknown_terminal_suffix: &'static str,
    ambiguous_terminal_prefix: &'static str,
    ambiguous_terminal_suffix: &'static str,
    browser_terminal_prefix: &'static str,
    browser_terminal_suffix: &'static str,
}

impl AttachMessages {
    pub fn remote_attach_workers_failed(&self, error: &str) -> String {
        self.remote_attach_workers_failed_template.replace("{error}", error)
    }

    fn surface_sync_operation(&self, operation: &str) -> &'static str {
        match operation {
            "attach" => self.surface_sync_attach,
            "resize" => self.surface_sync_resize,
            _ => self.surface_sync_operation,
        }
    }

    pub fn surface_sync_failed(&self, surface: u64, operation: &str, error: &str) -> String {
        self.surface_sync_failed_template
            .replace("{surface}", &surface.to_string())
            .replace("{operation}", self.surface_sync_operation(operation))
            .replace("{error}", error)
    }

    pub fn surface_sync_unknown(&self, surface: u64, operation: &str, error: &str) -> String {
        self.surface_sync_unknown_template
            .replace("{surface}", &surface.to_string())
            .replace("{operation}", self.surface_sync_operation(operation))
            .replace("{error}", error)
    }

    pub fn unknown_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.unknown_terminal_prefix, self.unknown_terminal_suffix)
    }

    #[cfg(test)]
    pub fn ambiguous_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.ambiguous_terminal_prefix, self.ambiguous_terminal_suffix)
    }

    #[cfg(test)]
    pub fn browser_not_terminal(&self, reference: &str) -> String {
        format!("{}{reference:?}{}", self.browser_terminal_prefix, self.browser_terminal_suffix)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct SidebarMessages {
    pub machines: &'static str,
    pub workspaces: &'static str,
    pub panes: &'static str,
    pub tabs: &'static str,
    pub agents: &'static str,
    pub projection_path_separator: &'static str,
    pub new_machine: &'static str,
    pub connect_machine: &'static str,
    pub no_machines: &'static str,
    pub no_workspaces: &'static str,
    pub no_panes: &'static str,
    pub no_tabs: &'static str,
    pub no_agents: &'static str,
    pub recoverable_machine: &'static str,
    pub rename_machine: &'static str,
    pub delete_machine: &'static str,
    pub restore_machine: &'static str,
    pub purge_machine: &'static str,
    pub confirm_delete_machine: &'static str,
    pub confirm_purge_machine: &'static str,
    pub new_workspace: &'static str,
    pub new_isolated_workspace: &'static str,
    pub new_shared_workspace: &'static str,
    pub recoverable_workspace: &'static str,
    pub rename_workspace: &'static str,
    pub delete_workspace: &'static str,
    pub restore_workspace: &'static str,
    pub purge_workspace: &'static str,
    pub confirm_purge_workspace: &'static str,
    pub no_active_session: &'static str,
    pub managed_workspace_unsupported: &'static str,
    pub managed_workspace_machine_inactive: &'static str,
    pub managed_workspace_unavailable: &'static str,
    pub managed_workspace_operation_not_allowed: &'static str,
    pub running: &'static str,
    pub connecting: &'static str,
    pub waking: &'static str,
    pub sleeping_wake_hint: &'static str,
    pub sleeping: &'static str,
    pub stopped: &'static str,
    pub unavailable: &'static str,
    pub working: &'static str,
    pub blocked: &'static str,
    pub idle: &'static str,
    pub done: &'static str,
    pub unknown: &'static str,
    pub connect_prompt: &'static str,
    pub connect_host_prompt: &'static str,
    pub connecting_to: &'static str,
    pub starting_on: &'static str,
    pub failed_to_connect: &'static str,
    pub retry_connection: &'static str,
    pub close_dialog: &'static str,
    pub ssh_hosts: &'static str,
    pub type_to_filter: &'static str,
    pub other_host: &'static str,
    pub personal_scope: &'static str,
    pub plugin_exited: &'static str,
    pub team_scope: &'static str,
    pub scope: &'static str,
    pub provider_actions: &'static str,
    pub action_required: &'static str,
    pub action_too_long: &'static str,
    pub action_invalid_email: &'static str,
    pub action_invalid_integer: &'static str,
    pub action_below_minimum: &'static str,
    pub action_above_maximum: &'static str,
    pub action_missing_selected_machine: &'static str,
    pub action_missing_selected_workspace: &'static str,
    pub action_multiple_fields_unsupported: &'static str,
    pub action_list_workspace_ports: &'static str,
    pub action_make_workspace_port_public: &'static str,
    pub action_make_workspace_port_private: &'static str,
    pub action_open_private_workspace_port: &'static str,
    pub action_workspace_port: &'static str,
    pub confirm_destructive_action: &'static str,
    pub confirm_layout_undo: &'static str,
    pub confirmation_mismatch: &'static str,
    pub layout_nothing_to_undo: &'static str,
    pub layout_undo_stale: &'static str,
    pub initial_machine_connection_failed: &'static str,
    pub provider_notice_identity_unavailable: &'static str,
    pub provider_connection_already_running: &'static str,
    pub machine_provider_disconnected: &'static str,
    pub machine_action_failed: &'static str,
    pub layout_refresh_failed: &'static str,
    pub layout_stale: &'static str,
    pub file_no_focused_pane: &'static str,
    pub file_surface_unavailable: &'static str,
    pub file_input_not_queued: &'static str,
    pub file_command_failed: &'static str,
    pub file_sent_to_focused_pane: &'static str,
    pub refresh_remote_tree_retrying: &'static str,
    pub refresh_remote_tree_stopped: &'static str,
    pub clients_list_failed: &'static str,
    pub layout_undo_failed: &'static str,
    pub pairing_response_failed: &'static str,
    pub workspace_state_failed: &'static str,
    pub provider_action_open_url: &'static str,
    pub machine_provider_update_failed: &'static str,
    pub machine_provider_lifecycle_update_failed: &'static str,
    pub machine_provider_workspace_update_failed: &'static str,
    pub machine_reconnect_failed: &'static str,
    pub machine_terminal_colors_failed: &'static str,
    pub machine_provider_external_connect_unsupported: &'static str,
    pub machine_provider_external_connect_ambiguous: &'static str,
    pub machine_not_ready_to_connect: &'static str,
    pub machine_managed_authority_unsupported: &'static str,
    pub machine_managed_authority_invalid: &'static str,
    pub machine_catalog_create_unsupported: &'static str,
    pub machine_creation_source_unavailable: &'static str,
    pub machine_name_required: &'static str,
    pub client_machine_unavailable: &'static str,
    pub prototype_machine_added: &'static str,
    pub machine_catalog_provider_actions_unsupported: &'static str,
    pub machine_catalog_updates_failed: &'static str,
    pub machine_catalog_restart_failed: &'static str,
    pub machine_replacement_pending: &'static str,
    pub machine_replacement_worker_stopped: &'static str,
    pub machine_replacement_stale: &'static str,
    pub machine_replacement_not_pending: &'static str,
    pub machine_replacement_target_missing: &'static str,
    pub managed_ssh_requires_unix: &'static str,
}

impl SidebarMessages {
    pub(crate) fn connecting_to_message(&self, target: &str) -> String {
        self.connecting_to.replace("{target}", target)
    }

    pub(crate) fn starting_on_message(&self, target: &str) -> String {
        self.starting_on.replace("{target}", target)
    }

    pub(crate) fn failed_to_connect_message(&self, target: &str) -> String {
        self.failed_to_connect.replace("{target}", target)
    }

    pub(crate) fn provider_action_label(&self, action_id: &str) -> Option<&'static str> {
        match action_id {
            provider_action_id::LIST_WORKSPACE_PORTS => Some(self.action_list_workspace_ports),
            provider_action_id::MAKE_WORKSPACE_PORT_PUBLIC => {
                Some(self.action_make_workspace_port_public)
            }
            provider_action_id::MAKE_WORKSPACE_PORT_PRIVATE => {
                Some(self.action_make_workspace_port_private)
            }
            provider_action_id::OPEN_PRIVATE_WORKSPACE_PORT => {
                Some(self.action_open_private_workspace_port)
            }
            _ => None,
        }
    }

    pub(crate) fn provider_action_field_label(
        &self,
        action_id: &str,
        field_id: &str,
    ) -> Option<&'static str> {
        matches!(
            (action_id, field_id),
            (
                provider_action_id::MAKE_WORKSPACE_PORT_PUBLIC
                    | provider_action_id::MAKE_WORKSPACE_PORT_PRIVATE
                    | provider_action_id::OPEN_PRIVATE_WORKSPACE_PORT,
                "port"
            )
        )
        .then_some(self.action_workspace_port)
    }
}

impl ForeignViewportMessages {
    pub fn hint(&self, cols: u16, rows: u16) -> Option<ForeignViewportHint> {
        let mut bytes = [0_u8; FOREIGN_VIEWPORT_HINT_CAPACITY];
        let len = {
            let mut cursor = Cursor::new(bytes.as_mut_slice());
            write!(&mut cursor, "{} ({cols}x{rows})", self.terminal_grid).ok()?;
            cursor.position() as usize
        };
        Some(ForeignViewportHint { bytes, len })
    }

    pub fn hint_width(&self, cols: u16, rows: u16) -> usize {
        self.terminal_grid.width() + 4 + decimal_width(cols) + decimal_width(rows)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ForeignViewportHint {
    bytes: [u8; FOREIGN_VIEWPORT_HINT_CAPACITY],
    len: usize,
}

impl ForeignViewportHint {
    pub fn as_str(&self) -> &str {
        std::str::from_utf8(&self.bytes[..self.len])
            .expect("foreign viewport hint is assembled from UTF-8 strings and ASCII digits")
    }
}

const fn decimal_width(mut value: u16) -> usize {
    let mut width = 1;
    while value >= 10 {
        value /= 10;
        width += 1;
    }
    width
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct StartupMessages {
    schema_too_new: &'static str,
    pub invalid_session_name: &'static str,
    pub duplicate_attach: &'static str,
    pub session_socket: &'static str,
    pub stop_newer_server: &'static str,
    pub no_server_listening: &'static str,
    pub reset_saved_state: &'static str,
    pub reset_saved_state_unsupported: &'static str,
    pub forced_handoff_unsupported: &'static str,
    pub different_server: &'static str,
    pub server_not_verified: &'static str,
    pub saved_state_requires_newer: &'static str,
    pub start_separate_session: &'static str,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct LocalServerMessages {
    pub startup_lifecycle_usage: &'static str,
    pub root_remote_usage: &'static str,
    pub root_server_usage: &'static str,
    pub root_server_scope: &'static str,
    pub session_stop_help: &'static str,
    pub help: &'static str,
    pub start_help: &'static str,
    pub ensure_help: &'static str,
    pub status_help: &'static str,
    pub stop_help: &'static str,
    pub reload_config_help: &'static str,
    pub running: &'static str,
    pub started: &'static str,
    pub stopped: &'static str,
    pub not_running: &'static str,
    pub owner_spawn_failed: &'static str,
    pub owner_not_ready: &'static str,
    pub reloaded: &'static str,
    pub connect_failed: &'static str,
    pub starting: &'static str,
    pub identity_failed: &'static str,
    pub communication_failed: &'static str,
    pub invalid_response: &'static str,
    pub reload_rejected: &'static str,
    pub reload_owner_stopped: &'static str,
    pub stop_rejected: &'static str,
    pub wrong_owner: &'static str,
    pub different_session: &'static str,
    pub invalid_identity: &'static str,
    pub unsupported_protocol: &'static str,
    pub force_unsupported: &'static str,
    pub session_conflict: &'static str,
    pub machine_not_supported: &'static str,
    pub invalid_session: &'static str,
    pub session_name_required: &'static str,
    pub invalid_action_syntax: &'static str,
    pub start_options_after_action: &'static str,
    pub start_rejects_output_mode: &'static str,
    pub unknown_scope: &'static str,
    pub unknown_server_action: &'static str,
    pub suggestion: &'static str,
    pub daemon_removed: &'static str,
    pub unexpected_after_stop: &'static str,
    pub stop_timeout: &'static str,
}

impl LocalServerMessages {
    pub(crate) fn owner_spawn_failed(&self) -> String {
        self.owner_spawn_failed.to_string()
    }

    pub(crate) fn unknown_scope(&self, scope: &str, suggestion: Option<&str>) -> String {
        self.with_suggestion(self.unknown_scope.replace("{scope}", scope), suggestion)
    }

    pub(crate) fn unknown_server_action(&self, action: &str, suggestion: Option<&str>) -> String {
        self.with_suggestion(self.unknown_server_action.replace("{action}", action), suggestion)
    }

    fn with_suggestion(&self, message: String, suggestion: Option<&str>) -> String {
        match suggestion {
            Some(candidate) => {
                format!("{message} {}", self.suggestion.replace("{candidate}", candidate))
            }
            None => message,
        }
    }
}

impl StartupMessages {
    pub(crate) fn schema_too_new(&self, session: &str, version: &str) -> String {
        self.schema_too_new.replace("{version}", version).replace("{session}", session)
    }
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Catalog {
    japanese: bool,
    pub startup: StartupMessages,
    pub local_server: LocalServerMessages,
    pub pairing: PairingMessages,
    pub foreign_viewport: ForeignViewportMessages,
    pub graphics: GraphicsMessages,
    pub terminal: TerminalMessages,
    pub session: SessionMessages,
    pub session_reset: SessionResetMessages,
    pub machine_agent: MachineAgentMessages,
    pub menu: MenuMessages,
    pub shortcuts: ShortcutMessages,
    pub browser: BrowserMessages,
    pub layout: LayoutMessages,
    pub runtime: RuntimeMessages,
    pub remote_client: RemoteClientMessages,
    pub remote: RemoteMessages,
    pub config: ConfigMessages,
    pub attach: AttachMessages,
    pub sidebar: SidebarMessages,
}

impl Catalog {
    pub fn action_label(&self, action: Action) -> &'static str {
        let definition = action.definition();
        if self.japanese { definition.label_ja } else { definition.label_en }
    }
}

static ENGLISH: Catalog = Catalog {
    japanese: false,
    startup: StartupMessages {
        schema_too_new: "cannot open session \"{session}\" with cmux {version}: its saved state is incompatible with this build",
        invalid_session_name: "The session name must be one path component without separators or control characters",
        duplicate_attach: "attach may be supplied only once",
        session_socket: "session socket",
        stop_newer_server: "a newer cmux server owns this saved session; stop it before retrying:",
        no_server_listening: "no server is listening on this socket",
        reset_saved_state: "inspect this session's incompatible saved state reset plan:",
        reset_saved_state_unsupported: "scoped saved-state reset is not supported on this platform; no reset command is shown",
        forced_handoff_unsupported: "this server cannot accept a safe forced shutdown command; use the newer cmux build that started it to stop the session",
        different_server: "this socket belongs to a different cmux session; no shutdown command is shown",
        server_not_verified: "cmux could not verify which session owns this socket; no shutdown command is shown",
        saved_state_requires_newer: "the saved state still requires a newer cmux; upgrade cmux to reopen this session",
        start_separate_session: "or start this build in a separate session:",
    },
    local_server: LocalServerMessages {
        startup_lifecycle_usage: "  cmux server <ACTION>     Start, inspect, stop, or reload one local session\n  cmux remote connect <ROUTE>  Attach through an authenticated remote route\n  cmux remote ssh <HOST>       Bootstrap and attach over direct SSH\n  cmux remote forward <ROUTE>  Forward a workspace TCP service locally\n  cmux remote rpc <ROUTE>     Run workspace coding-agent RPC requests\n  cmux remote enroll <ACTION> Enroll, approve, list, or revoke devices\n  cmux remote known-daemons   List client-pinned daemon identities and routes\n  cmux remote stop            Stop a replaceable SSH sidecar explicitly",
        root_remote_usage: "  cmux remote <connect|ssh|forward|rpc|enroll|known-daemons|stop> [OPTIONS]",
        root_server_usage: "  cmux server <start|ensure|status|stop|reload-config> [OPTIONS]",
        root_server_scope: "  server        Manage one named local durable session owner",
        session_stop_help: "  cmux session <name>|current stop",
        help: "USAGE\n  cmux server start [START OPTIONS]\n  cmux server ensure [--session <name>] [--socket <path>]\n  cmux server status [--session <name>] [--socket <path>]\n  cmux server stop [--session <name>] [--socket <path>] [--force]\n  cmux server reload-config [--session <name>] [--socket <path>]\n\n`server` always targets the local durable mux owner for one named session.\nUse `cmux remote --help` for authenticated remote-daemon lifecycle.\n",
        start_help: "USAGE\n  cmux server start [START OPTIONS]\n\nStart the local durable mux owner for one named session in the foreground.\n",
        ensure_help: "USAGE\n  cmux server ensure [--session <name>] [--socket <path>]\n\nStart a detached local session owner when none is running, wait until it\naccepts clients, and report it. Ensuring a running session succeeds.\n",
        status_help: "USAGE\n  cmux server status [--session <name>] [--socket <path>]\n",
        stop_help: "USAGE\n  cmux server stop [--session <name>] [--socket <path>] [--force]\n\nStopping an absent server succeeds. Durable session topology is preserved.\n",
        reload_config_help: "USAGE\n  cmux server reload-config [--session <name>] [--socket <path>]\n",
        running: "local server is running",
        started: "local server started",
        stopped: "local server stopped; durable session topology was preserved",
        not_running: "local server is not running; nothing needed to be stopped",
        owner_spawn_failed: "cannot start the detached session owner; check the session state and retry",
        owner_not_ready: "the detached session owner did not become ready; inspect the client log under the session state directory and retry",
        reloaded: "local server configuration reloaded",
        connect_failed: "cannot connect to the local server; check that the named session is running and retry",
        starting: "the local server is still starting; retry the lifecycle command",
        identity_failed: "cannot verify the local server identity; retry with the cmux build that started the session",
        communication_failed: "communication with the local server failed; verify that it is running and retry",
        invalid_response: "the local server returned an invalid lifecycle response; retry with the cmux build that started the session",
        reload_rejected: "the local server rejected the configuration reload; inspect its diagnostics and retry",
        reload_owner_stopped: "the local server stopped before it applied the configuration reload; start the session and retry",
        stop_rejected: "the local server rejected the stop request; retry with --force only when active clients can disconnect",
        wrong_owner: "the selected socket is not owned by a cmux local server",
        different_session: "the selected socket belongs to a different session",
        invalid_identity: "the local server returned an incomplete lifecycle identity",
        unsupported_protocol: "the selected session uses an incompatible cmux-tui protocol; restart it with this cmux build",
        force_unsupported: "this local server cannot accept a safely fenced forced stop; use the cmux build that started it",
        session_conflict: "the session name conflicts with --session",
        machine_not_supported: "--machine cannot target a local server; use the machine resource commands",
        invalid_session: "the session name is invalid; use one path component without separators or control characters",
        session_name_required: "session stop requires an exact session name or current",
        invalid_action_syntax: "unknown or incomplete server action; use --help",
        start_options_after_action: "server start options must appear after `server start`",
        start_rejects_output_mode: "server start does not support output modes",
        unknown_scope: "unknown resource scope \"{scope}\".",
        unknown_server_action: "unknown server action \"{action}\".",
        suggestion: "Did you mean `{candidate}`?",
        daemon_removed: "`cmux daemon` was renamed to `cmux server start`; run `cmux server start --help`",
        unexpected_after_stop: "local server sent unexpected data after accepting shutdown",
        stop_timeout: "timed out waiting for the local server to stop",
    },
    pairing: PairingMessages {
        title: "Approve browser?",
        confirm: "Confirm this code matches the browser:",
        peer_prefix: "from",
        deny: "[ Deny esc ]",
        approve: "[ Approve enter ]",
    },
    foreign_viewport: ForeignViewportMessages { terminal_grid: "terminal grid" },
    graphics: GraphicsMessages {
        output_failed: "Terminal graphics output failed; restoring the terminal",
        parser_recovery_failed: "Terminal graphics output could not reset the terminal parser; restoring the terminal",
        kitty_image_budget_worker_start_failed: "Failed to start Kitty image budget worker: {error}",
        kitty_image_budget_update_retrying: "Kitty image budget update failed, retrying: {summary}",
        kitty_image_budget_update_exhausted: "Kitty image budget update failed, stopped after exhausting retries: {summary}",
        cell_pixel_update_retries_exhausted: "Cell pixel update stopped after {attempts} retry attempts with {remaining} unconverged surface(s) at {width}x{height}; a later host acknowledgement can still recover",
        browser_surface_resize_failed: "Browser surface {surface} resize to {cols}x{rows} failed: {error}",
    },
    terminal: TerminalMessages {
        clear_history_help: "Clear PTY history while preserving its active prompt.",
        clear_history_failed: "Could not clear terminal history",
        clear_history_outcome_unknown: "Terminal history clear outcome is unknown. Reconnect the session before retrying.",
        clear_history_unsupported: "clear-history is not supported by this server; restart the cmux-tui server",
        clear_history_fallback_unrepresentable: "the current terminal keyboard mode cannot encode the fallback key",
        clear_history_preservation_impossible: "the active terminal input extends into retained history",
        clear_history_stream_timeout: "terminal output did not reach a safe clear-history boundary",
        clear_history_fallback_write_timeout: "terminal input did not accept the fallback key before timeout",
        clear_history_host_unsupported: "the terminal host does not support clear-history; reconnect the session",
        clear_history_host_exited: "the terminal host exited; reconnect the session",
        clear_history_host_failed: "the terminal host could not clear its history",
        clear_history_host_malformed_response: "the terminal host returned an invalid response; reconnect the session",
        clear_history_host_no_response: "the terminal host did not acknowledge clear-history; reconnect the session",
        clear_history_remote_no_response: "the remote session did not respond",
        clear_history_remote_disconnected: "the remote session disconnected; reconnect it",
        clear_history_remote_rejected: "the remote server rejected clear-history",
        clear_history_unexpected: "an unexpected terminal error occurred",
        keyboard_text_too_large: "Keyboard text exceeds the 4 MiB PTY buffer limit",
        paste_text_too_large: "Paste exceeds the 4 MiB PTY buffer limit",
        deferred_input_destination_changed: "Deferred input was discarded because its destination changed",
        pointer_input_discarded_during_layout_change: "Pointer input was discarded while the layout changed",
        deferred_input_queue_full: "Input queue byte limit reached while a session change is pending",
        pty_input_too_large: "Input exceeds the 4 MiB PTY buffer limit",
        pty_input_queue_full: "PTY input queue is full; input was not sent",
        pty_input_unavailable: "PTY input is unavailable after a transport failure",
        pty_input_exited: "Terminal exited; input was not sent",
        attach_outcome_unknown: "Surface attach outcome is unknown. Detach and reconnect before sending more input",
        operation_failed: "Terminal input failed",
    },
    session: SessionMessages {
        creation_reconciling: "Session creation may have completed; checking its receipt",
        operation_reconciling: "Session operation may have completed; refreshing the layout",
        operation_failed: "Session operation failed",
        operation_canceled: "Session operation was canceled",
        mux_subscription_recovered: "Mux event backlog overflowed; subscription recovered",
        mux_subscription_recovery_failed: "Mux event backlog recovery failed; queued input was discarded while retrying: {error}",
    },
    session_reset: SessionResetMessages {
        help: "  cmux session <name> reset-state [--force --confirm-reset <token>] [--state <path>]\n    Preview or confirm a scoped saved-state reset",
        exact_name_required: "session reset-state requires an exact session name",
        non_empty_name_required: "session reset-state requires a non-empty name",
        no_state_root: "cannot determine durable state directory; pass --state <path>",
        confirmation_required: "session reset-state --force requires a confirmation token from preview",
        confirmation_recovery: "rerun without --force, review the scoped targets, then retry with the printed --confirm-reset token",
        routing_options_unsupported: "session reset-state does not accept global routing options: {options}; use --state <path> to select the saved-state root",
        reset_failed: "could not complete saved-state reset for session \"{session}\"",
        reason_session_running: "the session is still running",
        recovery_session_running: "stop the running session before retrying the reset",
        reason_terminal_hosts_live: "terminal hosts are still live or cannot be verified",
        recovery_terminal_hosts_live: "reopen this session with a compatible cmux and stop it cleanly before retrying the reset",
        reason_terminal_hosts_unsupported: "terminal-host liveness cannot be verified on this platform",
        recovery_terminal_hosts_unsupported: "use a platform build that can verify terminal-host liveness, or start a separate session",
        reason_reset_unsupported: "safe saved-state reset is not supported on this platform",
        recovery_reset_unsupported: "use a supported platform build to reset this saved state, or start a separate session",
        reason_invalid_state_path: "the state path is not a directory",
        recovery_invalid_state_path: "rerun the preview with the intended --state path",
        reason_state_changed: "the scoped session state changed during reset",
        recovery_state_changed: "rerun the preview, then retry the reset if the targets are still correct",
        reason_state_too_large: "the scoped session state is too large to confirm safely",
        recovery_state_too_large: "reduce the scoped saved state or retry after a compatible cmux stops the session cleanly",
        reason_filesystem: "the filesystem refused the scoped reset",
        recovery_filesystem: "check permissions and available disk, then retry the reset",
        retry_after_preview: "rerun without --force to inspect the scoped reset plan",
    },
    machine_agent: MachineAgentMessages {
        help: "\
cmux machine-agent - share one local cmux session through a remote service

USAGE:
  cmux machine-agent [OPTIONS]

OPTIONS:
  --session <name>         Local cmux session (default: main)
  --socket <path>          Explicit local cmux control socket
  --state <path>           Private machine identity file
  --cloud-host <host>      SSH registration host (default: cmux.cloud)
  --cloud-user <user>      SSH user
  --cloud-port <port>      SSH port
  --cloud-identity <path>  SSH identity file
  -h, --help               Show this help

The agent opens one outbound connection. It never opens a public listener or
edits shell files. Authenticate with the configured host before retrying.
",
        usage: "cmux machine-agent       Share one local session through the configured host",
        pairing_code: "Pairing code",
        registered: "Sharing local cmux session",
        retrying: "Cloud connection lost; retrying in {milliseconds} ms",
        migration_failed: "Could not reconnect the machine; please try again",
        pairing_code_unavailable: "Pairing code could not be displayed securely. Run this command from an interactive terminal and retry",
        runtime_failed: "The machine agent could not start or continue; check its configuration",
        invalid_session: "The session name is invalid; use a short name without spaces or control characters",
        identity_unavailable: "The private machine identity is unavailable; check that --state points to a private writable file",
        registration_already_running: "A machine agent is already sharing this session; stop it before starting another",
        cloud_configuration_invalid: "The cloud connection settings are invalid; check the host, user, port, and identity file",
        argument_needs_value: "Option {argument} needs a value",
        invalid_cloud_port: "Invalid --cloud-port value: {value}",
        cloud_port_cannot_be_zero: "--cloud-port cannot be zero",
        unknown_argument: "Unknown machine-agent argument: {argument}",
    },
    menu: MenuMessages {
        copy_message: "Copy message",
        copy_workspace_id: "Copy workspace id",
        copy_tab_id: "Copy tab id",
        copy_pane_id: "Copy pane id",
        copy_url: "Copy URL",
        show_in_chrome: "Show in Chrome",
        connected_clients: "Connected clients",
        this_client: "this client",
        excluded: "excluded",
        no_grid: "no grid",
        use_client_size: "Use client size",
        use_only_client_size: "Use only this client size",
        include_client_size: "Include client size",
        restore_all_client_sizing: "Restore all client sizing",
        disconnect_client: "Disconnect client",
        copied: "Copied",
        copied_url: "Copied URL",
        rename: "Rename",
        maximize_pane: "Maximize pane",
        restore_pane_layout: "Restore pane layout",
        show_sidebar: "Show sidebar",
        hide_sidebar: "Hide sidebar",
        compact_sidebar: "Use compact sidebar",
        full_sidebar: "Use full sidebar",
        focus_sidebar: "Focus sidebar",
        sidebar_layout: "Sidebar",
        sidebar_profiles: "Layouts",
        show_sidebar_view: "Show {view}",
        hide_sidebar_view: "Hide {view}",
    },
    shortcuts: ShortcutMessages {
        title: "Keyboard shortcuts",
        close_button: "Esc close",
        footer: "↑/↓ or wheel scroll · Esc or ? close",
    },
    browser: BrowserMessages {
        failed_prefix: "browser failed: ",
        control_failed: "browser command failed: {error}",
        not_responding: "browser failed: browser is not responding",
        resize_recovery: "browser failed: browser resize recovery failed; reload to retry",
        new_page_verification_prefix: "browser failed: could not verify new page pixels: ",
        updated_page_verification_prefix: "browser failed: could not verify updated page pixels: ",
        verification_suffix: "; reload to retry",
        starting: "starting browser...",
        attach_unsupported: "browser panes are not supported over attach yet",
        graphics_unsupported: "terminal has no kitty graphics support",
        loading: "loading {url}...",
        busy: "browser is busy; command dropped",
        no_active_surface: "no active surface",
        not_browser: "active surface is not a browser",
        unknown_surface: "unknown browser surface",
    },
    layout: LayoutMessages {
        startup_shortcuts: "  g  new 2/3 column right   U    undo layout",
        verb_help_heading: "VERB HELP",
        new_pane_right_help: "Create a viewport pane to the right (default width: two-thirds).",
        set_viewport_pane_width_help: "Set the viewport width of the column containing a pane.",
        undo_layout_help: "Undo the latest structural layout change.",
        create_viewport_pane_operation: "create viewport pane",
        undo_layout_operation: "undo layout",
        resize_exact_split_operation: "resize exact pane split",
        split_id_subject: "split id",
        resize_viewport_pane_operation: "resize viewport pane",
        viewport_pane_subject: "viewport pane",
        remote_viewport_panes_unsupported: "remote cmux server does not support viewport panes; upgrade the server before using new-pane-right",
        ratio_must_be_number: "--ratio must be a number",
        ratio_must_be_finite: "--ratio must be a finite number",
        viewport_width_must_be_number: "--width must be a number",
        viewport_width_must_be_finite: "--width must be a finite number",
        viewport_width_out_of_range: "viewport pane width must be between 0.1 and 1.0",
        surface_size_release_failed: "surface {surface} size release failed; retrying on the next layout: {error}",
        pane_without_resizable_column: "pane {pane} has no resizable viewport column",
        remote_viewport_resize_unsupported: "remote cmux server does not support viewport pane resizing; upgrade the server",
        remote_layout_undo_unsupported: "remote cmux server does not support layout undo; upgrade the server",
        layout_undo_missing_screen: "layout undo response is missing screen",
        layout_undo_missing_revision: "layout undo response is missing revision",
        layout_undo_missing_closes_panes: "layout undo response is missing closes_panes",
        layout_undo_invalid_pane: "layout undo response contains an invalid pane",
        layout_undo_missing_outcome: "layout undo response does not contain exactly one valid outcome",
        layout_undo_confirmation_flags_together: "--revision and --confirm-close must be supplied together",
        layout_changed_before_undo: "layout changed before undo",
        unknown_split: "unknown split {split}",
        unknown_pane_split: "unknown pane/split {pane}",
        unrepresentable_viewport_width: "split {split} ratio {ratio} implies viewport width {width}; width must be between 0.1 and 1",
        unrepresentable_viewport_ratio: "split {split} ratio {ratio} cannot be represented as a viewport width between 0.1 and 1",
        viewport_ratio_target_missing: "the pane or split no longer exists",
        viewport_ratio_out_of_range: "the requested ratio cannot be represented by a viewport width between 0.1 and 1",
        viewport_column_missing: "the pane has no resizable viewport column",
        unsupported_server_command: "{command} is not supported by this server",
        layout_undo_applied: "undone screen={screen} revision={revision}",
        layout_undo_confirmation_required: "confirmation required: rerun with --revision {revision} --confirm-close (closes panes {panes})",
    },
    runtime: RuntimeMessages {
        unknown_panic: "unknown panic",
        terminal_capacity_exhausted: "No pseudo-terminals are available. Close an unused terminal session, then retry.",
        renderer_panicked: "terminal renderer panicked: {message}",
        host_input_failed: "host terminal input failed: {error}",
        signal_handlers_failed: "failed to install signal handlers: {error}",
        terminal_restore_also_failed: "{error}; host terminal restoration also failed: {restore_error}",
    },
    remote_client: RemoteClientMessages {
        connect_help: r#"USAGE: cmux remote connect [ROUTE] [OPTIONS]

ROUTES:
  unix:///ABSOLUTE/PATH | ssh://[USER@]HOST[:PORT] | ws:// | wss:// | iroh://
  relay+ws:// | relay+wss:// | relay+https:// | relay+do://

IDENTITY AND SESSION:
  --invite-file PATH|-  --daemon FINGERPRINT
  --device-name NAME  --session NAME
  --state-dir PATH  --local-socket PATH  --headless [--json]

  --invite-file avoids exposing the single-use invitation in process arguments.
  Regular files must be owner-only; - reads one line from stdin.

TRANSPORT:
  --lanes auto|single|isolated  --connect-timeout-seconds N
  For one explicit relay route, --relay-slot SLOT with either
    --relay-ticket-file PATH or --relay-ticket-command PROGRAM.
  For fallbacks, repeat up to four --relay-route ROUTE, --relay-slot SLOT,
    and credential-source groups in occurrence order.
  --relay-ticket-command-arg ARG  --iroh-relay URL  --iroh-address ADDR
  --iroh-path auto|direct-only|relay-only
  --ssh-binary PATH  --remote-binary PATH  --ssh-arg ARG  --no-install
  --remote-state-dir PATH for a non-default daemon state directory
  --upgrade explicitly replaces an SSH-managed remote sidecar after installing
    the pinned binary; terminal panes survive, while remote RPC state resets

RECONNECT:
  --reconnect-attempts N|unlimited  --reconnect-initial-ms MS
  --reconnect-max-ms MS  --reconnect-attempt-timeout-ms MS
  --reconnect-jitter full|none  --heartbeat-interval-ms MS
  --heartbeat-timeout-ms MS
"#,
        ssh_help: r#"USAGE: cmux remote ssh [USER@]HOST[:PORT] [OPTIONS]

Direct SSH uses one carrier by default. Pass --lanes auto or isolated to opt in
to multiple carriers. The remote binary is probed and, unless --no-install is
set, installed into the user account when missing or incompatible.

OPTIONS:
  --session NAME  --lanes single|auto|isolated  --headless [--json]
  --ssh-binary PATH  --remote-binary PATH  --ssh-arg ARG  --no-install
  --remote-state-dir PATH for a non-default daemon state directory
  --upgrade explicitly replaces an SSH-managed remote sidecar; terminal panes
    survive, remote clients and forwards disconnect, RPC processes stop, and
    other RPC resources reset
  --state-dir PATH  --local-socket PATH  --connect-timeout-seconds N
  --reconnect-attempts N|unlimited  --reconnect-initial-ms MS
  --reconnect-max-ms MS  --reconnect-attempt-timeout-ms MS
  --reconnect-jitter full|none  --heartbeat-interval-ms MS
  --heartbeat-timeout-ms MS
"#,
        forward_help: r#"USAGE: cmux remote forward [ROUTE] --workspace-root PATH --port PORT [OPTIONS]

OPTIONS:
  --host HOST  --listen ADDR  --scheme http|https
  All identity, transport, SSH, relay, Iroh, and reconnect options accepted by
  `cmux remote connect` are also accepted.
"#,
        rpc_help: r#"USAGE: cmux remote rpc [ROUTE] [OPTIONS]

Reads one WorkspaceRequest JSON object per stdin line and writes one response
per line. --request JSON sends one request and exits.

OPTIONS:
  --request WORKSPACE_REQUEST_JSON
  All identity, transport, SSH, relay, Iroh, and reconnect options accepted by
  `cmux remote connect` are also accepted.
"#,
        enroll_help: r#"USAGE: cmux remote enroll ACTION [OPTIONS]

ACTIONS:
  status | create | pending | approve ID | deny ID | devices | connections
  revoke DEVICE_ID | disconnect DEVICE_ID SESSION_ID | connect ROUTE

OPTIONS:
  --session NAME  --state-dir PATH  --admin-socket PATH  --json
  create: --ttl SECONDS  --advertise ROUTE
  create relay access: repeat --relay-route ROUTE --relay-slot SLOT with
    --relay-ticket-file PATH, in occurrence order,
    for up to two relay fallbacks
  connect accepts every option documented by `cmux remote connect`.
"#,
        known_daemons_help: "USAGE: cmux remote known-daemons [list] [--state-dir PATH] [--json]\n       cmux remote known-daemons forget FINGERPRINT [--state-dir PATH] [--json]\n",
        remote_probe_help: "USAGE: cmux-tui remote-probe [--json]\n",
        remote_link_help: "USAGE: cmux-tui remote-link --stdio [--session NAME] [--state-dir PATH]\n",
        install_self_help: "USAGE: cmux-tui install-self --destination PATH\n",
        command_help: "USAGE: cmux remote <connect|ssh|forward|rpc|enroll|known-daemons|stop> [OPTIONS]\n\nRun `cmux remote COMMAND --help` for command-specific routes and options. Legacy top-level aliases remain available for one compatibility cycle.\n",
        remote_lifecycle_help: "USAGE: cmux remote connect|ssh|forward|rpc [OPTIONS]\n       cmux remote enroll <ACTION> [OPTIONS]\n       cmux remote known-daemons [OPTIONS]\n       cmux remote stop [OPTIONS]\n\nAuthenticated remote operations are explicit under `remote`. Start the owning process with `cmux server start` and explicit remote flags. `cmux remote stop` manages only replaceable SSH sidecars. Stop a listener embedded by `cmux server start` with `cmux server stop`; this also stops its local owner and workspaces.\n",
        option_needs_value: "{option} needs a value",
        invalid_option_value: "{option} has an invalid value; expected {expected}",
        option_must_be_positive: "{option} must be positive",
        unknown_option: "unknown option {option}",
        unknown_option_for_command: "unknown option {option} for {command}",
        option_once: "{option} may only be specified once",
        unknown_action: "unknown {command} action {action}",
        enroll_arity: "enroll {action} expects exactly {expected} positional arguments",
        option_create_only: "{option} is only valid for enroll create",
        inline_invitation_rejected: "inline invitations are not accepted; use --invite-file or stdin",
        invitation_path_invalid: "invitation path must be an owner-only regular file or - for stdin",
        invitation_input_read_failed: "could not read invitation input",
        invitation_input_empty: "invitation input is empty",
        invitation_input_too_large: "invitation input exceeds {maximum} bytes",
        invitation_input_multiline: "invitation input must contain exactly one URI",
        invitation_input_invalid_utf8: "invitation input is not valid UTF-8",
        inline_relay_ticket_rejected: "inline relay tickets are not accepted; use --relay-ticket-file or --relay-ticket-command",
        inline_enroll_relay_ticket_rejected: "inline relay tickets are not accepted; use --relay-ticket-file",
        relay_command_arg_order: "--relay-ticket-command-arg must follow --relay-ticket-command",
        relay_credentials_require_explicit_route: "relay credentials without --relay-route require one explicit relay connection route",
        relay_shorthand_requires_relay_route: "relay credential shorthand requires an explicit relay route, got {route}",
        relay_credential_pair_required: "each relay credential needs one --relay-slot and one relay credential source",
        multiple_relay_credentials_require_routes: "multiple relay credentials require one --relay-route per credential group",
        route_scoped_relay_credential_pair_required: "each route-scoped relay credential needs one --relay-route, one --relay-slot, and one credential source",
        relay_credential_limit: "a client supports at most {maximum} relay credentials",
        relay_route_not_relay: "relay credential route {route} is not a relay route",
        relay_route_repeated: "relay credential route {route} is repeated",
        invitation_relay_route_repeated: "invitation repeats relay bootstrap route {route}",
        relay_route_limit: "a client supports at most {maximum} relay credential routes including invitation bootstrap routes",
        invitation_daemon_mismatch: "invitation daemon fingerprint does not match --daemon {fingerprint}",
        invitation_no_routes: "invitation contains no usable route hints",
        daemon_no_routes: "daemon {fingerprint} has no stored routes; pass a route or enroll again",
        known_daemon_key_unavailable: "known daemon key disappeared",
        carrier_daemon_requires_carrier: "daemon {fingerprint} is known only through a trusted SSH or Unix carrier; use that carrier route or enroll this device for network access",
        upgrade_requires_ssh: "--upgrade requires SSH to be the initial route",
        relay_route_not_candidate: "relay credential route {route} is not one of this connection's route candidates",
        daemon_key_changed: "daemon key changed for {name}",
        known_daemon_refresh_missing: "known daemon disappeared while refreshing its route",
        positional_invitation_rejected: "positional invitations are not accepted; use --invite-file or stdin",
        connect_one_route: "connect accepts one route",
        reconnect_policy_invalid: "reconnect delays, attempt timeout, and enabled heartbeat timeout must be positive; max delay must be at least initial",
        upgrade_no_install: "--upgrade cannot be combined with --no-install",
        json_requires_headless: "--json requires --headless for connect and ssh",
        help_invalid_options: "help cannot be combined with invalid connect options",
        ssh_destination_required: "ssh expects the destination before options",
        ssh_destination_invalid: "invalid SSH destination",
        forward_workspace_required: "forward needs --workspace-root on the daemon",
        forward_port_required: "forward needs --port",
        rpc_request_invalid: "--request is not a WorkspaceRequest JSON object",
        rpc_input_invalid: "invalid WorkspaceRequest",
        rpc_stdin_too_large: "RPC stdin line exceeds {maximum} bytes",
        rpc_stdin_invalid_utf8: "RPC stdin line is not valid UTF-8",
        known_forget_arity: "known-daemons forget expects exactly one fingerprint",
        known_state_dir_unavailable: "cannot determine remote state directory; use --state-dir",
        known_daemon_not_known: "daemon {fingerprint} is not known",
        known_daemon_forgotten: "Forgot daemon {fingerprint}.",
        known_daemons_empty: "No known daemons.",
        known_daemon_auth_enrolled: "enrolled",
        known_daemon_auth_carrier: "carrier",
    },
    remote: RemoteMessages {
        remote_stop_help: "USAGE: cmux remote stop [--session NAME] [--state-dir PATH] [--acknowledge-failed-finalization | --acknowledge-legacy-finalization]\n\nThis command manages only replaceable SSH sidecars. Stop a listener embedded by `cmux server start` with `cmux server stop`; this also stops its local owner and workspaces.\n\n--acknowledge-legacy-finalization is only for an already-stopped pre-fence daemon. Verify that no legacy cmux-tui process remains before using it.\n",
        remote_stop_unknown_option: "unknown option {option} for cmux remote stop",
        remote_stop_no_positional: "cmux remote stop accepts no positional arguments",
        remote_stop_acknowledgements_mutually_exclusive: "--acknowledge-failed-finalization and --acknowledge-legacy-finalization are mutually exclusive",
        invalid_runtime_metadata: "remote daemon runtime metadata is invalid; verify that no cmux-tui process remains, then rerun cmux remote stop with --acknowledge-legacy-finalization ({path})",
        inspect_runtime_metadata: "could not inspect remote daemon runtime metadata ({path})",
        inactive_legacy_needs_migration: "inactive legacy daemon state needs explicit migration; verify that no legacy cmux-tui process remains, then rerun cmux remote stop with --acknowledge-legacy-finalization",
        refuse_live_invalid_lifecycle: "refusing to stop a live daemon without valid lifecycle metadata",
        embedded_daemon_stop_refused: "cmux remote stop manages only replaceable SSH sidecars; this remote listener belongs to the local server, so use `cmux server stop --session <name>` to stop its owner and workspaces",
        daemon_shutdown_failed: "daemon shutdown failed",
        observe_daemon_exit: "could not observe remote daemon process exit",
        daemon_stop_timeout: "remote daemon did not stop within 20 seconds",
        verify_previous_finalization_path: "could not verify previous remote daemon authorization finalization ({path})",
        verify_previous_finalization: "could not verify previous remote daemon authorization finalization",
        previous_finalization_failed_ack: "previous remote daemon authorization finalization failed; inspect the authorization state, then rerun cmux remote stop with --acknowledge-failed-finalization",
        verify_finalization: "could not verify remote daemon authorization finalization",
        finalization_wrong_lifecycle: "could not verify remote daemon authorization finalization: shutdown outcome belongs to a different daemon lifecycle",
        finalization_failed: "remote daemon authorization finalization failed",
        verify_lifecycle_fence: "could not verify remote daemon lifecycle fence",
        confirm_lifecycle_fence_durability: "could not confirm remote daemon lifecycle fence durability",
        inspect_authorization_state: "could not inspect remote daemon authorization state",
        inspect_authorization_schema: "could not inspect remote daemon authorization schema",
        legacy_authorization_requires_migration: "previous remote daemon authorization state requires explicit migration; verify that no legacy cmux-tui process remains, then run cmux remote stop --acknowledge-legacy-finalization",
        prepare_lifecycle_state: "could not prepare remote daemon lifecycle state",
        verify_previous_lifecycle_metadata: "could not verify previous remote daemon lifecycle metadata",
        modern_predecessor_missing_outcome: "could not verify previous remote daemon authorization finalization: the modern predecessor did not publish an outcome",
        runtime_empty_lifecycle: "could not verify previous remote daemon authorization finalization: runtime metadata has an empty lifecycle id",
        state_predates_lifecycle_fence: "previous remote daemon state predates lifecycle fencing; stop the legacy daemon with cmux remote stop before reconnecting",
        state_missing_lifecycle_fence: "previous remote daemon state has no lifecycle fence; stop the legacy daemon with cmux remote stop before reconnecting",
        authorization_finalization_failed: "authorization finalization failed",
        lifecycle_fence_version_unsupported: "remote daemon lifecycle fence version {version} is unsupported",
        inspect_stopped_authorization_state: "could not inspect stopped daemon authorization state",
        acquire_stopped_authorization_lease: "could not acquire the stopped daemon authorization lease",
        finalize_stopped_authorization_migration: "could not finalize stopped daemon authorization migration",
        snapshot_runtime_for_recovery: "could not snapshot remote daemon runtime metadata for recovery",
        snapshot_finalization_for_recovery: "could not snapshot remote daemon authorization finalization for recovery",
        acquire_recovery_authorization_lease: "could not acquire the remote daemon authorization lease for recovery",
        resnapshot_runtime_for_recovery: "could not resnapshot remote daemon runtime metadata for recovery",
        resnapshot_finalization_for_recovery: "could not resnapshot remote daemon authorization finalization for recovery",
        lifecycle_evidence_changed_before_recovery: "remote daemon lifecycle evidence changed before authorization recovery",
        complete_authorization_recovery: "could not complete remote daemon authorization recovery",
        verify_runtime_for_recovery: "could not verify remote daemon runtime metadata for recovery",
        refuse_failed_ack_with_legacy_runtime: "refusing to acknowledge failed authorization finalization with legacy runtime metadata",
        no_failed_finalization_recorded: "no failed remote daemon authorization finalization is recorded",
        finalization_succeeded_no_ack: "remote daemon authorization finalization succeeded and does not need acknowledgement",
        inspect_legacy_authorization_state: "could not inspect legacy daemon authorization state",
        no_legacy_authorization_state: "no legacy remote daemon authorization state is recorded",
        snapshot_legacy_runtime: "could not snapshot legacy remote daemon runtime metadata",
        snapshot_legacy_shutdown: "could not snapshot legacy remote daemon shutdown metadata",
        acquire_legacy_recovery_authorization_lease: "could not acquire the remote daemon authorization lease for legacy recovery",
        resnapshot_legacy_runtime: "could not resnapshot legacy remote daemon runtime metadata",
        resnapshot_legacy_shutdown: "could not resnapshot legacy remote daemon shutdown metadata",
        lifecycle_evidence_changed_before_legacy_recovery: "remote daemon lifecycle evidence changed before legacy recovery",
        complete_legacy_authorization_recovery: "could not complete legacy remote daemon authorization recovery",
        failed_finalization_label: "failed authorization finalization",
        legacy_finalization_label: "legacy authorization finalization",
        refuse_active_socket: "refusing to acknowledge {finalization} while daemon socket {path} is active",
        verify_socket_inactive: "could not verify daemon socket {path} is inactive",
        lifecycle_runtime_requires_failed_ack: "remote daemon runtime metadata is lifecycle-aware; use --acknowledge-failed-finalization when its shutdown failed",
        shutdown_evidence_requires_failed_ack: "remote daemon shutdown evidence requires --acknowledge-failed-finalization",
        lifecycle_evidence_changed_during_legacy_recovery: "remote daemon lifecycle evidence changed during legacy recovery",
        lifecycle_evidence_changed_during_recovery: "remote daemon lifecycle evidence changed during recovery",
    },
    config: ConfigMessages {
        invalid_macos_option_as_alt: "cmux-tui: ignoring non-boolean keys.macos_option_as_alt = {value}",
        invalid_section: "cmux-tui: ignoring invalid config section {section}",
        unknown_field: "cmux-tui: ignoring unknown config field {field}",
        invalid_root: "cmux-tui: ignoring config because the root value is not an object",
    },
    attach: AttachMessages {
        filtered_subscription_unavailable: "single-terminal attach requires a newer cmux-tui server; restart the session",
        remote_attach_queue_full: "remote surface attach queue is full",
        remote_attach_workers_failed_template: "could not start surface attach workers: {error}",
        surface_sync_failed_template: "surface {surface} {operation} failed; retries are rate-limited: {error}",
        surface_sync_unknown_template: "surface {surface} {operation} outcome is unknown; detach and reconnect before sending more input: {error}",
        surface_sync_attach: "attach",
        surface_sync_resize: "resize",
        surface_sync_operation: "operation",
        unknown_terminal_prefix: "unknown terminal ",
        unknown_terminal_suffix: "; use `cmux terminal list` to list terminal IDs",
        ambiguous_terminal_prefix: "ambiguous terminal reference ",
        ambiguous_terminal_suffix: "; use an unambiguous ID from `cmux terminal list`",
        browser_terminal_prefix: "surface ",
        browser_terminal_suffix: " is a browser, not a terminal",
    },
    sidebar: SidebarMessages {
        machines: "machines",
        workspaces: "workspaces",
        panes: "panes",
        tabs: "tabs",
        agents: "agents",
        projection_path_separator: " › ",
        new_machine: "new vm",
        connect_machine: "ssh host",
        no_machines: "no machines",
        no_workspaces: "no workspaces",
        no_panes: "no panes",
        no_tabs: "no tabs",
        no_agents: "no agents",
        recoverable_machine: "recoverable",
        rename_machine: "Rename machine",
        delete_machine: "Delete machine",
        restore_machine: "Restore machine",
        purge_machine: "Delete permanently",
        confirm_delete_machine: "Type CONFIRM to delete this machine after a final snapshot",
        confirm_purge_machine: "Type CONFIRM to permanently delete this machine and its snapshots",
        new_workspace: "new workspace",
        new_isolated_workspace: "new isolated",
        new_shared_workspace: "new shared",
        recoverable_workspace: "recoverable",
        rename_workspace: "Rename workspace",
        delete_workspace: "Delete workspace",
        restore_workspace: "Restore workspace",
        purge_workspace: "Delete permanently",
        confirm_purge_workspace: "Type CONFIRM to permanently delete this workspace",
        no_active_session: "select or create a machine first",
        managed_workspace_unsupported: "this machine provider cannot create managed workspaces",
        managed_workspace_machine_inactive: "No machine is active; select or reconnect this workspace's machine, then retry",
        managed_workspace_unavailable: "Managed workspace details are unavailable; wait for the provider to refresh, then retry",
        managed_workspace_operation_not_allowed: "The provider does not allow this operation for this workspace; use an action shown in its menu",
        running: "running",
        connecting: "connecting",
        waking: "waking",
        sleeping_wake_hint: "sleeping — press any key to wake",
        sleeping: "sleeping",
        stopped: "stopped",
        unavailable: "unavailable",
        working: "working",
        blocked: "blocked",
        idle: "idle",
        done: "done",
        unknown: "unknown",
        connect_prompt: "Host address or pairing code",
        connect_host_prompt: "SSH host or user@host",
        connecting_to: "Connecting to {target}…",
        starting_on: "Starting a session on {target}…",
        failed_to_connect: "Could not connect to {target}",
        retry_connection: "Retry",
        close_dialog: "Close",
        ssh_hosts: "SSH hosts",
        type_to_filter: "type to filter",
        other_host: "Add SSH host…",
        personal_scope: "personal",
        plugin_exited: "sidebar plugin exited",
        team_scope: "team",
        scope: "scope",
        provider_actions: "actions",
        action_required: "This value is required",
        action_too_long: "This value is too long",
        action_invalid_email: "Enter a valid email address",
        action_invalid_integer: "Enter a whole number",
        action_below_minimum: "This number is below the allowed minimum",
        action_above_maximum: "This number is above the allowed maximum",
        action_missing_selected_machine: "Select a machine before running this action",
        action_missing_selected_workspace: "Select a workspace before running this action",
        action_multiple_fields_unsupported: "This action needs a form that this client cannot show",
        action_list_workspace_ports: "List workspace ports",
        action_make_workspace_port_public: "Make workspace port public",
        action_make_workspace_port_private: "Make workspace port private",
        action_open_private_workspace_port: "Open private workspace port",
        action_workspace_port: "Port",
        confirm_destructive_action: "Type CONFIRM to continue",
        confirm_layout_undo: "Type CONFIRM to close pane(s) {items}",
        confirmation_mismatch: "Type CONFIRM exactly to run this action",
        layout_nothing_to_undo: "Nothing to undo",
        layout_undo_stale: "The layout changed; undo was not applied",
        initial_machine_connection_failed: "Could not connect",
        provider_notice_identity_unavailable: "Could not prepare the connection. Try again; if the problem persists, restart cmux.",
        provider_connection_already_running: "Another connection is already running. Close it and try again.",
        machine_provider_disconnected: "Machine provider disconnected; reconnecting",
        machine_action_failed: "Machine action failed",
        layout_refresh_failed: "Session changed, but its layout refresh failed: {error}",
        layout_stale: "Session changed, but its layout is still stale: {error}",
        file_no_focused_pane: "No focused pane",
        file_surface_unavailable: "Focused surface is unavailable",
        file_input_not_queued: "Input was not queued",
        file_command_failed: "File command failed: {error}",
        file_sent_to_focused_pane: "Sent to focused pane",
        refresh_remote_tree_retrying: "Refresh remote tree failed; retrying: {error}",
        refresh_remote_tree_stopped: "Refresh remote tree failed after {attempts} attempts; automatic retries stopped, reconnect to retry: {error}",
        clients_list_failed: "Could not list clients: {error}",
        layout_undo_failed: "Could not undo layout: {error}",
        pairing_response_failed: "Could not respond to pairing request: {error}",
        workspace_state_failed: "Could not update workspace state: {error}",
        provider_action_open_url: "Open",
        machine_provider_update_failed: "Machine provider update failed",
        machine_provider_lifecycle_update_failed: "Machine provider lifecycle update failed",
        machine_provider_workspace_update_failed: "Machine provider workspace update failed",
        machine_reconnect_failed: "Could not reconnect machine",
        machine_terminal_colors_failed: "Could not apply terminal colors",
        machine_provider_external_connect_unsupported: "This machine provider cannot connect external machines",
        machine_provider_external_connect_ambiguous: "The previous connection attempt may have succeeded; reconnect the provider and retry with the same pairing code",
        machine_not_ready_to_connect: "Selected machine is not ready to connect",
        machine_managed_authority_unsupported: "This provider cannot authorize managed workspace mirrors; upgrade the machine provider",
        machine_managed_authority_invalid: "The machine provider returned an invalid managed workspace authority binding",
        machine_catalog_create_unsupported: "This machine catalog cannot create machines",
        machine_creation_source_unavailable: "This machine creation source is unavailable",
        machine_name_required: "Enter a machine name",
        client_machine_unavailable: "This client-owned machine is unavailable",
        prototype_machine_added: "Added prototype machine",
        machine_catalog_provider_actions_unsupported: "This machine catalog has no provider actions",
        machine_catalog_updates_failed: "Machine catalog updates could not start",
        machine_catalog_restart_failed: "Machine switched without live catalog updates",
        machine_replacement_pending: "Another machine replacement is already pending",
        machine_replacement_worker_stopped: "Machine replacement worker stopped before commit",
        machine_replacement_stale: "Machine replacement decision is stale",
        machine_replacement_not_pending: "Machine replacement is no longer pending",
        machine_replacement_target_missing: "Machine replacement target is missing",
        managed_ssh_requires_unix: "Managed SSH machine connections require Unix",
    },
};

static JAPANESE: Catalog = Catalog {
    japanese: true,
    startup: StartupMessages {
        schema_too_new: "cmux {version} ではセッション \"{session}\" を開けません。保存状態はこのビルドと互換性がありません",
        invalid_session_name: "セッション名には、区切り文字や制御文字を含まない 1 つのパス要素を指定してください",
        duplicate_attach: "attach は 1 回だけ指定できます",
        session_socket: "セッションソケット",
        stop_newer_server: "新しい cmux サーバーがこの保存済みセッションを所有しています。再試行する前に停止:",
        no_server_listening: "このソケットを待ち受けているサーバーはありません",
        reset_saved_state: "このセッションの互換性のない保存状態のリセット計画を確認:",
        reset_saved_state_unsupported: "このプラットフォームではスコープ付き保存状態リセットに対応していないため、リセットコマンドは表示しません",
        forced_handoff_unsupported: "このサーバーは安全な強制停止コマンドに対応していません。セッションを停止するには、起動に使用した新しい cmux ビルドを使用してください",
        different_server: "このソケットは別の cmux セッションに属しています。シャットダウンコマンドは表示しません",
        server_not_verified: "このソケットを所有するセッションを確認できませんでした。シャットダウンコマンドは表示しません",
        saved_state_requires_newer: "保存状態には新しい cmux が必要です。このセッションを再度開くには cmux をアップグレードしてください",
        start_separate_session: "または、このビルドを別のセッションで開始:",
    },
    local_server: LocalServerMessages {
        startup_lifecycle_usage: "  cmux server <操作>       一つのローカルセッションを起動、確認、停止、再読み込み\n  cmux remote connect <ルート>  認証済みリモートルート経由で接続\n  cmux remote ssh <ホスト>       直接 SSH で導入して接続\n  cmux remote forward <ルート>  ワークスペースの TCP サービスをローカル転送\n  cmux remote rpc <ルート>       ワークスペースのコーディングエージェント RPC を実行\n  cmux remote enroll <操作>      デバイスを登録、承認、一覧、失効\n  cmux remote known-daemons      クライアントに固定したデーモン ID とルートを一覧表示\n  cmux remote stop               置換可能な SSH サイドカーを明示的に停止",
        root_remote_usage: "  cmux remote <connect|ssh|forward|rpc|enroll|known-daemons|stop> [オプション]",
        root_server_usage: "  cmux server <start|ensure|status|stop|reload-config> [オプション]",
        root_server_scope: "  server        一つの名前付きローカル永続セッション所有者を管理",
        session_stop_help: "  cmux session <名前>|current stop",
        help: "使用方法\n  cmux server start [起動オプション]\n  cmux server ensure [--session <名前>] [--socket <パス>]\n  cmux server status [--session <名前>] [--socket <パス>]\n  cmux server stop [--session <名前>] [--socket <パス>] [--force]\n  cmux server reload-config [--session <名前>] [--socket <パス>]\n\n`server` は常に一つの名前付きセッションのローカル永続 mux 所有者を対象にします。\n認証済みリモートデーモンの操作は `cmux remote --help` を参照してください。\n",
        start_help: "使用方法\n  cmux server start [起動オプション]\n\n一つの名前付きセッションのローカル永続 mux 所有者をフォアグラウンドで起動します。\n",
        ensure_help: "使用方法\n  cmux server ensure [--session <名前>] [--socket <パス>]\n\nローカルセッション所有者が実行されていない場合はデタッチ状態で起動し、\nクライアントを受け付けるまで待って結果を報告します。実行中の場合も成功します。\n",
        status_help: "使用方法\n  cmux server status [--session <名前>] [--socket <パス>]\n",
        stop_help: "使用方法\n  cmux server stop [--session <名前>] [--socket <パス>] [--force]\n\nサーバーが存在しない場合も成功します。永続セッションの構成は保持されます。\n",
        reload_config_help: "使用方法\n  cmux server reload-config [--session <名前>] [--socket <パス>]\n",
        running: "ローカルサーバーは実行中です",
        started: "ローカルサーバーを起動しました",
        stopped: "ローカルサーバーを停止しました。永続セッションの構成は保持されています",
        not_running: "ローカルサーバーは実行されていません。停止は不要でした",
        owner_spawn_failed: "デタッチされたセッション所有者を起動できません。セッション状態を確認して再試行してください",
        owner_not_ready: "デタッチされたセッション所有者が準備完了になりませんでした。セッション状態ディレクトリのクライアントログを確認して再試行してください",
        reloaded: "ローカルサーバーの設定を再読み込みしました",
        connect_failed: "ローカルサーバーに接続できません。名前付きセッションが実行中であることを確認して再試行してください",
        starting: "ローカルサーバーは起動中です。ライフサイクルコマンドを再試行してください",
        identity_failed: "ローカルサーバーの識別情報を確認できません。セッションを起動した cmux ビルドで再試行してください",
        communication_failed: "ローカルサーバーとの通信に失敗しました。実行中であることを確認して再試行してください",
        invalid_response: "ローカルサーバーが無効なライフサイクル応答を返しました。セッションを起動した cmux ビルドで再試行してください",
        reload_rejected: "ローカルサーバーが設定の再読み込みを拒否しました。診断情報を確認して再試行してください",
        reload_owner_stopped: "ローカルサーバーが設定の再読み込みを適用する前に停止しました。セッションを起動して再試行してください",
        stop_rejected: "ローカルサーバーが停止要求を拒否しました。アクティブなクライアントを切断できる場合のみ --force で再試行してください",
        wrong_owner: "選択したソケットは cmux ローカルサーバーに所有されていません",
        different_session: "選択したソケットは別のセッションに属しています",
        invalid_identity: "ローカルサーバーが完全なライフサイクル識別情報を返しませんでした",
        unsupported_protocol: "選択したセッションは互換性のない cmux-tui プロトコルを使用しています。この cmux ビルドで再起動してください",
        force_unsupported: "このローカルサーバーは安全にフェンスされた強制停止に対応していません。起動に使用した cmux ビルドで停止してください",
        session_conflict: "セッション名が --session と競合しています",
        machine_not_supported: "--machine でローカルサーバーを対象にすることはできません。machine リソースコマンドを使用してください",
        invalid_session: "セッション名が無効です。区切り文字や制御文字を含まない 1 つのパス要素を指定してください",
        session_name_required: "session stop には正確なセッション名または current が必要です",
        invalid_action_syntax: "サーバー操作が不明または不完全です。--help を使用してください",
        start_options_after_action: "server start のオプションは `server start` の後に指定してください",
        start_rejects_output_mode: "server start では出力モードを使用できません",
        unknown_scope: "不明なリソーススコープ \"{scope}\"。",
        unknown_server_action: "不明なサーバー操作 \"{action}\"。",
        suggestion: "`{candidate}` のことですか？",
        daemon_removed: "`cmux daemon` は `cmux server start` に名前が変更されました。`cmux server start --help` を実行してください",
        unexpected_after_stop: "停止を受理した後にローカルサーバーが予期しないデータを送信しました",
        stop_timeout: "ローカルサーバーの停止待機がタイムアウトしました",
    },
    pairing: PairingMessages {
        title: "ブラウザを承認しますか？",
        confirm: "ブラウザのコードと一致するか確認:",
        peer_prefix: "接続元:",
        deny: "[ 拒否 esc ]",
        approve: "[ 承認 enter ]",
    },
    foreign_viewport: ForeignViewportMessages { terminal_grid: "端末グリッド" },
    graphics: GraphicsMessages {
        output_failed: "ターミナル画像の出力に失敗したため、ターミナルを復元します",
        parser_recovery_failed: "ターミナル画像の出力後にパーサーをリセットできなかったため、ターミナルを復元します",
        kitty_image_budget_worker_start_failed: "Kitty 画像予算ワーカーを開始できませんでした: {error}",
        kitty_image_budget_update_retrying: "Kitty 画像予算の更新に失敗しました。再試行しています: {summary}",
        kitty_image_budget_update_exhausted: "Kitty 画像予算の更新に失敗し、再試行回数の上限に達したため停止しました: {summary}",
        cell_pixel_update_retries_exhausted: "セルピクセル更新は {attempts} 回の再試行後に停止しました。{width}x{height} で未収束のサーフェスが {remaining} 個あります。後続のホスト確認応答で復旧できます",
        browser_surface_resize_failed: "ブラウザサーフェス {surface} の {cols}x{rows} へのサイズ変更に失敗しました: {error}",
    },
    terminal: TerminalMessages {
        clear_history_help: "アクティブなプロンプトを保持したまま PTY 履歴を消去します。",
        clear_history_failed: "ターミナル履歴を消去できませんでした",
        clear_history_outcome_unknown: "ターミナル履歴の消去結果を確認できません。再試行する前にセッションを再接続してください。",
        clear_history_unsupported: "このサーバーでは clear-history を使用できません。cmux-tui サーバーを再起動してください",
        clear_history_fallback_unrepresentable: "現在のターミナルキーボードモードでは代替キーを送信できません",
        clear_history_preservation_impossible: "アクティブなターミナル入力が保持中の履歴にまたがっています",
        clear_history_stream_timeout: "ターミナル出力が履歴を安全に消去できる境界に達しませんでした",
        clear_history_fallback_write_timeout: "タイムアウトまでにターミナル入力が代替キーを受け付けませんでした",
        clear_history_host_unsupported: "ターミナルホストが clear-history に対応していません。セッションを再接続してください",
        clear_history_host_exited: "ターミナルホストが終了しました。セッションを再接続してください",
        clear_history_host_failed: "ターミナルホストで履歴の消去に失敗しました",
        clear_history_host_malformed_response: "ターミナルホストから無効な応答が返されました。セッションを再接続してください",
        clear_history_host_no_response: "ターミナルホストから clear-history の応答がありませんでした。セッションを再接続してください",
        clear_history_remote_no_response: "リモートセッションから応答がありませんでした",
        clear_history_remote_disconnected: "リモートセッションとの接続が切れました。再接続してください",
        clear_history_remote_rejected: "リモートサーバーが clear-history を拒否しました",
        clear_history_unexpected: "予期しないターミナルエラーが発生しました",
        keyboard_text_too_large: "キーボード入力が 4 MiB の PTY バッファ上限を超えています",
        paste_text_too_large: "貼り付けテキストが 4 MiB の PTY バッファ上限を超えています",
        deferred_input_destination_changed: "遅延入力は送信先が変更されたため破棄されました",
        pointer_input_discarded_during_layout_change: "レイアウトの変更中にポインター入力が破棄されました",
        deferred_input_queue_full: "セッション変更の保留中に入力キューのバイト上限に達しました",
        pty_input_too_large: "入力が 4 MiB の PTY バッファ上限を超えています",
        pty_input_queue_full: "PTY 入力キューがいっぱいのため、入力は送信されませんでした",
        pty_input_unavailable: "転送エラー後のため PTY 入力を使用できません",
        pty_input_exited: "ターミナルが終了したため、入力は送信されませんでした",
        attach_outcome_unknown: "サーフェスの接続結果を確認できません。入力を再開する前に切断して再接続してください",
        operation_failed: "ターミナル入力に失敗しました",
    },
    session: SessionMessages {
        creation_reconciling: "セッションの作成が完了している可能性があります。結果を確認しています",
        operation_reconciling: "セッション操作が完了している可能性があります。レイアウトを更新しています",
        operation_failed: "セッション操作に失敗しました",
        operation_canceled: "セッション操作はキャンセルされました",
        mux_subscription_recovered: "Mux イベントの滞留が上限を超えました。購読を復旧しました",
        mux_subscription_recovery_failed: "Mux イベントの滞留から復旧できませんでした。再試行中のキュー入力を破棄しました: {error}",
    },
    session_reset: SessionResetMessages {
        help: "  cmux session <name> reset-state [--force --confirm-reset <token>] [--state <path>]\n    スコープ付き保存状態のリセットをプレビューまたは確認実行",
        exact_name_required: "session reset-state には正確なセッション名が必要です",
        non_empty_name_required: "session reset-state には空でない名前が必要です",
        no_state_root: "永続状態ディレクトリを特定できません。--state <path> を指定してください",
        confirmation_required: "session reset-state --force にはプレビューで表示された確認トークンが必要です",
        confirmation_recovery: "--force なしで再実行し、スコープ付き対象を確認してから、表示された --confirm-reset トークンを付けて再試行してください",
        routing_options_unsupported: "session reset-state ではグローバルルーティングオプション {options} を使用できません。保存状態のルートを選択するには --state <path> を使用してください",
        reset_failed: "セッション \"{session}\" の保存状態リセットを完了できませんでした",
        reason_session_running: "セッションがまだ実行中です",
        recovery_session_running: "実行中のセッションを停止してからリセットを再試行してください",
        reason_terminal_hosts_live: "ターミナルホストがまだ動作中、または確認できません",
        recovery_terminal_hosts_live: "互換性のある cmux でこのセッションを再度開き、正常に停止してからリセットを再試行してください",
        reason_terminal_hosts_unsupported: "このプラットフォームではターミナルホストの生存確認ができません",
        recovery_terminal_hosts_unsupported: "ターミナルホストの生存確認に対応したプラットフォームのビルドを使うか、別のセッションを開始してください",
        reason_reset_unsupported: "このプラットフォームでは安全な保存状態リセットに対応していません",
        recovery_reset_unsupported: "対応プラットフォームのビルドで保存状態をリセットするか、別のセッションを開始してください",
        reason_invalid_state_path: "状態パスがディレクトリではありません",
        recovery_invalid_state_path: "意図した --state パスでプレビューを再実行してください",
        reason_state_changed: "スコープ付きセッション状態がリセット中に変更されました",
        recovery_state_changed: "プレビューを再実行し、対象が正しければリセットを再試行してください",
        reason_state_too_large: "スコープ付きセッション状態が大きすぎるため安全に確認できません",
        recovery_state_too_large: "スコープ付き保存状態を減らすか、互換性のある cmux でセッションを正常に停止してから再試行してください",
        reason_filesystem: "ファイルシステムがスコープ付きリセットを拒否しました",
        recovery_filesystem: "権限と空きディスク容量を確認してからリセットを再試行してください",
        retry_after_preview: "--force なしで再実行してスコープ付きリセット計画を確認してください",
    },
    machine_agent: MachineAgentMessages {
        help: "\
cmux machine-agent - ローカルの cmux セッションをリモートサービス経由で共有

使用方法:
  cmux machine-agent [オプション]

オプション:
  --session <name>         ローカル cmux セッション（既定: main）
  --socket <path>          ローカル cmux 制御ソケットを指定
  --state <path>           非公開のマシン ID ファイル
  --cloud-host <host>      SSH 登録ホスト（既定: cmux.cloud）
  --cloud-user <user>      SSH ユーザー
  --cloud-port <port>      SSH ポート
  --cloud-identity <path>  SSH ID ファイル
  -h, --help               このヘルプを表示

エージェントは外向きの接続を 1 つ開きます。公開リスナーを開いたり、シェルファイル
を編集したりしません。再試行する前に、設定したホストで認証してください。
",
        usage: "cmux machine-agent       設定したホスト経由でローカルセッションを共有",
        pairing_code: "ペアリングコード",
        registered: "ローカル cmux セッションを共有中",
        retrying: "クラウド接続が切断されました。{milliseconds} ミリ秒後に再接続します",
        migration_failed: "マシンを再接続できませんでした。もう一度お試しください",
        pairing_code_unavailable: "ペアリングコードを安全に表示できませんでした。対話型端末でこのコマンドを実行して再試行してください",
        runtime_failed: "machine-agent を開始または続行できませんでした。設定を確認してください",
        invalid_session: "セッション名が無効です。空白や制御文字を含まない短い名前を使用してください",
        identity_unavailable: "非公開のマシン ID を使用できません。--state が非公開で書き込み可能なファイルを指していることを確認してください",
        registration_already_running: "このセッションは別の machine-agent が共有中です。停止してからもう一度開始してください",
        cloud_configuration_invalid: "クラウド接続設定が無効です。ホスト、ユーザー、ポート、ID ファイルを確認してください",
        argument_needs_value: "オプション {argument} には値が必要です",
        invalid_cloud_port: "--cloud-port の値が無効です: {value}",
        cloud_port_cannot_be_zero: "--cloud-port に 0 は指定できません",
        unknown_argument: "不明な machine-agent 引数です: {argument}",
    },
    menu: MenuMessages {
        copy_message: "メッセージをコピー",
        copy_workspace_id: "ワークスペース ID をコピー",
        copy_tab_id: "タブ ID をコピー",
        copy_pane_id: "ペイン ID をコピー",
        copy_url: "URL をコピー",
        show_in_chrome: "Chrome で表示",
        connected_clients: "接続中のクライアント",
        this_client: "このクライアント",
        excluded: "除外",
        no_grid: "グリッドなし",
        use_client_size: "クライアントサイズを使用",
        use_only_client_size: "このクライアントサイズのみを使用",
        include_client_size: "クライアントサイズを含める",
        restore_all_client_sizing: "すべてのクライアントサイズ設定を復元",
        disconnect_client: "クライアントを切断",
        copied: "コピーしました",
        copied_url: "URL をコピーしました",
        rename: "名前を変更",
        maximize_pane: "ペインを最大化",
        restore_pane_layout: "ペイン配置を復元",
        show_sidebar: "サイドバーを表示",
        hide_sidebar: "サイドバーを隠す",
        compact_sidebar: "サイドバーをコンパクト表示",
        full_sidebar: "サイドバーを通常表示",
        focus_sidebar: "サイドバーにフォーカス",
        sidebar_layout: "サイドバー",
        sidebar_profiles: "レイアウト",
        show_sidebar_view: "{view}を表示",
        hide_sidebar_view: "{view}を非表示",
    },
    shortcuts: ShortcutMessages {
        title: "キーボードショートカット",
        close_button: "Esc 閉じる",
        footer: "↑/↓ またはホイールでスクロール · Esc または ? で閉じる",
    },
    browser: BrowserMessages {
        failed_prefix: "ブラウザでエラーが発生しました: ",
        control_failed: "ブラウザ操作に失敗しました: {error}",
        not_responding: "ブラウザが応答していません",
        resize_recovery: "ブラウザのサイズ変更を復旧できませんでした。再読み込みして再試行してください",
        new_page_verification_prefix: "新しいページの表示を確認できませんでした: ",
        updated_page_verification_prefix: "更新後のページ表示を確認できませんでした: ",
        verification_suffix: "。再読み込みして再試行してください",
        starting: "ブラウザを起動しています…",
        attach_unsupported: "アタッチ経由ではブラウザペインにまだ対応していません",
        graphics_unsupported: "ターミナルが Kitty グラフィックスに対応していません",
        loading: "{url} を読み込んでいます…",
        busy: "ブラウザが処理中のため、コマンドを破棄しました",
        no_active_surface: "アクティブなサーフェスがありません",
        not_browser: "アクティブなサーフェスはブラウザではありません",
        unknown_surface: "不明なブラウザサーフェスです",
    },
    layout: LayoutMessages {
        startup_shortcuts: "  g  右に 2/3 幅の列を追加   U    レイアウトを元に戻す",
        verb_help_heading: "コマンドヘルプ",
        new_pane_right_help: "右側にビューポートペインを作成（既定の幅: 3 分の 2）。",
        set_viewport_pane_width_help: "ペインを含むビューポート列の幅を設定。",
        undo_layout_help: "直前のレイアウト変更を元に戻す。",
        create_viewport_pane_operation: "ビューポートペインを作成",
        undo_layout_operation: "レイアウトを元に戻す",
        resize_exact_split_operation: "ペイン分割のサイズを変更",
        split_id_subject: "分割 ID",
        resize_viewport_pane_operation: "ビューポートペインのサイズを変更",
        viewport_pane_subject: "ビューポートペイン",
        remote_viewport_panes_unsupported: "リモート cmux サーバーはビューポートペインに対応していません。new-pane-right を使用する前にサーバーをアップグレードしてください",
        ratio_must_be_number: "--ratio には数値を指定してください",
        ratio_must_be_finite: "--ratio には有限の数値を指定してください",
        viewport_width_must_be_number: "--width には数値を指定してください",
        viewport_width_must_be_finite: "--width には有限の数値を指定してください",
        viewport_width_out_of_range: "ビューポートペインの幅は 0.1 から 1.0 の範囲で指定してください",
        surface_size_release_failed: "サーフェス {surface} のサイズ設定の解放に失敗しました。次回のレイアウト更新時に再試行します: {error}",
        pane_without_resizable_column: "ペイン {pane} にはサイズ変更可能なビューポート列がありません",
        remote_viewport_resize_unsupported: "リモート cmux サーバーはビューポートペインのサイズ変更に対応していません。サーバーをアップグレードしてください",
        remote_layout_undo_unsupported: "リモート cmux サーバーはレイアウトの取り消しに対応していません。サーバーをアップグレードしてください",
        layout_undo_missing_screen: "レイアウト取り消し応答にスクリーンがありません",
        layout_undo_missing_revision: "レイアウト取り消し応答にリビジョンがありません",
        layout_undo_missing_closes_panes: "レイアウト取り消し応答に closes_panes がありません",
        layout_undo_invalid_pane: "レイアウト取り消し応答に無効なペインがあります",
        layout_undo_missing_outcome: "レイアウト取り消し応答に有効な結果が1つだけ含まれていません",
        layout_undo_confirmation_flags_together: "--revision と --confirm-close は同時に指定してください",
        layout_changed_before_undo: "取り消し前にレイアウトが変更されました",
        unknown_split: "分割 {split} が見つかりません",
        unknown_pane_split: "ペインまたは分割 {pane} が見つかりません",
        unrepresentable_viewport_width: "分割 {split} の比率 {ratio} ではビューポート幅が {width} になります。幅は 0.1 から 1 の範囲で指定してください",
        unrepresentable_viewport_ratio: "分割 {split} の比率 {ratio} は 0.1 から 1 の範囲のビューポート幅では表現できません",
        viewport_ratio_target_missing: "対象のペインまたは分割が存在しません",
        viewport_ratio_out_of_range: "指定した比率は 0.1 から 1 の範囲のビューポート幅では表現できません",
        viewport_column_missing: "対象のペインにはサイズ変更可能なビューポート列がありません",
        unsupported_server_command: "{command} はこのサーバーではサポートされていません",
        layout_undo_applied: "元に戻しました screen={screen} revision={revision}",
        layout_undo_confirmation_required: "確認が必要です: --revision {revision} --confirm-close を付けて再実行してください（閉じるペイン: {panes}）",
    },
    runtime: RuntimeMessages {
        unknown_panic: "不明なパニック",
        terminal_capacity_exhausted: "疑似ターミナルの空きがありません。不要なターミナルセッションを閉じてから再試行してください。",
        renderer_panicked: "ターミナル描画処理でパニックが発生しました: {message}",
        host_input_failed: "ホストターミナルの入力に失敗しました: {error}",
        signal_handlers_failed: "シグナルハンドラーの設定に失敗しました: {error}",
        terminal_restore_also_failed: "{error}; ホストターミナルの復元にも失敗しました: {restore_error}",
    },
    remote_client: RemoteClientMessages {
        connect_help: r#"使用方法: cmux remote connect [ルート] [オプション]

ルート:
  unix:///絶対パス | ssh://[ユーザー@]ホスト[:ポート] | ws:// | wss:// | iroh://
  relay+ws:// | relay+wss:// | relay+https:// | relay+do://

ID とセッション:
  --invite-file パス|-  --daemon フィンガープリント
  --device-name 名前  --session 名前
  --state-dir パス  --local-socket パス  --headless [--json]

  --invite-file は一回限りの招待をプロセス引数に公開しません。
  通常ファイルは所有者だけが読める必要があります。- は標準入力から 1 行読みます。

トランスポート:
  --lanes auto|single|isolated  --connect-timeout-seconds 秒数
  単一の明示的なリレールートでは --relay-slot スロットと、
    --relay-ticket-file パスまたは --relay-ticket-command プログラムを指定します。
  代替ルートでは --relay-route、--relay-slot、認証情報の組を出現順に最大 4 回指定します。
  --relay-ticket-command-arg 引数  --iroh-relay URL  --iroh-address アドレス
  --iroh-path auto|direct-only|relay-only
  --ssh-binary パス  --remote-binary パス  --ssh-arg 引数  --no-install
  --remote-state-dir パス  既定以外のデーモン状態ディレクトリ
  --upgrade は固定済みバイナリのインストール後に SSH 管理のサイドカーを置換します。
    ターミナルペインは維持され、リモート RPC 状態はリセットされます。

再接続:
  --reconnect-attempts 回数|unlimited  --reconnect-initial-ms ミリ秒
  --reconnect-max-ms ミリ秒  --reconnect-attempt-timeout-ms ミリ秒
  --reconnect-jitter full|none  --heartbeat-interval-ms ミリ秒
  --heartbeat-timeout-ms ミリ秒
"#,
        ssh_help: r#"使用方法: cmux remote ssh [ユーザー@]ホスト[:ポート] [オプション]

直接 SSH は既定で 1 本の搬送接続を使用します。複数接続を使うには
--lanes auto または isolated を指定します。リモートバイナリを確認し、
--no-install がなければ未導入または非互換時にユーザー領域へインストールします。

オプション:
  --session 名前  --lanes single|auto|isolated  --headless [--json]
  --ssh-binary パス  --remote-binary パス  --ssh-arg 引数  --no-install
  --remote-state-dir パス  既定以外のデーモン状態ディレクトリ
  --upgrade は SSH 管理のサイドカーを明示的に置換します。ターミナルペインは維持され、
    リモートクライアントと転送は切断され、RPC プロセスなどの状態はリセットされます。
  --state-dir パス  --local-socket パス  --connect-timeout-seconds 秒数
  --reconnect-attempts 回数|unlimited  --reconnect-initial-ms ミリ秒
  --reconnect-max-ms ミリ秒  --reconnect-attempt-timeout-ms ミリ秒
  --reconnect-jitter full|none  --heartbeat-interval-ms ミリ秒
  --heartbeat-timeout-ms ミリ秒
"#,
        forward_help: r#"使用方法: cmux remote forward [ルート] --workspace-root パス --port ポート [オプション]

オプション:
  --host ホスト  --listen アドレス  --scheme http|https
  `cmux remote connect` の ID、トランスポート、SSH、リレー、Iroh、再接続の
  全オプションも使用できます。
"#,
        rpc_help: r#"使用方法: cmux remote rpc [ルート] [オプション]

標準入力の各行から WorkspaceRequest JSON を 1 件読み、応答を 1 行出力します。
--request JSON は 1 件を送信して終了します。

オプション:
  --request WORKSPACE_REQUEST_JSON
  `cmux remote connect` の ID、トランスポート、SSH、リレー、Iroh、再接続の
  全オプションも使用できます。
"#,
        enroll_help: r#"使用方法: cmux remote enroll 操作 [オプション]

操作:
  status | create | pending | approve ID | deny ID | devices | connections
  revoke DEVICE_ID | disconnect DEVICE_ID SESSION_ID | connect ルート

オプション:
  --session 名前  --state-dir パス  --admin-socket パス  --json
  create: --ttl 秒数  --advertise ルート
  create のリレーアクセスでは --relay-route、--relay-slot、
    --relay-ticket-file の組を出現順に最大 2 回指定します。
  connect では `cmux remote connect` の全オプションを使用できます。
"#,
        known_daemons_help: "使用方法: cmux remote known-daemons [list] [--state-dir パス] [--json]\n          cmux remote known-daemons forget フィンガープリント [--state-dir パス] [--json]\n",
        remote_probe_help: "使用方法: cmux-tui remote-probe [--json]\n",
        remote_link_help: "使用方法: cmux-tui remote-link --stdio [--session 名前] [--state-dir パス]\n",
        install_self_help: "使用方法: cmux-tui install-self --destination パス\n",
        command_help: "使用方法: cmux remote <connect|ssh|forward|rpc|enroll|known-daemons|stop> [オプション]\n\nコマンド別のルートとオプションは `cmux remote コマンド --help` で表示します。従来のトップレベル別名は互換期間中も使用できます。\n",
        remote_lifecycle_help: "使用方法: cmux remote connect|ssh|forward|rpc [オプション]\n          cmux remote enroll <操作> [オプション]\n          cmux remote known-daemons [オプション]\n          cmux remote stop [オプション]\n\n認証済みリモート操作は `remote` で明示的に指定します。所有プロセスは明示的なリモートフラグを付けた `cmux server start` で起動します。`cmux remote stop` は置換可能な SSH サイドカーだけを管理します。`cmux server start` に組み込まれたリスナーは `cmux server stop` で停止してください。この操作はローカルの所有者とワークスペースも停止します。\n",
        option_needs_value: "{option} には値が必要です",
        invalid_option_value: "{option} の値が無効です。{expected} を指定してください",
        option_must_be_positive: "{option} には正の値を指定してください",
        unknown_option: "不明なオプションです: {option}",
        unknown_option_for_command: "{command} の不明なオプションです: {option}",
        option_once: "{option} は 1 回だけ指定できます",
        unknown_action: "不明な {command} 操作です: {action}",
        enroll_arity: "enroll {action} には位置引数をちょうど {expected} 個指定してください",
        option_create_only: "{option} は enroll create でのみ使用できます",
        inline_invitation_rejected: "招待を引数へ直接指定できません。--invite-file または標準入力を使用してください",
        invitation_path_invalid: "招待パスには所有者専用の通常ファイル、または標準入力を表す - を指定してください",
        invitation_input_read_failed: "招待入力を読み取れませんでした",
        invitation_input_empty: "招待入力が空です",
        invitation_input_too_large: "招待入力が {maximum} バイトの上限を超えています",
        invitation_input_multiline: "招待入力には URI を 1 つだけ含めてください",
        invitation_input_invalid_utf8: "招待入力が有効な UTF-8 ではありません",
        inline_relay_ticket_rejected: "リレーチケットを引数へ直接指定できません。--relay-ticket-file または --relay-ticket-command を使用してください",
        inline_enroll_relay_ticket_rejected: "リレーチケットを引数へ直接指定できません。--relay-ticket-file を使用してください",
        relay_command_arg_order: "--relay-ticket-command-arg は --relay-ticket-command の後に指定してください",
        relay_credentials_require_explicit_route: "--relay-route を指定しないリレー認証情報には、明示的なリレー接続ルートを 1 つ指定してください",
        relay_shorthand_requires_relay_route: "リレー認証情報の短縮形式には明示的なリレールートが必要です。指定されたルート: {route}",
        relay_credential_pair_required: "各リレー認証情報には --relay-slot と認証情報ソースを 1 つずつ指定してください",
        multiple_relay_credentials_require_routes: "複数のリレー認証情報には、認証情報グループごとに --relay-route を 1 つ指定してください",
        route_scoped_relay_credential_pair_required: "ルート別の各リレー認証情報には --relay-route、--relay-slot、認証情報ソースを 1 つずつ指定してください",
        relay_credential_limit: "クライアントが使用できるリレー認証情報は最大 {maximum} 個です",
        relay_route_not_relay: "リレー認証情報のルート {route} はリレールートではありません",
        relay_route_repeated: "リレー認証情報のルート {route} が重複しています",
        invitation_relay_route_repeated: "招待内のリレーブートストラップルート {route} が重複しています",
        relay_route_limit: "招待のブートストラップルートを含め、クライアントが使用できるリレー認証情報ルートは最大 {maximum} 個です",
        invitation_daemon_mismatch: "招待のデーモンフィンガープリントが --daemon {fingerprint} と一致しません",
        invitation_no_routes: "招待に使用可能なルート候補がありません",
        daemon_no_routes: "デーモン {fingerprint} に保存済みルートがありません。ルートを指定するか、再登録してください",
        known_daemon_key_unavailable: "登録済みデーモンの鍵が見つかりません",
        carrier_daemon_requires_carrier: "デーモン {fingerprint} は信頼済みの SSH または Unix 搬送路でのみ登録されています。その搬送路を使用するか、ネットワーク接続用にこのデバイスを登録してください",
        upgrade_requires_ssh: "--upgrade を使用するには最初のルートを SSH にしてください",
        relay_route_not_candidate: "リレー認証情報のルート {route} はこの接続のルート候補に含まれていません",
        daemon_key_changed: "デーモン {name} の鍵が変更されています",
        known_daemon_refresh_missing: "ルートの更新中に登録済みデーモンが見つからなくなりました",
        positional_invitation_rejected: "招待を位置引数へ指定できません。--invite-file または標準入力を使用してください",
        connect_one_route: "connect に指定できるルートは 1 つです",
        reconnect_policy_invalid: "再接続遅延、試行タイムアウト、有効なハートビートタイムアウトには正の値が必要です。最大遅延は初期遅延以上にしてください",
        upgrade_no_install: "--upgrade と --no-install は同時に指定できません",
        json_requires_headless: "connect と ssh で --json を使うには --headless が必要です",
        help_invalid_options: "ヘルプと無効な connect オプションは同時に指定できません",
        ssh_destination_required: "ssh の接続先をオプションより前に指定してください",
        ssh_destination_invalid: "SSH の接続先が無効です",
        forward_workspace_required: "forward にはデーモン上の --workspace-root が必要です",
        forward_port_required: "forward には --port が必要です",
        rpc_request_invalid: "--request は WorkspaceRequest JSON オブジェクトではありません",
        rpc_input_invalid: "WorkspaceRequest が無効です",
        rpc_stdin_too_large: "RPC 標準入力の 1 行が {maximum} バイトの上限を超えています",
        rpc_stdin_invalid_utf8: "RPC 標準入力の行は有効な UTF-8 ではありません",
        known_forget_arity: "known-daemons forget にはフィンガープリントを 1 つ指定してください",
        known_state_dir_unavailable: "リモート状態ディレクトリを特定できません。--state-dir を指定してください",
        known_daemon_not_known: "デーモン {fingerprint} は登録されていません",
        known_daemon_forgotten: "デーモン {fingerprint} を削除しました。",
        known_daemons_empty: "登録済みのデーモンはありません。",
        known_daemon_auth_enrolled: "登録済み",
        known_daemon_auth_carrier: "信頼済み搬送路",
    },
    remote: RemoteMessages {
        remote_stop_help: "使用方法: cmux remote stop [--session NAME] [--state-dir PATH] [--acknowledge-failed-finalization | --acknowledge-legacy-finalization]\n\nこのコマンドは置換可能な SSH サイドカーだけを管理します。`cmux server start` に組み込まれたリスナーは `cmux server stop` で停止してください。この操作はローカルの所有者とワークスペースも停止します。\n\n--acknowledge-legacy-finalization は、停止済みでライフサイクルフェンス導入前のデーモン専用です。使用前に旧 cmux-tui プロセスが残っていないことを確認してください。\n",
        remote_stop_unknown_option: "cmux remote stop の不明なオプションです: {option}",
        remote_stop_no_positional: "cmux remote stop に位置引数は指定できません",
        remote_stop_acknowledgements_mutually_exclusive: "--acknowledge-failed-finalization と --acknowledge-legacy-finalization は同時に指定できません",
        invalid_runtime_metadata: "リモートデーモンのランタイムメタデータが無効です。cmux-tui プロセスが残っていないことを確認してから、cmux remote stop を --acknowledge-legacy-finalization 付きで再実行してください（{path}）",
        inspect_runtime_metadata: "リモートデーモンのランタイムメタデータを確認できませんでした（{path}）",
        inactive_legacy_needs_migration: "停止中の旧形式デーモン状態には明示的な移行が必要です。旧 cmux-tui プロセスが残っていないことを確認してから、cmux remote stop を --acknowledge-legacy-finalization 付きで再実行してください",
        refuse_live_invalid_lifecycle: "有効なライフサイクルメタデータがない実行中デーモンの停止を拒否しました",
        embedded_daemon_stop_refused: "cmux remote stop は置換可能な SSH サイドカーだけを管理します。このリモートリスナーはローカルサーバーに属するため、その所有者とワークスペースを停止するには `cmux server stop --session <名前>` を使用してください",
        daemon_shutdown_failed: "デーモンの停止に失敗しました",
        observe_daemon_exit: "リモートデーモンプロセスの終了を確認できませんでした",
        daemon_stop_timeout: "リモートデーモンが 20 秒以内に停止しませんでした",
        verify_previous_finalization_path: "前回のリモートデーモン認可終了処理を確認できませんでした（{path}）",
        verify_previous_finalization: "前回のリモートデーモン認可終了処理を確認できませんでした",
        previous_finalization_failed_ack: "前回のリモートデーモン認可終了処理に失敗しました。認可状態を確認してから、cmux remote stop を --acknowledge-failed-finalization 付きで再実行してください",
        verify_finalization: "リモートデーモンの認可終了処理を確認できませんでした",
        finalization_wrong_lifecycle: "リモートデーモンの認可終了処理を確認できませんでした。停止結果が別のデーモンライフサイクルに属しています",
        finalization_failed: "リモートデーモンの認可終了処理に失敗しました",
        verify_lifecycle_fence: "リモートデーモンのライフサイクルフェンスを確認できませんでした",
        confirm_lifecycle_fence_durability: "リモートデーモンのライフサイクルフェンスが永続化されたことを確認できませんでした",
        inspect_authorization_state: "リモートデーモンの認可状態を確認できませんでした",
        inspect_authorization_schema: "リモートデーモンの認可スキーマを確認できませんでした",
        legacy_authorization_requires_migration: "前回のリモートデーモン認可状態には明示的な移行が必要です。旧 cmux-tui プロセスが残っていないことを確認してから、cmux remote stop --acknowledge-legacy-finalization を実行してください",
        prepare_lifecycle_state: "リモートデーモンのライフサイクル状態を準備できませんでした",
        verify_previous_lifecycle_metadata: "前回のリモートデーモンライフサイクルメタデータを確認できませんでした",
        modern_predecessor_missing_outcome: "前回のリモートデーモン認可終了処理を確認できませんでした。新形式の先行デーモンが結果を保存していません",
        runtime_empty_lifecycle: "前回のリモートデーモン認可終了処理を確認できませんでした。ランタイムメタデータのライフサイクル ID が空です",
        state_predates_lifecycle_fence: "前回のリモートデーモン状態はライフサイクルフェンス導入前のものです。再接続する前に cmux remote stop で旧デーモンを停止してください",
        state_missing_lifecycle_fence: "前回のリモートデーモン状態にライフサイクルフェンスがありません。再接続する前に cmux remote stop で旧デーモンを停止してください",
        authorization_finalization_failed: "認可終了処理に失敗しました",
        lifecycle_fence_version_unsupported: "リモートデーモンのライフサイクルフェンスバージョン {version} はサポートされていません",
        inspect_stopped_authorization_state: "停止済みデーモンの認可状態を確認できませんでした",
        acquire_stopped_authorization_lease: "停止済みデーモンの認可リースを取得できませんでした",
        finalize_stopped_authorization_migration: "停止済みデーモンの認可移行を完了できませんでした",
        snapshot_runtime_for_recovery: "復旧用のリモートデーモンランタイムメタデータを取得できませんでした",
        snapshot_finalization_for_recovery: "復旧用のリモートデーモン認可終了処理を取得できませんでした",
        acquire_recovery_authorization_lease: "復旧用のリモートデーモン認可リースを取得できませんでした",
        resnapshot_runtime_for_recovery: "復旧用のリモートデーモンランタイムメタデータを再取得できませんでした",
        resnapshot_finalization_for_recovery: "復旧用のリモートデーモン認可終了処理を再取得できませんでした",
        lifecycle_evidence_changed_before_recovery: "認可の復旧前にリモートデーモンのライフサイクル情報が変更されました",
        complete_authorization_recovery: "リモートデーモンの認可を復旧できませんでした",
        verify_runtime_for_recovery: "復旧用のリモートデーモンランタイムメタデータを確認できませんでした",
        refuse_failed_ack_with_legacy_runtime: "旧形式のランタイムメタデータでは、失敗した認可終了処理を確認済みとして扱えません",
        no_failed_finalization_recorded: "失敗したリモートデーモン認可終了処理は記録されていません",
        finalization_succeeded_no_ack: "リモートデーモンの認可終了処理は成功しているため、確認済みとして扱う必要はありません",
        inspect_legacy_authorization_state: "旧形式デーモンの認可状態を確認できませんでした",
        no_legacy_authorization_state: "旧形式のリモートデーモン認可状態は記録されていません",
        snapshot_legacy_runtime: "旧形式リモートデーモンのランタイムメタデータを取得できませんでした",
        snapshot_legacy_shutdown: "旧形式リモートデーモンの停止メタデータを取得できませんでした",
        acquire_legacy_recovery_authorization_lease: "旧形式復旧用のリモートデーモン認可リースを取得できませんでした",
        resnapshot_legacy_runtime: "旧形式リモートデーモンのランタイムメタデータを再取得できませんでした",
        resnapshot_legacy_shutdown: "旧形式リモートデーモンの停止メタデータを再取得できませんでした",
        lifecycle_evidence_changed_before_legacy_recovery: "旧形式復旧前にリモートデーモンのライフサイクル情報が変更されました",
        complete_legacy_authorization_recovery: "旧形式リモートデーモンの認可を復旧できませんでした",
        failed_finalization_label: "失敗した認可終了処理",
        legacy_finalization_label: "旧形式の認可終了処理",
        refuse_active_socket: "デーモンソケット {path} が有効なため、{finalization}を確認済みとして扱えません",
        verify_socket_inactive: "デーモンソケット {path} が無効であることを確認できませんでした",
        lifecycle_runtime_requires_failed_ack: "リモートデーモンのランタイムメタデータはライフサイクル対応です。停止に失敗した場合は --acknowledge-failed-finalization を使用してください",
        shutdown_evidence_requires_failed_ack: "リモートデーモンの停止情報には --acknowledge-failed-finalization が必要です",
        lifecycle_evidence_changed_during_legacy_recovery: "旧形式復旧中にリモートデーモンのライフサイクル情報が変更されました",
        lifecycle_evidence_changed_during_recovery: "復旧中にリモートデーモンのライフサイクル情報が変更されました",
    },
    config: ConfigMessages {
        invalid_macos_option_as_alt: "cmux-tui: 真偽値ではない keys.macos_option_as_alt = {value} を無視します",
        invalid_section: "cmux-tui: 無効な設定セクション {section} を無視します",
        unknown_field: "cmux-tui: 不明な設定フィールド {field} を無視します",
        invalid_root: "cmux-tui: ルート値がオブジェクトではないため設定を無視します",
    },
    attach: AttachMessages {
        filtered_subscription_unavailable: "単一ターミナルへの接続には新しい cmux-tui サーバーが必要です。セッションを再起動してください",
        remote_attach_queue_full: "リモートサーフェス接続キューがいっぱいです",
        remote_attach_workers_failed_template: "リモートサーフェス接続ワーカーを開始できませんでした: {error}",
        surface_sync_failed_template: "サーフェス {surface} の{operation}に失敗しました。再試行は制限されています: {error}",
        surface_sync_unknown_template: "サーフェス {surface} の{operation}結果は不明です。入力を続ける前に切断して再接続してください: {error}",
        surface_sync_attach: "接続",
        surface_sync_resize: "サイズ変更",
        surface_sync_operation: "操作",
        unknown_terminal_prefix: "ターミナル ",
        unknown_terminal_suffix: " が見つかりません。`cmux terminal list` でターミナル ID 一覧を確認してください",
        ambiguous_terminal_prefix: "ターミナル参照 ",
        ambiguous_terminal_suffix: " は曖昧です。`cmux terminal list` に表示される一意の ID を使用してください",
        browser_terminal_prefix: "サーフェス ",
        browser_terminal_suffix: " はブラウザであり、ターミナルではありません",
    },
    sidebar: SidebarMessages {
        machines: "マシン",
        workspaces: "ワークスペース",
        panes: "ペイン",
        tabs: "タブ",
        agents: "エージェント",
        projection_path_separator: " › ",
        new_machine: "新規VM",
        connect_machine: "SSHホスト",
        no_machines: "マシンがありません",
        no_workspaces: "ワークスペースがありません",
        no_panes: "ペインがありません",
        no_tabs: "タブがありません",
        no_agents: "エージェントがありません",
        recoverable_machine: "復元可能",
        rename_machine: "マシン名を変更",
        delete_machine: "マシンを削除",
        restore_machine: "マシンを復元",
        purge_machine: "完全に削除",
        confirm_delete_machine: "最終スナップショット後に削除するには CONFIRM と入力してください",
        confirm_purge_machine: "マシンとスナップショットを完全に削除するには CONFIRM と入力してください",
        new_workspace: "新規ワークスペース",
        new_isolated_workspace: "新規隔離",
        new_shared_workspace: "新規共有",
        recoverable_workspace: "復元可能",
        rename_workspace: "ワークスペース名を変更",
        delete_workspace: "ワークスペースを削除",
        restore_workspace: "ワークスペースを復元",
        purge_workspace: "完全に削除",
        confirm_purge_workspace: "完全に削除するには CONFIRM と入力してください",
        no_active_session: "先にマシンを選択または作成してください",
        managed_workspace_unsupported: "このマシンプロバイダーは管理ワークスペースを作成できません",
        managed_workspace_machine_inactive: "アクティブなマシンがありません。このワークスペースのマシンを選択または再接続してから再試行してください",
        managed_workspace_unavailable: "管理ワークスペースの情報を取得できません。プロバイダーの更新後に再試行してください",
        managed_workspace_operation_not_allowed: "プロバイダーはこのワークスペースでこの操作を許可していません。メニューに表示される操作を使用してください",
        running: "実行中",
        connecting: "接続中",
        waking: "再開中",
        sleeping_wake_hint: "スリープ中 — 任意のキーで再開",
        sleeping: "スリープ中",
        stopped: "停止",
        unavailable: "利用不可",
        working: "作業中",
        blocked: "ブロック中",
        idle: "待機中",
        done: "完了",
        unknown: "不明",
        connect_prompt: "ホストアドレスまたはペアリングコード",
        connect_host_prompt: "SSH ホストまたは user@host",
        connecting_to: "{target} に接続中…",
        starting_on: "{target} でセッションを開始中…",
        failed_to_connect: "{target} に接続できませんでした",
        retry_connection: "再試行",
        close_dialog: "閉じる",
        ssh_hosts: "SSH ホスト",
        type_to_filter: "入力して絞り込み",
        other_host: "SSH ホストを追加…",
        personal_scope: "個人",
        plugin_exited: "サイドバープラグインが終了しました",
        team_scope: "チーム",
        scope: "スコープ",
        provider_actions: "操作",
        action_required: "この値は必須です",
        action_too_long: "この値は長すぎます",
        action_invalid_email: "有効なメールアドレスを入力してください",
        action_invalid_integer: "整数を入力してください",
        action_below_minimum: "この数値は許可された最小値未満です",
        action_above_maximum: "この数値は許可された最大値を超えています",
        action_missing_selected_machine: "この操作を実行する前にマシンを選択してください",
        action_missing_selected_workspace: "この操作を実行する前にワークスペースを選択してください",
        action_multiple_fields_unsupported: "この操作に必要なフォームをこのクライアントでは表示できません",
        action_list_workspace_ports: "ワークスペースのポートを表示",
        action_make_workspace_port_public: "ワークスペースのポートを公開",
        action_make_workspace_port_private: "ワークスペースのポートを非公開",
        action_open_private_workspace_port: "非公開のワークスペースポートを開く",
        action_workspace_port: "ポート",
        confirm_destructive_action: "続行するには CONFIRM と入力",
        confirm_layout_undo: "ペイン {items} を閉じるには CONFIRM と入力",
        confirmation_mismatch: "この操作を実行するには CONFIRM と正確に入力してください",
        layout_nothing_to_undo: "元に戻せるレイアウト操作はありません",
        layout_undo_stale: "レイアウトが変更されたため、元に戻す操作は適用されませんでした",
        initial_machine_connection_failed: "マシンに接続できませんでした",
        provider_notice_identity_unavailable: "接続を準備できませんでした。もう一度お試しください。問題が解決しない場合は、cmux を再起動してください。",
        provider_connection_already_running: "別の接続がすでに実行中です。終了してから、もう一度お試しください。",
        machine_provider_disconnected: "マシンプロバイダーから切断されました。再接続しています",
        machine_action_failed: "マシン操作に失敗しました",
        layout_refresh_failed: "セッションが変更されましたが、レイアウトの更新に失敗しました: {error}",
        layout_stale: "セッションが変更されましたが、レイアウトはまだ古いままです: {error}",
        file_no_focused_pane: "フォーカスされたペインがありません",
        file_surface_unavailable: "フォーカスされたサーフェスを利用できません",
        file_input_not_queued: "入力をキューに追加できませんでした",
        file_command_failed: "ファイル操作に失敗しました: {error}",
        file_sent_to_focused_pane: "フォーカスされたペインに送信しました",
        refresh_remote_tree_retrying: "リモートツリーの更新に失敗しました。再試行しています: {error}",
        refresh_remote_tree_stopped: "{attempts} 回試行しましたがリモートツリーの更新に失敗しました。自動再試行を停止しました。再接続して再試行してください: {error}",
        clients_list_failed: "クライアント一覧を取得できませんでした: {error}",
        layout_undo_failed: "レイアウトを元に戻せませんでした: {error}",
        pairing_response_failed: "ペアリング要求に応答できませんでした: {error}",
        workspace_state_failed: "ワークスペースの状態を更新できませんでした: {error}",
        provider_action_open_url: "リンクを開く",
        machine_provider_update_failed: "マシンプロバイダーの更新に失敗しました",
        machine_provider_lifecycle_update_failed: "マシンプロバイダーのライフサイクル更新に失敗しました",
        machine_provider_workspace_update_failed: "マシンプロバイダーのワークスペース更新に失敗しました",
        machine_reconnect_failed: "マシンに再接続できませんでした",
        machine_terminal_colors_failed: "ターミナルの色を適用できませんでした",
        machine_provider_external_connect_unsupported: "このマシンプロバイダーは外部マシンに接続できません",
        machine_provider_external_connect_ambiguous: "前回の接続処理が完了している可能性があります。プロバイダーを再接続し、同じペアリングコードで再試行してください",
        machine_not_ready_to_connect: "選択したマシンは接続準備ができていません",
        machine_managed_authority_unsupported: "このプロバイダーは管理ワークスペースのミラーを認可できません。マシンプロバイダーをアップグレードしてください",
        machine_managed_authority_invalid: "マシンプロバイダーから無効な管理ワークスペース権限バインディングが返されました",
        machine_catalog_create_unsupported: "このマシンカタログではマシンを作成できません",
        machine_creation_source_unavailable: "このマシン作成元は利用できません",
        machine_name_required: "マシン名を入力してください",
        client_machine_unavailable: "このクライアント管理マシンは利用できません",
        prototype_machine_added: "プロトタイプマシンを追加しました",
        machine_catalog_provider_actions_unsupported: "このマシンカタログにはプロバイダーアクションがありません",
        machine_catalog_updates_failed: "マシンカタログの更新を開始できませんでした",
        machine_catalog_restart_failed: "マシンは切り替わりましたが、カタログのライブ更新を再開できませんでした",
        machine_replacement_pending: "別のマシン切り替えを処理中です",
        machine_replacement_worker_stopped: "確定前にマシン切り替え処理が停止しました",
        machine_replacement_stale: "マシン切り替えの状態が古くなっています",
        machine_replacement_not_pending: "保留中のマシン切り替えがありません",
        machine_replacement_target_missing: "マシン切り替え先が見つかりません",
        managed_ssh_requires_unix: "管理 SSH マシン接続には Unix が必要です",
    },
};

pub(crate) fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<&'static Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| catalog_for_locale(&system_locale()))
}

pub(crate) fn catalog_for_locale(locale: &str) -> &'static Catalog {
    if locale.to_ascii_lowercase().starts_with("ja") { &JAPANESE } else { &ENGLISH }
}

fn system_locale() -> String {
    std::env::var("LC_ALL")
        .or_else(|_| std::env::var("LC_MESSAGES"))
        .or_else(|_| std::env::var("LANG"))
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locale_tags_select_complete_catalogs() {
        assert_eq!(catalog_for_locale("en_US.UTF-8"), &ENGLISH);
        assert_eq!(catalog_for_locale("ja_JP.UTF-8"), &JAPANESE);
        assert_eq!(catalog_for_locale("C"), &ENGLISH);
        assert_eq!(ENGLISH.menu.maximize_pane, "Maximize pane");
        assert_eq!(JAPANESE.menu.maximize_pane, "ペインを最大化");
        assert_eq!(ENGLISH.action_label(Action::NewPaneSmart), "New pane");
        assert_eq!(JAPANESE.action_label(Action::NewPaneSmart), "新しいペイン");
        assert_eq!(ENGLISH.shortcuts.title, "Keyboard shortcuts");
        assert_eq!(JAPANESE.shortcuts.title, "キーボードショートカット");
        assert_eq!(ENGLISH.shortcuts.close_button, "Esc close");
        assert_eq!(JAPANESE.shortcuts.close_button, "Esc 閉じる");
        assert_eq!(ENGLISH.remote_client.known_daemons_empty, "No known daemons.");
        assert_eq!(JAPANESE.remote_client.known_daemons_empty, "登録済みのデーモンはありません。");
        assert_eq!(ENGLISH.remote_client.known_daemon_auth_enrolled, "enrolled");
        assert_eq!(JAPANESE.remote_client.known_daemon_auth_enrolled, "登録済み");
        assert_eq!(ENGLISH.remote_client.known_daemon_auth_carrier, "carrier");
        assert_eq!(JAPANESE.remote_client.known_daemon_auth_carrier, "信頼済み搬送路");
        assert_eq!(
            ENGLISH.remote_client.relay_credentials_require_explicit_route,
            "relay credentials without --relay-route require one explicit relay connection route"
        );
        assert_eq!(
            JAPANESE.remote_client.relay_credentials_require_explicit_route,
            "--relay-route を指定しないリレー認証情報には、明示的なリレー接続ルートを 1 つ指定してください"
        );
        assert_eq!(
            JAPANESE.remote_client.relay_shorthand_requires_relay_route("wss://example.test/"),
            "リレー認証情報の短縮形式には明示的なリレールートが必要です。指定されたルート: wss://example.test/"
        );
        assert_eq!(
            JAPANESE.remote_client.known_daemon_forgotten("fingerprint"),
            "デーモン fingerprint を削除しました。"
        );
        assert_eq!(
            JAPANESE.remote_client.known_daemon_not_known("fingerprint"),
            "デーモン \"fingerprint\" は登録されていません"
        );
        assert_eq!(
            ENGLISH.terminal.deferred_input_destination_changed,
            "Deferred input was discarded because its destination changed"
        );
        assert_eq!(
            JAPANESE.terminal.deferred_input_destination_changed,
            "遅延入力は送信先が変更されたため破棄されました"
        );
        assert_eq!(
            ENGLISH.terminal.deferred_input_queue_full,
            "Input queue byte limit reached while a session change is pending"
        );
        assert_eq!(
            JAPANESE.terminal.deferred_input_queue_full,
            "セッション変更の保留中に入力キューのバイト上限に達しました"
        );
        assert_eq!(ENGLISH.terminal.pty_input_exited, "Terminal exited; input was not sent");
        assert_eq!(
            JAPANESE.terminal.pty_input_exited,
            "ターミナルが終了したため、入力は送信されませんでした"
        );
        assert_eq!(ENGLISH.session.operation_failed, "Session operation failed");
        assert_eq!(
            JAPANESE.session.mux_subscription_recovered,
            "Mux イベントの滞留が上限を超えました。購読を復旧しました"
        );
        assert_eq!(
            JAPANESE.session.mux_subscription_recovery_failed("更新失敗"),
            "Mux イベントの滞留から復旧できませんでした。再試行中のキュー入力を破棄しました: 更新失敗"
        );
        assert_eq!(JAPANESE.session.operation_failed, "セッション操作に失敗しました");
        assert_eq!(
            JAPANESE.attach.filtered_subscription_unavailable,
            "単一ターミナルへの接続には新しい cmux-tui サーバーが必要です。セッションを再起動してください"
        );
        assert_eq!(ENGLISH.attach.remote_attach_queue_full, "remote surface attach queue is full");
        assert_eq!(
            JAPANESE.attach.remote_attach_queue_full,
            "リモートサーフェス接続キューがいっぱいです"
        );
        assert_eq!(
            ENGLISH.attach.remote_attach_workers_failed("os detail"),
            "could not start surface attach workers: os detail"
        );
        assert_eq!(
            JAPANESE.attach.remote_attach_workers_failed("os detail"),
            "リモートサーフェス接続ワーカーを開始できませんでした: os detail"
        );
        assert_eq!(
            ENGLISH.attach.unknown_terminal("missing"),
            "unknown terminal \"missing\"; use `cmux terminal list` to list terminal IDs"
        );
        assert_eq!(
            JAPANESE.attach.ambiguous_terminal("000010"),
            "ターミナル参照 \"000010\" は曖昧です。`cmux terminal list` に表示される一意の ID を使用してください"
        );
        assert_eq!(
            JAPANESE.attach.browser_not_terminal("browser"),
            "サーフェス \"browser\" はブラウザであり、ターミナルではありません"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").terminal.keyboard_text_too_large,
            "キーボード入力が 4 MiB の PTY バッファ上限を超えています"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").terminal.clear_history_help,
            "アクティブなプロンプトを保持したまま PTY 履歴を消去します。"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").terminal.clear_history_unsupported,
            "このサーバーでは clear-history を使用できません。cmux-tui サーバーを再起動してください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_provider_disconnected,
            "マシンプロバイダーから切断されました。再接続しています"
        );
        assert_eq!(catalog_for_locale("en_US.UTF-8").machine_agent.pairing_code, "Pairing code");
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").machine_agent.retrying_message(250),
            "Cloud connection lost; retrying in 250 ms"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.pairing_code,
            "ペアリングコード"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.retrying_message(250),
            "クラウド接続が切断されました。250 ミリ秒後に再接続します"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").machine_agent.migration_failed,
            "Could not reconnect the machine; please try again"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.migration_failed,
            "マシンを再接続できませんでした。もう一度お試しください"
        );
        assert!(
            catalog_for_locale("en_US.UTF-8")
                .machine_agent
                .help
                .contains("share one local cmux session through a remote service")
        );
        assert!(
            catalog_for_locale("ja_JP.UTF-8")
                .machine_agent
                .help
                .contains("ローカルの cmux セッションをリモートサービス経由で共有")
        );
        assert!(!catalog_for_locale("en_US.UTF-8").machine_agent.help.contains("BatchMode"));
        assert!(!catalog_for_locale("ja_JP.UTF-8").machine_agent.help.contains("BatchMode"));
        assert!(
            catalog_for_locale("en_US.UTF-8")
                .machine_agent
                .pairing_code_unavailable
                .contains("interactive terminal")
        );
        assert!(
            catalog_for_locale("ja_JP.UTF-8")
                .machine_agent
                .pairing_code_unavailable
                .contains("対話型端末")
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").machine_agent.invalid_cloud_port_message("invalid"),
            "Invalid --cloud-port value: invalid"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").machine_agent.invalid_cloud_port_message("invalid"),
            "--cloud-port の値が無効です: invalid"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.machine_action_failed,
            "Machine action failed"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.provider_notice_identity_unavailable,
            "Could not prepare the connection. Try again; if the problem persists, restart cmux."
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.provider_connection_already_running,
            "Another connection is already running. Close it and try again."
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.connect_prompt,
            "Host address or pairing code"
        );
        assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.new_machine, "new vm");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.new_machine, "新規VM");
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.connect_prompt,
            "ホストアドレスまたはペアリングコード"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.connect_host_prompt,
            "SSH host or user@host"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.connect_host_prompt,
            "SSH ホストまたは user@host"
        );
        assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.ssh_hosts, "SSH hosts");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.ssh_hosts, "SSH ホスト");
        assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.type_to_filter, "type to filter");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.type_to_filter, "入力して絞り込み");
        assert_eq!(catalog_for_locale("en_US.UTF-8").sidebar.other_host, "Add SSH host…");
        assert_eq!(catalog_for_locale("ja_JP.UTF-8").sidebar.other_host, "SSH ホストを追加…");
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.machine_name_required,
            "Enter a machine name"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_name_required,
            "マシン名を入力してください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_action_failed,
            "マシン操作に失敗しました"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.provider_notice_identity_unavailable,
            "接続を準備できませんでした。もう一度お試しください。問題が解決しない場合は、cmux を再起動してください。"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.provider_connection_already_running,
            "別の接続がすでに実行中です。終了してから、もう一度お試しください。"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_provider_external_connect_ambiguous,
            "前回の接続処理が完了している可能性があります。プロバイダーを再接続し、同じペアリングコードで再試行してください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_replacement_stale,
            "マシン切り替えの状態が古くなっています"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_catalog_updates_failed,
            "マシンカタログの更新を開始できませんでした"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_replacement_worker_stopped,
            "確定前にマシン切り替え処理が停止しました"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_not_ready_to_connect,
            "選択したマシンは接続準備ができていません"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_managed_authority_unsupported,
            "このプロバイダーは管理ワークスペースのミラーを認可できません。マシンプロバイダーをアップグレードしてください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.machine_managed_authority_invalid,
            "マシンプロバイダーから無効な管理ワークスペース権限バインディングが返されました"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").sidebar.confirm_layout_undo,
            "Type CONFIRM to close pane(s) {items}"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.confirm_layout_undo,
            "ペイン {items} を閉じるには CONFIRM と入力"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.layout_nothing_to_undo,
            "元に戻せるレイアウト操作はありません"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").sidebar.layout_undo_stale,
            "レイアウトが変更されたため、元に戻す操作は適用されませんでした"
        );
        let japanese_layout = &catalog_for_locale("ja_JP.UTF-8").layout;
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").layout.surface_size_release_failed(7, "disconnected"),
            "surface 7 size release failed; retrying on the next layout: disconnected"
        );
        assert_eq!(
            japanese_layout.surface_size_release_failed(7, "切断"),
            "サーフェス 7 のサイズ設定の解放に失敗しました。次回のレイアウト更新時に再試行します: 切断"
        );
        assert_eq!(
            japanese_layout.viewport_width_out_of_range,
            "ビューポートペインの幅は 0.1 から 1.0 の範囲で指定してください"
        );
        assert_eq!(
            japanese_layout.viewport_width_must_be_finite,
            "--width には有限の数値を指定してください"
        );
        assert_eq!(
            japanese_layout.viewport_width_must_be_number,
            "--width には数値を指定してください"
        );
        assert_eq!(japanese_layout.ratio_must_be_number, "--ratio には数値を指定してください");
        assert_eq!(
            japanese_layout.ratio_must_be_finite,
            "--ratio には有限の数値を指定してください"
        );
        assert_eq!(
            japanese_layout.pane_without_resizable_column(42),
            "ペイン 42 にはサイズ変更可能なビューポート列がありません"
        );
        assert_eq!(
            japanese_layout.unsupported_server_command("undo-layout"),
            "undo-layout はこのサーバーではサポートされていません"
        );
        assert_eq!(japanese_layout.layout_undo_applied(3, 9), "元に戻しました screen=3 revision=9");
        assert_eq!(
            japanese_layout.layout_undo_confirmation_required(8, "15,16"),
            "確認が必要です: --revision 8 --confirm-close を付けて再実行してください（閉じるペイン: 15,16）"
        );
        assert_eq!(
            japanese_layout.layout_undo_confirmation_flags_together,
            "--revision と --confirm-close は同時に指定してください"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").runtime.renderer_panicked("描画セルが無効"),
            "ターミナル描画処理でパニックが発生しました: 描画セルが無効"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").runtime.host_input_failed("切断"),
            "ホストターミナルの入力に失敗しました: 切断"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").runtime.signal_handlers_failed("権限がありません"),
            "シグナルハンドラーの設定に失敗しました: 権限がありません"
        );
        assert_eq!(
            catalog_for_locale("en_US.UTF-8")
                .runtime
                .terminal_restore_also_failed("event loop failed", "restore failed"),
            "event loop failed; host terminal restoration also failed: restore failed"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8")
                .runtime
                .terminal_restore_also_failed("イベントループ失敗", "復元失敗"),
            "イベントループ失敗; ホストターミナルの復元にも失敗しました: 復元失敗"
        );
    }

    #[test]
    fn remote_recovery_messages_are_localized() {
        let english = &catalog_for_locale("en_US.UTF-8").remote;
        let japanese = &catalog_for_locale("ja_JP.UTF-8").remote;

        assert!(english.remote_stop_help.contains("USAGE"));
        assert!(japanese.remote_stop_help.contains("使用方法"));
        assert!(english.remote_stop_help.contains("cmux server stop"));
        assert!(japanese.remote_stop_help.contains("cmux server stop"));
        assert!(english.embedded_daemon_stop_refused.contains("SSH"));
        assert!(japanese.embedded_daemon_stop_refused.contains("SSH"));
        assert_eq!(
            english.remote_stop_unknown_option("--unknown"),
            "unknown option \"--unknown\" for cmux remote stop"
        );
        assert_eq!(
            japanese.remote_stop_unknown_option("--unknown"),
            "cmux remote stop の不明なオプションです: \"--unknown\""
        );
        assert_eq!(
            english.invalid_runtime_metadata("/tmp/runtime.json"),
            "remote daemon runtime metadata is invalid; verify that no cmux-tui process remains, then rerun cmux remote stop with --acknowledge-legacy-finalization (/tmp/runtime.json)"
        );
        assert_eq!(
            japanese.invalid_runtime_metadata("/tmp/runtime.json"),
            "リモートデーモンのランタイムメタデータが無効です。cmux-tui プロセスが残っていないことを確認してから、cmux remote stop を --acknowledge-legacy-finalization 付きで再実行してください（/tmp/runtime.json）"
        );
        assert_eq!(
            english.lifecycle_fence_version_unsupported(7),
            "remote daemon lifecycle fence version 7 is unsupported"
        );
        assert_eq!(
            japanese.lifecycle_fence_version_unsupported(7),
            "リモートデーモンのライフサイクルフェンスバージョン 7 はサポートされていません"
        );
        assert_eq!(
            english.refuse_active_socket("failed finalization", "/tmp/admin.sock"),
            "refusing to acknowledge failed finalization while daemon socket /tmp/admin.sock is active"
        );
        assert_eq!(
            japanese.refuse_active_socket("失敗した終了処理", "/tmp/admin.sock"),
            "デーモンソケット /tmp/admin.sock が有効なため、失敗した終了処理を確認済みとして扱えません"
        );
    }

    #[test]
    fn deferred_input_discard_status_is_catalog_backed() {
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").terminal.deferred_input_destination_changed,
            "Deferred input was discarded because its destination changed"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").terminal.deferred_input_destination_changed,
            "遅延入力は送信先が変更されたため破棄されました"
        );
    }

    #[test]
    fn option_mode_config_warning_is_localized() {
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").config.invalid_macos_option_as_alt("\"guess\""),
            "cmux-tui: ignoring non-boolean keys.macos_option_as_alt = \"guess\""
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").config.invalid_macos_option_as_alt("\"guess\""),
            "cmux-tui: 真偽値ではない keys.macos_option_as_alt = \"guess\" を無視します"
        );
    }

    #[test]
    fn deferred_input_overflow_status_is_catalog_backed() {
        assert_eq!(
            catalog_for_locale("en_US.UTF-8").terminal.deferred_input_queue_full,
            "Input queue byte limit reached while a session change is pending"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8").terminal.deferred_input_queue_full,
            "セッション変更の保留中に入力キューのバイト上限に達しました"
        );
    }

    #[test]
    fn browser_recovery_failures_are_localized_at_the_ui_boundary() {
        let cases = [
            (
                "browser resize recovery failed; reload to retry",
                "browser failed: browser resize recovery failed; reload to retry",
                "ブラウザのサイズ変更を復旧できませんでした。再読み込みして再試行してください",
            ),
            (
                "could not verify new page pixels: capture timed out; reload to retry",
                "browser failed: could not verify new page pixels: capture timed out; reload to retry",
                "新しいページの表示を確認できませんでした: capture timed out。再読み込みして再試行してください",
            ),
            (
                "could not verify updated page pixels: capture timed out; reload to retry",
                "browser failed: could not verify updated page pixels: capture timed out; reload to retry",
                "更新後のページ表示を確認できませんでした: capture timed out。再読み込みして再試行してください",
            ),
        ];

        for (error, english, japanese) in cases {
            let status = cmux_tui_core::BrowserStatus::Failed(error.to_string());
            let failure = status.failure().expect("failed status");
            assert_eq!(catalog_for_locale("en_US.UTF-8").browser.failure_message(failure), english);
            assert_eq!(
                catalog_for_locale("ja_JP.UTF-8").browser.failure_message(failure),
                japanese
            );
        }
    }

    #[test]
    fn browser_control_failures_are_localized_at_the_ui_boundary() {
        assert_eq!(
            catalog_for_locale("en_US.UTF-8")
                .browser
                .control_failed("browser panes are not supported over attach yet"),
            "browser command failed: browser panes are not supported over attach yet"
        );
        assert_eq!(
            catalog_for_locale("ja_JP.UTF-8")
                .browser
                .control_failed("browser panes are not supported over attach yet"),
            "ブラウザ操作に失敗しました: browser panes are not supported over attach yet"
        );
    }

    #[test]
    fn workspace_port_provider_actions_use_localized_labels() {
        assert_eq!(
            catalog().sidebar.provider_action_label(provider_action_id::LIST_WORKSPACE_PORTS),
            Some(catalog().sidebar.action_list_workspace_ports)
        );
        assert_eq!(
            catalog().sidebar.provider_action_field_label(
                provider_action_id::MAKE_WORKSPACE_PORT_PUBLIC,
                "port"
            ),
            Some(catalog().sidebar.action_workspace_port)
        );
        assert_eq!(catalog().sidebar.provider_action_label("external.action"), None);
    }

    #[test]
    fn foreign_viewport_hints_are_neutral_and_stack_backed() {
        let english = ENGLISH.foreign_viewport.hint(12, 5).expect("English hint fits inline");
        assert_eq!(english.as_str(), "terminal grid (12x5)");
        assert_eq!(english.bytes.len(), 64);
        assert_eq!(ENGLISH.foreign_viewport.hint_width(12, 5), 20);

        let japanese = JAPANESE.foreign_viewport.hint(12, 5).expect("Japanese hint fits inline");
        assert_eq!(japanese.as_str(), "端末グリッド (12x5)");
        assert_eq!(japanese.bytes.len(), 64);
        assert_eq!(JAPANESE.foreign_viewport.hint_width(12, 5), 19);
    }
}
