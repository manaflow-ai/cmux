//! The tab groups a close takes with it (cx-gzh.31). Each group with a
//! closing tab rides on the closed-history group as an archive naming its
//! closed tabs, so reopening them forms it again: Close Group, a closed
//! screen, pane or workspace, or the last tab of a group.

use std::collections::HashSet;

use rusqlite::{Connection, OptionalExtension};
use serde_json::{Value, json};

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
                    m.tab_id, s.public_id, s.workspace_id
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
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?
    };
    let mut archives: Vec<Value> = Vec::new();
    for (group, pane, name, color, collapsed, icon, tab, screen, workspace) in rows {
        if !(tabs.contains(&tab) || screens.contains(&screen) || workspaces.contains(&workspace))
            || super::closed_history_store::is_ephemeral(connection, &workspace)?
        {
            continue;
        }
        match archives.last_mut().filter(|archive| archive["id"] == group.as_str()) {
            Some(archive) => {
                if let Some(tab_ids) = archive["tab_ids"].as_array_mut() {
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
                "tab_ids": [tab],
            })),
        }
    }
    Ok(archives)
}
