//! The focus of one window: the single owner of "what has the keyboard"
//! (plans/cmux-next/focus.md section 4). Client-local, never persisted,
//! never sent to the daemon. The app's first responder, Ghostty surface
//! focus, page focus, the layout's focused pane and the registry context are
//! outputs of it (the app's effect applier).
//!
//! The JSON shape is the macOS app's synthesized `Codable` shape: a case
//! with no payload is `{"case":{}}`, an unlabeled payload is `_0`, a nil
//! optional is an absent key.

use crate::topology::{Kind, Topology};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};

/// What inside (or outside) the focused pane has the keyboard.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Target {
    /// The focused pane's selected tab content (terminal or page).
    Content {},
    AddressBar {},
    FindBar {},
    /// The focused page's docked developer tools.
    DevTools {},
    /// The sidebar list; `keyboard` when it got there by keyboard.
    Sidebar {
        keyboard: bool,
    },
    /// Sidebar search or inline rename field.
    SidebarField {},
    /// Any other text field in the window.
    TextField {},
    None {},
}

impl Target {
    /// The sidebar list or one of its fields.
    pub fn is_sidebar(self) -> bool {
        matches!(self, Target::Sidebar { .. } | Target::SidebarField {})
    }

    pub fn is_pane_scoped(self) -> bool {
        matches!(
            self,
            Target::Content {} | Target::AddressBar {} | Target::FindBar {} | Target::DevTools {}
        )
    }

    pub(crate) fn is_chrome(self) -> bool {
        matches!(self, Target::AddressBar {} | Target::FindBar {} | Target::DevTools {})
    }
}

/// Something that takes the keyboard above the window content.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Overlay {
    Palette,
    Sheet,
    Rename,
    GroupEditor,
}

/// What an expectation waits for.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExpectationKey {
    Surface {
        #[serde(rename = "_0")]
        id: String,
    },
    Tab {
        #[serde(rename = "_0")]
        id: String,
    },
}

/// A focus that lands once its tab exists (a split, new tab, drop).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Expectation {
    pub key: ExpectationKey,
    pub target: Target,
    /// Lands only in a pane other than this one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub away_from: Option<String>,
    /// The user-intent generation that asked for it; a newer intent drops it.
    pub generation: u64,
}

/// Where focus returns when a drag is cancelled.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DragRestore {
    pub tabs: Vec<String>,
    pub source_pane: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    pub target: Target,
    /// The focused pane's selected tab when the drag began.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tab: Option<String>,
    /// A keyboard, CLI or palette intent happened during the drag.
    #[serde(default)]
    pub overridden: bool,
}

/// The one keyboard target the state implies.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Resolved {
    Terminal {
        pane: String,
        tab: String,
    },
    BrowserPage {
        pane: String,
        tab: String,
    },
    AddressBar {
        pane: String,
        tab: String,
    },
    FindBar {
        pane: String,
        tab: String,
    },
    DevTools {
        pane: String,
        tab: String,
    },
    AgentPage {
        pane: String,
        tab: String,
    },
    Page {
        pane: String,
        tab: String,
    },
    Conversation {
        pane: String,
        tab: String,
    },
    /// A focused pane with no content to type into (empty, loading).
    EmptyPane {
        pane: String,
    },
    Sidebar {},
    SidebarField {},
    TextField {},
    Overlay {
        #[serde(rename = "_0")]
        overlay: Overlay,
    },
    None {},
}

/// Registry context bits the focus implies.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Context {
    pub terminal: bool,
    pub browser: bool,
    pub agent: bool,
}

/// `layout.closeFocus`: the successor rule when the focused pane closes
/// (plans/cmux-next/close-focus.md).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum CloseFocusPolicy {
    /// The previous pane in the same column, else the next one there; when
    /// the column goes, the column to the left, else the one to the right.
    #[default]
    PreviousNeighbor,
    /// The most recently focused surviving pane, else `PreviousNeighbor`.
    MostRecent,
}

/// What the app reads from the state without recomputing a rule: filled by
/// every reduction (`FocusState::derive`).
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Derived {
    /// The keyboard target, the top overlay first.
    pub resolved: Resolved,
    /// The target below any overlay.
    pub underlying: Resolved,
    pub context: Context,
    /// The focused page is in browser focus mode.
    pub browser_focus_mode_active: bool,
    /// The shown workspace's focus history, newest first.
    pub recent_panes: Vec<String>,
}

impl Default for Derived {
    fn default() -> Self {
        Derived {
            resolved: Resolved::None {},
            underlying: Resolved::None {},
            context: Context::default(),
            browser_focus_mode_active: false,
            recent_panes: Vec::new(),
        }
    }
}

