//! The `workspaces.newPlacement` rule as one create uses it: the rule a create that does not place
//! itself from the window's current workspace gets (`NewWorkspaceDefaultSlot.anchored`), and the
//! default slot of its row and the rule it is placed by (`WorkspaceSpawn.placement`). Where the
//! slot then resolves against the sidebar is the sidebar's (cmux-layout-reducer); this is only the
//! part the create decides at the press.

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// `workspaces.newPlacement`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NewWorkspacePlacement {
    /// First in the current workspace's group, else first in the machine section.
    #[default]
    Top,
    /// Right after the workspace the window showed.
    AfterCurrent,
    /// Last in the current workspace's group, else the daemon's place.
    Bottom,
}

/// `workspaces.newPlacement` for one new workspace whose entry point names no place
/// (`NewWorkspaceDefaultSlot`): the setting, the workspace the window showed at the press, its
/// machine, whether the creator named the placement, and the gaps around the current row (kept as
/// the sidebar gave them: the sidebar resolves them, this crate only carries them).
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DefaultSlot {
    /// The setting.
    pub placement: NewWorkspacePlacement,
    /// The workspace the window showed when the new one was asked for.
    pub current: Option<String>,
    /// The machine of `current`, when known at the press.
    pub current_machine: Option<String>,
    /// Its creator named `placement`.
    pub named: bool,
    /// The gaps right below and right above `current` at the press.
    pub current_gaps: Vec<Value>,
}

impl DefaultSlot {
    /// The setting puts a new workspace after the current row (`placesAfterCurrent`).
    pub fn places_after_current(&self) -> bool {
        self.placement == NewWorkspacePlacement::AfterCurrent
    }

    /// This rule for a create that places itself from the window's current workspace
    /// (`from_current`) or not: one that does not drops the current anchor, except under
    /// `afterCurrent`, which always places after it. Only `current` goes: its machine and gaps stay.
    pub fn anchored(&self, from_current: bool) -> DefaultSlot {
        let mut rule = self.clone();
        if !from_current && rule.placement != NewWorkspacePlacement::AfterCurrent {
            rule.current = None;
        }
        rule
    }
}

/// How one create is placed (`WorkspaceSpawn.slot`, `placesBySetting`, `placesFromCurrent`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct SpawnPlacing {
    /// The create names a slot of its own.
    pub has_slot: bool,
    /// It is placed by the setting at all.
    pub places_by_setting: bool,
    /// It inherits the current workspace's group.
    pub places_from_current: bool,
}

impl Default for SpawnPlacing {
    fn default() -> Self {
        SpawnPlacing { has_slot: false, places_by_setting: true, places_from_current: true }
    }
}

/// The default slot of a create's row and the rule it is placed by.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SpawnPlacement {
    /// The row's default slot; nil for a create with a slot of its own (its row shows there).
    pub row: Option<DefaultSlot>,
    /// The rule it is placed by; nil for a create not placed by the setting.
    pub rule: Option<DefaultSlot>,
}

/// The default slot of this create's sidebar row and the rule it is placed by, from the window's
/// rule `setting` (`WorkspaceSpawn.placement(setting:)`): a create that does not place itself from
/// the window's current workspace loses that anchor (except `afterCurrent`), and only a create
/// placed by the setting gets a rule. A create with a slot of its own shows its row there (no
/// default row) and keeps the rule only as the fallback for a slot whose anchor closed.
pub fn spawn_placement(setting: &DefaultSlot, placing: SpawnPlacing) -> SpawnPlacement {
    let anchored = setting.anchored(placing.places_from_current && placing.places_by_setting);
    let row = if placing.has_slot { None } else { Some(anchored.clone()) };
    let rule = if placing.places_by_setting { Some(anchored) } else { None };
    SpawnPlacement { row, rule }
}
