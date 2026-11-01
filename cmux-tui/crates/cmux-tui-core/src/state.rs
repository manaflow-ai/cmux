//! The workspace-store side of the daemon (plans/cmux-next/OWNERSHIP-PRINCIPLES.md):
//! the v2 state operations and their storage. Workspace identity, ephemeral
//! workspaces, the home workspace (`workspace-kind-v1`), the agent folder, workspace status, progress and log, tab pins, tab state and
//! tab groups, saved tab groups, personal workspace groups, placements and
//! rooms, screen metadata and screen groups, closed history, and window
//! records.
//!
//! Nothing in this tree owns a PTY, a terminal host or a session runtime.
//! Handlers reach layout through [`crate::Mux`] methods and commit through
//! [`commit`], which writes the rows, the replay record and the
//! `session.events` batch in one transaction.

pub(crate) mod agent_folder;
#[cfg(test)]
mod agent_folder_tests;
pub(crate) mod agent_home_moves;
pub(crate) mod agent_message_policy;
pub(crate) mod agent_message_release;
pub(crate) mod agent_message_schema;
pub(crate) mod agent_message_store;
pub(crate) mod agent_message_unsend;
pub(crate) mod agent_messages;
pub(crate) mod agent_start;
pub(crate) mod app_workspaces;
pub(crate) mod browser_devices;
#[cfg(test)]
mod browser_devices_data_tests;
pub(crate) mod browser_devices_ops;
#[cfg(test)]
mod churn_tree_events_tests;
#[cfg(test)]
mod closed_browser_history_tests;
pub(crate) mod closed_history;
pub(crate) mod closed_history_delete;
pub(crate) mod closed_history_privacy;
pub(crate) mod closed_history_query;
#[cfg(test)]
mod closed_history_scrub_tests;
pub(crate) mod closed_history_store;
#[cfg(test)]
mod closed_history_tests;
#[cfg(test)]
mod closed_layout_tests;
mod closed_pane_split;
#[cfg(test)]
mod closed_relaunch_tests;
mod closed_screen_layout;
mod closed_tab_groups;
pub(crate) mod command_history_store;
pub(crate) mod commit;
pub(crate) mod conversation_tabs;
pub(crate) mod conversation_tabs_store;
pub(crate) mod ephemeral_moves;
#[cfg(test)]
mod ephemeral_moves_tests;
pub(crate) mod frontend_browser_keys;
#[cfg(test)]
mod group_delete_tests;
#[cfg(test)]
mod incognito_terminal_tests;
#[cfg(test)]
mod group_icon_tests;
#[cfg(test)]
mod group_pin_tests;
pub(crate) mod home;
pub(crate) mod home_store;
#[cfg(test)]
mod home_tests;
pub(crate) mod kept_tab_store;
pub(crate) mod kept_tabs;
#[cfg(test)]
mod last_tab_closes_workspace_tests;
pub(crate) mod layout_bulk;
#[cfg(test)]
mod layout_bulk_tests;
#[cfg(test)]
mod mixed_order_tests;
#[cfg(test)]
mod new_group_top_tests;
#[cfg(test)]
mod new_workspace_top_tests;
pub(crate) mod palette_usage;
pub(crate) mod palette_usage_ops;
#[cfg(test)]
mod palette_usage_protocol_tests;
pub(crate) mod palette_usage_store;
#[cfg(test)]
mod persistent_ids_tests;
pub(crate) mod personal;
pub(crate) mod personal_order;
pub(crate) mod personal_state_store;
pub(crate) mod placement_shift;
mod prelude;
pub(crate) mod project_sources;
pub(crate) mod project_watch;
pub(crate) mod projects;
pub(crate) mod projects_ops;
pub(crate) mod projects_store;
pub(crate) mod remote_terminal_tabs;
pub(crate) mod remote_terminal_tabs_store;
#[cfg(test)]
mod reopen_place_tests;
pub(crate) mod room_delete;
#[cfg(test)]
mod room_delete_amendment_tests;
#[cfg(test)]
mod room_delete_tests;
pub(crate) mod router;
#[cfg(test)]
mod screen_group_icon_tests;
pub(crate) mod screen_state_store;
pub(crate) mod screens;
pub(crate) mod sidebar_doc_legacy;
pub(crate) mod sidebar_doc_ops;
pub(crate) mod sidebar_doc_order;
pub(crate) mod sidebar_doc_store;
pub(crate) mod sidebar_doc_sync;
pub(crate) mod sidebar_doc_workspace_move;
#[cfg(test)]
mod sidebar_doc_workspace_move_tests;
#[cfg(test)]
mod tab_attention_tests;
#[cfg(test)]
mod tab_changed_pin_tests;
pub(crate) use cmux_layout_reducer::sidebar_layout;
pub(crate) mod sidebar_layout_ops;
#[cfg(test)]
mod sidebar_layout_protocol_tests;
pub(crate) mod sidebar_layout_store;
pub(crate) mod stash;
#[cfg(test)]
mod stash_member_tests;
#[cfg(test)]
mod stash_protocol_tests;
#[cfg(test)]
mod stash_restore_tests;
pub(crate) mod stash_router;
pub(crate) mod stash_store;
#[cfg(test)]
mod stash_workspace_tests;
pub(crate) mod stash_workspaces;
pub(crate) mod status_meta;
pub(crate) mod status_owners;
pub(crate) mod store;
#[cfg(test)]
mod tab_group_icon_tests;
pub(crate) mod tab_state_store;
pub(crate) mod tabs;
#[cfg(test)]
mod tests;
pub(crate) mod values;
pub(crate) mod window_record_store;
pub(crate) mod window_records;
pub(crate) mod workspace;
pub(crate) mod workspace_checklist;
pub(crate) mod workspace_checklist_store;
#[cfg(test)]
mod workspace_checklist_tests;
pub(crate) mod workspace_status_store;

pub(crate) use home_store::error_code as home_error_code;
pub(crate) use personal::PersonalChange;
pub(crate) use screens::ScreenChange;
pub(crate) use workspace::WorkspaceStatusChange;
