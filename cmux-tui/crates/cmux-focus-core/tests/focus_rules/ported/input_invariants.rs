//! The input invariants (plans/cmux-next/input-spec.md), ported from the
//! Swift `InputInvariants` with its `ChromiumPageFocusInvariantTests`, plus
//! one case per rule: each check fires on the state that breaks it and
//! stays quiet on the state that keeps it.

use cmux_focus_core::event::{FocusEvent, Responder, Source};
use cmux_focus_core::invariants::{
    Invariant, KeyWindow, Model, Observation, ObservedWindow, expected_responder, model, step,
    transition, world,
};
use cmux_focus_core::reducer;
use cmux_focus_core::state::{
    Context, Expectation, ExpectationKey, FocusState, Overlay, Resolved, Target,
};
use cmux_focus_core::topology::{Kind, Pane, Tab, Topology};
use std::collections::{HashMap, HashSet};

fn ids(violations: &[cmux_focus_core::invariants::Violation]) -> Vec<Invariant> {
    violations.iter().map(|v| v.invariant).collect()
}

fn tab(id: &str, kind: Kind) -> Tab {
    Tab { id: id.into(), surface: None, kind, terminal: None }
}

/// One pane `p1` with a terminal `t1` and a browser tab `b1`, `selected`
/// selected.
fn topology(selected: &str) -> Topology {
    Topology::new(
        Some("w".into()),
        vec![Pane {
            id: "p1".into(),
            tabs: vec![tab("t1", Kind::Terminal), tab("b1", Kind::Browser)],
            selected: Some(selected.into()),
        }],
        Vec::new(),
    )
}

/// A consistent model focused on `p1`'s selected tab.
fn focused(selected: &str) -> Model {
    let resolved = if selected == "t1" {
        Resolved::Terminal { pane: "p1".into(), tab: "t1".into() }
    } else {
        Resolved::BrowserPage { pane: "p1".into(), tab: selected.into() }
    };
    Model {
        window_key: true,
        topology: topology(selected),
        pane: Some("p1".into()),
        resolved: resolved.clone(),
        underlying: resolved,
        context: Context { terminal: selected == "t1", browser: selected != "t1", agent: false },
        ..Model::default()
    }
}

// MARK: Chromium pages (ChromiumPageFocusInvariantTests)

/// One window focused on a page tab: in Chromium its page window has the
/// keys and this window keeps no responder; in WebKit the page's view in the
/// pane is first responder of a key window.
fn page_observation(chromium: bool) -> Observation {
    let resolved = Resolved::Page { pane: "pane_a".into(), tab: "tab_keys".into() };
    let model = Model {
        resolved: resolved.clone(),
        underlying: resolved,
        window_key: !chromium,
        ..Model::default()
    };
    let window = ObservedWindow {
        id: "window_1".into(),
        model,
        responder: if chromium {
            Responder::WindowOrNone {}
        } else {
            Responder::Content { pane: "pane_a".into() }
        },
        responder_class: None,
        is_key: !chromium,
        layout_focus: None,
        ghostty_focused: Vec::new(),
        child_page: chromium.then(|| "tab_keys".into()),
        presented: HashMap::from([("pane_a".into(), "tab_keys".into())]),
        child_window_tabs: if chromium { vec!["tab_keys".into()] } else { Vec::new() },
        has_sheet: false,
        top_page: None,
    };
    Observation {
        windows: vec![window],
        key_window: if chromium {
            KeyWindow::ChildPage { window: "window_1".into() }
        } else {
            KeyWindow::Window { id: "window_1".into() }
        },
        palette_open: false,
        active_window: Some("window_1".into()),
        context: Context::default(),
    }
}

fn page_violations(observation: &Observation) -> Vec<Invariant> {
    let checked =
        [Invariant::ResponderMatches, Invariant::ChromiumMatches, Invariant::KeyWindowOwned];
    ids(&world(observation).violations).into_iter().filter(|i| checked.contains(i)).collect()
}

