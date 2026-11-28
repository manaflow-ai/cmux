//! Rail selection model: machine rail commands, workspace rail selection and
//! targets, and rail paging and keyboard navigation.

use cmux_tui_core::{Rect, WorkspaceId};
use crossterm::event::{KeyCode, KeyEvent};

use crate::app::layout::SidebarActionTarget;
use crate::machine::{MachineKey, WorkspaceCreationMode};

pub(super) enum MachineRailCommand {
    Activate(MachineKey),
    Rename(MachineKey),
    Delete(MachineKey),
    Purge(MachineKey),
    Create,
    Connect,
    ProviderMenu,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub(crate) enum WorkspaceRailSelection {
    #[default]
    Workspace,
    Recoverable,
    Action(SidebarActionTarget),
}

impl WorkspaceRailSelection {
    pub(crate) fn matches_action(self, target: SidebarActionTarget) -> bool {
        self == Self::Action(target)
    }
}

pub(super) fn workspace_creation_selection(
    mode: Option<WorkspaceCreationMode>,
) -> WorkspaceRailSelection {
    WorkspaceRailSelection::Action(SidebarActionTarget::CreateWorkspace(mode))
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum WorkspaceRailTarget {
    Workspace(WorkspaceId),
    Recoverable(String),
    Action(SidebarActionTarget),
}

pub(super) fn rail_page_size(area: Option<Rect>) -> usize {
    area.map_or(1, |area| usize::from(area.height.saturating_sub(1)).saturating_div(3).max(1))
}

pub(super) fn rail_navigation_index(
    key: &KeyEvent,
    current: usize,
    len: usize,
    page: usize,
) -> Option<usize> {
    if len == 0 {
        return None;
    }
    match key.code {
        KeyCode::Up | KeyCode::Char('k') => Some(current.saturating_sub(1)),
        KeyCode::Down | KeyCode::Char('j') => Some((current + 1).min(len - 1)),
        KeyCode::Home => Some(0),
        KeyCode::End => Some(len - 1),
        KeyCode::PageUp => Some(current.saturating_sub(page)),
        KeyCode::PageDown => Some(current.saturating_add(page).min(len - 1)),
        _ => None,
    }
}
