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
                // `floating-panes-v1`: a floating pane is never zoomed, so the request is refused.
                if Screen::zoom_beside_floating_panes(layout.zoomed_pane, &layout.floating)
                    != layout.zoomed_pane
                {
                    return Err(anyhow::Error::new(ResourceError::validation_invalid(
                        Some("enabled"),
                        "a floating pane cannot be zoomed",
                    )));
                }
                let topology = stored_workspace_topology(state, registry, workspace)?;
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
                )
                .keeping_dock_columns())
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
                let keeps = keeps_indexed_structure(current, &layout);
                let topology = stored_workspace_topology(state, registry, workspace)?;
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
                let plan = ResourceMutationPlan::new(
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
                        if !keeps {
                            Self::rebuild_split_screen_index(state);
                        }
                    },
                );
                Ok(size_plan(plan, keeps))
            },
        )
    }

    /// `set-divider-visible` (`split-divider-visibility-v1`): hide or show
    /// one split's divider. It rides `pane.split_ratio.set` with the internal
    /// [`DIVIDER_HIDDEN_FIELD`] in place of a ratio, so the change persists
    /// to the registry and records an undo step as a ratio change does.
    pub(super) fn resource_set_split_divider_hidden(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        split_id: &str,
        hidden: bool,
        context: LayoutMutationContext<'_>,
    ) -> anyhow::Result<ResourcePatchCommit> {
        let LayoutMutationContext { coalesce, expected_revision, mutation, fingerprint } = context;
        let split_id = SplitPublicId::parse(split_id.to_string()).map_err(anyhow::Error::new)?;
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
                let current = state
                    .workspaces
                    .get(workspace)
                    .and_then(|workspace| workspace.screens.get(screen))
                    .context("resolved pane's screen is gone")?;
                anyhow::ensure!(
                    current.root.contains_split(split),
                    "split belongs to another screen"
                );
                let mut layout = current.layout_snapshot();
                set_layout_divider_hidden(&mut layout, split, hidden)?;
                let topology = stored_workspace_topology(state, registry, workspace)?;
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
                    .context("screen is absent from durable topology")? = durable.clone();
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
                        let Some(target) = state
                            .workspaces
                            .get_mut(workspace)
                            .and_then(|workspace| workspace.screens.get_mut(screen))
                        else {
                            return;
                        };
                        let before = target.layout_snapshot_for_coalescing_change(coalesce);
                        target.root = layout.root;
                        target.layout_columns = layout.layout_columns;
                        target.record_prepared_layout_change(before, Vec::new(), coalesce);
                    },
                )
                .keeping_dock_columns())
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
                let keeps = keeps_indexed_structure(current, &layout);
                let topology = stored_workspace_topology(state, registry, workspace)?;
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
                let plan = ResourceMutationPlan::new(
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
                        if !keeps {
                            Self::rebuild_split_screen_index(state);
                        }
                    },
                );
                Ok(size_plan(plan, keeps))
            },
        )
    }
}

/// A `set-layout-sizes` batch that would change nothing: the caller answers ok and commits nothing.
#[derive(Debug)]
pub(in crate::mux) struct LayoutSizesUnchanged;

impl fmt::Display for LayoutSizesUnchanged {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("the layout already has these sizes")
    }
}

impl std::error::Error for LayoutSizesUnchanged {}

