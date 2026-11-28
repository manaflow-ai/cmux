//! Which point of a lifted sidebar card decides an internal drag's drop
//! (spec amendment 1780d02, centre band). The app sends one request per
//! drag move (`cmux_layout_reducer_json` op `resolve_drag`) instead of
//! converting both points and asking `resolve` up to three times.

use serde::{Deserialize, Serialize};

use crate::sidebar_drop::{Request, Target, base_y, resolve};

/// The card's centre and leading edge in displayed coordinates, the gap the
/// list shows, and the drop rules (`Request`; its `y` is unused here). The
/// onto band (`workspace_onto_start..workspace_onto_end`) is the centre band.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DragRequest {
    pub centre_y: f64,
    pub leading_y: f64,
    pub gap_y: Option<f64>,
    pub gap_height: f64,
    #[serde(flatten)]
    pub request: Request,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Probe {
    Centre,
    LeadingEdge,
}

/// The drop (nil: no slot) and the card point that decided it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Drag {
    pub target: Option<Target>,
    pub probe: Probe,
}

/// Over a loose workspace row that can take an onto-drop, the card's centre
/// decides: the onto band groups, above it the drop goes before the row,
/// below it after. Elsewhere (group rows, rows inside a group, a group drag)
/// the card's leading edge decides (nxdog30: a row makes way once the card
/// covers half of it). None when neither point can decide, or when the
/// centre is in the open gap and the leading edge finds no slot the dragged
/// rows can take: the caller keeps its last target, so over rows they cannot
/// join (another computer's, right above in one list, cx-hzpd) the gap holds
/// instead of refusing the drop.
pub fn resolve_drag(drag: &DragRequest) -> Option<Drag> {
    let centre = base_y(drag.centre_y, drag.gap_y, drag.gap_height);
    let leading = base_y(drag.leading_y, drag.gap_y, drag.gap_height);
    let band = (drag.request.workspace_onto_start, drag.request.workspace_onto_end);
    let mut at = drag.request.clone();
    if band.0 < band.1
        && let Some(y) = centre
    {
        at.y = y;
        let target = resolve(&at);
        if matches!(target, Some(Target::OntoWorkspace { .. })) {
            return Some(Drag { target, probe: Probe::Centre });
        }
        // A whole-row band asks whether the row under the centre could take
        // an onto-drop; if so the centre decides before or after it.
        (at.workspace_onto_start, at.workspace_onto_end) = (0.0, 1.0);
        if matches!(resolve(&at), Some(Target::OntoWorkspace { .. })) {
            (at.workspace_onto_start, at.workspace_onto_end) = (0.0, 0.0);
            return Some(Drag { target: resolve(&at), probe: Probe::Centre });
        }
    }
    at.y = leading?;
    (at.workspace_onto_start, at.workspace_onto_end) = (0.0, 0.0);
    let target = resolve(&at);
    if target.is_none() && centre.is_none() {
        return None;
    }
    Some(Drag { target, probe: Probe::LeadingEdge })
}
