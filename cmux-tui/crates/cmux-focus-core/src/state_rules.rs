//! The focus read view's own rules, which the macOS app's `CmuxNextFocus`
//! types still ran in Swift: what a resolved focus types into
//! (`FocusState.awaitableContent`, `terminalTab`, `browserTab`,
//! `isDevTools`, `mayQueueTyping`), whether the focus waits for another tab
//! (`awaitsOtherTab`), whether keys typed ahead still wait once focus
//! settled (`TypeAheadWait.survives`), a topology without a pane
//! (`FocusTopology.removing`), what an event says about who chose it
//! (`FocusEvent.isPersonsOwn`, `choosesFocusAsPerson`,
//! `choosesFocusInMenuPick`), a responder's `debug.focus` name, and the
//! machine's responder re-apply on a wait change
//! (`FocusMachine.reapplyingOnWaitChange`).
//!
//! The JSON shapes are the app's synthesized `Codable` shapes (see
//! [`crate::state`]). schemas/focus-state-rules/vectors.json holds random
//! cases written from a transliteration of the Swift; the tests below and
//! the app FFI's `focus_state_*` operations replay it.

use crate::event::{FocusEvent, Responder, Source};
use crate::state::{ExpectationKey, Resolved};
use crate::topology::{Tab, Topology};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The focused terminal or page that keys typed now are for.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AwaitableContent {
    pub pane: String,
    pub tab: String,
    /// A page (a browser tab's, an agent chat's, an internal page tab's), not a terminal.
    pub is_page: bool,
}

/// What a resolved focus types into.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedFacts {
    /// The focused terminal or page keys typed now are for; none for other focus.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub awaitable_content: Option<AwaitableContent>,
    /// The focused terminal's tab.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_tab: Option<String>,
    /// The browser tab of a browser page, its address bar, find bar or DevTools.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub browser_tab: Option<String>,
    pub is_dev_tools: bool,
    /// A page whose keys may wait for its document (an agent page, a React page).
    pub may_queue_typing: bool,
}

/// The focused terminal or page keys typed now are for (REOPEN-F4: a
/// window's key hold waits while its content is not shown yet).
pub fn awaitable_content(resolved: &Resolved) -> Option<AwaitableContent> {
    let (pane, tab, is_page) = match resolved {
        Resolved::Terminal { pane, tab } => (pane, tab, false),
        Resolved::BrowserPage { pane, tab }
        | Resolved::AgentPage { pane, tab }
        | Resolved::Page { pane, tab } => (pane, tab, true),
        _ => return None,
    };
    Some(AwaitableContent { pane: pane.clone(), tab: tab.clone(), is_page })
}

/// The focused terminal's tab; none when the focus is not on a terminal.
pub fn terminal_tab(resolved: &Resolved) -> Option<&str> {
    match resolved {
        Resolved::Terminal { tab, .. } => Some(tab),
        _ => None,
    }
}

/// The browser tab a browser target belongs to.
pub fn browser_tab(resolved: &Resolved) -> Option<&str> {
    match resolved {
        Resolved::BrowserPage { tab, .. }
        | Resolved::AddressBar { tab, .. }
        | Resolved::FindBar { tab, .. }
        | Resolved::DevTools { tab, .. } => Some(tab),
        _ => None,
    }
}

/// Pages whose keys may wait for their document: agent pages (the new tab
/// page, chats) and React pages.
pub fn may_queue_typing(resolved: &Resolved) -> bool {
    matches!(resolved, Resolved::AgentPage { .. } | Resolved::Page { .. })
}

/// Every fact of [`ResolvedFacts`] for `resolved`.
pub fn resolved_facts(resolved: &Resolved) -> ResolvedFacts {
    ResolvedFacts {
        awaitable_content: awaitable_content(resolved),
        terminal_tab: terminal_tab(resolved).map(str::to_owned),
        browser_tab: browser_tab(resolved).map(str::to_owned),
        is_dev_tools: matches!(resolved, Resolved::DevTools { .. }),
        may_queue_typing: may_queue_typing(resolved),
    }
}

/// The focus is on its way to a tab other than the focused one (a
/// creation's new tab the window does not show yet): `expecting` is the
/// pending expectation's key. A change re-applies the responder (P0
/// INVERSE-KEY).
pub fn awaits_other_tab(expecting: Option<&ExpectationKey>, resolved: &Resolved) -> bool {
    match expecting {
        Some(ExpectationKey::Tab { id }) => resolved.tab() != Some(id.as_str()),
        Some(ExpectationKey::Surface { .. }) => true,
        None => false,
    }
}