/// Recently focused panes kept per workspace.
pub const HISTORY_LIMIT: usize = 64;

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FocusState {
    pub window_key: bool,
    pub app_active: bool,
    pub topology: Topology,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pane: Option<String>,
    pub target: Target,
    pub overlays: Vec<Overlay>,
    /// Last focused pane per workspace (restored on switching back).
    pub remembered: HashMap<String, String>,
    /// Recently focused panes per workspace, newest first.
    pub history: HashMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expectation: Option<Expectation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub drag: Option<DragRestore>,
    /// Browser tabs in browser focus mode.
    pub browser_focus_mode: BTreeSet<String>,
    /// Bumped by every user intent.
    pub generation: u64,
    /// The sidebar is hidden: it cannot be a focus target.
    pub sidebar_hidden: bool,
    pub close_focus: CloseFocusPolicy,
    /// Recomputed by every reduction; ignored on input.
    #[serde(default)]
    pub derived: Derived,
}

impl Default for FocusState {
    fn default() -> Self {
        FocusState {
            window_key: false,
            app_active: false,
            topology: Topology::default(),
            pane: None,
            target: Target::Content {},
            overlays: Vec::new(),
            remembered: HashMap::new(),
            history: HashMap::new(),
            expectation: None,
            drag: None,
            browser_focus_mode: BTreeSet::new(),
            generation: 0,
            sidebar_hidden: false,
            close_focus: CloseFocusPolicy::PreviousNeighbor,
            derived: Derived::default(),
        }
    }
}

impl FocusState {
    /// The shown workspace's focus history, newest first.
    pub fn recent_panes(&self) -> Vec<String> {
        self.topology
            .workspace
            .as_ref()
            .and_then(|w| self.history.get(w))
            .cloned()
            .unwrap_or_default()
    }

    pub fn resolved(&self) -> Resolved {
        match self.overlays.last() {
            Some(top) => Resolved::Overlay { overlay: *top },
            None => self.underlying(),
        }
    }

    /// The target below any overlay (what closing the overlays restores,
    /// and what the palette's commands act on).
    pub fn underlying(&self) -> Resolved {
        match self.target {
            Target::Sidebar { .. } => Resolved::Sidebar {},
            Target::SidebarField {} => Resolved::SidebarField {},
            Target::TextField {} => Resolved::TextField {},
            Target::None {} => Resolved::None {},
            Target::Content {}
            | Target::AddressBar {}
            | Target::FindBar {}
            | Target::DevTools {} => {
                let Some(pane) = self.pane.clone() else { return Resolved::None {} };
                let Some(model) = self.topology.pane(&pane) else { return Resolved::None {} };
                let Some(tab) = model.selected_tab() else { return Resolved::EmptyPane { pane } };
                let tab_id = tab.id.clone();
                match (tab.kind, self.target) {
                    (Kind::Browser, Target::AddressBar {}) => {
                        Resolved::AddressBar { pane, tab: tab_id }
                    }
                    (Kind::Browser, Target::FindBar {}) => Resolved::FindBar { pane, tab: tab_id },
                    (Kind::Browser, Target::DevTools {}) => {
                        Resolved::DevTools { pane, tab: tab_id }
                    }
                    (Kind::Browser, _) => Resolved::BrowserPage { pane, tab: tab_id },
                    (Kind::Terminal, _) => Resolved::Terminal { pane, tab: tab_id },
                    (Kind::Agent, _) => Resolved::AgentPage { pane, tab: tab_id },
                    (Kind::Page, _) => Resolved::Page { pane, tab: tab_id },
                    (Kind::Conversation, _) => Resolved::Conversation { pane, tab: tab_id },
                    (Kind::Other, _) => Resolved::EmptyPane { pane },
                }
            }
        }
    }

    /// The sidebar, other text fields, sheets and rename prompts clear both
    /// bits, so content-scoped actions cannot run while the user types
    /// there. The palette keeps the bits of what is below it.
    pub fn context(&self) -> Context {
        if let Some(top) = self.overlays.last()
            && *top != Overlay::Palette
        {
            return Context::default();
        }
        match self.underlying() {
            Resolved::Terminal { .. } => Context { terminal: true, ..Context::default() },
            Resolved::BrowserPage { .. }
            | Resolved::AddressBar { .. }
            | Resolved::FindBar { .. }
            | Resolved::DevTools { .. } => Context { browser: true, ..Context::default() },
            Resolved::AgentPage { .. } => Context { agent: true, ..Context::default() },
            _ => Context::default(),
        }
    }

    /// The focused page is in browser focus mode.
    pub fn is_browser_focus_mode_active(&self) -> bool {
        match self.resolved() {
            Resolved::BrowserPage { tab, .. } => self.browser_focus_mode.contains(&tab),
            _ => false,
        }
    }

    /// Recomputes `derived` from the rest of the state.
    pub fn derive(&mut self) {
        self.derived = Derived {
            resolved: self.resolved(),
            underlying: self.underlying(),
            context: self.context(),
            browser_focus_mode_active: self.is_browser_focus_mode_active(),
            recent_panes: self.recent_panes(),
        };
    }
}