#[test]
fn a_focused_chromium_page_with_the_keys_is_in_sync() {
    assert_eq!(page_violations(&page_observation(true)), []);
}

#[test]
fn a_focused_webkit_page_with_the_responder_is_in_sync() {
    assert_eq!(page_violations(&page_observation(false)), []);
}

// MARK: Model (F)

#[test]
fn a_consistent_model_breaks_nothing() {
    assert_eq!(ids(&model(&focused("t1"), Some("w1"))), []);
    assert_eq!(ids(&model(&focused("b1"), Some("w1"))), []);
}

#[test]
fn a_machine_state_breaks_nothing() {
    let mut state = FocusState::default();
    let mut effects = Vec::new();
    reducer::set_topology(&mut state, topology("b1"), &mut effects);
    reducer::reduce(
        &mut state,
        &FocusEvent::FocusTarget { target: Target::AddressBar {}, source: Source::Keyboard },
        &mut effects,
    );
    let view = Model::of(&state);
    assert_eq!(view.resolved, Resolved::AddressBar { pane: "p1".into(), tab: "b1".into() });
    assert_eq!(ids(&model(&view, None)), []);
}

#[test]
fn f1_an_open_overlay_is_the_target() {
    let mut m = focused("t1");
    m.overlays = vec![Overlay::Palette];
    let v = model(&m, Some("w1"));
    assert_eq!(ids(&v), [Invariant::OverlayOnTop]);
    assert_eq!(v[0].window.as_deref(), Some("w1"));
    assert_eq!(v[0].detail, "resolved terminal with overlay palette open");
    m.resolved = Resolved::Overlay { overlay: Overlay::Palette };
    assert_eq!(ids(&model(&m, None)), []);
}

#[test]
fn f2_focus_names_a_live_selected_pane_and_tab() {
    let mut m = focused("t1");
    m.pane = Some("gone".into());
    assert_eq!(
        ids(&model(&m, None)),
        [Invariant::LivePane, Invariant::LivePane, Invariant::TargetKind]
    );
    let mut m = focused("t1");
    m.topology = topology("b1");
    let v = model(&m, None);
    assert!(v.iter().any(|v| v.detail == "resolved tab t1 is not the selection of p1"), "{v:?}");
}

#[test]
fn f3_a_window_with_panes_has_a_focused_pane() {
    let mut m = focused("t1");
    m.pane = None;
    m.resolved = Resolved::None {};
    assert_eq!(ids(&model(&m, None)), [Invariant::PaneWhenPanes]);
    m.target = Target::Sidebar { keyboard: false };
    assert_eq!(ids(&model(&m, None)), []);
}

#[test]
fn f4_the_target_fits_the_tab_kind() {
    let mut m = focused("t1");
    m.resolved = Resolved::BrowserPage { pane: "p1".into(), tab: "t1".into() };
    assert_eq!(ids(&model(&m, None)), [Invariant::TargetKind]);
    let mut m = focused("t1");
    m.target = Target::FindBar {};
    let v = model(&m, None);
    assert_eq!(ids(&v), [Invariant::TargetKind]);
    assert_eq!(v[0].detail, "target findBar kept on a terminal tab");
}

#[test]
fn f5_no_stale_expectation() {
    let mut m = focused("t1");
    m.generation = 3;
    m.expectation = Some(Expectation {
        key: ExpectationKey::Tab { id: "new".into() },
        target: Target::Content {},
        away_from: None,
        generation: 2,
    });
    let v = model(&m, None);
    assert_eq!(ids(&v), [Invariant::NoStaleExpectation]);
    assert_eq!(v[0].detail, "expectation tab(\"new\") from generation 2 at 3");
}

#[test]
fn f6_focus_mode_names_live_tabs() {
    let mut m = focused("b1");
    m.browser_focus_mode = ["b1".to_owned(), "zz".to_owned()].into();
    let v = model(&m, None);
    assert_eq!(ids(&v), [Invariant::FocusModeLive]);
    assert_eq!(v[0].detail, "focus mode on missing tabs [\"zz\"]");
}

