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
