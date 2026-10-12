//! Resource layout operations: pane zoom, split ratio and viewport width through the resource API.

use super::*;

impl Mux {
    pub(super) fn resource_zoom_pane(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        enabled: Option<bool>,
        expected_revision: Option<u64>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "pane.zoom",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let (workspace, screen) =
                    state.screen_of(pane).context("resolved pane has no screen")?;
                let current = &state.workspaces[workspace].screens[screen];
                let mut layout = current.layout_snapshot();
                layout.zoomed_pane = match enabled {
                    Some(true) => Some(pane),
                    Some(false) => None,
                    None if layout.zoomed_pane == Some(pane) => None,
                    None => Some(pane),
                };
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
                    .find(|screen| screen.public_id == durable.public_id)
                    .context("zoomed screen is absent from durable topology")? = durable.clone();
                let value = pane_value_with_zoom(
                    state,
                    topology_pane(&after, &pane_id)?,
                    &after,
                    layout.zoomed_pane == Some(pane),
                )?;
                let screen_value = screen_value(
                    &durable,
                    &after,
                    after.active_workspace.as_ref(),
                    active_screen(&after, &durable.workspace_id),
                )?;
                let result = json!({"pane":pane_id,"screen":durable.public_id});
                let deltas = upserts([
                    ("pane", pane_id.as_str(), value),
                    ("screen", durable.public_id.as_str(), screen_value),
                ]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        let screen = &mut state.workspaces[workspace].screens[screen];
                        let before = screen.layout_snapshot();
                        screen.zoomed_pane = layout.zoomed_pane;
                        if before.zoomed_pane != screen.zoomed_pane {
                            screen.record_layout_change(before, Vec::new(), None);
                        }
                    },
                ))
            },
        )
    }

    pub(super) fn resource_set_split_ratio(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        split_id: &str,
        ratio: f64,
        context: LayoutMutationContext<'_>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let LayoutMutationContext { coalesce, expected_revision, mutation, fingerprint } = context;
        let split_id = SplitPublicId::parse(split_id.to_string()).map_err(anyhow::Error::new)?;
        let ratio = ratio as f32;
        anyhow::ensure!(ratio.is_finite() && 0.0 < ratio && ratio < 1.0, "invalid split ratio");
        self.commit_resource_mutation_plan(
            mutation,
            "pane.split_ratio.set",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let split = state
                    .resource_indexes
                    .splits
                    .get(&split_id)
                    .copied()
                    .with_context(|| format!("unknown split {split_id}"))?;
                let (workspace, screen) =
                    state.screen_of(pane).context("resolved pane has no screen")?;
                let current = &state.workspaces[workspace].screens[screen];
                anyhow::ensure!(
                    current.root.contains_split(split),
                    "split belongs to another screen"
                );
                let mut layout = current.layout_snapshot();
                set_layout_split_ratio(&mut layout, split, ratio)?;
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
                    .find(|screen| screen.public_id == durable.public_id)
                    .context("resized screen is absent from durable topology")? = durable.clone();
                let value = pane_value(state, topology_pane(&after, &pane_id)?, &after)?;
                let screen_value = screen_value(
                    &durable,
                    &after,
                    after.active_workspace.as_ref(),
                    active_screen(&after, &durable.workspace_id),
                )?;
                let result = json!({"pane":pane_id,"screen":durable.public_id});
                let deltas = upserts([
                    ("pane", pane_id.as_str(), value),
                    ("screen", durable.public_id.as_str(), screen_value),
                ]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        let target = &mut state.workspaces[workspace].screens[screen];
                        let before = target.layout_snapshot_for_coalescing_change(coalesce);
                        target.root = layout.root;
                        target.creation_order_auto_layout = layout.creation_order_auto_layout;
                        target.viewport_splits = layout.viewport_splits;
                        target.viewport_base_width = layout.viewport_base_width;
                        target.layout_columns = layout.layout_columns;
                        target.record_prepared_layout_change(before, Vec::new(), coalesce);
                        Self::rebuild_split_screen_index(state);
                    },
                ))
            },
        )
    }

    pub(super) fn resource_set_viewport_width(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        columns: Option<u64>,
        exact_width: Option<f64>,
        context: LayoutMutationContext<'_>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let LayoutMutationContext { coalesce, expected_revision, mutation, fingerprint } = context;
        anyhow::ensure!(
            columns.is_some() ^ exact_width.is_some(),
            "exactly one of columns or width is required"
        );
        let columns =
            columns.map(u16::try_from).transpose().context("viewport columns exceed uint16")?;
        let exact_width = exact_width.map(|width| width as f32);
        if let Some(width) = exact_width {
            anyhow::ensure!(
                width.is_finite()
                    && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
                "viewport width is outside the representable range"
            );
        }
        self.commit_resource_mutation_plan(
            mutation,
            "pane.viewport_width.set",
            fingerprint,
            None,
            expected_revision,
            move |state, registry| {
                let resolved = self
                    .resolve_resource_path_in_state(
                        state,
                        registry,
                        ResourceTarget::Pane,
                        &selectors,
                    )
                    .map_err(anyhow::Error::new)?;
                let pane = resolved.pane.context("pane selector has no live pane")?;
                let pane_id = resolved.path.pane.context("pane selector has no public id")?;
                let (workspace, screen) =
                    state.screen_of(pane).context("resolved pane has no screen")?;
                let current = &state.workspaces[workspace].screens[screen];
                anyhow::ensure!(current.layout_columns_active(), "pane is not in viewport layout");
                let mut layout = current.layout_snapshot();
                let column_index = layout
                    .layout_columns
                    .iter()
                    .position(|column| column.root.contains(pane))
                    .context("pane has no viewport column")?;
                let width = if let Some(width) = exact_width {
                    width
                } else {
                    let current_width = layout.layout_columns[column_index].width;
                    let rendered_columns = state
                        .panes
                        .get(&pane)
                        .and_then(Pane::active_surface)
                        .and_then(|surface| state.surfaces.get(&surface))
                        .map(|surface| surface.size().0)
                        .context("pane has no measurable active surface")?;
                    let viewport_columns = f32::from(rendered_columns.max(1)) / current_width;
                    f32::from(columns.expect("validated columns")) / viewport_columns
                };
                anyhow::ensure!(
                    width.is_finite()
                        && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
                    "viewport width is outside the representable range"
                );
                layout.layout_columns[column_index].width = width;
                // A lone column of rows fills the width again (1.0).
                sync_layout_column_projection(&mut layout);
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
                    .find(|screen| screen.public_id == durable.public_id)
                    .context("viewport screen is absent from durable topology")? = durable.clone();
                let value = pane_value(state, topology_pane(&after, &pane_id)?, &after)?;
                let screen_value = screen_value(
                    &durable,
                    &after,
                    after.active_workspace.as_ref(),
                    active_screen(&after, &durable.workspace_id),
                )?;
                let result = json!({"pane":pane_id,"screen":durable.public_id});
                let deltas = upserts([
                    ("pane", pane_id.as_str(), value),
                    ("screen", durable.public_id.as_str(), screen_value),
                ]);
                Ok(ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        let target = &mut state.workspaces[workspace].screens[screen];
                        let before = target.layout_snapshot_for_coalescing_change(coalesce);
                        target.root = layout.root;
                        target.viewport_splits = layout.viewport_splits;
                        target.viewport_base_width = layout.viewport_base_width;
                        target.layout_columns = layout.layout_columns;
                        target.record_prepared_layout_change(before, Vec::new(), coalesce);
                        Self::rebuild_split_screen_index(state);
                    },
                ))
            },
        )
    }
}
