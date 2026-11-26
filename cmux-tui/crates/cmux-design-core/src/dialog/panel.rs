//! The floating dialog panel's drag rule (`CmuxFloatingDialogPanel.startsDrag(at:)`).

use serde::{Deserialize, Serialize};

/// What a view between the hit and the card is, as the drag rule sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ViewKind {
    /// An editable `NSTextField`.
    EditableField,
    /// A non-editable `NSTextField` (a label).
    Label,
    /// An `NSImageView`.
    Image,
    /// Any other `NSControl` (a button, a choice).
    Control,
    /// An `NSText` (a field editor).
    Text,
    /// An `NSScroller`.
    Scroller,
    /// Any other view (glass, stacks).
    Other,
}

/// `startsDrag` request.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DragRequest {
    /// The hit view is the card or inside it (not the shadow band).
    pub in_card: bool,
    /// The views from the hit view up to the card, the card left out.
    #[serde(default)]
    pub chain: Vec<ViewKind>,
}

/// Whether a press drags the card: on its glass, a label or an image, never on a control the
/// person works nor outside the card.
pub fn starts_drag(in_card: bool, chain: &[ViewKind]) -> bool {
    in_card
        && chain
            .iter()
            .all(|kind| matches!(kind, ViewKind::Label | ViewKind::Image | ViewKind::Other))
}
