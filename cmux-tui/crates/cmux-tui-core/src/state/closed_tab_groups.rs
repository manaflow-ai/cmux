//! The tab groups a close takes with it (cx-gzh.31). Each group with a
//! closing tab rides on the closed-history group as an archive naming its
//! closed tabs, so reopening them forms it again: Close Group, a closed
//! screen, pane or workspace, or the last tab of a group.

use std::collections::HashSet;
use std::sync::Arc;

use anyhow::Context;
use rusqlite::{Connection, OptionalExtension};
use serde_json::{Value, json};

use crate::mux::tab_groups::{group_members, move_members_into, pane_by_public_id, tab_public_id};
use crate::mux::tab_strip::{StripRequest, StripResult};
use crate::mux::*;
use crate::{Actor, SurfaceId};

/// The archives of the live tab groups holding a tab that closes: one in
/// `tabs`, or in a screen of `screens` or a workspace of `workspaces`.
/// Each names only its closing tabs, in strip order, in the fields
/// `record_ungrouped_group` takes. Groups in an ephemeral workspace are
/// never recorded.
pub(super) fn closing_tab_groups(
    connection: &Connection,
    tabs: &HashSet<String>,
    screens: &HashSet<String>,
    workspaces: &HashSet<String>,
) -> anyhow::Result<Vec<Value>> {
    let ready = connection
        .query_row(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'tab_group_members'",
            [],
            |_| Ok(()),
        )
        .optional()?
        .is_some();
    if !ready {
        return Ok(Vec::new());
    }
    let rows = {
        let mut statement = connection.prepare(
            "SELECT g.group_id, g.pane_id, g.name, g.color, g.collapsed, g.icon,
                    m.tab_id, s.public_id, s.workspace_id, g.saved_id
             FROM tab_group_members AS m
             JOIN tab_groups AS g ON g.group_id = m.group_id
             JOIN resource_tabs AS t ON t.public_id = m.tab_id AND t.deleted_revision IS NULL
                                        AND t.pane_id = g.pane_id
             JOIN resource_panes AS p ON p.public_id = t.pane_id
             JOIN resource_screens AS s ON s.public_id = p.screen_id
             ORDER BY g.group_id ASC, t.position ASC",
        )?;
        statement
            .query_map([], |row| {
                Ok((
                    row.get::<_, String>(0)?,
                    row.get::<_, String>(1)?,
                    row.get::<_, String>(2)?,
                    row.get::<_, String>(3)?,
                    row.get::<_, i64>(4)?,
                    row.get::<_, Option<String>>(5)?,
                    row.get::<_, String>(6)?,
                    row.get::<_, String>(7)?,
                    row.get::<_, String>(8)?,
                    row.get::<_, Option<String>>(9)?,
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut archives: Vec<Value> = Vec::new();
    for (group, pane, name, color, collapsed, icon, tab, screen, workspace, saved) in rows {
        if !(tabs.contains(&tab) || screens.contains(&screen) || workspaces.contains(&workspace))
            || super::closed_history_store::is_ephemeral(connection, &workspace)?
        {
            continue;
        }
        match archives.last_mut().filter(|archive| archive["id"] == group.as_str()) {
            Some(archive) => {
                if let Some(tab_ids) = archive.get_mut("tab_ids").and_then(Value::as_array_mut) {
                    tab_ids.push(json!(tab));
                }
            }
            None => archives.push(json!({
                "id": group,
                "pane_id": pane,
                "workspace_id": workspace,
                "name": name,
                "color": color,
                "collapsed": collapsed != 0,
                "icon": icon,
                "saved_id": saved,
                "tab_ids": [tab],
            })),
        }
    }
    Ok(archives)
}

impl Mux {
    /// Add `added` (reopened tabs, each back at its recorded place) to the
    /// live group `id`, which an earlier partial reopen formed. The block
    /// keeps the order of the strip, so the group keeps the order it closed
    /// in.
    pub(super) fn rejoin_closed_tab_group(
        self: &Arc<Self>,
        actor: &Actor,
        id: &str,
        added: Vec<SurfaceId>,
    ) -> anyhow::Result<()> {
        let group_id = id.to_string();
        self.commit_tab_strip_change(
            StripRequest::local(actor, "closed.reopen"),
            None,
            move |mux, state, edit| {
                let record =
                    edit.groups.groups.get(&group_id).cloned().ok_or_else(|| {
                        crate::state::commit::state_not_found("tab_group", &group_id)
                    })?;
                let pane =
                    pane_by_public_id(state, &record.pane_id).context("tab group pane is gone")?;
                let mut members = group_members(state, &edit.groups, &group_id);
                for surface in &added {
                    if !members.contains(surface) {
                        members.push(*surface);
                    }
                }
                let strip = state.panes[&pane].tabs.clone();
                // A tab reopened in another pane goes to the end of the block.
                members.sort_by_key(|surface| {
                    strip.iter().position(|tab| tab == surface).unwrap_or(usize::MAX)
                });
                let anchor = strip
                    .iter()
                    .take_while(|tab| Some(*tab) != members.first())
                    .filter(|tab| !members.contains(tab))
                    .count();
                move_members_into(mux, state, &members, pane, anchor)?;
                for surface in &added {
                    edit.groups.members.insert(tab_public_id(state, *surface)?, group_id.clone());
                }
                // The saved record (if any) still names every closed tab:
                // a partial reopen never rewrites it from the tabs back so far.
                edit.result = StripResult::Group(group_id);
                Ok(())
            },
        )?;
        Ok(())
    }

    /// Link the group `id` a reopen formed again to the saved group `saved`
    /// it was linked to when it closed, unless that saved group is gone or
    /// another live group took it (Reopen Saved Group since the close). The
    /// saved record stays as it is: it names every closed tab, not only the
    /// ones this reopen brought back.
    pub(super) fn relink_saved_tab_group(
        self: &Arc<Self>,
        actor: &Actor,
        id: &str,
        saved: &str,
    ) -> anyhow::Result<()> {
        let (group_id, saved) = (id.to_string(), saved.to_string());
        self.commit_tab_strip_change(
            StripRequest::local(actor, "closed.reopen"),
            None,
            move |mux, _, edit| {
                let exists = mux
                    .presentation_snapshot()
                    .saved_tab_groups
                    .iter()
                    .any(|record| record.id == saved);
                let taken = edit
                    .groups
                    .groups
                    .values()
                    .any(|group| group.saved_id.as_deref() == Some(&saved));
                if exists
                    && !taken
                    && let Some(record) = edit.groups.groups.get_mut(&group_id)
                {
                    record.saved_id = Some(saved);
                }
                edit.result = StripResult::Group(group_id);
                Ok(())
            },
        )?;
        Ok(())
    }
}
