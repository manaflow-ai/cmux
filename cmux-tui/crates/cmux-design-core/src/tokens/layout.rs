//! Layout and settings rules of CmuxNextDesignTokens: the pane attention settings
//! (`AttentionSettings.swift`: `AttentionStyle`, `AttentionMarkLook`, `AttentionSettings`,
//! `AttentionMark`), the one-axis list scroll rule (`CloseFocus/ListViewport.swift`:
//! `ListViewport`, `ListViewportRows`, `ListViewportChange`), `NoticeTiming.swift`,
//! `SidebarNavRow.swift`, `TabShellIconTheme.swift`, `TerminalCellBackgrounds.swift`,
//! `ToolbarPosition+StripBand.swift`, `WorkspaceRowElement.swift` (`WorkspaceRowElement`,
//! `WorkspaceRowKind`, `WorkspaceRowStatusPlacement`), `WorkspaceRowLayout.swift` and
//! `SidebarSectionsPreferences.swift`'s `AgentBadgesExperiment`.
//!
//! Skipped: `CloseFocus/CloseSelection+Tabs.swift` (`successor(ofTab:)` forwards to
//! `CloseSelection.tab`, which calls cmux-focus-core's `close_selection` through the FFI: the rule
//! is Rust already).
//!
//! Ops: `tokens.layout_attention_defaults`, `tokens.layout_attention_surface`,
//! `tokens.layout_attention_rules`, `tokens.layout_attention_ranges`,
//! `tokens.layout_viewport_clamp`, `tokens.layout_viewport_is_fully_visible`,
//! `tokens.layout_viewport_reveal`, `tokens.layout_viewport_anchor`,
//! `tokens.layout_viewport_anchored`, `tokens.layout_viewport_settle`,
//! `tokens.layout_viewport_moved_by_itself`, `tokens.layout_notice_timing`,
//! `tokens.layout_strip_band`, `tokens.layout_agent_badges`, `tokens.layout_row_element`,
//! `tokens.layout_row_second_line`, `tokens.layout_row_layout_for`, `tokens.layout_enums`.

/// A Swift `String` raw-value enum: the cases in `allCases` order, `rawValue`, `init(rawValue:)`
/// and the raw values on the wire.
macro_rules! raw_enum {
    ($(#[$meta:meta])* $name:ident { $($(#[$vmeta:meta])* $variant:ident = $raw:literal),+ $(,)? }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, serde::Serialize, serde::Deserialize)]
        pub enum $name {
            $($(#[$vmeta])* #[serde(rename = $raw)] $variant),+
        }

        impl $name {
            /// `allCases`, in Swift's order.
            pub const ALL: &'static [$name] = &[$($name::$variant),+];

            /// `rawValue`.
            pub fn raw_value(self) -> &'static str {
                match self {
                    $($name::$variant => $raw),+
                }
            }

            /// `init(rawValue:)`.
            pub fn from_raw(raw: &str) -> Option<$name> {
                Self::ALL.iter().copied().find(|case| case.raw_value() == raw)
            }

            /// Every raw value, in `allCases` order.
            pub fn raw_values() -> Vec<&'static str> {
                Self::ALL.iter().map(|case| case.raw_value()).collect()
            }
        }
    };
}

pub mod attention;
pub mod chrome;
pub mod rows;
pub mod viewport;

use crate::ops::{OpError, OpResult};
use serde_json::Value;

/// Runs the `tokens.layout_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    let Some(rest) = name.strip_prefix("layout_") else {
        return Err(OpError::Unknown);
    };
    for area in [attention::call, viewport::call, chrome::call, rows::call] {
        match area(rest, request) {
            Err(OpError::Unknown) => continue,
            other => return other,
        }
    }
    Err(OpError::Unknown)
}
