//! A personal workspace group's own marks beyond name, color and collapse:
//! its icon (`workspace-group-icon-v1`) and its pin (`workspace-group-pin-v1`).

use rusqlite::{Transaction, params};
use serde_json::json;

use super::super::WorkspaceRegistry;
use super::super::personal_store::{PersonalGroup, commit_personal, read_group, subject};
use super::super::presentation_store::{validate_presentation_icon, validate_workspace_group_id};

impl WorkspaceRegistry {
    /// Set (`Some`) or clear (`None`) the icon of group `id` inside the
    /// caller's transaction (the v2 `workspace_group.update {icon}`
    /// commit). The icon is the shared icon string: one emoji or an SF
    /// Symbol name.
    pub(crate) fn set_personal_group_icon_in(
        tx: &Transaction<'_>,
        id: &str,
        icon: Option<&str>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        if let Some(icon) = icon {
            validate_presentation_icon(icon)?;
        }
        let before =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        tx.execute("UPDATE personal_groups SET icon = ?2 WHERE group_id = ?1", params![id, icon])?;
        let after =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        let changed = after != before;
        if changed {
            commit_personal(
                tx,
                "personal.group.updated",
                vec![subject("personal_group", id)],
                &json!({"group": after}),
            )?;
        }
        Ok((after, changed))
    }

    /// Pin (save) or unpin group `id` inside the caller's transaction (the
    /// v2 `workspace_group.update {pinned}` commit).
    pub(crate) fn set_personal_group_pinned_in(
        tx: &Transaction<'_>,
        id: &str,
        pinned: bool,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        let before =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        tx.execute(
            "UPDATE personal_groups SET pinned = ?2 WHERE group_id = ?1",
            params![id, i64::from(pinned)],
        )?;
        let after =
            read_group(tx, id)?.ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        let changed = after != before;
        if changed {
            commit_personal(
                tx,
                "personal.group.updated",
                vec![subject("personal_group", id)],
                &json!({"group": after}),
            )?;
        }
        Ok((after, changed))
    }
}
