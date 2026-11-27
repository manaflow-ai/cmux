//! The list column's width (`HomeSidebarWidth`) and whether a window still needs its first
//! workspace (`FirstWorkspace.needsFirstWorkspace`).

use serde::{Deserialize, Serialize};

/// `HomeSidebarWidth.minimum`: the collapsed (avatars only) list.
pub const MINIMUM: f64 = 100.0;
/// `HomeSidebarWidth.standard`.
pub const STANDARD: f64 = 328.0;
/// `HomeSidebarWidth.fullMinimum`: the narrowest list with names.
pub const FULL_MINIMUM: f64 = 188.0;
/// `HomeSidebarWidth.transcriptMinimum`.
pub const TRANSCRIPT_MINIMUM: f64 = 280.0;

/// `HomeSidebarWidth.clamp`: a saved width that fits the window.
pub fn clamp(width: f64, window: f64, minimum: f64, full_minimum: f64, transcript: f64) -> f64 {
    let fit = minimum.max(width.min(window / 2.0).min(window - transcript));
    if fit < full_minimum { minimum } else { fit }
}

/// `HomeSidebarWidth.drag`: where a divider drag settles (0 hides the list).
pub fn drag(proposed: f64, minimum: f64, full_minimum: f64, widest: f64) -> f64 {
    if proposed < minimum / 2.0 {
        0.0
    } else if widest < full_minimum {
        minimum
    } else if proposed < full_minimum {
        if proposed < (minimum + full_minimum) / 2.0 { minimum } else { full_minimum }
    } else {
        proposed.min(widest)
    }
}

/// `HomeSidebarWidth.columnMinimum`.
pub fn column_minimum(list_minimum: f64, divider: f64) -> f64 {
    list_minimum + divider + TRANSCRIPT_MINIMUM
}

/// The parts of `WorkspaceModel` `needsFirstWorkspace` reads.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub ephemeral: bool,
    pub resource_id: Option<String>,
    pub recovered: Option<bool>,
}

const RECOVERED_NAMES: [&str; 2] = ["Recovered terminals", "復元されたターミナル"];

/// `[WorkspaceModel].needsFirstWorkspace(leftover:home:)`: no workspace of the person's own.
pub fn needs_first_workspace(
    workspaces: &[Workspace],
    leftover: &[String],
    home: Option<&str>,
) -> bool {
    !workspaces.iter().any(|w| {
        !leftover.contains(&w.id)
            && !w.ephemeral
            && w.kind != "home"
            && (home.is_none() || w.resource_id.as_deref() != home)
            && !w.recovered.unwrap_or_else(|| RECOVERED_NAMES.contains(&w.name.as_str()))
    })
}
