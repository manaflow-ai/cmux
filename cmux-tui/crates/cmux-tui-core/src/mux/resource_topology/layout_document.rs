//! Resource layout documents: validating, parsing and applying a layout document to a screen.

use super::*;

#[derive(Debug)]
pub(super) struct ParsedResourceLayout {
    pub(super) workspace_index: usize,
    pub(super) screen_index: usize,
    pub(super) snapshot: ScreenLayoutSnapshot,
    pub(super) tab_orders: Vec<(PaneId, Vec<SurfaceId>, usize)>,
}

pub(super) fn validate_layout_apply_intent(
    state: &State,
    resolved: &ResolvedResourceSlots,
    document: &Value,
) -> anyhow::Result<()> {
    let _ = parse_resource_layout_document(state, resolved.workspace, document)?;
    Ok(())
}

pub(super) fn parse_resource_layout_document(
    state: &State,
    resolved_workspace: Option<WorkspaceId>,
    document: &Value,
) -> anyhow::Result<ParsedResourceLayout> {
    let object = document.as_object().context("layout document must be an object")?;
    anyhow::ensure!(object["version"].as_u64() == Some(1), "unsupported layout version");
    let screen_id = ScreenPublicId::parse(
        object["screen_id"].as_str().context("layout omitted screen_id")?.to_string(),
    )
    .map_err(anyhow::Error::new)?;
    let screen_slot = state
        .resource_indexes
        .screens
        .get(&screen_id)
        .copied()
        .with_context(|| format!("layout references unknown screen {screen_id}"))?;
    let (workspace_index, screen_index) =
        find_screen(state, screen_slot).context("layout screen is not live")?;
    anyhow::ensure!(
        resolved_workspace == Some(state.workspaces[workspace_index].id),
        "layout screen belongs to another workspace"
    );
    let current = &state.workspaces[workspace_index].screens[screen_index];
    let active_pane = parse_layout_pane(state, screen_slot, &object["active_pane_id"])?;
    let zoomed_pane = match object.get("zoomed_pane_id") {
        Some(Value::Null) | None => None,
        Some(value) => Some(parse_layout_pane(state, screen_slot, value)?),
    };
    let mut seen_panes = HashSet::new();
    let mut seen_splits = HashSet::new();
    let mut seen_tabs = HashSet::new();
    let mut tab_orders = Vec::new();
    // `rows-v1`: each viewport column's kept row count, checked against the
    // normalized result below.
    let mut kept_rows: Vec<(SplitId, usize)> = Vec::new();
    let root_value = object.get("root").context("layout omitted root")?;
    let (root, layout_columns, viewport_base_width) = if root_value["kind"].as_str()
        == Some("viewport")
    {
        let base_width =
            root_value["base_width"].as_f64().context("viewport omitted base_width")? as f32;
        anyhow::ensure!(
            base_width.is_finite()
                && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&base_width),
            "invalid viewport base width"
        );
        let columns = root_value["columns"]
            .as_array()
            .filter(|columns| !columns.is_empty())
            .context("viewport columns must be non-empty")?;
        let mut parsed = Vec::with_capacity(columns.len());
        let mut changed_dock = false;
        for column in columns {
            let id = parse_layout_split(state, screen_slot, &column["column_id"])?;
            anyhow::ensure!(seen_splits.insert(id), "layout split appears more than once");
            let width = column["width"].as_f64().context("column omitted width")? as f32;
            anyhow::ensure!(
                width.is_finite()
                    && (MIN_VIEWPORT_PANE_WIDTH..=MAX_VIEWPORT_PANE_WIDTH).contains(&width),
                "invalid viewport column width"
            );
            let root = parse_resource_layout_node(
                state,
                screen_slot,
                &column["root"],
                &mut seen_panes,
                &mut seen_splits,
                &mut seen_tabs,
                &mut tab_orders,
            )?;
            // `dock` present: `null` clears the flag, an object sets
            // it. Absent: a column that keeps its id keeps its flag, so a
            // client without `dock-columns-v1` never clears one.
            let kept = current
                .layout_columns
                .iter()
                .find(|column| column.id == id)
                .and_then(|column| column.dock);
            let dock = match column.get("dock") {
                Some(Value::Null) => None,
                Some(value) => Some(
                    serde_json::from_value::<ColumnDock>(value.clone())
                        .context("invalid viewport column dock")?,
                ),
                None => kept,
            };
            changed_dock |= dock.is_some() && dock != kept;
            let rows = match column.get("rows") {
                None => kept_layout_rows(current, id),
                Some(value) => parse_layout_rows(state, screen_slot, current, id, value)?,
            };
            kept_rows.push((id, rows.len()));
            parsed.push(LayoutColumn { dock, rows, ..LayoutColumn::new(id, width, root, None) });
        }
        // A document that sets a new flag must satisfy the docked
        // invariants itself. Flags it keeps or echoes unchanged are
        // repaired by normalization, as when a column is removed.
        anyhow::ensure!(
            !changed_dock || crate::model::dock_columns_are_consistent(&parsed),
            "invalid viewport dock columns"
        );
        anyhow::ensure!(
            parsed.first().is_some_and(|column| column.width == base_width),
            "viewport base_width must equal the first column width"
        );
        let mut snapshot = current.layout_snapshot();
        snapshot.layout_columns = parsed.clone();
        sync_layout_column_projection(&mut snapshot);
        (snapshot.root, parsed, Some(base_width))
    } else {
        // A split-tree document has no columns, so it cannot carry rows.
        rows::refuse_layout_replace(current)?;
        (
            parse_resource_layout_node(
                state,
                screen_slot,
                root_value,
                &mut seen_panes,
                &mut seen_splits,
                &mut seen_tabs,
                &mut tab_orders,
            )?,
            Vec::new(),
            None,
        )
    };
    let current_panes = current.root.pane_ids_vec().into_iter().collect::<HashSet<_>>();
    anyhow::ensure!(
        seen_panes == current_panes,
        "layout pane membership must exactly match the live screen"
    );
    let current_tabs = current_panes
        .iter()
        .flat_map(|pane| {
            state.panes.get(pane).into_iter().flat_map(|pane| pane.tabs.iter().copied())
        })
        .collect::<HashSet<_>>();
    anyhow::ensure!(
        seen_tabs == current_tabs,
        "layout tab membership must exactly match the live screen"
    );
    anyhow::ensure!(seen_panes.contains(&active_pane), "active pane is absent from layout");
    anyhow::ensure!(
        zoomed_pane.is_none_or(|pane| seen_panes.contains(&pane)),
        "zoomed pane is absent from layout"
    );
    let mut snapshot = ScreenLayoutSnapshot {
        root,
        active_pane,
        zoomed_pane,
        creation_order_auto_layout: None,
        viewport_splits: Default::default(),
        viewport_base_width,
        layout_columns,
    };
    if !snapshot.layout_columns.is_empty() {
        sync_layout_column_projection(&mut snapshot);
    }
    // Normalization drops rows whose compat chain the document's tree does
    // not hold: such a document is refused, so no apply loses a row.
    for (column, count) in kept_rows {
        let normalized = snapshot
            .layout_columns
            .iter()
            .find(|candidate| candidate.id == column)
            .map_or(0, |candidate| candidate.rows.len());
        anyhow::ensure!(
            normalized == count,
            "layout rows of column {column} do not match its tree: rows 2..n must be the \
             down splits that chain the column's rows"
        );
    }
    Ok(ParsedResourceLayout { workspace_index, screen_index, snapshot, tab_orders })
}

