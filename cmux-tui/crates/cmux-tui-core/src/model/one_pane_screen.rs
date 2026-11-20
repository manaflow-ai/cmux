//! A new screen with one pane.

use super::{Node, Screen};
use crate::resource::ScreenPublicId;
use crate::{PaneId, ScreenId};

impl Screen {
    /// A new screen whose tree is the one pane `pane`. The pane has the focus and the screen follows the default
    /// auto layout. It has no zoom, no viewport columns, no floating pane and no layout history.
    pub(crate) fn with_one_pane(
        id: ScreenId,
        public_id: ScreenPublicId,
        name: Option<String>,
        pane: PaneId,
    ) -> Self {
        Self {
            id,
            public_id,
            name,
            root: Node::Leaf(pane),
            active_pane: pane,
            zoomed_pane: None,
            creation_order_auto_layout: Some(vec![pane]),
            viewport_splits: Default::default(),
            viewport_base_width: None,
            layout_columns: Vec::new(),
            layout_revision: 0,
            floating: Vec::new(),
            layout_undo: Default::default(),
        }
    }
}