// MARK: Transitions (T)

#[test]
fn t1_a_stale_expect_never_moves_focus() {
    let old = Model { generation: 5, ..focused("t1") };
    let event = FocusEvent::Expect {
        key: ExpectationKey::Tab { id: "b1".into() },
        target: Target::Content {},
        away_from: None,
        generation: 4,
    };
    let moved = Model { target: Target::AddressBar {}, ..old.clone() };
    assert_eq!(ids(&transition(&old, &event, &moved, None)), [Invariant::NoSteal]);
    assert_eq!(ids(&transition(&old, &event, &old, None)), []);
    // A current expect may change it.
    let current = FocusEvent::Expect {
        key: ExpectationKey::Tab { id: "b1".into() },
        target: Target::Content {},
        away_from: None,
        generation: 5,
    };
    assert_eq!(ids(&transition(&old, &current, &moved, None)), []);
}

#[test]
fn t2_passive_events_never_retarget() {
    let old = focused("t1");
    let moved = Model { pane: Some("p9".into()), ..old.clone() };
    let v = transition(&old, &FocusEvent::WindowKey { key: true }, &moved, Some("w1"));
    assert_eq!(ids(&v), [Invariant::PassiveEvents]);
    assert_eq!(v[0].detail, "windowKey(true) moved focus p1/content -> p9/content");
    let report = FocusEvent::Responder { responder: Responder::Sidebar {}, source: Source::Mouse };
    // A responder report moves focus only when no overlay is open.
    assert_eq!(ids(&transition(&old, &report, &moved, None)), []);
    let under = Model { overlays: vec![Overlay::Sheet], ..old.clone() };
    assert_eq!(ids(&transition(&under, &report, &moved, None)), [Invariant::PassiveEvents]);
    // A user choice may move it.
    let choice =
        FocusEvent::FocusPane { pane: "p9".into(), workspace: None, source: Source::Mouse };
    assert_eq!(ids(&transition(&old, &choice, &moved, None)), []);
}

#[test]
fn t3_the_generation_never_decreases() {
    let old = Model { generation: 7, ..focused("t1") };
    let new = Model { generation: 6, ..focused("t1") };
    let event = FocusEvent::BeginIntent {};
    assert_eq!(ids(&transition(&old, &event, &new, None)), [Invariant::MonotonicGeneration]);
    // The wrap from the largest generation is not a decrease.
    let top = Model { generation: u64::MAX, ..focused("t1") };
    assert_eq!(ids(&transition(&top, &event, &new, None)), []);
}

#[test]
fn a_step_runs_the_model_and_transition_checks() {
    let old = Model { generation: 7, ..focused("t1") };
    let mut new = Model { generation: 6, ..focused("t1") };
    new.overlays = vec![Overlay::Rename];
    assert_eq!(
        ids(&step(&old, &FocusEvent::BeginIntent {}, &new, None)),
        [Invariant::OverlayOnTop, Invariant::MonotonicGeneration]
    );
}

// MARK: World (W)

fn terminal_window() -> ObservedWindow {
    ObservedWindow {
        id: "w1".into(),
        model: focused("t1"),
        responder: Responder::Content { pane: "p1".into() },
        responder_class: Some("GhosttySurfaceView".into()),
        is_key: true,
        layout_focus: Some("p1".into()),
        ghostty_focused: vec!["t1".into()],
        child_page: None,
        presented: HashMap::from([("p1".into(), "t1".into())]),
        child_window_tabs: Vec::new(),
        has_sheet: false,
        top_page: None,
    }
}

fn observe(window: ObservedWindow) -> Observation {
    let context = window.model.context;
    Observation {
        key_window: KeyWindow::Window { id: window.id.clone() },
        active_window: Some(window.id.clone()),
        windows: vec![window],
        palette_open: false,
        context,
    }
}

#[test]
fn a_terminal_window_in_sync_breaks_nothing() {
    let result = world(&observe(terminal_window()));
    assert_eq!(ids(&result.violations), []);
    assert!(result.unsettled.is_empty());
}

