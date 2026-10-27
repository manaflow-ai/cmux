//! What the focus state machine knows about the workspace a window shows:
//! panes in layout order, their tabs (strip order), the selected tab, and
//! the columns of every screen (plans/cmux-next/focus.md section 4).
//! The app builds it from the daemon mirror and the window's client-local
//! selection, and sends it only when it changed. A topology keeps pane and
//! tab indexes, so a lookup by id is O(1) (`Topology::index`).

use serde::{Deserialize, Serialize};
use std::collections::{BTreeSet, HashMap};

/// The kind of a tab's content.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Terminal,
    Browser,
    /// An agent chat tab: the acpmux React pane's web view.
    Agent,
    /// An internal page tab (Settings, Debug Settings): a native view.
    Page,
    /// A conversation tab (Home): its message box is the primary input.
    Conversation,
    /// A tab kind the app shows no content for.
    Other,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Tab {
    pub id: String,
    /// Daemon surface id; none for session-local browser tabs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub surface: Option<String>,
    pub kind: Kind,
}

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Pane {
    pub id: String,
    pub tabs: Vec<Tab>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected: Option<String>,
}

impl Pane {
    pub fn tab(&self, id: &str) -> Option<&Tab> {
        self.tabs.iter().find(|tab| tab.id == id)
    }

    pub fn selected_tab(&self) -> Option<&Tab> {
        self.selected.as_deref().and_then(|id| self.tab(id))
    }
}

/// One column of a screen: its stable id (the layout column id; a split
/// screen's one column uses the screen id) and its pane ids in layout order.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Column {
    pub id: String,
    pub panes: Vec<String>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(from = "TopologyWire")]
pub struct Topology {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
    #[serde(default)]
    pub panes: Vec<Pane>,
    /// Every screen's columns in visual order (left docked, strip, right
    /// docked; a split screen is one column). Empty means one screen with
    /// one column holding `panes` in order.
    #[serde(default)]
    pub screens: Vec<Vec<Column>>,
    /// Pane id -> index in `panes`; tab id -> (pane index, tab index).
    /// Derived from `panes` by `index`; not part of the value. Build a
    /// topology with `new` (or decode it); after any direct edit of `panes`
    /// other than a selection, call `index`.
    #[serde(skip)]
    panes_by_id: HashMap<String, usize>,
    #[serde(skip)]
    tabs_by_id: HashMap<String, (usize, usize)>,
}

/// The decoded shape; `From` builds the indexes.
#[derive(Deserialize)]
struct TopologyWire {
    #[serde(default)]
    workspace: Option<String>,
    #[serde(default)]
    panes: Vec<Pane>,
    #[serde(default)]
    screens: Vec<Vec<Column>>,
}

impl From<TopologyWire> for Topology {
    fn from(wire: TopologyWire) -> Topology {
        Topology::new(wire.workspace, wire.panes, wire.screens)
    }
}

impl PartialEq for Topology {
    fn eq(&self, other: &Self) -> bool {
        self.workspace == other.workspace
            && self.panes == other.panes
            && self.screens == other.screens
    }
}

impl Eq for Topology {}

impl Topology {
    pub fn new(workspace: Option<String>, panes: Vec<Pane>, screens: Vec<Vec<Column>>) -> Topology {
        let mut topology = Topology {
            workspace,
            panes,
            screens,
            panes_by_id: HashMap::new(),
            tabs_by_id: HashMap::new(),
        };
        topology.index();
        topology
    }

    /// Rebuilds the id indexes from `panes` (after a decode). The first pane
    /// or tab with an id wins, as the linear lookups did.
    pub fn index(&mut self) {
        self.panes_by_id.clear();
        self.tabs_by_id.clear();
        for (p, pane) in self.panes.iter().enumerate() {
            self.panes_by_id.entry(pane.id.clone()).or_insert(p);
            for (t, tab) in pane.tabs.iter().enumerate() {
                self.tabs_by_id.entry(tab.id.clone()).or_insert((p, t));
            }
        }
    }

    /// The columns of the screen that holds `pane`.
    pub fn columns_containing(&self, pane: &str) -> Option<Vec<Column>> {
        if self.screens.is_empty() {
            return self.contains_pane(pane).then(|| {
                vec![Column {
                    id: String::new(),
                    panes: self.panes.iter().map(|p| p.id.clone()).collect(),
                }]
            });
        }
        self.screens
            .iter()
            .find(|screen| screen.iter().any(|column| column.panes.iter().any(|p| p == pane)))
            .cloned()
    }

    /// Column id -> panes, over every screen (the first column with an id wins).
    pub fn columns_by_id(&self) -> HashMap<String, Vec<String>> {
        if self.screens.is_empty() {
            return HashMap::from([(
                String::new(),
                self.panes.iter().map(|p| p.id.clone()).collect(),
            )]);
        }
        let mut map = HashMap::new();
        for column in self.screens.iter().flatten() {
            map.entry(column.id.clone()).or_insert_with(|| column.panes.clone());
        }
        map
    }

    pub fn pane(&self, id: &str) -> Option<&Pane> {
        self.panes_by_id.get(id).and_then(|&index| self.panes.get(index))
    }

    pub fn contains_pane(&self, id: &str) -> bool {
        self.panes_by_id.contains_key(id)
    }

    pub fn contains_tab(&self, id: &str) -> bool {
        self.tabs_by_id.contains_key(id)
    }

    /// Pane and tab holding the tab with this id.
    pub fn location_of_tab(&self, id: &str) -> Option<(String, String)> {
        let &(pane, _) = self.tabs_by_id.get(id)?;
        self.panes.get(pane).map(|pane| (pane.id.clone(), id.to_owned()))
    }

    /// Pane and tab showing this daemon surface.
    pub fn location_of_surface(&self, surface: &str) -> Option<(String, String)> {
        self.panes.iter().find_map(|pane| {
            pane.tabs
                .iter()
                .find(|tab| tab.surface.as_deref() == Some(surface))
                .map(|tab| (pane.id.clone(), tab.id.clone()))
        })
    }

    pub fn all_tab_ids(&self) -> BTreeSet<String> {
        self.panes.iter().flat_map(|pane| pane.tabs.iter().map(|tab| tab.id.clone())).collect()
    }

    /// Selects `tab` in `pane` in this copy (the applier makes it real).
    pub fn select(&mut self, tab: &str, pane: &str) {
        if let Some(pane) =
            self.panes_by_id.get(pane).copied().and_then(|index| self.panes.get_mut(index))
        {
            pane.selected = Some(tab.to_owned());
        }
    }

    pub(crate) fn selected_of(&self, pane: &str) -> Option<&str> {
        self.pane(pane).and_then(|p| p.selected.as_deref())
    }

    pub(crate) fn selected_kind(&self, pane: Option<&str>) -> Option<Kind> {
        pane.and_then(|p| self.pane(p)).and_then(Pane::selected_tab).map(|tab| tab.kind)
    }
}
