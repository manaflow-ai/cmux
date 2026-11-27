//! Frontend presentation snapshot types: focus, resize, viewport and the full
//! presentation snapshot that the app journals, plus journal event ids.

use cmux_tui_core::FrontendFocusTarget;

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct FrontendFocusSnapshot {
    pub(super) target: FrontendFocusTarget,
    pub(super) workspace_id: Option<cmux_tui_core::resource::WorkspacePublicId>,
    pub(super) screen_id: Option<cmux_tui_core::resource::ScreenPublicId>,
    pub(super) pane_id: Option<cmux_tui_core::resource::PanePublicId>,
    pub(super) tab_id: Option<cmux_tui_core::resource::TabPublicId>,
    pub(super) content_id: Option<cmux_tui_core::resource::ContentPublicId>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct FrontendResizeSnapshot {
    pub(super) cols: u16,
    pub(super) rows: u16,
    pub(super) cell_width: u16,
    pub(super) cell_height: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct FrontendViewportSnapshot {
    pub(super) screen_id: Option<cmux_tui_core::resource::ScreenPublicId>,
    pub(super) offset: u64,
    pub(super) target: u64,
    pub(super) settled: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct FrontendPresentationSnapshot {
    pub(super) focus: FrontendFocusSnapshot,
    pub(super) resize: FrontendResizeSnapshot,
    pub(super) viewport: FrontendViewportSnapshot,
}

pub(super) fn frontend_journal_event_id() -> String {
    format!("event_frontend_{}", uuid::Uuid::new_v4().simple())
}
