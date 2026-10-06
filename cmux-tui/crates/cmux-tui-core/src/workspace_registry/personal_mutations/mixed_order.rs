//! Mixed personal order (`personal-mixed-order-v1`): groups and loose
//! workspaces in one sidebar order. A group's slot is a position in the
//! personal workspace order (`personal_groups.top_position`): the group
//! shows right before the first workspace at or after it. NULL keeps the
//! older order, every group after every loose workspace.

use rusqlite::{Connection, params};
use serde_json::json;

use super::super::WorkspaceRegistry;
use super::super::personal_store::{PersonalGroup, commit_personal, read_group, subject};
use super::super::presentation_store::validate_workspace_group_id;

/// Each group's slot as the number of workspaces before it that are not
/// `moving`, read before a reorder of the workspace positions.
pub(super) fn group_slots(
    connection: &Connection,
    moving: Option<(&str, &str)>,
) -> anyhow::Result<Vec<(String, usize)>> {
    let (session, key) = moving.unwrap_or(("", ""));
    let mut statement = connection.prepare(
        "SELECT g.group_id, (SELECT COUNT(*) FROM personal_workspaces AS w
                             WHERE w.position < g.top_position
                               AND NOT (w.session_id = ?1 AND w.workspace_key = ?2))
         FROM personal_groups AS g WHERE g.top_position IS NOT NULL",
    )?;
    let rows = statement.query_map(params![session, key], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })?;
    rows.map(|row| {
        let (id, count) = row?;
        Ok((id, usize::try_from(count)?))
    })
    .collect()
}

/// After a reorder, puts each group back right before the workspace that
/// follows the same number of not-`moving` workspaces (its slot among the
/// others), or after the last one.
pub(super) fn restore_group_slots(
    connection: &Connection,
    slots: &[(String, usize)],
    moving: Option<(&str, &str)>,
) -> anyhow::Result<()> {
    if slots.is_empty() {
        return Ok(());
    }
    let (session, key) = moving.unwrap_or(("", ""));
    let others = {
        let mut statement = connection.prepare(
            "SELECT position FROM personal_workspaces
             WHERE NOT (session_id = ?1 AND workspace_key = ?2) ORDER BY position ASC",
        )?;
        statement
            .query_map(params![session, key], |row| row.get::<_, i64>(0))?
            .collect::<Result<Vec<_>, _>>()?
    };
    let end: i64 = connection.query_row(
        "SELECT COALESCE(MAX(position) + 1, 0) FROM personal_workspaces",
        [],
        |row| row.get(0),
    )?;
    for (id, slot) in slots {
        let top = others.get(*slot).copied().unwrap_or(end);
        connection.execute(
            "UPDATE personal_groups SET top_position = ?2 WHERE group_id = ?1",
            params![id, top],
        )?;
    }
    Ok(())
}

impl WorkspaceRegistry {
    /// Put group `id` right before the personal workspace at `top_index`
    /// (`index` of `list-personal`; the count or more puts it after every
    /// workspace), or with None after every loose workspace.
    pub fn set_personal_group_top(
        &mut self,
        id: &str,
        top_index: Option<usize>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        let tx = self.connection.transaction()?;
        let before =
            read_group(&tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        let top = match top_index {
            None => None,
            Some(index) => Some(tx.query_row(
                "SELECT COALESCE((SELECT position FROM personal_workspaces
                                  ORDER BY position ASC, session_id ASC, workspace_key ASC
                                  LIMIT 1 OFFSET ?1),
                                 (SELECT COALESCE(MAX(position) + 1, 0) FROM personal_workspaces))",
                [i64::try_from(index)?],
                |row| row.get::<_, i64>(0),
            )?),
        };
        tx.execute(
            "UPDATE personal_groups SET top_position = ?2 WHERE group_id = ?1",
            params![id, top],
        )?;
        crate::state::home_store::require_home_first(&tx)?;
        let after =
            read_group(&tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        let changed = after != before;
        if changed {
            commit_personal(
                &tx,
                "personal.group.moved",
                vec![subject("personal_group", id)],
                &json!({"group_id": id, "top_index": after.top_index}),
            )?;
        }
        tx.commit()?;
        Ok((after, changed))
    }
}
