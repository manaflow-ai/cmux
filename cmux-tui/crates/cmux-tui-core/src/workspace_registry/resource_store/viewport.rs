//! A screen's stored viewport columns, with their `dock-columns-v1` flags
//! and `rows-v1` rows, and their validation.

use super::*;

#[derive(Debug, Clone, PartialEq, Default, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct RegistryViewport {
    pub base_width: Option<f32>,
    pub columns: Vec<RegistryViewportColumn>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RegistryViewportColumn {
    pub id: SplitPublicId,
    pub width: f32,
    pub layout: RegistryLayoutNode,
    pub auto_layout: Option<Vec<PanePublicId>>,
    /// `dock-columns-v1`. Additive: records written before it omit the
    /// field, and it is omitted while the column is not docked. The stored
    /// key stays `sticky` (its pre-R87 name) until the release pin serves
    /// dock-columns-v1: an older daemon refuses an unknown field and could
    /// not open the session. `dock` is read too, for the later flip. A top
    /// or bottom dock (`edge-docks-v1`) is never serialized here: it lives
    /// in `resource_column_docks` (screen_rows.rs) and is overlaid at load.
    #[serde(default, rename = "sticky", alias = "dock", skip_serializing_if = "not_a_side_flag")]
    pub dock: Option<crate::model::ColumnDock>,
    /// `rows-v1`: empty, or the column's rows top to bottom. Never part of
    /// `viewport_json` (an older build would refuse the unknown field): rows
    /// live in `resource_screen_rows` (screen_rows.rs), overlaid at load.
    #[serde(skip)]
    pub rows: Vec<RegistryRow>,
}

/// One stored row of a viewport column. `id` is row 1's own id, or for rows
/// 2..n the id of the compat chain split above that row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RegistryRow {
    pub id: SplitPublicId,
    pub height: u16,
}

impl RegistryViewport {
    /// One column with two or more rows: columns mode with one column.
    pub fn has_lone_row_column(&self) -> bool {
        self.columns.len() == 1 && self.columns[0].rows.len() >= 2
    }

    /// The form written to `viewport_json`. A lone column with rows is stored
    /// as no viewport at all: the screen layout is already its compat chain,
    /// a build without `rows-v1` reads it as a split tree, and the column
    /// lives in `resource_screen_rows` only.
    pub(super) fn durable(&self) -> RegistryViewport {
        if self.has_lone_row_column() { RegistryViewport::default() } else { self.clone() }
    }
}

fn not_a_side_flag(dock: &Option<crate::model::ColumnDock>) -> bool {
    dock.is_none_or(|dock| dock.edge.is_band())
}

impl RegistryViewportColumn {
    pub fn new(
        id: SplitPublicId,
        width: f32,
        layout: RegistryLayoutNode,
        auto_layout: Option<Vec<PanePublicId>>,
        dock: Option<crate::model::ColumnDock>,
    ) -> Self {
        Self { id, width, layout, auto_layout, dock, rows: Vec::new() }
    }

    pub fn with_rows(mut self, rows: Vec<RegistryRow>) -> Self {
        self.rows = rows;
        self
    }
}

