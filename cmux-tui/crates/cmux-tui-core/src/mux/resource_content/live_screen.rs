//! The registry record of one live screen, including its viewport columns,
//! their `sticky-columns-v1` flags and their `rows-v1` rows.

use super::{pane_public_id, pane_public_ids, registry_layout_node, split_public_id};
use crate::model::State;
use crate::resource::WorkspacePublicId;
use crate::workspace_registry::{RegistryScreen, RegistryViewport, RegistryViewportColumn};

pub(super) fn registry_screen_from_live(
    state: &State,
    workspace_id: &WorkspacePublicId,
    position: usize,
    screen: &crate::model::Screen,
) -> anyhow::Result<RegistryScreen> {
    let layout = registry_layout_node(state, &screen.root)?;
    let viewport = if screen.layout_columns.is_empty() {
        RegistryViewport::default()
    } else {
        RegistryViewport {
            base_width: screen.viewport_base_width,
            columns: screen
                .layout_columns
                .iter()
                .map(|column| {
                    Ok(RegistryViewportColumn::new(
                        split_public_id(state, column.id)?,
                        column.width,
                        registry_layout_node(state, &column.root)?,
                        column
                            .zellij_auto_layout
                            .as_ref()
                            .map(|panes| pane_public_ids(state, panes))
                            .transpose()?,
                        column.sticky,
                    )
                    .with_rows(crate::mux::registry_viewport::registry_rows(state, column)?))
                })
                .collect::<anyhow::Result<Vec<_>>>()?,
        }
    };
    Ok(RegistryScreen {
        public_id: screen.public_id.clone(),
        workspace_id: workspace_id.clone(),
        position,
        name: screen.name.clone(),
        layout,
        active_pane: pane_public_id(state, screen.active_pane)?,
        zoomed_pane: screen.zoomed_pane.map(|pane| pane_public_id(state, pane)).transpose()?,
        auto_layout: screen
            .zellij_auto_layout
            .as_ref()
            .map(|panes| pane_public_ids(state, panes))
            .transpose()?,
        viewport,
    })
}
