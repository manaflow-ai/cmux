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

/// What the app reads from the state without recomputing a rule: kept
/// current by every reduction (`FocusState::derive`). The shown workspace's
/// focus history is not here: it is read on request (`recent_panes`).
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
}

impl Default for Derived {
    fn default() -> Self {
        Derived {
            resolved: Resolved::None {},
            underlying: Resolved::None {},
            context: Context::default(),
            browser_focus_mode_active: false,
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
    /// Recomputed by every reduction; ignored on input (`import` derives it).
    #[serde(default, skip_serializing)]
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
    pub fn recent_panes(&self) -> &[String] {
        self.topology
            .workspace
            .as_ref()
            .and_then(|w| self.history.get(w))
            .map_or(&[], Vec::as_slice)
    }

    /// A state read from its JSON shape (a journal checkpoint), derived.
    pub fn import(json: &[u8]) -> serde_json::Result<FocusState> {
        let mut state: FocusState = serde_json::from_slice(json)?;
        state.derive();
        Ok(state)
    }

    /// The JSON shape: the state with its `derived` values, including the
    /// shown workspace's focus history (`derived.recentPanes`).
    pub fn export(&self) -> serde_json::Value {
        let mut value = serde_json::to_value(self).unwrap_or(serde_json::Value::Null);
        if let serde_json::Value::Object(object) = &mut value {
            let mut derived =
                serde_json::to_value(&self.derived).unwrap_or(serde_json::Value::Null);
            if let serde_json::Value::Object(fields) = &mut derived {
                fields.insert("recentPanes".into(), serde_json::json!(self.recent_panes()));
            }
            object.insert("derived".into(), derived);
        }
        value
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
        Self::context_of(&self.overlays, &self.underlying())
    }

    fn context_of(overlays: &[Overlay], underlying: &Resolved) -> Context {
        if let Some(top) = overlays.last()
            && *top != Overlay::Palette
        {
            return Context::default();
        }
        match underlying {
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

    /// Recomputes `derived` from the rest of the state (one resolution).
    pub fn derive(&mut self) {
        let underlying = self.underlying();
        let resolved = match self.overlays.last() {
            Some(top) => Resolved::Overlay { overlay: *top },
            None => underlying.clone(),
        };
        let context = Self::context_of(&self.overlays, &underlying);
        let browser_focus_mode_active = matches!(&resolved, Resolved::BrowserPage { tab, .. }
            if self.browser_focus_mode.contains(tab));
        self.derived = Derived { resolved, underlying, context, browser_focus_mode_active };
    }
}
