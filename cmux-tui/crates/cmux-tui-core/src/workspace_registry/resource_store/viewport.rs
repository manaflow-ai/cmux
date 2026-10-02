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
    /// daemon still reads every record that has no sticky column.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub sticky: Option<crate::model::ColumnSticky>,
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
