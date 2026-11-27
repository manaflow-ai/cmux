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
mod tests {
    use super::*;
    use crate::state::Target;
    use crate::topology::{Column, Kind, Pane};
    use serde_json::json;

    fn agent(pane: &str, tab: &str) -> Resolved {
        Resolved::AgentPage { pane: pane.into(), tab: tab.into() }
    }

    fn terminal(pane: &str, tab: &str) -> Resolved {
        Resolved::Terminal { pane: pane.into(), tab: tab.into() }
    }

    fn waiting() -> TypeAheadWait {
        TypeAheadWait { focus: agent("pane_a", "pending_tab_1"), page: "readiness-1".into() }
    }

    // TypeAheadRekeyTests

    #[test]
    fn keys_survive_the_tabs_store_id() {
        assert!(waiting().survives(&agent("pane_a", "tab_1"), Some("readiness-1")));
    }

    #[test]
    fn keys_survive_the_same_focus() {
        assert!(waiting().survives(&agent("pane_a", "pending_tab_1"), Some("readiness-1")));
    }

    #[test]
    fn keys_drop_on_another_page() {
        assert!(!waiting().survives(&agent("pane_a", "tab_2"), Some("readiness-2")));
    }

    #[test]
    fn keys_drop_when_focus_leaves_the_page() {
        assert!(!waiting().survives(&terminal("pane_b", "tab_3"), None));
        assert!(!waiting().survives(&Resolved::Sidebar {}, None));
    }

    #[test]
    fn keys_survive_the_stand_in_panes_real_id() {
        let typed = TypeAheadWait {
            focus: agent("pane:6917529027641081902", "tab_1"),
            page: "readiness-1".into(),
        };
        assert!(typed.survives(&agent("pane_57a5fd95", "tab_1"), Some("readiness-1")));
        assert!(!typed.survives(&agent("pane_57a5fd95", "tab_2"), Some("readiness-2")));
        assert!(!typed.survives(&terminal("pane_57a5fd95", "tab_3"), None));
    }

    #[test]
    fn keys_drop_in_another_pane() {
        assert!(!waiting().survives(&agent("pane_b", "tab_1"), Some("readiness-1")));
    }

    // FocusTopologyMoveRemovalTests

    fn topology() -> Topology {
        let tab = |id: &str, kind| Tab { id: id.into(), surface: None, kind, terminal: None };
        let column = |id: &str, pane: &str| Column {
            id: id.into(),
            panes: vec![pane.into()],
            ..Default::default()
        };
        Topology::new(
            Some("w".into()),
            vec![
                Pane { id: "left".into(), tabs: vec![tab("a", Kind::Terminal)], selected: None },
                Pane { id: "right".into(), tabs: vec![tab("b", Kind::Browser)], selected: None },
            ],
            vec![vec![column("c1", "left"), column("c2", "right")]],
        )
    }

    fn carry_b_to(pane: &str) -> BTreeMap<String, Carried> {
        let tab = topology().pane("right").unwrap().tabs[0].clone();
        BTreeMap::from([("b".into(), Carried { pane: pane.into(), tab })])
    }

    #[test]
    fn the_moved_tab_lands_in_its_destination() {
        let after = removing_carrying(&topology(), "right", &carry_b_to("left"));
        assert!(!after.contains_pane("right"));
        let left = after.pane("left").unwrap();
        assert_eq!(left.tabs.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["a", "b"]);
        assert_eq!(left.tab("b").unwrap().kind, Kind::Browser);
        assert!(after.contains_tab("b"));
    }

    #[test]
    fn an_unknown_destination_drops_the_pane_as_before() {
        assert_eq!(
            removing_carrying(&topology(), "right", &carry_b_to("gone")),
            removing(&topology(), "right")
        );
    }

    #[test]
    fn removing_a_pane_drops_its_emptied_column_and_keeps_the_others() {
        let after = removing(&topology(), "right");
        assert_eq!(after.screens.len(), 1);
        assert_eq!(after.screens[0].iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["c1"]);
        assert_eq!(removing(&topology(), "absent"), topology());
    }

    // AwaitedContentTests.aFocusedAgentOrPageTabIsAwaitedAsAPageUntilItShows