/// Row 1 id of a column that gets rows from a document: the apply replaces
/// it with a fresh id ([`apply_resource_layout_document`]). Never stored.
const FRESH_ROW_ID: SplitId = SplitId::MAX;

/// The `rows` of a document column (`rows-v1`), top to bottom: `[]` for one
/// row, else two or more `{row_id?, height}`. Row 1's `row_id` is the
/// column's current row 1 id, or omitted (the column's current row 1, else a
/// new id). Rows 2..n name the compat chain splits of the column's `root`;
/// the caller checks that the tree holds that chain.
fn parse_layout_rows(
    state: &State,
    screen: ScreenId,
    current: &Screen,
    column: SplitId,
    value: &Value,
) -> anyhow::Result<Vec<crate::model::LayoutRow>> {
    let entries = value.as_array().context("layout column rows must be an array")?;
    if entries.is_empty() {
        return Ok(Vec::new());
    }
    anyhow::ensure!(
        entries.len() >= 2,
        "layout column rows must be empty or hold two or more rows"
    );
    let current_first = current
        .layout_columns
        .iter()
        .find(|candidate| candidate.id == column)
        .and_then(|candidate| candidate.rows.first())
        .map(|row| row.id);
    let mut rows = Vec::with_capacity(entries.len());
    for (index, entry) in entries.iter().enumerate() {
        let entry = entry.as_object().context("layout row must be an object")?;
        if let Some(field) = entry.keys().find(|key| !matches!(key.as_str(), "row_id" | "height")) {
            anyhow::bail!("layout row has unknown field {field:?}");
        }
        let height = entry
            .get("height")
            .and_then(Value::as_u64)
            .and_then(|height| u16::try_from(height).ok())
            .filter(|height| crate::model::ROW_HEIGHT_PERMILLE.contains(height))
            .context("layout row height must be an integer from 100 to 1000")?;
        let row_id = entry.get("row_id").filter(|value| !value.is_null());
        let id = if index == 0 {
            match row_id {
                None => current_first.unwrap_or(FRESH_ROW_ID),
                Some(value) => {
                    let id = SplitPublicId::parse(
                        value.as_str().context("row id must be a string")?.to_string(),
                    )
                    .map_err(anyhow::Error::new)?;
                    let slot = state.resource_indexes.splits.get(&id).copied();
                    current_first.filter(|first| slot == Some(*first)).with_context(|| {
                        format!("layout row 1 id must be the column's current row 1 id ({id})")
                    })?
                }
            }
        } else {
            let value =
                row_id.with_context(|| format!("layout row {} omitted row_id", index + 1))?;
            let id = parse_layout_split(state, screen, value)?;
            anyhow::ensure!(
                id != column && Some(id) != current_first,
                "layout row {} must name a split of the column's tree",
                index + 1
            );
            id
        };
        anyhow::ensure!(
            rows.iter().all(|row: &crate::model::LayoutRow| row.id != id),
            "layout row appears more than once"
        );
        rows.push(crate::model::LayoutRow::new(id, height));
    }
    Ok(rows)
}