/// The page keys typed ahead wait for: the focus they were typed in and
/// the page's type-ahead surface.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TypeAheadWait {
    pub focus: Resolved,
    pub page: String,
}

impl TypeAheadWait {
    /// Whether the keys still wait once focus settled at `settled`, whose
    /// page has the type-ahead surface `settled_page` (none when it shows no
    /// page). False when focus moved off the page. The same page in the same
    /// pane under another tab id (a provisional id became the store id) keeps
    /// them, and so does the same page after its stand-in pane
    /// (`pane:<handle>`, Cmd-N's new workspace) got the daemon's id.
    pub fn survives(&self, settled: &Resolved, settled_page: Option<&str>) -> bool {
        if *settled == self.focus {
            return true;
        }
        if settled_page != Some(self.page.as_str()) {
            return false;
        }
        settled.pane() == self.focus.pane()
            || self.focus.pane().is_some_and(|pane| pane.starts_with("pane:"))
    }
}

/// Where a tab of a removed pane goes: the pane it is carried to and the
/// tab as that pane's store reports it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Carried {
    pub pane: String,
    pub tab: Tab,
}

/// `topology` without `pane`, as the daemon's tree without it shows it: its
/// column keeps its id and loses the pane, and a column left empty goes.
pub fn removing(topology: &Topology, pane: &str) -> Topology {
    let panes = topology.panes.iter().filter(|p| p.id != pane).cloned().collect();
    let screens = topology
        .screens
        .iter()
        .map(|columns| {
            columns
                .iter()
                .filter_map(|column| {
                    let mut column = column.clone();
                    column.panes.retain(|id| id != pane);
                    (!column.panes.is_empty()).then_some(column)
                })
                .collect()
        })
        .collect();
    Topology::new(topology.workspace.clone(), panes, screens)
}

/// Without `pane`, each of its tabs that `carried` (by tab id) gives a pane
/// carried there first: a moved tab never leaves the topology, so its
/// browser focus mode stays. A tab whose destination the topology lacks,
/// or that is already there, leaves with the pane.
pub fn removing_carrying(
    topology: &Topology,
    pane: &str,
    carried: &BTreeMap<String, Carried>,
) -> Topology {
    let mut panes = topology.panes.clone();
    let tabs = topology.panes.iter().find(|p| p.id == pane).map(|p| p.tabs.clone());
    for tab in tabs.unwrap_or_default() {
        let Some(moved) = carried.get(&tab.id) else { continue };
        let Some(target) = panes.iter_mut().find(|p| p.id == moved.pane) else { continue };
        if target.tab(&moved.tab.id).is_some() {
            continue;
        }
        target.tabs.push(moved.tab.clone());
    }
    let carrying = Topology::new(topology.workspace.clone(), panes, topology.screens.clone());
    removing(&carrying, pane)
}

/// Who chose an event, by its source.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventFacts {
    /// A focus or selection change the person made by mouse, keyboard or
    /// palette: not the CLI, a script, the app or the daemon.
    pub is_persons_own: bool,
    /// A focus choice of the person's: a move from their own entry, or the
    /// responder report of their click (a key's responder change is none).
    pub chooses_focus_as_person: bool,
    /// A focus choice of a run the person chose from a menu: any focus or
    /// selection move, and any responder report no key's dispatch made.
    pub chooses_focus_in_menu_pick: bool,
    /// [`FocusEvent::changes_view`].
    pub changes_view: bool,
}

/// [`EventFacts::is_persons_own`].
pub fn is_persons_own(event: &FocusEvent) -> bool {
    match event {
        FocusEvent::FocusPane { source, .. }
        | FocusEvent::SelectTab { source, .. }
        | FocusEvent::FocusTarget { source, .. }
        | FocusEvent::Responder { source, .. } => {
            matches!(source, Source::Mouse | Source::Keyboard | Source::Palette)
        }
        _ => false,
    }
}

/// [`EventFacts::chooses_focus_as_person`].
pub fn chooses_focus_as_person(event: &FocusEvent) -> bool {
    if let FocusEvent::Responder { source, .. } = event {
        return *source == Source::Mouse;
    }
    is_persons_own(event)
}

/// [`EventFacts::chooses_focus_in_menu_pick`].
pub fn chooses_focus_in_menu_pick(event: &FocusEvent) -> bool {
    match event {
        FocusEvent::Responder { source, .. } => *source != Source::Keyboard,
        FocusEvent::FocusPane { .. }
        | FocusEvent::SelectTab { .. }
        | FocusEvent::FocusTarget { .. } => true,
        _ => false,
    }
}

