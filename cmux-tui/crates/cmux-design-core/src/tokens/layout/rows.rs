//! Sidebar workspace rows: `WorkspaceRowElement.swift` (`WorkspaceRowElement`,
//! `WorkspaceRowKind`, `WorkspaceRowStatusPlacement`) and `WorkspaceRowLayout.swift`
//! (`WorkspaceRowLayout`, `WorkspaceRowLayouts.layout(for:agent:)`), plus the catalog of every
//! layout enum's raw values.
//!
//! Ops (after `layout_`): `row_element`, `row_second_line`, `row_layout_for`, `enums`.

use super::attention::{AttentionMarkLook, AttentionStyle, FocusRingStyle};
use super::chrome::{
    AgentBadgesExperiment, TabBarOrder, TabBarPosition, TabShellIconTheme, TerminalCellBackgrounds,
    ToolbarPosition,
};
use crate::ops::{OpError, OpResult, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::{BTreeSet, HashMap};

raw_enum! {
    /// `WorkspaceRowElement`: what a sidebar workspace row shows (`sidebar.workspaceRow.*`).
    WorkspaceRowElement {
        /// The icon or emoji the user chose.
        Icon = "icon",
        /// The folder of the first tab that reports one.
        Directory = "directory",
        /// That tab's git branch.
        Branch = "branch",
        /// The front terminal's program.
        Process = "process",
        /// The status entries agents and hooks report.
        AgentStatus = "agentStatus",
        /// How many tabs the workspace has.
        TabCount = "tabCount",
        /// Listening ports.
        Ports = "ports",
        /// When an agent or a notification last changed the workspace.
        LastActivity = "lastActivity",
        /// A pull request / CI badge.
        PullRequest = "pullRequest",
        /// A terminal's or the workspace's progress.
        Progress = "progress",
        /// The agent-working indicator.
        Working = "working",
        /// The newest log line.
        Log = "log",
        /// The newest unread notification's text.
        Notification = "notification",
    }
}

impl WorkspaceRowElement {
    /// `secondLine`: the elements that make up the second line, in their default order.
    pub const SECOND_LINE: [WorkspaceRowElement; 7] = [
        WorkspaceRowElement::Notification,
        WorkspaceRowElement::Directory,
        WorkspaceRowElement::Branch,
        WorkspaceRowElement::Process,
        WorkspaceRowElement::AgentStatus,
        WorkspaceRowElement::Ports,
        WorkspaceRowElement::LastActivity,
    ];

    /// `isSecondLine`.
    pub fn is_second_line(self) -> bool {
        Self::SECOND_LINE.contains(&self)
    }
}

raw_enum! {
    /// `WorkspaceRowKind`: what a workspace's tabs are, for per-kind row settings.
    WorkspaceRowKind {
        /// Only terminals (or no tabs yet).
        Terminal = "terminal",
        /// Only agents.
        Agent = "agent",
        /// Only browser pages.
        Browser = "browser",
        /// Tabs of more than one kind.
        Mixed = "mixed",
    }
}

raw_enum! {
    /// `WorkspaceRowStatusPlacement` (`sidebar.workspaceRow.statusPlacement`).
    WorkspaceRowStatusPlacement {
        /// On the trailing column (the default).
        Trailing = "trailing",
        /// In the leading icon slot, before the title.
        Leading = "leading",
    }
}

/// `WorkspaceRowLayout.Slots`.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Slots {
    /// The icon slot.
    pub icon: bool,
    /// The working slot.
    pub working: bool,
    /// The progress slot.
    pub progress: bool,
}

/// `WorkspaceRowLayout`: a row layout the `sidebar_row_layout` reducer normalized.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceRowLayout {
    /// The layout is the user's own.
    pub custom: bool,
    /// The element ids of each line.
    pub lines: Vec<Vec<String>>,
    /// The slots it keeps.
    pub slots: Slots,
}

/// `WorkspaceRowLayouts.Kind`: one kind's fallback and per-agent layouts.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct KindLayouts {
    /// The kind's layout for any agent.
    pub fallback: Option<WorkspaceRowLayout>,
    /// Layouts by agent.
    pub agents: HashMap<String, WorkspaceRowLayout>,
}

/// `WorkspaceRowLayouts`: settings-time snapshots, one per configured (kind, agent) pair.
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct WorkspaceRowLayouts {
    /// Layouts by kind.
    pub kinds: HashMap<WorkspaceRowKind, KindLayouts>,
    /// Facts needed by any custom row.
    pub elements: BTreeSet<WorkspaceRowElement>,
}

impl WorkspaceRowLayouts {
    /// `layout(for:agent:)`: the agent's layout, else the kind's fallback; only a custom one.
    pub fn layout(
        &self,
        kind: WorkspaceRowKind,
        agent: Option<&str>,
    ) -> Option<&WorkspaceRowLayout> {
        let entry = self.kinds.get(&kind)?;
        let layout = agent.and_then(|a| entry.agents.get(a)).or(entry.fallback.as_ref());
        layout.filter(|l| l.custom)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ElementRequest {
    element: WorkspaceRowElement,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LayoutForRequest {
    #[serde(default)]
    layouts: WorkspaceRowLayouts,
    kind: WorkspaceRowKind,
    #[serde(default)]
    agent: Option<String>,
}

/// Every layout enum's raw values, in `allCases` order, by Swift type name.
pub fn enums() -> Value {
    json!({
        "AttentionStyle": AttentionStyle::raw_values(),
        "AttentionMarkLook": AttentionMarkLook::raw_values(),
        "FocusRingStyle": FocusRingStyle::raw_values(),
        "TabShellIconTheme": TabShellIconTheme::raw_values(),
        "TerminalCellBackgrounds": TerminalCellBackgrounds::raw_values(),
        "ToolbarPosition": ToolbarPosition::raw_values(),
        "TabBarPosition": TabBarPosition::raw_values(),
        "TabBarOrder": TabBarOrder::raw_values(),
        "AgentBadgesExperiment": AgentBadgesExperiment::raw_values(),
        "WorkspaceRowElement": WorkspaceRowElement::raw_values(),
        "WorkspaceRowKind": WorkspaceRowKind::raw_values(),
        "WorkspaceRowStatusPlacement": WorkspaceRowStatusPlacement::raw_values(),
    })
}

/// Runs the row ops (the name after `layout_`).
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "row_element" => {
            let r: ElementRequest = parse(request)?;
            Ok(json!({ "isSecondLine": r.element.is_second_line() }))
        }
        "row_second_line" => reply(&WorkspaceRowElement::SECOND_LINE),
        "row_layout_for" => {
            let r: LayoutForRequest = parse(request)?;
            reply(&r.layouts.layout(r.kind, r.agent.as_deref()))
        }
        "enums" => Ok(enums()),
        _ => Err(OpError::Unknown),
    }
}
