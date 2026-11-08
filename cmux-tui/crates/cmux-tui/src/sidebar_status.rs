//! Agent status for the default sidebar and the tab chips: each agent tab's
//! status, each workspace's rolled-up status and second rail line, and the
//! cross-workspace agents section in attention order.
//!
//! Red stub: the index is always empty.

#![allow(dead_code)]

use std::collections::HashMap;

use cmux_tui_core::{AgentStatus, SurfaceId, WorkspaceId};

use crate::session::{AgentInfo, TreeView};
use crate::sidebar_projection::ProjectionTarget;

/// What the default sidebar and tab chips show about agents.
#[derive(Debug, Default)]
pub(crate) struct SidebarStatus {
    tabs: HashMap<SurfaceId, AgentStatus>,
    workspaces: Vec<WorkspaceStatus>,
    agents: Vec<AgentRow>,
}

/// One workspace row's agent rollup and second line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkspaceStatus {
    pub id: WorkspaceId,
    pub status: Option<AgentStatus>,
    pub subtitle: String,
}

/// One agent of the agents section.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AgentRow {
    pub surface: SurfaceId,
    pub status: AgentStatus,
    pub target: ProjectionTarget,
    pub label: String,
    pub detail: String,
}

impl SidebarStatus {
    /// Red stub: builds an empty index.
    pub(crate) fn build(_tree: &TreeView, _agents: &[AgentInfo]) -> Self {
        Self::default()
    }

    pub(crate) fn tab(&self, surface: SurfaceId) -> Option<AgentStatus> {
        self.tabs.get(&surface).copied()
    }

    pub(crate) fn workspace(&self, index: usize) -> Option<&WorkspaceStatus> {
        self.workspaces.get(index)
    }

    pub(crate) fn agents(&self) -> &[AgentRow] {
        &self.agents
    }
}

#[cfg(test)]
#[path = "sidebar_status_tests.rs"]
mod tests;
