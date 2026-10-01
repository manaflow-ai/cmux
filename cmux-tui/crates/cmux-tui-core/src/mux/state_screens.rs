//! Screen metadata (pinned, color, icon), screen order, and screen groups
//! (`sgrp_<32 hex>`) as v2 state mutations. Pinned screens sort first and
//! cannot be grouped; group members stay contiguous. A change that reorders
//! screens commits the screen order patch and the state rows together.

use std::collections::{HashMap, HashSet};

use rusqlite::Connection;

use super::state_commit::{StateEffects, state_not_found};
use super::*;
use crate::workspace_registry::screen_state_store::{
    ScreenGroupRecord, ScreenMetaUpdate, delete_screen_group, new_screen_group_id,
    prune_screen_groups, put_screen_group, screen_group, screen_group_members, screen_group_of,
    screen_group_snapshot, screen_pinned, set_screen_group_member, update_screen_meta,
};
use crate::workspace_registry::state_store::{
    StateChanges, StateCommit, state_delete, state_upsert,
};
use crate::workspace_registry::state_values::{fresh_upserts, upserted_value};

/// What a screen change returns.
#[derive(Debug, Clone, PartialEq, Eq)]
enum ScreenResult {
    Screen(String),
    Group(String),
    Groups(Vec<String>),
}

/// State rows a screen change writes with its order patch.
#[derive(Debug, Default)]
struct ScreenEdit {
    meta: Vec<(String, ScreenMetaUpdate)>,
    groups: Vec<ScreenGroupRecord>,
    members: Vec<(String, Option<String>)>,
    touched_screens: Vec<String>,
    touched_groups: Vec<String>,
    result: Option<ScreenResult>,
}

/// One screen order request.
#[derive(Debug, Clone)]
pub(crate) enum ScreenChange {
    Update { selectors: crate::ResourceSelectors, update: ScreenMetaUpdate },
    Move { selectors: crate::ResourceSelectors, index: usize },
    GroupCreate { screens: Vec<String>, name: String, color: String },
    GroupAdd { group: String, screens: Vec<String> },
    GroupRemove { screens: Vec<String> },
}

fn workspace_of(state: &State, screen: &str) -> anyhow::Result<usize> {
    state
        .workspaces
        .iter()
        .position(|workspace| {
            workspace.screens.iter().any(|candidate| candidate.public_id.as_str() == screen)
        })
        .ok_or_else(|| anyhow::Error::new(ResourceError::not_found("screen", screen)))
}

fn screen_order(state: &State, workspace: usize) -> Vec<String> {
    state.workspaces[workspace].screens.iter().map(|screen| screen.public_id.to_string()).collect()
}

/// Pinned screens first, then each group contiguous at its first member,
/// otherwise stable.
fn normalize(
    order: &[String],
    pinned: &HashSet<String>,
    group_of: &HashMap<String, String>,
) -> Vec<String> {
    let mut output = order.iter().filter(|id| pinned.contains(*id)).cloned().collect::<Vec<_>>();
    let mut placed = HashSet::new();
    for id in order.iter().filter(|id| !pinned.contains(*id)) {
        if placed.contains(id) {
            continue;
        }
        match group_of.get(id) {
            Some(group) => {
                for member in order.iter().filter(|candidate| !pinned.contains(*candidate)) {
                    if group_of.get(member) == Some(group) && placed.insert(member.clone()) {
                        output.push(member.clone());
                    }
                }
            }
            None => {
                placed.insert(id.clone());
                output.push(id.clone());
            }
        }
    }
    output
}

/// Reorder `state.workspaces[workspace].screens` to `order`, keeping the
/// active screen.
fn apply_order(state: &mut State, workspace: usize, order: &[String]) {
    let record = &mut state.workspaces[workspace];
    let active =
        record.screens.get(record.active_screen).map(|screen| screen.public_id.to_string());
    record
        .screens
        .sort_by_key(|screen| order.iter().position(|id| id == screen.public_id.as_str()));
    if let Some(active) = active {
        record.active_screen = record
            .screens
            .iter()
            .position(|screen| screen.public_id.as_str() == active)
            .unwrap_or(record.active_screen);
    }
}

