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
pub(crate) mod closed_history;
pub(crate) mod closed_history_query;
pub(crate) mod closed_history_store;
#[cfg(test)]
mod closed_history_tests;
#[cfg(test)]
mod closed_relaunch_tests;
pub(crate) mod commit;
pub(crate) mod conversation_tabs;
pub(crate) mod conversation_tabs_store;
pub(crate) mod ephemeral_moves;
#[cfg(test)]
mod ephemeral_moves_tests;
pub(crate) mod frontend_browser_keys;
pub(crate) mod home;
pub(crate) mod home_store;
#[cfg(test)]
mod home_tests;
pub(crate) mod kept_tab_store;
pub(crate) mod kept_tabs;
#[cfg(test)]
mod last_tab_closes_workspace_tests;
#[cfg(test)]
mod mixed_order_tests;
pub(crate) mod personal;
pub(crate) mod personal_order;
pub(crate) mod personal_state_store;
mod prelude;
pub(crate) mod room_delete;
#[cfg(test)]
mod room_delete_tests;
pub(crate) mod router;
pub(crate) mod screen_state_store;
pub(crate) mod screens;
pub(crate) mod sidebar_layout;
pub(crate) mod sidebar_layout_ops;
#[cfg(test)]
mod sidebar_layout_protocol_tests;
pub(crate) mod sidebar_layout_store;
pub(crate) mod store;
pub(crate) mod tab_state_store;
pub(crate) mod tabs;
#[cfg(test)]
mod tests;
pub(crate) mod values;
pub(crate) mod window_record_store;
pub(crate) mod window_records;
pub(crate) mod workspace;
pub(crate) mod workspace_status_store;

pub(crate) use home_store::error_code as home_error_code;
pub(crate) use personal::PersonalChange;
pub(crate) use screens::ScreenChange;
pub(crate) use workspace::WorkspaceStatusChange;