#[test]
fn w1_to_w3_the_platform_matches_the_model() {
    let mut window = terminal_window();
    window.responder = Responder::Sidebar {};
    window.layout_focus = Some("p2".into());
    window.ghostty_focused = vec!["t9".into()];
    let v = world(&observe(window)).violations;
    assert_eq!(
        ids(&v),
        [Invariant::LayoutMatches, Invariant::ResponderMatches, Invariant::GhosttyMatches]
    );
    assert_eq!(v[1].detail, "appkit sidebar (GhosttySurfaceView) != model terminal");
    assert_eq!(v[2].detail, "ghostty [\"t9\"] != [t1]");
    // Ghostty focus in a window that is not key.
    let mut window = terminal_window();
    window.is_key = false;
    let v = world(&observe(window)).violations;
    assert!(
        v.iter().any(|v| v.detail == "ghostty [\"t1\"] while model is terminal, window not key")
    );
}

/// P0 INVERSE-KEY (5fe33a327ef): a window whose focus is on its way to another
/// tab (a creation's new tab the window does not show yet) is unsettled: the
/// page the person left gives up the keys meanwhile, so its content checks
/// (W1, the Chromium key window) must not file a desync for it. The Swift world
/// check had this rule; the Rust one, which the app now calls, must have it too.
#[test]
fn a_window_whose_focus_waits_for_another_tab_is_unsettled() {
    // The Chromium page b1 has the keys; the person asked for a new terminal tab
    // s9, which no topology shows yet, and the page already gave up its keys.
    let mut window = terminal_window();
    window.model = focused("b1");
    window.model.expectation = Some(Expectation {
        key: ExpectationKey::Tab { id: "s9".into() },
        target: Target::Content {},
        away_from: None,
        generation: window.model.generation,
    });
    window.presented = HashMap::from([("p1".into(), "b1".into())]);
    window.responder = Responder::WindowOrNone {};
    window.responder_class = None;
    window.ghostty_focused = Vec::new();
    window.child_page = None;
    let result = world(&observe(window.clone()));
    assert_eq!(result.unsettled, ["w1".to_owned()]);
    assert!(
        !ids(&result.violations).contains(&Invariant::ResponderMatches),
        "{:?}",
        result.violations
    );
    // The same window with no wait is settled, and its responder is checked.
    window.model.expectation = None;
    let result = world(&observe(window));
    assert!(result.unsettled.is_empty());
    assert!(
        ids(&result.violations).contains(&Invariant::ResponderMatches),
        "{:?}",
        result.violations
    );
}

/// An expectation for the tab the focus already shows is no wait for another tab.
#[test]
fn a_wait_for_the_focused_tab_is_settled() {
    let mut window = terminal_window();
    window.model.expectation = Some(Expectation {
        key: ExpectationKey::Tab { id: "t1".into() },
        target: Target::Content {},
        away_from: None,
        generation: window.model.generation,
    });
    let result = world(&observe(window));
    assert!(result.unsettled.is_empty());
    assert_eq!(ids(&result.violations), []);
}

#[test]
fn w8_and_settle_every_shown_pane_shows_its_selection() {
    let mut window = terminal_window();
    window.presented.insert("p1".into(), "b1".into());
    let result = world(&observe(window));
    // The focused pane does not present the targeted tab yet: unsettled.
    assert_eq!(result.unsettled, ["w1".to_owned()]);
    assert_eq!(ids(&result.violations), []);
    // Under a top page the window is neither checked nor unsettled.
    let mut window = terminal_window();
    window.presented.insert("p1".into(), "b1".into());
    window.top_page = Some(true);
    assert!(world(&observe(window)).unsettled.is_empty());
    // A pane that selects a tab it does not hold.
    let mut window = terminal_window();
    window.model.topology.panes.push(Pane {
        id: "p2".into(),
        tabs: vec![tab("x", Kind::Terminal)],
        selected: Some("y".into()),
    });
    window.presented.insert("p2".into(), "x".into());
    let v = world(&observe(window)).violations;
    assert_eq!(ids(&v), [Invariant::PresentedMatchesSelection]);
    assert_eq!(v[0].detail, "pane p2 selects y, which it does not hold");
}