impl Mux {
    /// `set-layout-sizes` (R-DAEMON-STATE DESIGN 2.10.1): every value applied, in order, to one layout snapshot of
    /// the screen of `selectors`'s pane with the checks of its single command, then one commit: one durable screen,
    /// one layout revision, one undo entry keyed `coalesce`. A refused value refuses the plan with its typed
    /// [`LayoutSizesError`] (the caller downcasts it); a batch that changes nothing refuses with
    /// [`LayoutSizesUnchanged`].
    pub(in crate::mux) fn resource_set_layout_sizes(
        self: &Arc<Self>,
        selectors: ResourceSelectors,
        values: Vec<LayoutSizeValue>,
        coalesce: Option<LayoutMutationKey>,
        mutation: &WorkspaceMutation,
        fingerprint: &Value,
    ) -> anyhow::Result<ResourcePatchCommit> {
        self.commit_resource_mutation_plan(
            mutation,
            "screen.layout_sizes.set",
            fingerprint,
            None,
            None,
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
                let current = state
                    .workspaces
                    .get(workspace)
                    .and_then(|item| item.screens.get(screen))
                    .context("resolved pane's screen is gone")?;
                let mut layout = current.layout_snapshot();
                let mut changed = false;
                let mut widths_changed = false;
                for (index, value) in values.iter().copied().enumerate() {
                    let (value_changed, is_width) = apply_layout_size_value(
                        state,
                        (workspace, screen),
                        current,
                        &mut layout,
                        index,
                        value,
                    )
                    .map_err(anyhow::Error::new)?;
                    changed |= value_changed;
                    widths_changed |= is_width && value_changed;
                }
                if !changed {
                    return Err(anyhow::Error::new(LayoutSizesUnchanged));
                }
                if widths_changed {
                    // A lone column of rows fills the width again (1.0), as `set-viewport-pane-width` leaves it.
                    sync_layout_column_projection(&mut layout);
                }
                let keeps = keeps_indexed_structure(current, &layout);
                let topology = stored_workspace_topology(state, registry, workspace)?;
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
                let plan = ResourceMutationPlan::new(
                    ResourcePatch { changes: vec![ResourceChange::UpsertScreen(durable)] },
                    result,
                    deltas,
                    move |state| {
                        // The plan resolved this screen under the same lock; it is still there.
                        let Some(target) = state
                            .workspaces
                            .get_mut(workspace)
                            .and_then(|item| item.screens.get_mut(screen))
                        else {
                            return;
                        };
                        let before = target.layout_snapshot_for_coalescing_change(coalesce);
                        target.root = layout.root;
                        target.creation_order_auto_layout = layout.creation_order_auto_layout;
                        target.viewport_splits = layout.viewport_splits;
                        target.viewport_base_width = layout.viewport_base_width;
                        target.layout_columns = layout.layout_columns;
                        target.record_prepared_layout_change(before, Vec::new(), coalesce);
                        if !keeps {
                            Self::rebuild_split_screen_index(state);
                        }
                    },
                );
                Ok(size_plan(plan, keeps))
            },
        )
    }
}

/// The stored subtree of the workspace at `workspace` alone: the screen row that a layout plan writes and the
/// values that it publishes read no row of another workspace.
fn stored_workspace_topology(
    state: &State,
    registry: &WorkspaceRegistry,
    workspace: usize,
) -> anyhow::Result<ResourceTopologySnapshot> {
    let workspace = state.workspaces.get(workspace).context("resolved pane's workspace is gone")?;
    registry.resource_topology_of_scope(std::slice::from_ref(&workspace.public_id))
}

/// What the dock rules and the id indexes read of one viewport column.
#[derive(PartialEq)]
struct IndexedColumn {
    id: SplitId,
    dock: Option<ColumnDock>,
    rows: Vec<SplitId>,
    panes: Vec<PaneId>,
}

/// What the dock rules (`ResourceMutationPlan::stage_checked`) and the id indexes
/// (`Mux::rebuild_split_screen_index`) read of one screen: the splits and the panes of its tree, in order, and
/// its columns. Sizes, divider flags and the zoom are not in it.
#[derive(PartialEq)]
struct IndexedStructure {
    splits: Vec<SplitId>,
    panes: Vec<PaneId>,
    columns: Vec<IndexedColumn>,
}

impl IndexedStructure {
    fn of(root: &Node, columns: &[LayoutColumn]) -> Self {
        fn split_ids(node: &Node, splits: &mut Vec<SplitId>) {
            if let Node::Split { id, a, b, .. } = node {
                splits.push(*id);
                split_ids(a, splits);
                split_ids(b, splits);
            }
        }
        let mut splits = Vec::new();
        split_ids(root, &mut splits);
        let columns = columns
            .iter()
            .map(|column| IndexedColumn {
                id: column.id,
                dock: column.dock,
                rows: column.row_ids().collect(),
                panes: column.root.pane_ids_vec(),
            })
            .collect();
        Self { splits, panes: root.pane_ids_vec(), columns }
    }
}

