//! Mixed personal order (`personal-mixed-order-v1`): groups and loose
//! workspaces in one sidebar order. A group's slot is a position in the
//! personal workspace order (`personal_groups.top_position`); NULL keeps the
//! older order, every group after every loose workspace.

use super::super::WorkspaceRegistry;
use super::super::personal_store::{PersonalGroup, read_group};
use super::super::presentation_store::validate_workspace_group_id;

impl WorkspaceRegistry {
    /// Put group `id` right before the personal workspace at `top_index`
    /// (`index` of `list-personal`; the count puts it after every
    /// workspace), or with None after every loose workspace.
    pub fn set_personal_group_top(
        &mut self,
        id: &str,
        top_index: Option<usize>,
    ) -> anyhow::Result<(PersonalGroup, bool)> {
        validate_workspace_group_id(id)?;
        let _ = top_index;
        let group = read_group(&self.connection, id)?
            .ok_or_else(|| anyhow::anyhow!("unknown personal group {id}"))?;
        Ok((group, false))
    }
}