#[test]
fn w5_to_w7_key_window_overlays_and_context() {
    // The model thinks it is not key while AppKit made it key.
    let mut window = terminal_window();
    window.model.window_key = false;
    assert_eq!(ids(&world(&observe(window)).violations), [Invariant::KeyWindowOwned]);
    // The palette is open but no window's overlay stack has it.
    let mut observation = observe(terminal_window());
    observation.palette_open = true;
    assert_eq!(ids(&world(&observation).violations), [Invariant::OverlaysMatch]);
    // A sheet is attached with no sheet overlay.
    let mut window = terminal_window();
    window.has_sheet = true;
    assert_eq!(ids(&world(&observe(window)).violations), [Invariant::OverlaysMatch]);
    // Another window is active while the keys go to this one, and the
    // published context is not this window's.
    let mut observation = observe(terminal_window());
    observation.active_window = Some("w2".into());
    observation.context = Context { browser: true, ..Context::default() };
    let v = world(&observation).violations;
    assert_eq!(ids(&v), [Invariant::ContextMatches, Invariant::ContextMatches]);
    assert_eq!(v[0].detail, "active window w2 while the keys go to w1");
    // An app-wide panel with the keys and no overlay anywhere.
    let mut observation = observe(terminal_window());
    observation.windows[0].model.window_key = false;
    observation.key_window = KeyWindow::Panel { window: None, kind: "palette".into() };
    let v = world(&observation).violations;
    assert_eq!(ids(&v), [Invariant::KeyWindowOwned]);
    assert_eq!(v[0].detail, "panel palette has the keys but no window has an overlay");
}

#[test]
fn the_expected_responder_table() {
    let p = || "p".to_owned();
    let t = || "t".to_owned();
    let content = Some(Responder::Content { pane: p() });
    assert_eq!(expected_responder(&Resolved::Terminal { pane: p(), tab: t() }, None), content);
    assert_eq!(expected_responder(&Resolved::BrowserPage { pane: p(), tab: t() }, None), content);
    assert_eq!(
        expected_responder(&Resolved::AgentPage { pane: p(), tab: t() }, Some("t")),
        Some(Responder::WindowOrNone {})
    );
    assert_eq!(
        expected_responder(&Resolved::AddressBar { pane: p(), tab: t() }, None),
        Some(Responder::AddressBar { pane: p() })
    );
    assert_eq!(
        expected_responder(&Resolved::DevTools { pane: p(), tab: t() }, None),
        Some(Responder::WindowOrNone {})
    );
    assert_eq!(expected_responder(&Resolved::EmptyPane { pane: p() }, None), None);
    assert_eq!(expected_responder(&Resolved::Overlay { overlay: Overlay::Sheet }, None), None);
}

#[test]
fn ghostty_agrees_only_for_the_key_windows_terminal() {
    let own: HashSet<String> = ["t1".to_owned(), "t2".to_owned()].into();
    let terminal = Resolved::Terminal { pane: "p".into(), tab: "t1".into() };
    assert_eq!(terminal.ghostty_mismatch(&["t1".into(), "other".into()], &own, true), None);
    assert_eq!(
        terminal.ghostty_mismatch(&["t2".into()], &own, true).as_deref(),
        Some("ghostty focused [\"t2\"] != [t1]")
    );
    assert_eq!(
        terminal.ghostty_mismatch(&["t1".into()], &own, false).as_deref(),
        Some("ghostty focused [\"t1\"] while model is terminal (window not key)")
    );
    assert_eq!(Resolved::Sidebar {}.ghostty_mismatch(&["other".into()], &own, true), None);
}

