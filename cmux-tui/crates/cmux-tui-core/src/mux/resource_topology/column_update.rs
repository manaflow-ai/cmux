//! `column.update` (resource API v2): sets a viewport column's sticky flag,
//! its width, or both, in one commit. The sticky change goes through the
//! same reducer as the JSON-lines `set-column-sticky`
//! ([`crate::mux::sticky_columns::apply_column_sticky`]).

use super::*;
use crate::model::ColumnSticky;
use crate::mux::sticky_columns::{apply_column_sticky, parse_column_sticky};

/// The validated fields of one `column.update` request.
struct ColumnUpdate {
    column: SplitPublicId,
    /// `Some(None)` unpins, `Some(Some(_))` pins, `None` leaves the flag.
    sticky: Option<Option<ColumnSticky>>,
    width: Option<f32>,
}

impl ColumnUpdate {
    fn parse(fields: &Map<String, Value>) -> anyhow::Result<Self> {
        let column = SplitPublicId::parse(required_str(fields, "column")?.to_string())
            .map_err(anyhow::Error::new)?;
        let edge = fields.get("edge").and_then(Value::as_str);
        let mode = fields.get("mode").and_then(Value::as_str);
        let sticky = match fields.get("sticky").and_then(Value::as_bool) {
            Some(sticky) => Some(parse_column_sticky(sticky, edge, mode)?),
            None => {
                anyhow::ensure!(edge.is_none() && mode.is_none(), "edge and mode need sticky");
                None
            }
        };
        let width = fields.get("width").and_then(Value::as_f64).map(|width| width as f32);
        if let Some(width) = width {
            anyhow::ensure!(
                width.is_finite()
                    && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
                "column width is outside the representable range"
            );
        }
        anyhow::ensure!(sticky.is_some() || width.is_some(), "column.update needs sticky or width");
        Ok(Self { column, sticky, width })
    }
}

impl Mux {
    pub(super) fn resource_update_column(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        fields: &Map<String, Value>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let update = ColumnUpdate::parse(fields)?;
        self.commit_resource_mutation_plan(
            mutation,
            "column.update",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Screen,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let screen = resolved.screen.context("screen selector has no live screen")?;
                let (workspace, screen) =
                    find_screen(state, screen).context("resolved screen disappeared")?;
                let current = &state.workspaces[workspace].screens[screen];
                let column = state
                    .resource_indexes
                    .splits
                    .get(&update.column)
                    .copied()
                    .with_context(|| format!("unknown column {}", update.column))?;
                let index = current
                    .layout_columns
                    .iter()
                    .position(|candidate| candidate.id == column)
                    .with_context(|| format!("column {} is not on this screen", update.column))?;
                let mut layout = current.layout_snapshot();
                if let Some(sticky) = update.sticky {
                    apply_column_sticky(&mut layout.layout_columns, index, sticky)?;
                }
                if let Some(width) = update.width {
                    layout.layout_columns[index].width = width;
                    sync_layout_column_widths(&mut layout);
                }
                let changed = layout.layout_columns.iter().zip(&current.layout_columns).any(
                    |(after, before)| after.sticky != before.sticky || after.width != before.width,
                );
                let topology = registry.resource_topology_snapshot()?;
                let durable = registry_screen_from_layout(
                    state,
                    workspace,
                    screen,
                    &layout,
                    &topology,
                    current.name.clone(),
                )?;
                let mut after = topology;
                *after
                    .screens
                    .iter_mut()
                    .find(|candidate| candidate.public_id == durable.public_id)
                    .context("column screen is absent from durable topology")? = durable.clone();
                let value = screen_value(
                    &durable,
                    &after,
                    after.active_workspace.as_ref(),
                    active_screen(&after, &durable.workspace_id),
                )?;
                let result =
                    serde_json::json!({"screen": durable.public_id, "column": update.column});
                let deltas = upserts([("screen", durable.public_id.as_str(), value)]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        if !changed {
                            return;
                        }
                        let target = &mut state.workspaces[workspace].screens[screen];
                        let before = target.layout_snapshot();
                        target.root = layout.root;
                        target.viewport_splits = layout.viewport_splits;
                        target.viewport_base_width = layout.viewport_base_width;
                        target.layout_columns = layout.layout_columns;
                        target.record_layout_change(before, Vec::new(), None);
                    },
                ))
            },
        )
    }
}
