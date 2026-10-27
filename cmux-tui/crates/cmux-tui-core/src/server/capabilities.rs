//! The capabilities `identify` advertises: the static set this daemon
//! always serves, plus the ones a binary installs at startup.

use super::*;

/// Verified app registrations may include the `agent_cli` family.
#[cfg(unix)]
const AGENT_CLI_APP_PROVIDER_CAPABILITY: &str = "agent-cli-app-provider-v1";

/// A personal workspace's own remote-localhost choice: `remote_localhost`
/// on `set-personal-workspace` and the personal workspace rows.
pub const PERSONAL_REMOTE_LOCALHOST_CAPABILITY: &str = "personal-remote-localhost-v1";

/// A pinned column may be a screen's only column (the Home dock with nothing
/// beside it): `move-tab-to-column` with a pinned `dock` makes it from a
/// screen's only tab without a `respawn`, and closing the last column beside
/// it leaves the pinned column alone instead of being refused.
pub const PINNED_DOCK_ALONE_CAPABILITY: &str = "pinned-dock-alone-v1";

/// `identify`'s capabilities: [`always_identified`] plus `cloud-conversations-v1`
/// and `cloud-lease-app-only-v1` when the binary installed a cloud transport, `history-search-v1` when it
/// installed the search index,
/// `terminal-reaper-active-v1` while the unplaced-terminal reaper runs, and
/// `daemon-build-v1` when the binary installed its build identity.
pub(super) fn identify_capabilities(mux: &Mux) -> Vec<&'static str> {
    let mut capabilities = always_identified();
    if mux.cloud_conversations().is_some() {
        capabilities.push(cloud_conversations::CAPABILITY);
        capabilities.push(cloud_conversations::APP_ONLY_LEASE_CAPABILITY);
        capabilities.push(cloud_conversations::WS_CLOUD_CAPABILITY);
        capabilities.push(cloud_conversations::CLOUD_RUNS_CAPABILITY);
        capabilities.push(cloud_conversations::CLOUD_LIVE_CAPABILITY);
        capabilities.push(cloud_conversations::CLOUD_TYPING_CAPABILITY);
        capabilities.push(cloud_conversations::CLOUD_PRESENCE_CAPABILITY);
        capabilities.push(cloud_attachments::CAPABILITY);
        capabilities.push(cloud_conversations::SELFHOST_CAPABILITY);
    }
    if mux.host_replica().is_some_and(|replica| replica.running()) {
        capabilities.push(cloud_host_replica::CAPABILITY);
    }
    if mux.serves_ws_listen() {
        capabilities.push(WS_LISTEN_CAPABILITY);
        capabilities.push(WS_LISTEN_ORIGINS_CAPABILITY);
    }
    if mux.history_search().is_some() {
        capabilities.push(history_search::HISTORY_SEARCH_CAPABILITY);
    }
    #[cfg(unix)]
    if mux.serves_agent_session_attach() {
        capabilities.push(AGENT_SESSION_ATTACH_CAPABILITY);
        capabilities.push(agent_session_attach::AGENT_SESSION_PRESENCE_CAPABILITY);
        capabilities.push(agent_inventory::CAPABILITY);
        capabilities.push(agent_inventory::OWNER_CAPABILITY);
        capabilities.push(agent_inventory::REFRESH_CAPABILITY);
        capabilities.push(agent_inventory::watch::CAPABILITY);
        capabilities.push(agent_inventory::watch::FENCED_CAPABILITY);
        capabilities.push(agent_inventory::watch::ADMISSION_CAPABILITY);
        capabilities
            .push(agent_session_attach::agent_session_observe::AGENT_SESSION_OBSERVE_CAPABILITY);
        capabilities
            .push(agent_session_attach::agent_session_children::AGENT_SESSION_CHILDREN_CAPABILITY);
    }
    #[cfg(unix)]
    if mux.serves_agent_session_start() {
        capabilities.push(AGENT_SESSION_START_CAPABILITY);
        capabilities.push(AGENT_SESSION_TRUST_CAPABILITY);
        capabilities.push(AGENT_SESSION_START_KEYED_REASON_CAPABILITY);
    }
    #[cfg(unix)]
    if mux.serves_agent_update() {
        capabilities.push(agent_transfer::agent_update::AGENT_UPDATE_CAPABILITY);
        capabilities.push(agent_transfer::agent_update::AGENT_UPDATE_OWNER_CAPABILITY);
    }
    #[cfg(unix)]
    if mux.serves_agent_transfer() {
        capabilities.push(agent_transfer::AGENT_TRANSFER_CAPABILITY);
    }
    #[cfg(unix)]
    if mux.on_cloud_host() {
        capabilities.push(agent_transfer::access_requests::ACCESS_REQUEST_CAPABILITY);
    }
    if mux.terminal_reaper_running() {
        capabilities.push(TERMINAL_REAPER_ACTIVE_CAPABILITY);
    }
    if daemon_build::installed() {
        capabilities.push(DAEMON_BUILD_CAPABILITY);
    }
    if crate::chief_brains::taken().is_some() {
        capabilities.push(chief_control::CAPABILITY);
    }
    #[cfg(debug_assertions)]
    capabilities
        .retain(|capability| !test_hidden_capabilities().iter().any(|hidden| hidden == capability));
    capabilities
}

