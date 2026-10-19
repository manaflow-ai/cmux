//! Delete and move of personal workspace groups, nest-aware
//! (`workspace-group-nest-v1`): delete moves a group's items up into its
//! parent; move orders a group among its sibling groups.

use rusqlite::{Transaction, params};
use serde_json::json;

use super::super::WorkspaceRegistry;
use super::super::personal_store::{
    PersonalGroup, commit_personal, insertion_final_index, read_group, read_groups, subject,
    write_order,
};
use super::super::presentation_store::validate_workspace_group_id;

impl WorkspaceRegistry {
    /// Delete a group; its workspaces and nested groups move up into its
    /// parent (the top level for a top-level group). Returns its workspaces.
    pub(crate) fn delete_personal_group_in(
        tx: &Transaction<'_>,
        id: &str,
    ) -> anyhow::Result<Vec<(String, String)>> {
        validate_workspace_group_id(id)?;
        anyhow::ensure!(read_group(tx, id)?.is_some(), "unknown personal group {id}");
        let members = {
            let mut statement = tx.prepare(
                "SELECT session_id, workspace_key FROM personal_workspaces WHERE group_id = ?1
                 ORDER BY position ASC",
            )?;
            statement
                .query_map([id], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))?
                .collect::<Result<Vec<_>, _>>()?
        };
        // Its workspaces and nested groups move up into its own parent
        // (none: the top level); nothing closes.
        let parent = read_group(tx, id)?.and_then(|group| group.parent);
        tx.execute(
            "UPDATE personal_workspaces SET group_id = ?2 WHERE group_id = ?1",
            params![id, parent],
        )?;
        tx.execute(
            "UPDATE personal_groups SET parent_id = ?2 WHERE parent_id = ?1",
            params![id, parent],
        )?;
        tx.execute("DELETE FROM personal_groups WHERE group_id = ?1", [id])?;
        let order = read_groups(tx)?.into_iter().map(|group| group.id).collect::<Vec<_>>();
        write_order(tx, "personal_groups", "group_id", &order)?;
        commit_personal(
            tx,
            "personal.group.deleted",
            vec![subject("personal_group", id)],
            &json!({"group_id": id, "ungrouped": members}),
        )?;
        Ok(members)
    }

    pub(crate) fn move_personal_group_in(
        tx: &Transaction<'_>,
        id: &str,
        index: usize,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        let groups = read_groups(tx)?;
        let order = groups.iter().map(|group| group.id.clone()).collect::<Vec<_>>();
        let moving = groups
            .iter()
            .find(|group| group.id == id)
            .ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        // `index` counts among the groups with the same parent
        // (`workspace-group-nest-v1`); with no nested group these are all
        // groups, as before.
        let siblings: Vec<&str> = groups
            .iter()
            .filter(|group| group.parent == moving.parent)
            .map(|group| group.id.as_str())
            .collect();
        let old = siblings.iter().position(|candidate| *candidate == id).unwrap_or(0);
        let new = insertion_final_index(old, index, siblings.len());
        let changed = new != old;
        if changed {
            let order = super::group_parent::sibling_move(&groups, id, new).unwrap_or(order);
            write_order(tx, "personal_groups", "group_id", &order)?;
            commit_personal(
                tx,
                "personal.group.moved",
                vec![subject("personal_group", id)],
                &json!({"group_id": id, "index": new}),
            )?;
        }
        let group =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        Ok((group, changed))
    }
}