/// Every fact of [`EventFacts`] for `event`.
pub fn event_facts(event: &FocusEvent) -> EventFacts {
    EventFacts {
        is_persons_own: is_persons_own(event),
        chooses_focus_as_person: chooses_focus_as_person(event),
        chooses_focus_in_menu_pick: chooses_focus_in_menu_pick(event),
        changes_view: event.changes_view(),
    }
}

/// The stable `debug.focus` name of a responder (`content:<pane>`).
pub fn responder_name(responder: &Responder) -> String {
    match responder {
        Responder::Content { pane } => format!("content:{pane}"),
        Responder::AddressBar { pane } => format!("addressBar:{pane}"),
        Responder::FindBar { pane } => format!("findBar:{pane}"),
        Responder::DevTools { pane } => format!("devTools:{pane}"),
        Responder::Sidebar {} => "sidebar".into(),
        Responder::SidebarField {} => "sidebarField".into(),
        Responder::TextField {} => "textField".into(),
        Responder::WindowOrNone {} => "windowOrNone".into(),
    }
}

/// Whether a reduction re-applies the responder because the focus started
/// or stopped waiting for another tab: `waited` before, `awaits` after, and
/// whether the reduction already moves the responder. The page the person
/// left gives up the keys in the key's turn (P0 INVERSE-KEY).
pub fn reapplies_on_wait_change(waited: bool, awaits: bool, moves_responder: bool) -> bool {
    waited != awaits && !moves_responder
}

/// The JSON operations over these rules (the app FFI's `focus_state_*`).
pub const OPERATIONS: [&str; 7] = [
    "focus_state_awaits_other_tab",
    "focus_state_event_facts",
    "focus_state_removing_pane",
    "focus_state_resolved_facts",
    "focus_state_responder_name",
    "focus_state_type_ahead_survives",
    "focus_state_wait_change",
];

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct SurvivesRequest {
    wait: TypeAheadWait,
    settled: Resolved,
    #[serde(default)]
    settled_page: Option<String>,
}

#[derive(Deserialize)]
struct ResolvedRequest {
    resolved: Resolved,
}

#[derive(Deserialize)]
struct AwaitsRequest {
    #[serde(default)]
    expecting: Option<ExpectationKey>,
    resolved: Resolved,
}

#[derive(Deserialize)]
struct RemovingRequest {
    topology: Topology,
    pane: String,
    #[serde(default)]
    carried: BTreeMap<String, Carried>,
}

#[derive(Deserialize)]
struct EventRequest {
    event: FocusEvent,
}

#[derive(Deserialize)]
struct ResponderRequest {
    responder: Responder,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WaitChangeRequest {
    waited: bool,
    awaits: bool,
    moves_responder: bool,
}

/// Answers operation `op` (one of [`OPERATIONS`]) for its JSON `request`;
/// none for an unknown operation or a request that does not decode.
pub fn call(op: &str, request: &[u8]) -> Option<serde_json::Value> {
    use serde_json::{from_slice, json, to_value};
    let reply = match op {
        "focus_state_type_ahead_survives" => {
            let r: SurvivesRequest = from_slice(request).ok()?;
            json!({"survives": r.wait.survives(&r.settled, r.settled_page.as_deref())})
        }
        "focus_state_resolved_facts" => {
            let r: ResolvedRequest = from_slice(request).ok()?;
            to_value(resolved_facts(&r.resolved)).ok()?
        }
        "focus_state_awaits_other_tab" => {
            let r: AwaitsRequest = from_slice(request).ok()?;
            json!({"awaits": awaits_other_tab(r.expecting.as_ref(), &r.resolved)})
        }
        "focus_state_removing_pane" => {
            let r: RemovingRequest = from_slice(request).ok()?;
            json!({"topology": removing_carrying(&r.topology, &r.pane, &r.carried)})
        }
        "focus_state_event_facts" => {
            let r: EventRequest = from_slice(request).ok()?;
            to_value(event_facts(&r.event)).ok()?
        }
        "focus_state_responder_name" => {
            let r: ResponderRequest = from_slice(request).ok()?;
            json!({"name": responder_name(&r.responder)})
        }
        "focus_state_wait_change" => {
            let r: WaitChangeRequest = from_slice(request).ok()?;
            json!({"reapplies": reapplies_on_wait_change(r.waited, r.awaits, r.moves_responder)})
        }
        _ => return None,
    };
    Some(reply)
}

#[cfg(test)]
#[path = "state_rules_tests.rs"]
mod tests;