/// What `identify` advertises on every daemon this binary starts here, however
/// it was started: the static set plus the ones it always adds on this
/// platform. The ones that depend on what the daemon installs at startup
/// (cloud transport, WebSocket listener, search index, agent sessions, the
/// reaper, build identity, a Chief) are [`identify_capabilities`]'s alone.
fn always_identified() -> Vec<&'static str> {
    let mut capabilities = advertised_capabilities(cfg!(unix));
    capabilities.push("machine-identity-v1");
    // Receipts can outlive the acpmux configuration that prepared them.
    #[cfg(unix)]
    capabilities.push(agent_cli_job::CAPABILITY);
    #[cfg(unix)]
    capabilities.push(agent_cli_job::RESOLVE_CAPABILITY);
    #[cfg(unix)]
    capabilities.push(agent_cli_intents::CAPABILITY);
    capabilities.push(activity::CAPABILITY);
    capabilities.push(page_credential::PAGE_CREDENTIAL_CAPABILITY);
    capabilities.push(page_credential::SCOPED_PAGE_CREDENTIAL_CAPABILITY);
    #[cfg(unix)]
    capabilities.push(tab_restart::CAPABILITY);
    #[cfg(unix)]
    capabilities.push(tab_restart::KEPT_LAYOUT_CAPABILITY);
    #[cfg(unix)]
    capabilities.push(tab_park::CAPABILITY);
    #[cfg(unix)]
    capabilities.push(AGENT_CLI_APP_PROVIDER_CAPABILITY);
    #[cfg(unix)]
    capabilities.push(crate::apps::AGENT_INVENTORY_INVALIDATION_CAPABILITY);
    #[cfg(unix)]
    capabilities.push(client_registry::machine_catalog::CAPABILITY);
    capabilities
}

/// `cmux-tui __daemon-capabilities [--json]`: `always_identified`, sorted, with no
/// daemon running. Every daemon this binary starts beside the same files (the
/// app bundle's `bin/`, where `apps-v1` follows `cmux-app-host`) advertises at
/// least these in `identify`. The app bundle records them in
/// `Contents/Resources/bin/daemon-capabilities.json`
/// (scripts/cmux-next/write-daemon-capabilities.sh) for the web pages, which
/// update apart from the app.
pub fn static_capabilities() -> Vec<&'static str> {
    let mut capabilities = always_identified();
    capabilities.sort_unstable();
    capabilities.dedup();
    capabilities
}

/// Test seam, debug builds only: `CMUX_TEST_DAEMON_HIDE_CAPABILITIES` (a
/// comma list, read once) names capabilities `identify` leaves out, so a
/// journey can stand this daemon in for an older build that lacks them
/// (cmux link's machine gate, cx-rppd.13). Release builds advertise all.
#[cfg(debug_assertions)]
fn test_hidden_capabilities() -> &'static [String] {
    static HIDDEN: std::sync::OnceLock<Vec<String>> = std::sync::OnceLock::new();
    HIDDEN.get_or_init(|| {
        std::env::var("CMUX_TEST_DAEMON_HIDE_CAPABILITIES")
            .unwrap_or_default()
            .split(',')
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .map(str::to_owned)
            .collect()
    })
}

/// cx-3r9mt: the daemon capabilities this build serves on any machine, for
/// the remote update rule (`cmux_remote::update_need`, `remote-probe`'s
/// `daemon_capabilities`). The static set without the ones a host decides
/// (apps, file ops, browser runtime, image paste, the clear-history fallback,
/// and every capability `identify` adds at runtime), so the same source gives
/// the same set on a Mac, a Linux machine and Windows. A capability never
/// leaves this set once shipped (keep a retired name listed): a build without
/// it is not comparable with older ones, which stops their automatic updates.
pub fn build_capabilities() -> Vec<&'static str> {
    let host_dependent = [crate::apps::CAPABILITY, crate::apps::CANCEL_REQUEST_CAPABILITY];
    let mut capabilities = advertised_capabilities(false);
    capabilities.retain(|capability| !host_dependent.contains(capability));
    #[cfg(unix)]
    capabilities.retain(|capability| {
        *capability != crate::fs_ops::FS_CAPABILITY && *capability != BROWSER_RUNTIME_CAPABILITY
    });
    #[cfg(any(target_os = "linux", target_os = "android", target_vendor = "apple"))]
    capabilities.retain(|capability| *capability != crate::image_paste::CAPABILITY);
    capabilities.sort_unstable();
    capabilities.dedup();
    capabilities
}

