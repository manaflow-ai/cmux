//! Inputs to the focus state machine and its outputs
//! (plans/cmux-next/focus.md section 4). Every entrypoint that changes
//! focus sends one event to its window's coordinator; nothing else writes
//! focus.

use crate::state::{Context, ExpectationKey, Overlay, Resolved, Target};
use crate::topology::Topology;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    Mouse,
    Keyboard,
    Cli,
    Palette,
    /// App-driven (daemon echo, repair). Not a user intent.
    Programmatic,
}

impl Source {
    pub fn is_user_intent(self) -> bool {
        self != Source::Programmatic
    }
}

/// The first responder the platform actually chose, classified.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Responder {
    Content {
        pane: String,
    },
    AddressBar {
        pane: String,
    },
    FindBar {
        pane: String,
    },
    /// A page's docked DevTools window became key.
    DevTools {
        pane: String,
    },
    Sidebar {},
    SidebarField {},
    TextField {},
    /// The window itself or nothing: usually a view left the window.
    WindowOrNone {},
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum DragOutcome {
    Cancelled {},
    /// The tabs land in this window; the first one takes focus once it is
    /// in a pane other than `away_from`.
    #[serde(rename_all = "camelCase")]
    Dropped {
        tabs: Vec<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        away_from: Option<String>,
    },
    /// The tabs left this window (the drop window focuses them).
    MovedAway {},
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FocusEvent {
    /// Daemon delta, workspace switch, selection or content change.
    Topology {
        #[serde(rename = "_0")]
        topology: Topology,
    },
    /// Mouse down in a pane, keyboard navigation, CLI, palette. A
    /// `workspace` other than the shown one is remembered for when it shows.
    FocusPane {
        #[serde(rename = "_0")]
        pane: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        workspace: Option<String>,
        source: Source,
    },
    SelectTab {
        pane: String,
        tab: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        workspace: Option<String>,
        source: Source,
    },
    /// Cmd-L, find in page, sidebar search.
    FocusTarget {
        #[serde(rename = "_0")]
        target: Target,
        source: Source,
    },
    Responder {
        #[serde(rename = "_0")]
        responder: Responder,
        source: Source,
    },
    WindowKey {
        #[serde(rename = "_0")]
        key: bool,
    },
    AppActive {
        #[serde(rename = "_0")]
        active: bool,
    },
    OverlayOpened {
        #[serde(rename = "_0")]
        overlay: Overlay,
    },
    OverlayClosed {
        #[serde(rename = "_0")]
        overlay: Overlay,
    },
    /// Starts a user intent that lands later (bumps the generation).
    BeginIntent {},
    /// Focus `key` once it exists, if no newer intent happened since
    /// `generation`.
    #[serde(rename_all = "camelCase")]
    Expect {
        #[serde(rename = "_0")]
        key: ExpectationKey,
        target: Target,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        away_from: Option<String>,
        generation: u64,
    },
    DragBegan {
        tabs: Vec<String>,
        pane: String,
    },
    DragEnded {
        #[serde(rename = "_0")]
        outcome: DragOutcome,
    },
    /// A pane's selected content view now exists (frame-deferred show).
    ContentPresented {
        pane: String,
    },
    /// None toggles the focused page.
    ToggleBrowserFocusMode {
        #[serde(default, skip_serializing_if = "Option::is_none")]
        tab: Option<String>,
    },
    /// The window's sidebar was shown or hidden.
    SidebarVisibility {
        hidden: bool,
    },
    /// The pane this window's record saved for `workspace` (relaunch).
    RestoredPane {
        #[serde(rename = "_0")]
        pane: String,
        workspace: String,
    },
}

impl FocusEvent {
    /// Moves focus or selection on purpose (a pane or tab choice, a focus
    /// target, a new intent or expectation, a drop landing): what an action
    /// run without view-change permission must not send. Reports of what
    /// the platform or the daemon did are not.
    pub fn changes_view(&self) -> bool {
        matches!(
            self,
            FocusEvent::FocusPane { .. }
                | FocusEvent::SelectTab { .. }
                | FocusEvent::FocusTarget { .. }
                | FocusEvent::BeginIntent {}
                | FocusEvent::Expect { .. }
                | FocusEvent::DragEnded { outcome: DragOutcome::Dropped { .. } }
        )
    }
}

/// Outputs of the reducer, applied by the app after the reducer returns.
/// Each is idempotent.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FocusEffect {
    /// Make `tab` the selected tab of `pane` (client-local selection).
    Select {
        pane: String,
        tab: String,
    },
    /// Mirror the focused pane into the layout without a layout intent.
    RevealPane {
        #[serde(rename = "_0")]
        pane: String,
    },
    /// Make the platform responder match the resolved target.
    MoveResponder {
        #[serde(rename = "_0")]
        resolved: Resolved,
    },
    PublishContext {
        #[serde(rename = "_0")]
        context: Context,
    },
    BrowserFocusMode {
        tab: String,
        active: bool,
    },
}
