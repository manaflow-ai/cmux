//! Small chrome settings: `NoticeTiming.swift`, `SidebarNavRow.swift`, `TabShellIconTheme.swift`,
//! `TerminalCellBackgrounds.swift`, `ToolbarPosition+StripBand.swift` and
//! `SidebarSectionsPreferences.swift`'s `AgentBadgesExperiment`.
//!
//! Ops (after `layout_`): `notice_timing`, `strip_band`, `agent_badges`.

use crate::ops::{OpError, OpResult, parse, reply};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;

/// `NoticeTiming.connectionQuiet` in milliseconds: a connection state the person can do nothing
/// about shows only once it has lasted this long.
pub const CONNECTION_QUIET_MS: u64 = 10_000;

/// `SidebarNavRow`: one row of the sidebar's nav block (`sidebar.nav`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SidebarNavRow {
    /// The canonical catalog action id.
    pub action: String,
    /// The look's title override; nil for the action's own.
    #[serde(default)]
    pub title: Option<String>,
    /// The look's symbol override; nil for the action's own.
    #[serde(default)]
    pub symbol: Option<String>,
}

impl SidebarNavRow {
    /// `init(action:)` with no overrides.
    pub fn new(action: impl Into<String>) -> Self {
        SidebarNavRow { action: action.into(), title: None, symbol: None }
    }
}

raw_enum! {
    /// `TabShellIconTheme` (`tabs.shellIconTheme`).
    TabShellIconTheme {
        /// Keeps the `>_` kind glyph.
        Default = "default",
        /// Draws the icon of the machine the shell runs on.
        Machine = "machine",
    }
}

raw_enum! {
    /// `TerminalCellBackgrounds` (`appearance.terminalCellBackgrounds`).
    TerminalCellBackgrounds {
        /// Fully opaque, as Ghostty draws them (the default).
        Opaque = "opaque",
        /// At the window's opacity.
        Window = "window",
        /// Greys that differ from the background only in lightness fade toward transparent.
        Tint = "tint",
        /// Both `tint` and `window`.
        TintWindow = "tintWindow",
    }
}

raw_enum! {
    /// `ToolbarPosition` (ToolbarPosition.swift): the browser toolbar's edge.
    ToolbarPosition {
        /// Above the page (the default).
        Top = "top",
        /// Below the page.
        Bottom = "bottom",
    }
}

raw_enum! {
    /// `TabBarPosition` (ChromePlacement.swift): the tab strip's edge (`tabs.barPosition`).
    TabBarPosition {
        /// Above the pane's content (the default).
        Top = "top",
        /// Below the pane's content.
        Bottom = "bottom",
    }
}

raw_enum! {
    /// `TabBarOrder` (TabBarOrder.swift): the strip's order beside the toolbar (`tabs.barOrder`).
    TabBarOrder {
        /// The tab bar, then the toolbar (the default).
        AboveToolbar = "aboveToolbar",
        /// The toolbar, then the tab bar, then the page.
        BelowToolbar = "belowToolbar",
    }
}

/// `ToolbarPosition.holdsStripBand(strip:order:)`: the strip goes between a toolbar on this edge
/// and its page.
pub fn holds_strip_band(
    toolbar: ToolbarPosition,
    strip: TabBarPosition,
    order: TabBarOrder,
) -> bool {
    match (strip, toolbar) {
        (TabBarPosition::Top, ToolbarPosition::Top) => order == TabBarOrder::BelowToolbar,
        (TabBarPosition::Bottom, ToolbarPosition::Bottom) => order == TabBarOrder::AboveToolbar,
        _ => false,
    }
}

raw_enum! {
    /// `AgentBadgesExperiment` (`experiments.agentBadges`, `experiments.agentBadgesBeam`).
    AgentBadgesExperiment {
        /// The shipped tabs and rows (the default).
        Off = "off",
        /// Count pills on tabs, a status pill on rows.
        Pills = "pills",
        /// `pills`, plus the edge beam on a running row.
        Beam = "beam",
    }
}

impl AgentBadgesExperiment {
    /// `init(switches:)`: the beam switch does nothing while Agent Badges is off.
    pub fn from_switches(switches: &HashMap<String, bool>) -> Self {
        if switches.get("agentBadges") != Some(&true) {
            return AgentBadgesExperiment::Off;
        }
        if switches.get("agentBadgesBeam") == Some(&true) {
            AgentBadgesExperiment::Beam
        } else {
            AgentBadgesExperiment::Pills
        }
    }

    /// `showsPills`.
    pub fn shows_pills(self) -> bool {
        self != AgentBadgesExperiment::Off
    }

    /// `showsBeam`.
    pub fn shows_beam(self) -> bool {
        self == AgentBadgesExperiment::Beam
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StripBandRequest {
    toolbar: ToolbarPosition,
    strip: TabBarPosition,
    order: TabBarOrder,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BadgesRequest {
    #[serde(default)]
    switches: HashMap<String, bool>,
}

/// `agent_badges`'s reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentBadges {
    /// The arm.
    pub experiment: AgentBadgesExperiment,
    /// `showsPills`.
    pub shows_pills: bool,
    /// `showsBeam`.
    pub shows_beam: bool,
}

/// Runs the chrome ops (the name after `layout_`).
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "notice_timing" => Ok(json!({ "connectionQuietMs": CONNECTION_QUIET_MS })),
        "strip_band" => {
            let r: StripBandRequest = parse(request)?;
            Ok(json!({ "holds": holds_strip_band(r.toolbar, r.strip, r.order) }))
        }
        "agent_badges" => {
            let r: BadgesRequest = parse(request)?;
            let experiment = AgentBadgesExperiment::from_switches(&r.switches);
            reply(&AgentBadges {
                experiment,
                shows_pills: experiment.shows_pills(),
                shows_beam: experiment.shows_beam(),
            })
        }
        _ => Err(OpError::Unknown),
    }
}