/// The app sends its `InputObservation` as its `Codable` JSON: the shapes
/// decode, and the result encodes as its `InputInvariants.WorldResult`.
#[test]
fn the_apps_observation_json_decodes() {
    let json = r#"{
      "windows": [{
        "id": "window_1",
        "model": {
          "windowKey": false, "appActive": true,
          "topology": {"workspace": "w", "panes": [{"id": "pane_a", "tabs": [{"id": "tab_keys", "kind": "page"}], "selected": "tab_keys"}], "screens": []},
          "pane": "pane_a", "target": {"content": {}}, "overlays": [], "isDragging": false,
          "browserFocusMode": [], "generation": 4, "sidebarHidden": false,
          "resolved": {"page": {"pane": "pane_a", "tab": "tab_keys"}},
          "underlying": {"page": {"pane": "pane_a", "tab": "tab_keys"}},
          "context": {"terminal": false, "browser": false, "agent": false},
          "isBrowserFocusModeActive": false
        },
        "responder": {"windowOrNone": {}},
        "isKey": false, "layoutFocus": "pane_a", "ghosttyFocused": [], "childPage": "tab_keys",
        "presented": {"pane_a": "tab_keys"}, "childWindowTabs": ["tab_keys"], "hasSheet": false
      }],
      "keyWindow": {"childPage": {"window": "window_1"}},
      "paletteOpen": false, "activeWindow": "window_1",
      "context": {"terminal": false, "browser": false, "agent": false}
    }"#;
    let observation: Observation = serde_json::from_str(json).unwrap();
    let result = world(&observation);
    assert_eq!(ids(&result.violations), []);
    let encoded = serde_json::to_value(&result).unwrap();
    assert_eq!(encoded, serde_json::json!({"violations": [], "unsettled": []}));
    let broken: Observation = serde_json::from_str(
        &json.replace(r#""activeWindow": "window_1""#, r#""activeWindow": "w2""#),
    )
    .unwrap();
    let encoded = serde_json::to_value(world(&broken).violations).unwrap();
    assert_eq!(
        encoded,
        serde_json::json!([{
            "invariant": "W7", "window": "window_1",
            "detail": "active window w2 while the keys go to window_1"
        }])
    );
}

// MARK: debug.focus's Ghostty check (GhosttyFocusAgreementTests)

fn tabs(ids: &[&str]) -> Vec<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

fn own(ids: &[&str]) -> HashSet<String> {
    ids.iter().map(|id| (*id).to_owned()).collect()
}

/// The same texts as the Swift check, for each case.
#[test]
fn the_key_windows_terminal_must_be_the_only_ghostty_focus_of_its_tabs() {
    let terminal = Resolved::Terminal { pane: "p".into(), tab: "t".into() };
    assert_eq!(
        terminal.ghostty_mismatch(&tabs(&["t", "elsewhere"]), &own(&["t", "u"]), true),
        None
    );
    assert_eq!(
        terminal.ghostty_mismatch(&tabs(&["u"]), &own(&["t", "u"]), true).as_deref(),
        Some("ghostty focused [\"u\"] != [t]")
    );
    assert_eq!(
        terminal.ghostty_mismatch(&[], &own(&["t"]), true).as_deref(),
        Some("ghostty focused [] != [t]")
    );
}

#[test]
fn no_other_focus_may_leave_a_ghostty_focus_in_its_window() {
    let sidebar = Resolved::Sidebar {};
    assert_eq!(sidebar.ghostty_mismatch(&tabs(&["elsewhere"]), &own(&["t"]), true), None);
    assert_eq!(
        sidebar.ghostty_mismatch(&tabs(&["t"]), &own(&["t"]), true).as_deref(),
        Some("ghostty focused [\"t\"] while model is sidebar")
    );
    let terminal = Resolved::Terminal { pane: "p".into(), tab: "t".into() };
    assert_eq!(
        terminal.ghostty_mismatch(&tabs(&["t"]), &own(&["t"]), false).as_deref(),
        Some("ghostty focused [\"t\"] while model is terminal (window not key)")
    );
}