/// The pinned flags and group memberships of one workspace's screens after
/// the edit's pending rows.
fn layout_flags(
    connection: &Connection,
    order: &[String],
    edit: &ScreenEdit,
) -> anyhow::Result<(HashSet<String>, HashMap<String, String>)> {
    let mut pinned = HashSet::new();
    let mut group_of = HashMap::new();
    for id in order {
        if screen_pinned(connection, id)? {
            pinned.insert(id.clone());
        }
        if let Some(group) = screen_group_of(connection, id)? {
            group_of.insert(id.clone(), group);
        }
    }
    for (id, update) in &edit.meta {
        match update.pinned {
            Some(true) => {
                pinned.insert(id.clone());
                group_of.remove(id);
            }
            Some(false) => {
                pinned.remove(id);
            }
            None => {}
        }
    }
    for (id, group) in &edit.members {
        match group {
            Some(group) => group_of.insert(id.clone(), group.clone()),
            None => group_of.remove(id),
        };
    }
    Ok((pinned, group_of))
}

fn plan_change(
    mux: &Mux,
    connection: &Connection,
    state: &mut State,
    change: ScreenChange,
    edit: &mut ScreenEdit,
) -> anyhow::Result<()> {
    let (workspace, mut order) = match &change {
        ScreenChange::Update { selectors, .. } | ScreenChange::Move { selectors, .. } => {
            let resolved = mux.resolve_in_state(state, crate::ResourceTarget::Screen, selectors)?;
            let screen = resolved.path.screen.context("screen selector resolved no screen")?;
            let workspace = workspace_of(state, screen.as_str())?;
            (workspace, screen_order(state, workspace))
        }
        ScreenChange::GroupCreate { screens, .. }
        | ScreenChange::GroupAdd { screens, .. }
        | ScreenChange::GroupRemove { screens } => {
            let workspace = workspace_of(state, &screens[0])?;
            for screen in screens {
                anyhow::ensure!(
                    workspace_of(state, screen)? == workspace,
                    "bad request: grouped screens must share one workspace"
                );
            }
            (workspace, screen_order(state, workspace))
        }
    };
    let workspace_id = state.workspaces[workspace].public_id.to_string();
    match change {
        ScreenChange::Update { selectors, update } => {
            let screen = mux
                .resolve_in_state(state, crate::ResourceTarget::Screen, &selectors)?
                .path
                .screen
                .context("screen selector resolved no screen")?
                .to_string();
            if update.pinned == Some(true)
                && let Some(group) = screen_group_of(connection, &screen)?
            {
                edit.touched_groups.push(group);
            }
            edit.meta.push((screen.clone(), update));
            edit.touched_screens.push(screen.clone());
            edit.result = Some(ScreenResult::Screen(screen));
        }
        ScreenChange::Move { selectors, index } => {
            let screen = mux
                .resolve_in_state(state, crate::ResourceTarget::Screen, &selectors)?
                .path
                .screen
                .context("screen selector resolved no screen")?
                .to_string();
            order.retain(|id| *id != screen);
            let index = index.min(order.len());
            order.insert(index, screen.clone());
            edit.touched_screens.push(screen.clone());
            edit.result = Some(ScreenResult::Screen(screen));
        }
        ScreenChange::GroupCreate { screens, name, color } => {
            let group = new_screen_group_id();
            for screen in &screens {
                anyhow::ensure!(
                    !screen_pinned(connection, screen)?,
                    "bad request: pinned screens cannot be grouped"
                );
                if let Some(previous) = screen_group_of(connection, screen)? {
                    edit.touched_groups.push(previous);
                }
                edit.members.push((screen.clone(), Some(group.clone())));
            }
            edit.groups.push(ScreenGroupRecord {
                id: group.clone(),
                workspace_id,
                name,
                color,
                collapsed: false,
            });
            edit.touched_screens.extend(screens);
            edit.touched_groups.push(group.clone());
            edit.result = Some(ScreenResult::Group(group));
        }
        ScreenChange::GroupAdd { group, screens } => {
            let record = screen_group(connection, &group)?
                .ok_or_else(|| state_not_found("screen_group", &group))?;
            anyhow::ensure!(
                record.workspace_id == workspace_id,
                "bad request: grouped screens must share one workspace"
            );
            let members = screen_group_members(connection, &group)?;
            for screen in &screens {
                anyhow::ensure!(
                    !screen_pinned(connection, screen)?,
                    "bad request: pinned screens cannot be grouped"
                );
                if let Some(previous) = screen_group_of(connection, screen)?
                    && previous != group
                {
                    edit.touched_groups.push(previous);
                }
                edit.members.push((screen.clone(), Some(group.clone())));
            }
            // New members land after the group's last member.
            if let Some(last) = members.iter().rev().find(|member| !screens.contains(member)) {
                order.retain(|id| !screens.contains(id));
                let after = order.iter().position(|id| id == last).map_or(order.len(), |at| at + 1);
                order.splice(after..after, screens.iter().cloned());
            }
            edit.touched_screens.extend(screens);
            edit.touched_groups.push(group.clone());
            edit.result = Some(ScreenResult::Group(group));
        }
        ScreenChange::GroupRemove { screens } => {
            let mut touched = Vec::new();
            for screen in &screens {
                let Some(group) = screen_group_of(connection, screen)? else { continue };
                let members = screen_group_members(connection, &group)?;
                // The screen lands right after its former group.
                if let Some(last) = members.iter().rev().find(|member| !screens.contains(member)) {
                    order.retain(|id| id != screen);
                    let after =
                        order.iter().position(|id| id == last).map_or(order.len(), |at| at + 1);
                    order.insert(after, screen.clone());
                }
                edit.members.push((screen.clone(), None));
                if !touched.contains(&group) {
                    touched.push(group);
                }
            }
            edit.touched_screens.extend(screens);
            edit.touched_groups.extend(touched.iter().cloned());
            edit.result = Some(ScreenResult::Groups(touched));
        }
    }
    let (pinned, group_of) = layout_flags(connection, &order, edit)?;
    let order = normalize(&order, &pinned, &group_of);
    apply_order(state, workspace, &order);
    Ok(())
}