/// True when `layout` holds the splits, panes and columns of `current`: a size command on a screen whose column
/// projection is consistent. The column projection of a stale screen can take a column away; then this is false.
fn keeps_indexed_structure(current: &Screen, layout: &ScreenLayoutSnapshot) -> bool {
    IndexedStructure::of(&current.root, &current.layout_columns)
        == IndexedStructure::of(&layout.root, &layout.layout_columns)
}

/// A size plan that keeps the indexed structure of its screen declares it, so no dock rule scans the session
/// and the state is not cloned for it. A plan that changes the structure takes the whole check.
fn size_plan(plan: ResourceMutationPlan, keeps: bool) -> ResourceMutationPlan {
    if keeps { plan.keeping_dock_columns() } else { plan }
}

/// One batch value applied to `layout` (of the screen `on`) with the checks its single command makes, the split
/// ratio's implied column width computed from the batch's own earlier values. Returns (changed, a width value).
fn apply_layout_size_value(
    state: &State,
    on: (usize, usize),
    current: &Screen,
    layout: &mut ScreenLayoutSnapshot,
    index: usize,
    value: LayoutSizeValue,
) -> Result<(bool, bool), LayoutSizesError> {
    match value {
        LayoutSizeValue::SplitRatio { split, ratio } => {
            let refused = |error| LayoutSizesError::Ratio { index, error };
            // The clamp keeps a NaN (in-process callers; JSON cannot carry one), and the store cannot persist one.
            // An infinite ratio (JSON `1e39` as f32) clamps below, as `set-split-ratio` clamps it.
            if ratio.is_nan() {
                return Err(LayoutSizesError::NanRatio { index });
            }
            let ratio = clamp_split_ratio(ratio);
            let Some((split_workspace, split_screen, owner)) =
                state.split_screens.get(&split).copied()
            else {
                return Err(refused(LayoutRatioError::UnknownSplit { split }));
            };
            if (split_workspace, split_screen) != on {
                return Err(LayoutSizesError::OtherScreen { index });
            }
            if current.id != owner {
                return Err(refused(LayoutRatioError::UnknownSplit { split }));
            }
            if current.layout_columns.iter().any(|column| column.is_row_split(split)) {
                return Err(refused(LayoutRatioError::RowSplitCompatReadonly { split }));
            }
            if let Some(position) = layout
                .layout_columns
                .iter()
                .position(|column| column.id == split)
                .filter(|position| *position > 0)
            {
                let width_before = layout
                    .layout_columns
                    .get(..position)
                    .unwrap_or_default()
                    .iter()
                    .map(|column| column.width)
                    .sum::<f32>();
                let width = width_before * (1.0 - ratio) / ratio;
                if !width.is_finite()
                    || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
                {
                    return Err(refused(LayoutRatioError::UnrepresentableViewportWidth {
                        split,
                        ratio,
                        width,
                    }));
                }
                if layout.layout_columns.get(position).is_some_and(|column| column.width == width) {
                    return Ok((false, false));
                }
            } else {
                let Some(current_ratio) = layout.root.split_ratio(split) else {
                    return Err(refused(LayoutRatioError::UnknownSplit { split }));
                };
                if current_ratio == ratio {
                    return Ok((false, false));
                }
            }
            set_layout_split_ratio(layout, split, ratio)
                .map_err(|_| refused(LayoutRatioError::UnknownSplit { split }))?;
            Ok((true, false))
        }
        LayoutSizeValue::PaneWidth { pane, width } => {
            let refused = |error| LayoutSizesError::Width { index, error };
            if !width.is_finite()
                || !(MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width)
            {
                return Err(refused(ViewportWidthError::OutOfRange { width }));
            }
            match state.screen_of(pane) {
                None => return Err(refused(ViewportWidthError::PaneNotResizable { pane })),
                Some(pane_screen) if pane_screen != on => {
                    return Err(LayoutSizesError::OtherScreen { index });
                }
                Some(_) => {}
            }
            if layout.layout_columns.is_empty() {
                return Err(refused(ViewportWidthError::PaneNotResizable { pane }));
            }
            let Some(column) =
                layout.layout_columns.iter_mut().find(|column| column.root.contains(pane))
            else {
                return Err(refused(ViewportWidthError::PaneNotResizable { pane }));
            };
            if (column.width - width).abs() < f32::EPSILON {
                return Ok((false, true));
            }
            column.width = width;
            Ok((true, true))
        }
    }
}
