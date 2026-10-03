//! A screen's stored viewport columns, with their `sticky-columns-v1` flags.

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
    /// `sticky-columns-v1`. Additive: records written before it omit the
    /// field, and it is omitted while the column is not sticky, so an older
    /// daemon still reads every record that has no sticky column. A top or
    /// bottom dock (`edge-docks-v1`) is never serialized here: it lives in
    /// `resource_column_docks` (screen_rows.rs) and is overlaid at load.
    #[serde(default, skip_serializing_if = "not_a_side_flag")]
    pub sticky: Option<crate::model::ColumnSticky>,
}

fn not_a_side_flag(sticky: &Option<crate::model::ColumnSticky>) -> bool {
    sticky.is_none_or(|sticky| sticky.edge.is_band())
}

impl RegistryViewportColumn {
    pub fn new(
        id: SplitPublicId,
        width: f32,
        layout: RegistryLayoutNode,
        auto_layout: Option<Vec<PanePublicId>>,
        sticky: Option<crate::model::ColumnSticky>,
    ) -> Self {
        Self { id, width, layout, auto_layout, sticky }
    }
}