fn screen_state_write(edit: ScreenEdit) -> crate::resource_mutation::PlanStateWrite {
    Box::new(move |transaction, result, changes| {
        for group in &edit.groups {
            put_screen_group(transaction, group)?;
        }
        for (screen, update) in &edit.meta {
            update_screen_meta(transaction, screen, update)?;
        }
        for (screen, group) in &edit.members {
            set_screen_group_member(transaction, screen, group.as_deref())?;
        }
        let dropped = prune_screen_groups(transaction)?;
        let fresh = fresh_upserts(transaction, &[], &edit.touched_screens, &[])?;
        changes.extend(fresh.iter().cloned());
        let mut groups = edit.touched_groups.clone();
        for screen in changes
            .iter()
            .filter(|change| change["kind"] == "upsert" && change["resource"] == "screen")
            .filter_map(|change| change["id"].as_str().map(str::to_string))
            .collect::<Vec<_>>()
        {
            if let Some(group) = screen_group_of(transaction, &screen)?
                && !groups.contains(&group)
            {
                groups.push(group);
            }
        }
        for id in &groups {
            match screen_group_snapshot(transaction, id)? {
                Some(snapshot) => changes.push(state_upsert("screen_group", id, snapshot)),
                None => changes.push(state_delete("screen_group", id)),
            }
        }
        for id in dropped.iter().filter(|id| !groups.contains(id)) {
            changes.push(state_delete("screen_group", id));
        }
        *result = match &edit.result {
            Some(ScreenResult::Screen(screen)) => upserted_value(&fresh, "screen", screen)
                .ok_or_else(|| state_not_found("screen", screen))?,
            Some(ScreenResult::Group(group)) => screen_group_snapshot(transaction, group)?
                .ok_or_else(|| state_not_found("screen_group", group))?,
            Some(ScreenResult::Groups(ids)) => {
                let mut values = Vec::new();
                for id in ids {
                    if let Some(snapshot) = screen_group_snapshot(transaction, id)? {
                        values.push(snapshot);
                    }
                }
                Value::Array(values)
            }
            None => result.clone(),
        };
        Ok(())
    })
}