    #[test]
    fn a_focused_agent_or_page_tab_is_awaited_as_a_page() {
        for resolved in [agent("p", "a"), Resolved::Page { pane: "p".into(), tab: "a".into() }] {
            let awaitable = awaitable_content(&resolved).expect("held for nothing");
            assert_eq!(
                awaitable,
                AwaitableContent { pane: "p".into(), tab: "a".into(), is_page: true }
            );
            assert!(may_queue_typing(&resolved));
        }
        let facts = resolved_facts(&terminal("p", "t"));
        assert!(!facts.awaitable_content.unwrap().is_page);
        assert_eq!(facts.terminal_tab.as_deref(), Some("t"));
        assert!(!facts.may_queue_typing);
        assert_eq!(resolved_facts(&Resolved::Sidebar {}), ResolvedFacts::default());
        let dev = resolved_facts(&Resolved::DevTools { pane: "p".into(), tab: "b".into() });
        assert!(dev.is_dev_tools && dev.browser_tab.as_deref() == Some("b"));
        assert!(dev.awaitable_content.is_none());
    }

    #[test]
    fn awaits_other_tab_reads_the_expectation_key() {
        let tab = |id: &str| ExpectationKey::Tab { id: id.into() };
        assert!(!awaits_other_tab(None, &terminal("p", "t")));
        assert!(!awaits_other_tab(Some(&tab("t")), &terminal("p", "t")));
        assert!(awaits_other_tab(Some(&tab("new")), &terminal("p", "t")));
        assert!(awaits_other_tab(Some(&tab("new")), &Resolved::Sidebar {}));
        let surface = ExpectationKey::Surface { id: "t".into() };
        assert!(awaits_other_tab(Some(&surface), &terminal("p", "t")));
    }

    #[test]
    fn event_facts_follow_the_source() {
        let pane = |source| FocusEvent::FocusPane { pane: "p".into(), workspace: None, source };
        let responder = |source| FocusEvent::Responder {
            responder: Responder::Content { pane: "p".into() },
            source,
        };
        for source in [Source::Mouse, Source::Keyboard, Source::Palette] {
            assert!(is_persons_own(&pane(source)) && chooses_focus_as_person(&pane(source)));
        }
        for source in [Source::Cli, Source::Programmatic] {
            assert!(!is_persons_own(&pane(source)) && chooses_focus_in_menu_pick(&pane(source)));
        }
        assert!(chooses_focus_as_person(&responder(Source::Mouse)));
        assert!(!chooses_focus_as_person(&responder(Source::Keyboard)));
        assert!(is_persons_own(&responder(Source::Keyboard)));
        assert!(!chooses_focus_in_menu_pick(&responder(Source::Keyboard)));
        assert!(chooses_focus_in_menu_pick(&responder(Source::Cli)));
        let target = FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Cli };
        assert_eq!(
            event_facts(&target),
            EventFacts {
                is_persons_own: false,
                chooses_focus_as_person: false,
                chooses_focus_in_menu_pick: true,
                changes_view: true
            }
        );
        assert_eq!(event_facts(&FocusEvent::WindowKey { key: true }), EventFacts::default());
    }

    #[test]
    fn responder_names_are_stable() {
        assert_eq!(responder_name(&Responder::FindBar { pane: "p".into() }), "findBar:p");
        assert_eq!(responder_name(&Responder::WindowOrNone {}), "windowOrNone");
    }

    #[test]
    fn a_wait_change_reapplies_unless_the_responder_moves() {
        assert!(reapplies_on_wait_change(false, true, false));
        assert!(reapplies_on_wait_change(true, false, false));
        assert!(!reapplies_on_wait_change(true, true, false));
        assert!(!reapplies_on_wait_change(false, true, true));
    }

    #[test]
    fn the_shapes_are_the_apps_codable_shapes() {
        let wait: TypeAheadWait = serde_json::from_value(json!({
            "focus": {"agentPage": {"pane": "p", "tab": "t"}}, "page": "r"
        }))
        .unwrap();
        assert_eq!(wait.focus, agent("p", "t"));
        let facts = serde_json::to_value(resolved_facts(&agent("p", "t"))).unwrap();
        assert_eq!(
            facts,
            json!({"awaitableContent": {"pane": "p", "tab": "t", "isPage": true},
                   "isDevTools": false, "mayQueueTyping": true})
        );
    }
}
