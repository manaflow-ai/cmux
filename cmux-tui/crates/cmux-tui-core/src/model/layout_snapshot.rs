//! The layout state of a screen that layout undo and a layout document keep and put back.

use std::collections::BTreeMap;

use super::{LayoutColumn, Node, Screen};
use crate::{PaneId, SplitId};

#[derive(Debug, Clone)]
pub(crate) struct ScreenLayoutSnapshot {
    pub root: Node,
    pub active_pane: PaneId,
    pub zoomed_pane: Option<PaneId>,
    pub creation_order_auto_layout: Option<Vec<PaneId>>,
    pub viewport_splits: BTreeMap<SplitId, f32>,
    pub viewport_base_width: Option<f32>,
    pub layout_columns: Vec<LayoutColumn>,
    pub floating: Vec<cmux_layout_reducer::floating_panes::Floating<PaneId>>,
}

impl Screen {
    pub(crate) fn layout_snapshot(&self) -> ScreenLayoutSnapshot {
        ScreenLayoutSnapshot {
            root: self.root.clone(),
            active_pane: self.active_pane,
            zoomed_pane: self.zoomed_pane,
            creation_order_auto_layout: self.creation_order_auto_layout.clone(),
            viewport_splits: self.viewport_splits.clone(),
            viewport_base_width: self.viewport_base_width,
            layout_columns: self.layout_columns.clone(),
            floating: self.floating.clone(),
        }
    }
}