pub(super) fn advertised_capabilities(
    bounded_clear_history_fallback_writes: bool,
) -> Vec<&'static str> {
    let mut capabilities = vec![
        crate::resource_api::MACHINE_CATALOG_READ_CAPABILITY,
        ATTACH_INITIAL_SIZE_CAPABILITY,
        "attach-identity-v1",
        crate::terminal_activity::CAPABILITY,
        split_kind::SPLIT_CLIENT_KEYS_CAPABILITY,
        split_kind::SPLIT_CLIENT_SPLIT_ID_CAPABILITY,
        creating_input::TERMINAL_INPUT_WHILE_CREATING_CAPABILITY,
        cmd_terminal_io::SEND_EXPECT_FOREGROUND_CAPABILITY,
        cmd_terminal_io::SEND_EXPECT_AGENT_CAPABILITY,
        WORKSPACE_REGISTRY_CAPABILITY,
        DAEMON_HANDOFF_FORCE_CAPABILITY,
        GUARDED_BROWSER_POINTER_CAPABILITY,
        VIEWPORT_SPLITS_CAPABILITY,
        VIEWPORT_COLUMN_RESIZE_CAPABILITY,
        DOCK_COLUMNS_CAPABILITY,
        LAYOUT_DELTA_CAPABILITY,
        EDGE_DOCKS_CAPABILITY,
        DOCK_COLUMN_ROLE_CAPABILITY,
        PERMANENT_DOCK_CAPABILITY,
        PINNED_DOCK_CAPABILITY,
        PINNED_DOCK_ALONE_CAPABILITY,
        ROWS_CAPABILITY,
        rows::ROW_CLIENT_KEYS_CAPABILITY,
        COLUMN_MOVE_CAPABILITY,
        PANE_BROWSER_KIND_CAPABILITY,
        LAYOUT_UNDO_CAPABILITY,
        TAB_WORKSPACE_MOVE_CAPABILITY,
        CLEAR_HISTORY_CAPABILITY,
        TERMINAL_COMMAND_HISTORY_CAPABILITY,
        SURFACE_SUBSCRIBE_FILTER_CAPABILITY,
        SESSION_JOURNAL_CAPABILITY,
        FRONTEND_JOURNAL_CAPABILITY,
        VIEW_ATTACHMENT_LEASE_CAPABILITY,
        VIEW_ATTACHMENT_DETACH_CAPABILITY,
        SHARED_SIZING_CAPABILITY,
        SIZING_VIEW_DETACH_CAPABILITY,
        SIZE_LEASE_CAPABILITY,
        crate::mux::host_policy::HOST_SIZE_POLICY_CAPABILITY,
        HOST_GRID_VIEW_CAPABILITY,
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
        BROWSER_PROVIDER_NATIVE_HOSTING_CAPABILITY,
        CLIENT_FOCUS_CAPABILITY,
        MACHINE_USAGE_CAPABILITY,
        MACHINE_LISTENING_TCP_CAPABILITY,
        TERMINAL_PORTS_CAPABILITY,
        SERVER_STATS_CAPABILITY,
        TERMINAL_IDLE_CLOSE_CAPABILITY,
        TERMINAL_REAP_CAPABILITY,
        RESUME_COMMAND_CAPABILITY,
        END_TERMINALS_KEEP_LAYOUT_CAPABILITY,
        BATCH_CLOSE_CAPABILITY,
        CLOSE_WORKSPACE_IF_EMPTY_CAPABILITY,
        TERMINAL_RESOURCES_CAPABILITY,
        TERMINAL_PLACEMENT_ENV_CAPABILITY,
        WORKSPACE_GROUPS_CAPABILITY,
        WORKSPACE_METADATA_CAPABILITY,
        AGENT_PRESENCE_CAPABILITY,
        WORKSPACE_PIN_CAPABILITY,
        NOTIFICATION_MARK_UNREAD_CAPABILITY,
        TAB_MARK_UNREAD_CAPABILITY,
        TAB_ATTENTION_CAPABILITY,
        WORKSPACE_DESCRIPTION_CAPABILITY,
        WORKSPACE_STATUS_CAPABILITY,
        WORKSPACE_CREATE_FOCUS_CAPABILITY,
        TAB_METADATA_CAPABILITY,
        FRONTEND_BROWSER_TABS_CAPABILITY,
        FRONTEND_BROWSER_HISTORY_CAPABILITY,
        FRONTEND_BROWSER_TAB_PROFILE_CAPABILITY,
        TAB_DRAG_CAPABILITY,
        TAB_WORKSPACE_NAME_CAPABILITY,
        WORKSPACE_NAME_SOURCE_CAPABILITY,
        TAB_SPLIT_RESPAWN_CAPABILITY,
        TAB_SPLIT_KEEP_FOCUS_CAPABILITY,
        TAB_COLUMN_RESPAWN_CAPABILITY,
        NOTIFICATION_ACK_CAPABILITY,
        TAB_GROUPS_CAPABILITY,
        SAVED_TAB_GROUPS_CAPABILITY,
        TERMINAL_ENV_CAPABILITY,
        LOOPBACK_FORWARD_CAPABILITY,
        SESSION_IDENTITY_CAPABILITY,
        PROFILES_CAPABILITY,
        personal::SESSION_ICON_CAPABILITY,
        PERSONAL_TERMINALS_CAPABILITY,
        BROWSER_PROFILES_CAPABILITY,
        PERSONAL_REMOTE_LOCALHOST_CAPABILITY,
        BOOKMARKS_CAPABILITY,
        BOOKMARK_ICON_CAPABILITY,
        crate::mux::settings::SETTINGS_CAPABILITY,
        crate::mux::keybindings::KEYBINDINGS_CAPABILITY,
        crate::mux::feed_local::FEED_LOCAL_OWNER_CAPABILITY,
        icon_assets::ICON_ASSETS_CAPABILITY,
        conversations::LOCAL_CONVERSATIONS_CAPABILITY,
        conversations::CONVERSATION_SEARCH_CAPABILITY,
        conversations::CONVERSATION_DRAFT_CAPABILITY,
        conversations::CONVERSATION_DRAFT_EVENTS_CAPABILITY,
        conversations::CONVERSATION_THREADS_CAPABILITY,
        conversations::CONVERSATION_THREAD_READ_CAPABILITY,
        conversations::CONVERSATION_TREE_CAPABILITY,
        conversations::CONVERSATION_THREAD_OBJECTS_CAPABILITY,
        conversations::CONVERSATION_INBOX_STATE_CAPABILITY,
        conversations::HOME_INBOX_CAPABILITY,
        conversation_runs::CONVERSATION_RUNS_CAPABILITY,
        conversation_live::CHIEF_LIVE_CAPABILITY,
        conversations::LINK_PREVIEW_CAPABILITY,
        conversations::CONVERSATION_PERSON_CREDENTIALS_CAPABILITY,
        participant_avatars::PARTICIPANT_AVATARS_CAPABILITY,
        conversations::WS_CONVERSATIONS_CAPABILITY,
        crate::conversation_store::attachments::LOCAL_ATTACHMENTS_CAPABILITY,
        conversation_attachments::WS_ATTACHMENTS_CAPABILITY,
        chief_registry_resource::CHIEF_PROFILE_WS_CAPABILITY,
        chief_registry_resource::CHIEF_EVENTS_CAPABILITY,
        chief_registry_resource::CHIEF_PROFILE_ADOPT_CAPABILITY,
        chief_registry_resource::CHIEF_PROFILE_HISTORY_CAPABILITY,
        SCREEN_METADATA_CAPABILITY,
        SCREEN_GROUPS_CAPABILITY,
        NOTIFICATION_SOURCE_CAPABILITY,
        crate::NOTIFICATION_DESKTOP_CAPABILITY,
        crate::NOTIFICATION_REPLY_CAPABILITY,
        TERMINAL_SHELL_ARGS_CAPABILITY,
        TERMINAL_FRONTEND_SHELL_INTEGRATION_CAPABILITY,
        SCREEN_TERMINAL_ENV_CAPABILITY,
        LAUNCH_SNAPSHOT_CAPABILITY,
        STATE_RESOURCES_CAPABILITY,
        WINDOW_RECORDS_CAPABILITY,
        TERMINAL_STATE_CAPABILITY,
        FRONTEND_BROWSER_OWNER_CAPABILITY,
        crate::state::frontend_browser_keys::FRONTEND_BROWSER_TAB_KEYS_CAPABILITY,
        crate::launch_credential::LAUNCH_CREDENTIAL_CAPABILITY,
        crate::state::home_store::WORKSPACE_KIND_CAPABILITY,
        crate::state::app_workspaces::APP_SCREENS_CAPABILITY,
        crate::state::agent_folder::CAPABILITY,
        crate::state::agent_start::CAPABILITY,
        crate::resource_router::OPEN_URL_CAPABILITY,
        crate::state::personal_order::PERSONAL_MIXED_ORDER_CAPABILITY,
        crate::state::personal::WORKSPACE_GROUP_ICON_CAPABILITY,
        crate::state::personal::WORKSPACE_GROUP_PIN_CAPABILITY,
        crate::state::screens::SCREEN_GROUP_ICON_CAPABILITY,
        crate::state::tabs::TAB_GROUP_ICON_CAPABILITY,
        crate::state::sidebar_layout_store::CAPABILITY,
        crate::state::sidebar_doc_store::CAPABILITY,
        crate::state::sidebar_doc_store::HOST_GROUP_OPTOUT_CAPABILITY,
        crate::state::placement_shift::CAPABILITY,
        crate::state::projects_store::CAPABILITY,
        crate::state::projects_store::SOURCES_CAPABILITY,
        crate::state::palette_usage_store::CAPABILITY,
        crate::state::stash_store::CAPABILITY,
        crate::state::stash_store::WORKSPACES_CAPABILITY,
        crate::state::browser_devices::CAPABILITY,
        crate::state::workspace_checklist::CAPABILITY,
        crate::state::browser_devices::FIT_CAPABILITY,
        crate::state::browser_devices::FIT_WIDTH_CAPABILITY,
        crate::browser_profile_ops::CAPABILITY,
        crate::state::layout_bulk::CAPABILITY,
        crate::state::conversation_tabs_store::CONVERSATION_TABS_CAPABILITY,
        crate::state::conversation_tabs_store::AGENT_SESSION_TABS_CAPABILITY,
        crate::state::conversation_tabs_store::PAGE_TABS_CAPABILITY,
        crate::state::conversation_tabs_store::PAGE_TAB_ROUTE_CAPABILITY,
        crate::state::remote_terminal_tabs_store::REMOTE_TERMINAL_TABS_CAPABILITY,
        detached_terminals::DETACHED_TERMINALS_CAPABILITY,
        close_tabs_command::CLOSE_REASON_CAPABILITY,
        conversation_tabs_wire::CONVERSATION_TAB_TRANSACTION_CAPABILITY,
        conversation_tabs_wire::CONVERSATION_TAB_SPLIT_CAPABILITY,
        crate::git_ops::CHECKPOINTS_CAPABILITY,
        crate::git_ops::FILES_SEARCH_CAPABILITY,
        crate::history_ops::CAPABILITY,
        crate::git_ops::FILES_LIST_CAPABILITY,
        crate::git_ops::BRANCHES_CAPABILITY,
        crate::git_ops::COMMIT_CAPABILITY,
        crate::git_ops::PUSH_CAPABILITY,
        crate::git_ops::WORKTREE_CAPABILITY,
        crate::git_ops::WORKTREE_APPLY_CAPABILITY,
        crate::git_ops::WORKTREE_REMOVE_CAPABILITY,
        crate::request_origin::ORIGIN_CLAIM_CAPABILITY,
        crate::request_origin::page_router_table::PAGE_ROUTER_CAPABILITY,
        crate::request_origin::page_router_table::PAGE_EVENTS_CAPABILITY,
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
    #[cfg(unix)]
    capabilities.push(BROWSER_RUNTIME_CAPABILITY);
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

    /// `cmux-tui capabilities` names only what `identify` always serves: a
    /// daemon with nothing installed at startup advertises every one of them.
    #[test]
    fn identify_serves_every_static_capability() {
        let mux = Mux::new_for_test("static-capabilities", SurfaceOptions::default());
        let identified = identify_capabilities(&mux);
        let listed = static_capabilities();
        assert!(listed.contains(&conversations::WS_CONVERSATIONS_CAPABILITY));
        assert!(listed.contains(&page_credential::PAGE_CREDENTIAL_CAPABILITY));
        for capability in &listed {
            assert!(identified.contains(capability), "identify lacks {capability}");
        }
        assert!(listed.windows(2).all(|pair| pair[0] < pair[1]), "sorted and unique: {listed:?}");
        assert!(!listed.contains(&TERMINAL_REAPER_ACTIVE_CAPABILITY), "runtime-only");
    }
}
