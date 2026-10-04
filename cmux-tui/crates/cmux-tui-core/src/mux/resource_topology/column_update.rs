//! `column.update` (resource API v2): sets a viewport column's dock flag,
//! its width, or both, in one commit. The docked change goes through the
//! same reducer as the JSON-lines `set-column-dock`
//! ([`crate::mux::dock_columns::apply_column_dock`]).

use super::*;
use crate::model::ColumnDock;
use crate::mux::dock_columns::{apply_column_dock, parse_column_dock};

/// The validated fields of one `column.update` request.
struct ColumnUpdate {
    column: SplitPublicId,
    /// `Some(None)` unpins, `Some(Some(_))` pins, `None` leaves the flag.
    dock: Option<Option<ColumnDock>>,
    width: Option<f32>,
}

fn invalid(field: &str, reason: impl Into<String>) -> anyhow::Error {
    anyhow::Error::new(ResourceError::validation_invalid(Some(field), reason))
}

impl ColumnUpdate {
    fn parse(fields: &Map<String, Value>) -> anyhow::Result<Self> {
        let column = SplitPublicId::parse(required_str(fields, "column")?.to_string())
            .map_err(anyhow::Error::new)?;
        let edge = fields.get("edge").and_then(Value::as_str);
        let mode = fields.get("mode").and_then(Value::as_str);
        let dock = match fields.get("dock").and_then(Value::as_bool) {
            Some(dock) => Some(
                parse_column_dock(dock, edge, mode)
                    .map_err(|error| invalid("dock", error.to_string()))?,
            ),
            None if edge.is_some() || mode.is_some() => {
                return Err(invalid("dock", "edge and mode need dock"));
            }
            None => None,
        };
        let width = fields.get("width").and_then(Value::as_f64).map(|width| width as f32);
        if let Some(width) = width
            && !(width.is_finite()
                && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width))
        {
            return Err(invalid("width", "width must be from 0.1 through 1"));
        }
        if dock.is_none() && width.is_none() {
            return Err(invalid("dock", "column.update needs dock or width"));
        }
        Ok(Self { column, dock, width })
    }
}

/// The pure reducer of `column.update`: the screen's layout and the op give
/// the layout after the op (`None` when nothing changes) or the reject. Pane
/// membership, tabs and column order are not touched.
fn reduce_column_update(
    layout: &ScreenLayoutSnapshot,
    index: usize,
    update: &ColumnUpdate,
) -> anyhow::Result<Option<ScreenLayoutSnapshot>> {
    let mut next = layout.clone();
    if let Some(dock) = update.dock {
        apply_column_dock(&mut next.layout_columns, index, dock)
            .map_err(|error| invalid("dock", error.to_string()))?;
    }
    let width_changed =
        update.width.is_some_and(|width| (next.layout_columns[index].width - width).abs() > 0.0);
    if let Some(width) = update.width.filter(|_| width_changed) {
        next.layout_columns[index].width = width;
        sync_layout_column_widths(&mut next);
    }
    let flags_changed = next
        .layout_columns
        .iter()
        .zip(&layout.layout_columns)
        .any(|(after, before)| after.dock != before.dock);
    Ok((flags_changed || width_changed).then_some(next))
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
                let index = state
                    .resource_indexes
                    .splits
                    .get(&update.column)
                    .and_then(|column| {
                        current.layout_columns.iter().position(|candidate| candidate.id == *column)
                    })
                    .ok_or_else(|| invalid("column", "not a viewport column of this screen"))?;
                if update.dock.is_some() {
                    let dock = cmux_layout_reducer::AppAction::Dock;
                    app_rules::refuse_at(state, current.id, dock)?;
                }
                let snapshot = current.layout_snapshot();
                let changed = reduce_column_update(&snapshot, index, &update)?;
                let layout = changed.clone().unwrap_or(snapshot);
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
                        let Some(layout) = changed else {
                            return;
                        };
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
