//! The capabilities `identify` advertises: the static set this daemon
//! always serves, plus the ones a binary installs at startup.

use super::*;

/// `identify`'s capabilities: the static set plus `cloud-conversations-v1`
/// when the binary installed a cloud transport, and
/// `terminal-reaper-active-v1` while the unplaced-terminal reaper runs.
pub(super) fn identify_capabilities(mux: &Mux) -> Vec<&'static str> {
    let mut capabilities = advertised_capabilities(cfg!(unix));
    capabilities.push(activity::CAPABILITY);
    if mux.cloud_conversations().is_some() {
        capabilities.push(cloud_conversations::CAPABILITY);
    }
    if mux.terminal_reaper_running() {
        capabilities.push(TERMINAL_REAPER_ACTIVE_CAPABILITY);
    }
    capabilities
}

pub(super) fn advertised_capabilities(
    bounded_clear_history_fallback_writes: bool,
) -> Vec<&'static str> {
    let mut capabilities = vec![
        ATTACH_INITIAL_SIZE_CAPABILITY,
        "attach-identity-v1",
        WORKSPACE_REGISTRY_CAPABILITY,
        DAEMON_HANDOFF_FORCE_CAPABILITY,
        GUARDED_BROWSER_POINTER_CAPABILITY,
        VIEWPORT_SPLITS_CAPABILITY,
        VIEWPORT_COLUMN_RESIZE_CAPABILITY,
        DOCK_COLUMNS_CAPABILITY,
        EDGE_DOCKS_CAPABILITY,
        DOCK_COLUMN_ROLE_CAPABILITY,
        PERMANENT_DOCK_CAPABILITY,
        ROWS_CAPABILITY,
        PANE_BROWSER_KIND_CAPABILITY,
        LAYOUT_UNDO_CAPABILITY,
        TAB_WORKSPACE_MOVE_CAPABILITY,
        CLEAR_HISTORY_CAPABILITY,
        TERMINAL_COMMAND_JOURNAL_CAPABILITY,
        SURFACE_SUBSCRIBE_FILTER_CAPABILITY,
        SESSION_JOURNAL_CAPABILITY,
        FRONTEND_JOURNAL_CAPABILITY,
        VIEW_ATTACHMENT_LEASE_CAPABILITY,
        VIEW_ATTACHMENT_DETACH_CAPABILITY,
        SHARED_SIZING_CAPABILITY,
        SIZING_VIEW_DETACH_CAPABILITY,
        OPEN_DEVICE_KINDS_CAPABILITY,
        TERMINAL_COLOR_OVERRIDES_CAPABILITY,
        TERMINAL_PENDING_SEQUENCE_CAPABILITY,
        terminal_snapshot::TERMINAL_SNAPSHOT_CAPABILITY,
        terminal_snapshot::TERMINAL_SNAPSHOT_HISTORY_CAPABILITY,
        terminal_snapshot::TERMINAL_SNAPSHOT_LOCAL_HISTORY_CAPABILITY,
        terminal_snapshot::TERMINAL_SNAPSHOT_IMAGES_CAPABILITY,
        CREATION_RECEIPTS_CAPABILITY,
        CREATION_ATTEMPT_KEYS_CAPABILITY,
        CREATION_SELECTOR_FALLBACKS_CAPABILITY,
        PROVIDER_MANAGED_WORKSPACE_GUARD_CAPABILITY,
        BROWSER_PROVIDER_CAPABILITY,
        CLIENT_FOCUS_CAPABILITY,
        MACHINE_USAGE_CAPABILITY,
        MACHINE_LISTENING_TCP_CAPABILITY,
        SERVER_STATS_CAPABILITY,
        TERMINAL_IDLE_CLOSE_CAPABILITY,
        TERMINAL_REAP_CAPABILITY,
        END_TERMINALS_KEEP_LAYOUT_CAPABILITY,
        BATCH_CLOSE_CAPABILITY,
        TERMINAL_RESOURCES_CAPABILITY,
        TERMINAL_PLACEMENT_ENV_CAPABILITY,
        WORKSPACE_GROUPS_CAPABILITY,
        WORKSPACE_METADATA_CAPABILITY,
        WORKSPACE_PIN_CAPABILITY,
        NOTIFICATION_MARK_UNREAD_CAPABILITY,
        TAB_METADATA_CAPABILITY,
        FRONTEND_BROWSER_TABS_CAPABILITY,
        FRONTEND_BROWSER_HISTORY_CAPABILITY,
        TAB_DRAG_CAPABILITY,
        TAB_WORKSPACE_NAME_CAPABILITY,
        TAB_SPLIT_RESPAWN_CAPABILITY,
        TAB_COLUMN_RESPAWN_CAPABILITY,
        NOTIFICATION_ACK_CAPABILITY,
        TAB_GROUPS_CAPABILITY,
        SAVED_TAB_GROUPS_CAPABILITY,
        TERMINAL_ENV_CAPABILITY,
        LOOPBACK_FORWARD_CAPABILITY,
        SESSION_IDENTITY_CAPABILITY,
        PROFILES_CAPABILITY,
        PERSONAL_TERMINALS_CAPABILITY,
        BROWSER_PROFILES_CAPABILITY,
        BOOKMARKS_CAPABILITY,
        conversations::LOCAL_CONVERSATIONS_CAPABILITY,
        conversations::CONVERSATION_SEARCH_CAPABILITY,
        crate::conversation_store::attachments::LOCAL_ATTACHMENTS_CAPABILITY,
        SCREEN_METADATA_CAPABILITY,
        SCREEN_GROUPS_CAPABILITY,
        NOTIFICATION_SOURCE_CAPABILITY,
        TERMINAL_SHELL_ARGS_CAPABILITY,
        TERMINAL_FRONTEND_SHELL_INTEGRATION_CAPABILITY,
        SCREEN_TERMINAL_ENV_CAPABILITY,
        LAUNCH_SNAPSHOT_CAPABILITY,
        STATE_RESOURCES_CAPABILITY,
        WINDOW_RECORDS_CAPABILITY,
        TERMINAL_STATE_CAPABILITY,
        FRONTEND_BROWSER_OWNER_CAPABILITY,
        crate::state::frontend_browser_keys::FRONTEND_BROWSER_TAB_KEYS_CAPABILITY,
        crate::state::home_store::WORKSPACE_KIND_CAPABILITY,
        crate::state::agent_folder::CAPABILITY,
        crate::state::personal_order::PERSONAL_MIXED_ORDER_CAPABILITY,
        crate::state::personal::WORKSPACE_GROUP_ICON_CAPABILITY,
        crate::state::personal::WORKSPACE_GROUP_PIN_CAPABILITY,
        crate::state::sidebar_layout_store::CAPABILITY,
        crate::state::conversation_tabs_store::CONVERSATION_TABS_CAPABILITY,
        crate::state::conversation_tabs_store::AGENT_SESSION_TABS_CAPABILITY,
        crate::state::conversation_tabs_store::PAGE_TABS_CAPABILITY,
        close_tabs_command::CLOSE_REASON_CAPABILITY,
        conversation_tabs_wire::CONVERSATION_TAB_TRANSACTION_CAPABILITY,
        crate::git_ops::CHECKPOINTS_CAPABILITY,
        crate::git_ops::FILES_SEARCH_CAPABILITY,
        crate::request_origin::ORIGIN_CLAIM_CAPABILITY,
        crate::browser_host::BROWSER_HOST_PROVIDER_CAPABILITY,
        crate::mux::FRONTEND_BROWSER_ACTIVATE_CAPABILITY,
        crate::mux::FRONTEND_BROWSER_INSERT_AFTER_CAPABILITY,
        clipboard_read::CAPABILITY,
        chief_inspect::CAPABILITY,
    ];
    if bounded_clear_history_fallback_writes {
        capabilities.push(CLEAR_HISTORY_KEY_CAPABILITY);
    }
    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    capabilities.push(crate::image_paste::CAPABILITY);
    capabilities.extend(crate::apps::advertised_capabilities());
    #[cfg(unix)]
    capabilities.extend(crate::fs_ops::advertised());
    capabilities
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{SurfaceOptions, start_terminal_reaper};

    /// A client decides from `identify` whether closing a tab may only
    /// detach its terminal: that is safe only while the reaper runs.
    #[test]
    fn identify_advertises_the_reaper_only_while_it_runs() {
        let mux = Mux::new_for_test("reaper-capability", SurfaceOptions::default());
        assert!(identify_capabilities(&mux).contains(&TERMINAL_REAP_CAPABILITY));
        assert!(!identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY));
        let reaper = start_terminal_reaper(&mux).unwrap();
        assert!(identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY));
        reaper.stop();
        assert!(!identify_capabilities(&mux).contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY));
        assert!(identify_capabilities(&mux).contains(&TERMINAL_REAP_CAPABILITY));
    }
}