pub(super) fn validate_registry_viewport(
    viewport: &RegistryViewport,
    screen_layout: &RegistryLayoutNode,
    screen_panes: &HashSet<&PanePublicId>,
    screen_splits: &HashSet<&SplitPublicId>,
) -> anyhow::Result<()> {
    let valid_width = |width: f32| {
        width.is_finite()
            && (crate::MIN_VIEWPORT_PANE_WIDTH..=crate::MAX_VIEWPORT_PANE_WIDTH).contains(&width)
    };
    if viewport.columns.is_empty() {
        if viewport.base_width.is_some() {
            anyhow::bail!("viewport metadata has no columns");
        }
        return Ok(());
    }
    if viewport.columns.len() < 2 && !viewport.has_lone_row_column() {
        anyhow::bail!("viewport must have at least two columns when active");
    }
    let base_width =
        viewport.base_width.ok_or_else(|| anyhow::anyhow!("viewport is missing base width"))?;
    if !valid_width(base_width) || viewport.columns[0].width != base_width {
        anyhow::bail!("viewport has invalid base width {base_width}");
    }
    let mut column_ids = HashSet::new();
    let mut internal_splits = HashSet::new();
    let mut column_panes = HashSet::new();
    for (index, column) in viewport.columns.iter().enumerate() {
        if !valid_width(column.width) {
            anyhow::bail!("viewport column has invalid width {}", column.width);
        }
        if !column_ids.insert(&column.id) {
            anyhow::bail!("viewport has duplicate column id {}", column.id);
        }
        if index != 0 && !screen_splits.contains(&column.id) {
            anyhow::bail!("viewport column has unknown projected split {}", column.id);
        }
        let mut panes = HashSet::new();
        let mut splits = HashSet::new();
        validate_layout_node(&column.layout, &mut panes, &mut splits)?;
        if panes.iter().any(|pane| !screen_panes.contains(*pane))
            || splits.iter().any(|split| !screen_splits.contains(*split))
        {
            anyhow::bail!("viewport column references content outside its screen");
        }
        for split in splits {
            if !internal_splits.insert(split) {
                anyhow::bail!("split {split} appears in more than one viewport column");
            }
        }
        if let Some(auto_layout) = &column.auto_layout
            && (auto_layout.len() != panes.len()
                || auto_layout.iter().any(|pane| !panes.contains(pane)))
        {
            anyhow::bail!("viewport column has invalid auto-layout membership");
        }
        for pane in panes {
            if !column_panes.insert(pane) {
                anyhow::bail!("pane {pane} appears in more than one viewport column");
            }
        }
    }
    if &column_panes != screen_panes {
        anyhow::bail!("viewport columns do not cover the screen panes");
    }
    let owners = viewport.columns.iter().skip(1).map(|column| &column.id).collect::<HashSet<_>>();
    if owners.iter().any(|owner| internal_splits.contains(*owner)) {
        anyhow::bail!("viewport boundary owner also appears inside a column");
    }
    let covered_splits =
        owners.iter().copied().chain(internal_splits.iter().copied()).collect::<HashSet<_>>();
    if &covered_splits != screen_splits {
        anyhow::bail!("viewport columns do not cover the screen splits");
    }
    let mut projected = viewport.columns[0].layout.clone();
    let mut width_before = viewport.columns[0].width;
    for column in viewport.columns.iter().skip(1) {
        projected = RegistryLayoutNode::Split {
            split: column.id.clone(),
            direction: "right".into(),
            ratio: width_before / (width_before + column.width),
            first: Box::new(projected),
            second: Box::new(column.layout.clone()),
        };
        width_before += column.width;
    }
    if &projected != screen_layout {
        anyhow::bail!("viewport compatibility layout does not match its ordered columns");
    }
    Ok(())
}

#[cfg(test)]
mod dock_key_tests {
    use super::*;
    use crate::model::{ColumnDock, DockEdge, DockMode};

    fn viewport() -> RegistryViewport {
        let pane = |n: u128| PanePublicId::parse(format!("pane_{n:032x}")).unwrap();
        let split = |n: u128| SplitPublicId::parse(format!("split_{n:032x}")).unwrap();
        let docked = ColumnDock { edge: DockEdge::Left, mode: DockMode::Docked };
        RegistryViewport {
            base_width: None,
            columns: vec![
                RegistryViewportColumn::new(
                    split(1),
                    0.3,
                    RegistryLayoutNode::Leaf { pane: pane(1) },
                    None,
                    Some(docked),
                ),
                RegistryViewportColumn::new(
                    split(2),
                    0.7,
                    RegistryLayoutNode::Leaf { pane: pane(2) },
                    None,
                    None,
                ),
            ],
        }
    }

    /// R87 DOCK-WIRE: the stored key stays `sticky` until the release pin
    /// serves dock-columns-v1, because an older daemon refuses an unknown
    /// field (`deny_unknown_fields`) and could not open the session. Both
    /// keys load as the column's dock flag.
    #[test]
    fn a_registry_viewport_writes_sticky_and_reads_sticky_or_dock() {
        let viewport = viewport();
        let written = serde_json::to_string(&viewport).unwrap();
        assert!(written.contains("\"sticky\":") && !written.contains("\"dock\""), "{written}");
        let loaded: RegistryViewport = serde_json::from_str(&written).unwrap();
        assert_eq!(loaded, viewport);
        let dock_named = written.replace("\"sticky\":", "\"dock\":");
        let loaded: RegistryViewport = serde_json::from_str(&dock_named).unwrap();
        assert_eq!(loaded, viewport);
    }
}