/// The rows of viewport column `column` after a layout document
/// (`rows-v1`) that omits its `rows`: the rows the column with that id has
/// now, with their heights; the ratio of a compat chain split follows those
/// heights.
fn kept_layout_rows(current: &Screen, column: SplitId) -> Vec<crate::model::LayoutRow> {
    current
        .layout_columns
        .iter()
        .find(|candidate| candidate.id == column)
        .map(|candidate| candidate.rows.clone())
        .unwrap_or_default()
}

pub(super) fn parse_resource_layout_node(
    state: &State,
    screen: ScreenId,
    value: &Value,
    seen_panes: &mut HashSet<PaneId>,
    seen_splits: &mut HashSet<SplitId>,
    seen_tabs: &mut HashSet<SurfaceId>,
    tab_orders: &mut Vec<(PaneId, Vec<SurfaceId>, usize)>,
) -> anyhow::Result<Node> {
    Ok(match value["kind"].as_str().context("layout node omitted kind")? {
        "leaf" => {
            let pane = parse_layout_pane(state, screen, &value["pane_id"])?;
            anyhow::ensure!(seen_panes.insert(pane), "pane appears more than once in layout");
            let tab_values = value["tab_ids"]
                .as_array()
                .filter(|tabs| !tabs.is_empty())
                .context("leaf tab_ids must be non-empty")?;
            let mut tabs = Vec::with_capacity(tab_values.len());
            for value in tab_values {
                let tab = parse_layout_tab(state, screen, value)?;
                anyhow::ensure!(seen_tabs.insert(tab), "tab appears more than once in layout");
                tabs.push(tab);
            }
            let active = match value.get("active_tab_id") {
                Some(active) => {
                    let active = parse_layout_tab(state, screen, active)?;
                    tabs.iter()
                        .position(|tab| *tab == active)
                        .context("active_tab_id is absent from leaf tab_ids")?
                }
                None => 0,
            };
            tab_orders.push((pane, tabs, active));
            Node::Leaf(pane)
        }
        "split" => {
            let split = parse_layout_split(state, screen, &value["split_id"])?;
            anyhow::ensure!(seen_splits.insert(split), "split appears more than once in layout");
            let ratio = value["ratio"].as_f64().context("split omitted ratio")? as f32;
            anyhow::ensure!(ratio.is_finite() && 0.0 < ratio && ratio < 1.0, "invalid split ratio");
            let direction = match value["direction"].as_str() {
                Some("horizontal") => SplitDir::Right,
                Some("vertical") => SplitDir::Down,
                _ => anyhow::bail!("invalid layout split direction"),
            };
            Node::Split {
                id: split,
                dir: direction,
                ratio,
                a: Box::new(parse_resource_layout_node(
                    state,
                    screen,
                    &value["first"],
                    seen_panes,
                    seen_splits,
                    seen_tabs,
                    tab_orders,
                )?),
                b: Box::new(parse_resource_layout_node(
                    state,
                    screen,
                    &value["second"],
                    seen_panes,
                    seen_splits,
                    seen_tabs,
                    tab_orders,
                )?),
            }
        }
        "stack" => {
            let panes = value["pane_ids"]
                .as_array()
                .filter(|panes| !panes.is_empty())
                .context("stack pane_ids must be non-empty")?
                .iter()
                .map(|value| parse_layout_pane(state, screen, value))
                .collect::<anyhow::Result<Vec<_>>>()?;
            for pane in &panes {
                anyhow::ensure!(seen_panes.insert(*pane), "pane appears more than once in layout");
                let record = state
                    .panes
                    .get(pane)
                    .with_context(|| format!("layout stack references missing pane {pane}"))?;
                for tab in &record.tabs {
                    anyhow::ensure!(seen_tabs.insert(*tab), "tab appears more than once in layout");
                }
                tab_orders.push((
                    *pane,
                    record.tabs.clone(),
                    record.active_tab.min(record.tabs.len().saturating_sub(1)),
                ));
            }
            let expanded = parse_layout_pane(state, screen, &value["expanded_pane_id"])?;
            Node::stack_with_expanded(panes, expanded)
                .context("expanded pane is absent from stack")?
        }
        other => anyhow::bail!("invalid layout node kind {other:?}"),
    })
}

