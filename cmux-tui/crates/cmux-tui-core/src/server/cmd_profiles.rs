//! Profile, session and personal-group command handlers: create, update,
//! delete, move and follow profiles, put/forget/import session organization,
//! personal groups, and personal workspace/terminal placement. Each function
//! is one `Command` arm of `handle_command_with_cancellation`.

use super::personal;
use crate::Mux;
use serde_json::Value;
use std::sync::Arc;

pub(super) fn list_personal(mux: &Arc<Mux>) -> anyhow::Result<Value> {
    personal::list(mux)
}

#[allow(clippy::too_many_arguments)]
pub(super) fn create_profile(
    mux: &Arc<Mux>,
    name: String,
    profile: Option<String>,
    color: Option<String>,
    icon: Option<String>,
    theme: Option<String>,
    index: Option<usize>,
    browser_profile_id: Option<String>,
    default_session_id: Option<String>,
    defaults: Option<Value>,
    follows: Option<Vec<String>>,
) -> anyhow::Result<Value> {
    personal::create_profile(
        mux,
        crate::workspace_registry::ProfileInput {
            id: profile,
            name,
            color,
            icon,
            theme,
            index,
            browser_profile_id,
            default_session_id,
            defaults,
            follows,
        },
    )
}

#[allow(clippy::too_many_arguments)]
pub(super) fn update_profile(
    mux: &Arc<Mux>,
    profile: String,
    name: Option<String>,
    color: Option<Option<String>>,
    icon: Option<Option<String>>,
    theme: Option<Option<String>>,
    browser_profile_id: Option<Option<String>>,
    default_session_id: Option<Option<String>>,
    defaults: Option<Option<Value>>,
) -> anyhow::Result<Value> {
    personal::update_profile(
        mux,
        &profile,
        crate::workspace_registry::ProfileUpdate {
            name,
            color,
            icon,
            theme,
            browser_profile_id,
            default_session_id,
            defaults,
        },
    )
}

pub(super) fn move_profile(mux: &Arc<Mux>, profile: String, index: usize) -> anyhow::Result<Value> {
    personal::move_profile(mux, &profile, index)
}

pub(super) fn delete_profile(
    mux: &Arc<Mux>,
    client: u64,
    profile: String,
    move_to: Option<String>,
) -> anyhow::Result<Value> {
    personal::delete_profile(mux, client, &profile, move_to.as_deref())
}

pub(super) fn set_profile_follows(
    mux: &Arc<Mux>,
    profile: String,
    session_ids: Vec<String>,
) -> anyhow::Result<Value> {
    personal::set_profile_follows(mux, &profile, &session_ids)
}

pub(super) fn put_session(
    mux: &Arc<Mux>,
    session_id: String,
    machine_name: Option<String>,
    session_name: Option<String>,
    transport: Value,
    capabilities: Option<Value>,
    follow_with: Option<String>,
) -> anyhow::Result<Value> {
    personal::put_session(
        mux,
        &session_id,
        machine_name.as_deref(),
        session_name.as_deref(),
        &transport,
        capabilities.as_ref(),
        follow_with.as_deref(),
    )
}

pub(super) fn forget_session(
    mux: &Arc<Mux>,
    session_id: String,
    force: bool,
) -> anyhow::Result<Value> {
    personal::forget_session(mux, &session_id, force)
}

pub(super) fn import_session_organization(
    mux: &Arc<Mux>,
    session_id: String,
    groups: Vec<Value>,
    workspaces: Vec<Value>,
) -> anyhow::Result<Value> {
    personal::import_session_organization(mux, &session_id, groups, workspaces)
}

pub(super) fn create_personal_group(
    mux: &Arc<Mux>,
    name: String,
    group: Option<String>,
    profile: Option<String>,
    color: Option<String>,
    collapsed: bool,
    index: Option<usize>,
) -> anyhow::Result<Value> {
    personal::create_group(
        mux,
        group,
        profile.as_deref(),
        &name,
        color.as_deref(),
        collapsed,
        index,
    )
}

pub(super) fn update_personal_group(
    mux: &Arc<Mux>,
    group: String,
    name: Option<String>,
    color: Option<Option<String>>,
    collapsed: Option<bool>,
    profile: Option<String>,
) -> anyhow::Result<Value> {
    personal::update_group(mux, &group, name.as_deref(), color, collapsed, profile.as_deref())
}

pub(super) fn delete_personal_group(
    mux: &Arc<Mux>,
    client: u64,
    group: String,
) -> anyhow::Result<Value> {
    personal::delete_group(mux, client, &group)
}

pub(super) fn move_personal_group(
    mux: &Arc<Mux>,
    group: String,
    index: usize,
) -> anyhow::Result<Value> {
    personal::move_group(mux, &group, index)
}

pub(super) fn set_personal_workspace(
    mux: &Arc<Mux>,
    session_id: String,
    workspace_key: String,
    index: Option<usize>,
    group: Option<Option<String>>,
    browser_profile_id: Option<Option<String>>,
    theme: Option<Option<String>>,
) -> anyhow::Result<Value> {
    personal::set_workspace(
        mux,
        &session_id,
        &workspace_key,
        crate::workspace_registry::PersonalWorkspaceUpdate {
            index,
            group,
            browser_profile_id,
            theme,
        },
    )
}

pub(super) fn set_personal_terminal(
    mux: &Arc<Mux>,
    session_id: String,
    terminal_key: String,
    theme: Option<String>,
) -> anyhow::Result<Value> {
    personal::set_terminal(mux, &session_id, &terminal_key, theme.as_deref())
}