impl Mux {
    /// `screen.update`, `screen.move`, and the screen group mutations that
    /// change membership or order.
    pub(crate) fn state_screen_change(
        self: &Arc<Self>,
        mutation: &WorkspaceMutation,
        operation: &str,
        fingerprint: &Value,
        expected_revision: Option<u64>,
        change: ScreenChange,
    ) -> anyhow::Result<ResourcePatchCommit> {
        if let ScreenChange::Update { update, .. } = &change {
            update.validate()?;
        }
        if let ScreenChange::GroupCreate { name, color, .. } = &change {
            crate::workspace_registry::validate_tab_group_name(name)?;
            crate::workspace_registry::validate_tab_group_color(color)?;
        }
        let mux = Arc::clone(self);
        let commit = self.commit_resource_mutation_plan(
            mutation,
            operation,
            fingerprint,
            None,
            expected_revision,
            |state, registry| {
                let mut projected = state.clone();
                let mut edit = ScreenEdit::default();
                registry.read_state(|connection| {
                    plan_change(&mux, connection, &mut projected, change, &mut edit)
                })?;
                let projection = mux.resource_effect_projection_locked(
                    registry,
                    &mut projected,
                    serde_json::json!({}),
                )?;
                Ok(ResourceMutationPlan::new(
                    projection.patch,
                    projection.result,
                    projection.changes,
                    move |state| *state = projected,
                )
                .with_state_write(screen_state_write(edit)))
            },
        )?;
        if !commit.replayed {
            self.emit(MuxEvent::TreeChanged);
        }
        Ok(commit)
    }

    /// `screen_group.update` and `screen_group.ungroup`: rows only.
    pub(crate) fn state_screen_group_rows(
        &self,
        mutation: &WorkspaceMutation,
        operation: &'static str,
        expected_revision: Option<u64>,
        group: &str,
        update: Option<(Option<String>, Option<String>, Option<bool>)>,
    ) -> anyhow::Result<StateCommit> {
        if let Some((name, color, _)) = &update {
            if let Some(name) = name {
                crate::workspace_registry::validate_tab_group_name(name)?;
            }
            if let Some(color) = color {
                crate::workspace_registry::validate_tab_group_color(color)?;
            }
        }
        let fingerprint = serde_json::json!({
            "operation": operation,
            "screen_group": group,
            "update": update,
        });
        self.commit_state(
            mutation,
            operation,
            &fingerprint,
            expected_revision,
            StateEffects { presentation: false, tree: true },
            |transaction, _| {
                let mut record = screen_group(transaction, group)?
                    .ok_or_else(|| state_not_found("screen_group", group))?;
                let members = screen_group_members(transaction, group)?;
                if members.is_empty() {
                    return Err(state_not_found("screen_group", group));
                }
                match update {
                    Some((name, color, collapsed)) => {
                        if let Some(name) = name {
                            record.name = name;
                        }
                        if let Some(color) = color {
                            record.color = color;
                        }
                        if let Some(collapsed) = collapsed {
                            record.collapsed = collapsed;
                        }
                        put_screen_group(transaction, &record)?;
                        let snapshot = screen_group_snapshot(transaction, group)?
                            .ok_or_else(|| state_not_found("screen_group", group))?;
                        Ok(StateChanges::new(
                            snapshot.clone(),
                            vec![state_upsert("screen_group", group, snapshot)],
                        ))
                    }
                    None => {
                        delete_screen_group(transaction, group)?;
                        let mut changes = fresh_upserts(transaction, &[], &members, &[])?;
                        changes.push(state_delete("screen_group", group));
                        Ok(StateChanges::new(
                            serde_json::json!({"screen_group_id": group, "screen_ids": members}),
                            changes,
                        ))
                    }
                }
            },
        )
    }
}