pub(super) fn parse_layout_pane(
    state: &State,
    screen: ScreenId,
    value: &Value,
) -> anyhow::Result<PaneId> {
    let id = PanePublicId::parse(value.as_str().context("pane id must be a string")?.to_string())
        .map_err(anyhow::Error::new)?;
    let pane = state
        .resource_indexes
        .panes
        .get(&id)
        .copied()
        .with_context(|| format!("layout references unknown pane {id}"))?;
    anyhow::ensure!(
        state.resource_indexes.pane_screen.get(&pane) == Some(&screen),
        "layout pane belongs to another screen"
    );
    Ok(pane)
}

pub(super) fn parse_layout_tab(
    state: &State,
    screen: ScreenId,
    value: &Value,
) -> anyhow::Result<SurfaceId> {
    let id = TabPublicId::parse(value.as_str().context("tab id must be a string")?.to_string())
        .map_err(anyhow::Error::new)?;
    let tab = state
        .resource_indexes
        .tabs
        .get(&id)
        .copied()
        .with_context(|| format!("layout references unknown tab {id}"))?;
    let pane = state.pane_of(tab).context("layout tab has no live pane")?;
    anyhow::ensure!(
        state.resource_indexes.pane_screen.get(&pane) == Some(&screen),
        "layout tab belongs to another screen"
    );
    Ok(tab)
}

pub(super) fn parse_layout_split(
    state: &State,
    screen: ScreenId,
    value: &Value,
) -> anyhow::Result<SplitId> {
    let id = SplitPublicId::parse(value.as_str().context("split id must be a string")?.to_string())
        .map_err(anyhow::Error::new)?;
    let split = state
        .resource_indexes
        .splits
        .get(&id)
        .copied()
        .with_context(|| format!("layout references unknown split {id}"))?;
    let (workspace_index, screen_index) =
        find_screen(state, screen).context("layout screen is not live")?;
    let live = &state.workspaces[workspace_index].screens[screen_index];
    anyhow::ensure!(
        live.root.contains_split(split)
            || live.layout_columns.iter().any(|column| column.id == split),
        "layout split belongs to another screen"
    );
    Ok(split)
}

pub(super) fn apply_resource_layout_document(
    mux: &Mux,
    state: &mut State,
    slots: EffectSlots,
    document: &Value,
) -> anyhow::Result<()> {
    let mut parsed = parse_resource_layout_document(state, slots.workspace, document)?;
    for column in &mut parsed.snapshot.layout_columns {
        if let Some(first) = column.rows.first_mut().filter(|row| row.id == FRESH_ROW_ID) {
            first.id = mux.next_id();
        }
    }
    for (pane, tabs, active) in parsed.tab_orders {
        let record = state.panes.get_mut(&pane).context("layout pane disappeared")?;
        record.tabs = tabs;
        record.active_tab = active.min(record.tabs.len().saturating_sub(1));
        for tab in &record.tabs {
            state.resource_indexes.tab_pane.insert(*tab, pane);
        }
    }
    apply_layout_snapshot(
        &mut state.workspaces[parsed.workspace_index].screens[parsed.screen_index],
        parsed.snapshot,
    );
    Mux::rebuild_split_screen_index(state);
    Ok(())
}
