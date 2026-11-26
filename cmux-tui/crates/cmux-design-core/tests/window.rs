//! The window rules, ported value for value from the Swift tests (ClickTraceTests,
//! WindowZoomTests, WindowCycleReachesEachWindowTests, FocusRouteTests, FrameStripKeyRepeatTests,
//! LaunchDisplayTests, LaunchLayoutSettleTests, SwitchKeyChangesTests, TrafficLightsLineTests,
//! WindowedTrafficLightsTests), plus the press routing rules' own behavior.

use cmux_design_core::ops::call;
use cmux_design_core::window::click_trace::{
    self, CAPACITY, CONTROL_METHOD, ClickTrace, GRANT_WINDOW, KeyWindow, Press, WindowRef,
};
use cmux_design_core::window::diagnostics::{Mark, Row, Span, SwitchKeyChanges, pointer_move};
use cmux_design_core::window::fill::{Rgb, compensated_fill};
use cmux_design_core::window::launch::{
    self, LaunchDisplay, Move, SettleTally, key_repeat_delay, key_repeat_interval, mark_name,
    parse_display,
};
use cmux_design_core::window::press::{
    ChainWindow, CoveredButton, FocusOrigin, FullScreenTitlebarState, KeyNeutralFacts,
    KeyNeutralState, ResizeBand, focus_route_description, full_screen_titlebar_button, is_page,
    resize_bands_claim, shows_focus,
};
use cmux_design_core::window::targeting::WindowTargeting;
use cmux_design_core::window::top_row::{
    self, Glyph, Placement, RestingButton, WindowedTrafficLights, placement,
};
use cmux_design_core::window::zoom::WindowZoom;
use cmux_design_core::window::{EventKind, Point, Rect};
use serde_json::json;

// MARK: ClickTrace

fn press(kind: EventKind, timestamp: f64, x: f64, y: f64, window: Option<(&str, i64)>) -> Press {
    Press {
        kind,
        timestamp,
        x,
        y,
        window: window.map(|(name, number)| WindowRef { name: name.into(), number }),
    }
}

fn wref(name: &str, number: i64) -> WindowRef {
    WindowRef { name: name.into(), number }
}

#[test]
fn click_point_clamps_and_rounds() {
    assert_eq!(click_trace::point(f64::NAN), 0);
    assert_eq!(click_trace::point(f64::INFINITY), 0);
    assert_eq!(click_trace::point(-f64::INFINITY), 0);
    assert_eq!(click_trace::point(f64::MAX), i64::MAX);
    assert_eq!(click_trace::point(-f64::MAX), i64::MIN);
    assert_eq!(click_trace::point(41.6), 42);
}

#[test]
fn click_press_records_once_with_its_page_grants() {
    let mut trace = ClickTrace::default();
    let p = press(EventKind::LeftMouseDown, 5.0, 10.0, 20.0, Some(("NSPanel", 7)));
    trace.press(&p, 100.0, "t0");
    trace.press(&p, 100.0, "t0");
    trace.page_grant("tab_chat", "kept: first-frame hold", 100.2);
    trace.dispatched(EventKind::LeftMouseDown, 5.0, None);
    let entries = trace.entries(None);
    assert_eq!(entries.len(), 1);
    let e = &entries[0];
    assert_eq!(e.window, "NSPanel");
    assert_eq!(e.button, "left");
    assert_eq!(e.page_grants, vec!["tab_chat: kept: first-frame hold".to_string()]);
    assert!(!e.overlay_took);
    assert_eq!(e.key_window, None);
}

#[test]
fn click_not_finite_point_records_zero() {
    let mut trace = ClickTrace::default();
    trace.press(&press(EventKind::LeftMouseDown, 1.0, f64::NAN, f64::NAN, None), 0.0, "t");
    let e = &trace.entries(None)[0];
    assert_eq!((e.x, e.y), (0, 0));
    assert_eq!((e.window.as_str(), e.window_number), ("none", -1));
}

#[test]
fn click_late_grant_is_dropped() {
    let mut trace = ClickTrace::default();
    trace.press(&press(EventKind::LeftMouseDown, 5.0, 0.0, 0.0, Some(("NSWindow", 1))), 100.0, "t");
    trace.page_grant("tab_chat", "kept", 100.0 + GRANT_WINDOW + 0.5);
    assert!(trace.entries(None)[0].page_grants.is_empty());
}

#[test]
fn click_overlay_took_and_forwarded() {
    let mut trace = ClickTrace::default();
    let overlay = wref("NSPanel", 30);
    let parent = wref("NSWindow", 10);
    let page = press(EventKind::LeftMouseDown, 2.0, 1.0, 1.0, Some(("PageWindow", 20)));
    trace.overlay_took(&page, &overlay, 1.0, "t1");
    let mine = press(EventKind::LeftMouseDown, 3.0, 1.0, 1.0, Some(("NSPanel", 30)));
    trace.press(&mine, 2.0, "t2");
    trace.forwarded(EventKind::LeftMouseDown, 3.0, &parent);
    trace.forwarded(EventKind::LeftMouseDown, 2.0, &wref("PageWindow", 20));
    let entries = trace.entries(None);
    assert_eq!(entries.len(), 2);
    assert!(entries[0].overlay_took);
    assert_eq!(entries[0].forwarded_to_number, Some(30));
    assert!(!entries[1].overlay_took);
    assert_eq!(entries[1].forwarded_to.as_deref(), Some("NSWindow"));
    assert_eq!(entries[1].forwarded_to_number, Some(10));
}

#[test]
fn click_ring_keeps_capacity_newest() {
    let mut trace = ClickTrace::default();
    for i in 0..(CAPACITY + 25) {
        let p = press(EventKind::LeftMouseDown, (i + 1) as f64, 0.0, 0.0, Some(("NSWindow", 1)));
        trace.press(&p, i as f64, "t");
    }
    trace.press(&press(EventKind::LeftMouseUp, 9999.0, 0.0, 0.0, None), 9999.0, "t");
    let entries = trace.entries(None);
    assert_eq!(entries.len(), CAPACITY);
    assert_eq!(entries.first().unwrap().seq, 26);
    assert_eq!(entries.last().unwrap().seq, 225);
    assert!(entries.windows(2).all(|w| w[0].seq < w[1].seq));
    let last: Vec<u64> = trace.entries(Some(3)).iter().map(|e| e.seq).collect();
    assert_eq!(last, vec![223, 224, 225]);
}

#[test]
fn click_dispatched_and_settled_note_key_window() {
    let mut trace = ClickTrace::default();
    trace.press(&press(EventKind::RightMouseDown, 4.0, 0.0, 0.0, Some(("NSWindow", 1))), 0.0, "t");
    let key = KeyWindow { name: "NSWindow".into(), number: 1, first_responder: Some("V".into()) };
    trace.settled(4.0, Some(&key));
    let e = &trace.entries(None)[0];
    assert_eq!(e.button, "right");
    assert_eq!(e.key_window.as_deref(), Some("NSWindow"));
    assert_eq!(e.key_window_number, Some(1));
    assert_eq!(e.first_responder.as_deref(), Some("V"));
}

#[test]
fn click_control_method_matches_cli() {
    let cli = include_str!("../../cmux-tui/src/cli/app.rs");
    assert!(cli.contains(&format!("\"{CONTROL_METHOD}\"")));
}

#[test]
fn click_ops_route() {
    assert_eq!(call("window.clickPoint", &json!({"value": 41.6})).unwrap(), json!(42));
    assert_eq!(
        call("window.clickButton", &json!({"kind": "otherMouseDown"})).unwrap(),
        json!({"isPress": true, "button": "other"})
    );
}

// MARK: Press routing

fn facts() -> KeyNeutralFacts {
    KeyNeutralFacts {
        app_is_active: true,
        app_is_modal: false,
        window: 1,
        window_is_key: false,
        window_has_attached_sheet: false,
        key_window: Some(2),
        key_window_has_sheet_parent: false,
        key_window_is_page: true,
        target: Some(9),
    }
}

#[test]
fn key_neutral_press_goes_to_target_through_up() {
    let mut s = KeyNeutralState::default();
    let down = s.step(EventKind::LeftMouseDown, &facts(), false);
    assert!(down.routed);
    assert_eq!(down.deliver_to, Some(9));
    let drag = s.step(EventKind::LeftMouseDragged, &facts(), true);
    assert_eq!((drag.routed, drag.deliver_to), (true, Some(9)));
    let gone = s.step(EventKind::Pressure, &facts(), false);
    assert_eq!((gone.routed, gone.deliver_to), (true, None));
    let up = s.step(EventKind::LeftMouseUp, &facts(), true);
    assert_eq!((up.routed, up.deliver_to), (true, Some(9)));
    assert_eq!(s, KeyNeutralState::default());
    assert!(!s.step(EventKind::LeftMouseUp, &facts(), true).routed);
}

#[test]
fn key_neutral_press_declines_each_condition() {
    let cases: Vec<fn(&mut KeyNeutralFacts)> = vec![
        |f| f.app_is_active = false,
        |f| f.app_is_modal = true,
        |f| f.window_is_key = true,
        |f| f.window_has_attached_sheet = true,
        |f| f.key_window = None,
        |f| f.key_window = Some(1),
        |f| f.key_window_has_sheet_parent = true,
        |f| f.key_window_is_page = false,
        |f| f.target = None,
    ];
    for change in cases {
        let mut f = facts();
        change(&mut f);
        let mut s = KeyNeutralState::default();
        assert!(!s.step(EventKind::LeftMouseDown, &f, false).routed);
        assert!(!s.step(EventKind::LeftMouseDragged, &f, true).routed);
    }
}

#[test]
fn is_page_walks_page_parents_only() {
    let chain = [
        ChainWindow { id: 3, is_page: true, parent: Some(2) },
        ChainWindow { id: 2, is_page: true, parent: Some(1) },
        ChainWindow { id: 4, is_page: false, parent: Some(1) },
        ChainWindow { id: 5, is_page: true, parent: None },
    ];
    assert!(is_page(3, 1, &chain));
    assert!(is_page(2, 1, &chain));
    assert!(!is_page(4, 1, &chain));
    assert!(!is_page(5, 1, &chain));
    assert!(!is_page(6, 1, &chain));
    let cycle = [
        ChainWindow { id: 7, is_page: true, parent: Some(8) },
        ChainWindow { id: 8, is_page: true, parent: Some(7) },
    ];
    assert!(!is_page(7, 1, &cycle));
}

#[test]
fn full_screen_titlebar_press_clicks_on_up_over_same_button() {
    let mut s = FullScreenTitlebarState::default();
    assert!(!s.step(EventKind::LeftMouseDown, Some(1), None).taken);
    assert!(s.step(EventKind::LeftMouseDown, Some(1), Some(5)).taken);
    assert!(s.step(EventKind::LeftMouseDragged, Some(1), None).taken);
    assert!(!s.step(EventKind::LeftMouseDragged, Some(2), None).taken);
    let up = s.step(EventKind::LeftMouseUp, Some(1), Some(5));
    assert_eq!((up.taken, up.click), (true, Some(5)));
    assert!(s.step(EventKind::LeftMouseDown, Some(1), Some(5)).taken);
    let off = s.step(EventKind::LeftMouseUp, Some(1), Some(6));
    assert_eq!((off.taken, off.click), (true, None));
    assert!(!s.step(EventKind::LeftMouseUp, Some(1), Some(5)).taken);
    assert!(!s.step(EventKind::LeftMouseDown, None, Some(5)).taken);
}

#[test]
fn full_screen_titlebar_button_needs_cover_and_shown_enabled() {
    let b = CoveredButton { id: 4, enabled: true, hidden: false };
    assert_eq!(full_screen_titlebar_button(true, false, Some(b)), Some(4));
    assert_eq!(full_screen_titlebar_button(false, false, Some(b)), None);
    assert_eq!(full_screen_titlebar_button(true, true, Some(b)), None);
    assert_eq!(full_screen_titlebar_button(true, false, None), None);
    let off = CoveredButton { enabled: false, ..b };
    assert_eq!(full_screen_titlebar_button(true, false, Some(off)), None);
    let hidden = CoveredButton { hidden: true, ..b };
    assert_eq!(full_screen_titlebar_button(true, false, Some(hidden)), None);
}

#[test]
fn resize_bands_claim_own_shown_band_half_open() {
    let bands = [
        ResizeBand { window: 1, hidden: false, frame: Rect::new(0.0, 0.0, 10.0, 4.0) },
        ResizeBand { window: 1, hidden: true, frame: Rect::new(20.0, 0.0, 10.0, 4.0) },
        ResizeBand { window: 2, hidden: false, frame: Rect::new(40.0, 0.0, 10.0, 4.0) },
    ];
    assert!(resize_bands_claim(&bands, 1, Point { x: 0.0, y: 0.0 }));
    assert!(!resize_bands_claim(&bands, 1, Point { x: 10.0, y: 2.0 }));
    assert!(!resize_bands_claim(&bands, 1, Point { x: 25.0, y: 2.0 }));
    assert!(!resize_bands_claim(&bands, 1, Point { x: 45.0, y: 2.0 }));
    assert!(resize_bands_claim(&bands, 2, Point { x: 45.0, y: 2.0 }));
}

#[test]
fn shows_focus_only_in_key_window() {
    assert!(shows_focus(true, None));
    assert!(shows_focus(true, Some(true)));
    assert!(!shows_focus(true, Some(false)));
    assert!(!shows_focus(false, Some(true)));
}

#[test]
fn focus_route_description_names_origin_file_and_reason() {
    let d = focus_route_description(
        FocusOrigin::System,
        "restore after sheet",
        "/src/Tests/FocusRouteTests.swift",
        12,
    );
    assert!(d.starts_with("system "));
    assert!(d.contains("FocusRouteTests.swift:"));
    assert!(d.ends_with("restore after sheet"));
}

// MARK: Zoom (WindowZoomTests as state)

#[test]
fn zoom_goes_to_standard_and_back() {
    let start = Rect::new(100.0, 100.0, 800.0, 600.0);
    let standard = Rect::new(0.0, 0.0, 1440.0, 900.0);
    let mut z = WindowZoom::default();
    let to = z.target(start, standard).unwrap();
    assert_eq!(to, standard);
    let generation = z.begin(to, standard);
    assert_eq!(z.is_zooming_in(), Some(true));
    // Mid-animation, a second zoom reads the animation's target, so it goes back.
    let stale = z.begin(to, standard);
    z.end(generation);
    assert_eq!(z.is_zooming_in(), Some(true));
    z.end(stale);
    assert_eq!(z.is_zooming_in(), None);
    assert_eq!(z.target(standard, standard), Some(start));
    assert_eq!(z.target(standard, standard), None);
}

#[test]
fn zoom_snapped_end_counts_as_standard() {
    let start = Rect::new(100.0, 100.0, 800.0, 600.0);
    let standard = Rect::new(0.0, 0.0, 1440.0, 900.0);
    let mut z = WindowZoom::default();
    z.target(start, standard);
    let snapped = Rect::new(0.5, -0.5, 1440.5, 899.0);
    assert_eq!(z.target(snapped, standard), Some(start));
}

// MARK: WindowCycleReachesEachWindowTests

struct Desk {
    shells: Vec<u64>,
    ordered: Vec<u64>,
    key: Option<u64>,
}

impl Desk {
    fn press(&mut self, offset: i64) -> Option<u64> {
        let t = WindowTargeting {
            key_window: self.key,
            ordered: self.ordered.clone(),
            shells: self.shells.clone(),
        };
        let next = t.cycled(offset)?;
        self.ordered.retain(|w| *w != next);
        self.ordered.insert(0, next);
        self.key = Some(next);
        Some(next)
    }
}

const STARTS: [[u64; 3]; 4] = [[1, 2, 3], [1, 3, 2], [2, 3, 1], [3, 1, 2]];

fn desk(start: [u64; 3]) -> Desk {
    Desk { shells: vec![1, 2, 3], ordered: start.to_vec(), key: Some(start[0]) }
}

#[test]
fn cycle_reaches_each_window_both_ways() {
    for offset in [1, -1] {
        for start in STARTS {
            let mut d = desk(start);
            let seen: Vec<u64> = (0..3).map(|_| d.press(offset).unwrap()).collect();
            let mut unique = seen.clone();
            unique.sort();
            unique.dedup();
            assert_eq!(unique.len(), 3, "{start:?} {offset}");
            assert_eq!(*seen.last().unwrap(), start[0]);
        }
    }
}

#[test]
fn cycle_next_then_previous_returns() {
    for (a, b) in [(1, -1), (-1, 1)] {
        for start in STARTS {
            let mut d = desk(start);
            d.press(a);
            assert_eq!(d.press(b), Some(start[0]));
        }
    }
}

#[test]
fn cycle_one_and_two_windows() {
    let mut one = Desk { shells: vec![1], ordered: vec![1], key: Some(1) };
    assert_eq!(one.press(1), None);
    let mut two = Desk { shells: vec![1, 2], ordered: vec![1, 2], key: Some(1) };
    let seen: Vec<u64> = [1, 1, -1].iter().map(|o| two.press(*o).unwrap()).collect();
    assert_eq!(seen, vec![2, 1, 2]);
}

#[test]
fn target_prefers_key_shell_then_frontmost() {
    let t = WindowTargeting { key_window: Some(9), ordered: vec![9, 3, 2], shells: vec![1, 2, 3] };
    assert_eq!(t.target(), Some(3));
    let hidden = WindowTargeting { key_window: None, ordered: vec![], shells: vec![1, 2] };
    assert_eq!(hidden.target(), Some(1));
    assert_eq!(
        call("window.target", &json!({"keyWindow": 2, "ordered": [], "shells": [1, 2]})).unwrap(),
        json!(2)
    );
}

// MARK: FrameStripKeyRepeatTests

#[test]
fn key_repeat_delays() {
    assert_eq!(key_repeat_delay(100, 1, 34.0), 66.0);
    assert_eq!(key_repeat_delay(100, 2, 220.0), 0.0);
    assert_eq!(key_repeat_delay(100, 3, 225.0), 75.0);
    assert_eq!(key_repeat_interval(None), 40);
    assert_eq!(key_repeat_interval(Some(0.2)), 1);
    assert_eq!(key_repeat_interval(Some(100.0)), 100);
}

// MARK: LaunchDisplayTests

#[test]
fn launch_display_parse() {
    assert_eq!(parse_display(None, true), Some(LaunchDisplay::BuiltIn));
    assert_eq!(parse_display(Some("  "), true), Some(LaunchDisplay::BuiltIn));
    assert_eq!(parse_display(Some("BuiltIn"), true), Some(LaunchDisplay::BuiltIn));
    assert_eq!(parse_display(None, false), None);
    assert_eq!(parse_display(Some("builtin"), false), Some(LaunchDisplay::BuiltIn));
    assert_eq!(parse_display(Some("off"), true), None);
    assert_eq!(parse_display(Some("main"), true), Some(LaunchDisplay::Index(0)));
    assert_eq!(parse_display(Some("1"), true), Some(LaunchDisplay::Index(1)));
    assert_eq!(parse_display(Some("-1"), true), None);
    assert_eq!(parse_display(Some("xdr"), true), None);
}

#[test]
fn launch_display_screen_index() {
    assert_eq!(LaunchDisplay::Index(0).screen_index(&[false, true]), Some(0));
    assert_eq!(LaunchDisplay::Index(5).screen_index(&[false, true]), Some(1));
    assert_eq!(LaunchDisplay::BuiltIn.screen_index(&[false, true]), Some(1));
    assert_eq!(LaunchDisplay::BuiltIn.screen_index(&[false]), None);
    assert_eq!(LaunchDisplay::Index(0).screen_index(&[]), None);
}

// MARK: LaunchLayoutSettleTests

fn mark(marks: &[(String, f64)], name: &str) -> Option<f64> {
    marks.iter().find(|(n, _)| n == name).map(|(_, v)| *v)
}

#[test]
fn settle_still_first_frame() {
    let mut t = SettleTally::default();
    t.first(500.0);
    assert!(!t.is_over(1999.0));
    assert!(t.is_over(2000.0));
    let m = t.marks();
    assert_eq!(mark(&m, "layout.first_frame"), Some(500.0));
    assert_eq!(mark(&m, "layout.settle"), Some(500.0));
    assert_eq!(mark(&m, "layout.max_move"), Some(0.0));
    assert_eq!(mark(&m, "layout.changed_frames"), Some(0.0));
    assert_eq!(mark(&m, "layout.capped"), None);
}

#[test]
fn settle_after_moves() {
    let mut t = SettleTally::default();
    t.first(500.0);
    t.note(
        600.0,
        "SidebarContainerView",
        Some(Move { name: "SidebarContainerView".into(), points: 40.0 }),
    );
    t.note(900.0, "TabStripView", Some(Move { name: "TabStripView".into(), points: 6.0 }));
    assert!(!t.is_over(2100.0));
    assert!(t.is_over(2400.0));
    let m = t.marks();
    assert_eq!(mark(&m, "layout.settle"), Some(900.0));
    assert_eq!(mark(&m, "layout.max_move"), Some(40.0));
    assert_eq!(mark(&m, "layout.max_move.SidebarContainerView"), Some(40.0));
    assert_eq!(mark(&m, "layout.last.TabStripView"), Some(900.0));
    assert_eq!(mark(&m, "layout.changed_frames"), Some(2.0));
}

#[test]
fn settle_capped() {
    let mut t = SettleTally::default();
    t.first(0.0);
    for ms in (100..=5000).step_by(100) {
        t.note(ms as f64, "window", None);
    }
    assert!(t.is_over(5000.0));
    let m = t.marks();
    assert_eq!(mark(&m, "layout.capped"), Some(5000.0));
    assert_eq!(mark(&m, "layout.max_move"), Some(0.0));
    assert_eq!(mark(&m, "layout.last.window"), Some(5000.0));
}

#[test]
fn settle_mark_names_and_empty() {
    assert_eq!(mark_name("NSHostingView<ModifiedContent<A, B>>"), "NSHostingView");
    assert_eq!(mark_name("TabStripView moved 0,0,10,10 -> 0,0,12,10"), "TabStripView");
    assert_eq!(mark_name(""), "view");
    let t = SettleTally::default();
    assert!(!t.is_over(60_000.0));
    assert!(t.marks().is_empty());
}

#[test]
fn record_request_reads_flags() {
    let args = |a: &[&str]| a.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let r = launch::record_request(&args(&["app", "--record-launch", "~/rec"]), "/home/u").unwrap();
    assert_eq!((r.dir.as_str(), r.seconds), ("/home/u/rec", 6.0));
    let r = launch::record_request(
        &args(&["--record-launch", "/tmp/x", "--record-launch-seconds", "40"]),
        "/h",
    )
    .unwrap();
    assert_eq!(r.seconds, 12.0);
    assert_eq!(launch::record_request(&args(&["--record-launch", "--x"]), "/h"), None);
    assert_eq!(launch::record_request(&args(&["app"]), "/h"), None);
}

// MARK: SwitchKeyChangesTests

fn m(became: bool, at: f64) -> Mark {
    Mark { became, at }
}

fn counts(row: &Row) -> [f64; 4] {
    ["key_changes", "key_become", "key_resign", "key_marks_full"].map(|k| row[k])
}

#[test]
fn switch_key_changes_by_row() {
    let mut marks = Vec::new();
    for at in [100.0, 500.0, 900.0] {
        marks.push(m(true, at + 20.0));
        marks.push(m(false, at + 60.0));
    }
    marks.push(m(true, 2400.0));
    let k = SwitchKeyChanges { marks, full: false };
    let rows = k.columns(&[Some(100.0), Some(500.0), Some(900.0)]);
    let got: Vec<[f64; 4]> = rows.iter().map(counts).collect();
    assert_eq!(got, vec![[2.0, 1.0, 1.0, 0.0], [2.0, 1.0, 1.0, 0.0], [3.0, 2.0, 1.0, 0.0]]);
}

#[test]
fn switch_key_changes_edges() {
    let before = SwitchKeyChanges { marks: vec![m(true, 40.0)], full: false };
    for row in before.columns(&[Some(300.0), Some(700.0)]) {
        assert_eq!(counts(&row), [0.0; 4]);
    }
    let on_start = SwitchKeyChanges { marks: vec![m(false, 500.0)], full: false };
    let got: Vec<f64> =
        on_start.columns(&[Some(100.0), Some(500.0)]).iter().map(|r| r["key_changes"]).collect();
    assert_eq!(got, vec![0.0, 1.0]);
    let unsorted = SwitchKeyChanges {
        marks: vec![m(true, 150.0), m(true, 520.0), m(false, 560.0)],
        full: false,
    };
    let got: Vec<f64> =
        unsorted.columns(&[Some(500.0), Some(100.0)]).iter().map(|r| r["key_changes"]).collect();
    assert_eq!(got, vec![2.0, 1.0]);
    let gaps = SwitchKeyChanges { marks: vec![m(true, 300.0), m(true, 600.0)], full: false };
    let cols = gaps.columns(&[Some(100.0), None, Some(500.0)]);
    assert_eq!(cols[0]["key_changes"], 1.0);
    assert!(cols[1].is_empty());
    assert_eq!(cols[2]["key_changes"], 1.0);
}

#[test]
fn switch_key_changes_from_spans() {
    let spans: Vec<Span> = [
        ("show.park", 101.0),
        ("key.become", 120.0),
        ("commit", 130.0),
        ("key.resign", 180.0),
        ("key.becomeMain", 190.0),
    ]
    .iter()
    .map(|(n, s)| Span { name: n.to_string(), start: *s })
    .collect();
    let k = SwitchKeyChanges::from_spans(&spans, 512);
    assert_eq!(k.marks, vec![m(true, 120.0), m(false, 180.0)]);
    assert!(!k.full);
    let full = SwitchKeyChanges::from_spans(&spans, 5);
    assert!(full.full);
    assert_eq!(counts(&full.columns(&[Some(100.0)])[0]), [2.0, 1.0, 1.0, 1.0]);
}

#[test]
fn switch_key_changes_counted() {
    let row =
        |pairs: &[(&str, f64)]| -> Row { pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect() };
    let k = SwitchKeyChanges {
        marks: vec![m(true, 120.0), m(false, 180.0), m(true, 520.0)],
        full: false,
    };
    let rows = vec![
        row(&[("at_ms", 100.0), ("commit_ms", 17.5)]),
        row(&[("at_ms", 500.0), ("commit_ms", 11.25), ("key_changes", 7.0)]),
        row(&[("commit_ms", 9.0)]),
    ];
    let out = k.counted(&rows);
    assert_eq!(
        out[0],
        row(&[
            ("at_ms", 100.0),
            ("commit_ms", 17.5),
            ("key_changes", 2.0),
            ("key_become", 1.0),
            ("key_resign", 1.0),
            ("key_marks_full", 0.0),
        ])
    );
    assert_eq!(out[1]["key_changes"], 7.0);
    assert_eq!(out[1]["key_become"], 1.0);
    assert_eq!(out[1]["key_resign"], 0.0);
    assert_eq!(out[2], row(&[("commit_ms", 9.0)]));
    assert!(k.counted(&[]).is_empty());
}

// MARK: TrafficLightsLineTests

fn pl(container_height: f64, center_y: f64, leading_x: f64) -> Placement {
    Placement { container_height, center_y, leading_x }
}

#[test]
fn traffic_lights_placement() {
    assert_eq!(placement(None, 14.0, 32.0, 2.0), pl(32.0, 16.0, 9.0));
    for line in [20.0, 21.5] {
        assert_eq!(placement(Some(line), 14.0, 32.0, 2.0), pl(32.0, line, line - 7.0));
    }
    assert_eq!(placement(Some(26.5), 14.0, 32.0, 2.0), pl(33.5, 26.5, 19.5));
    assert_eq!(placement(Some(26.5), 14.0, 32.0, 1.0), pl(34.0, 27.0, 20.0));
    assert_eq!(placement(Some(20.3), 14.0, 32.0, 2.0).center_y, 20.5);
    assert_eq!(placement(Some(20.3), 14.0, 32.0, 1.0).center_y, 20.0);
}

#[test]
fn traffic_lights_resting_frame_and_masks() {
    let p = pl(32.0, 16.0, 9.0);
    let buttons = [
        RestingButton { offset: 0.0, width: 14.0, height: 16.0 },
        RestingButton { offset: 20.0, width: 14.0, height: 16.0 },
        RestingButton { offset: 40.0, width: 14.0, height: 16.0 },
    ];
    assert_eq!(
        top_row::resting_frame(&p, 700.0, &buttons),
        Some(Rect::new(9.0, 676.0, 54.0, 16.0))
    );
    assert_eq!(top_row::resting_frame(&p, 700.0, &[]), None);
    assert!(top_row::offsets_valid(Some(0.0), Some(20.0), Some(40.0)));
    assert!(!top_row::offsets_valid(Some(1.0), Some(20.0), Some(40.0)));
    assert!(!top_row::offsets_valid(Some(0.0), Some(20.0), Some(20.0)));
    use top_row::style_mask::*;
    assert_eq!(top_row::tiling_mask(0), TITLED | CLOSABLE | MINIATURIZABLE | RESIZABLE);
    assert_eq!(top_row::tiling_mask(FULL_SIZE_CONTENT_VIEW | (1 << 7)) & (1 << 7), 0);
    assert_eq!(top_row::button_x(true, 9.0, Some(20.0), 50.0, 30.0), 29.0);
    assert_eq!(top_row::button_x(true, 9.0, None, 50.0, 30.0), 29.0);
    assert_eq!(top_row::button_x(false, 9.0, Some(20.0), 50.0, 30.0), 50.0);
}

// MARK: WindowedTrafficLightsTests

#[test]
fn windowed_traffic_lights_keep_distance_from_top() {
    let mut w = WindowedTrafficLights::default();
    assert_eq!(w.resting(700.0), None);
    let lights = Rect::new(12.0, 670.0, 52.0, 16.0);
    w.note(lights, 700.0, true);
    assert_eq!(w.resting(700.0), Some(lights));
    assert_eq!(w.resting(900.0), Some(Rect::new(12.0, 870.0, 52.0, 16.0)));
    let mut ignored = WindowedTrafficLights::default();
    ignored.note(lights, 700.0, false);
    assert_eq!(ignored.resting(700.0), None);
}

#[test]
fn windowed_traffic_lights_matrix() {
    let places = [
        Rect::new(12.0, 670.0, 52.0, 16.0),
        Rect::new(20.0, 1062.0, 54.0, 14.0),
        Rect::new(12.5, 300.5, 52.0, 16.0),
        Rect::new(7.0, 0.0, 69.0, 20.0),
    ];
    for place in places {
        for noted in [320.0, 720.0, 1080.0, 1440.5] {
            if place.max_y() > noted {
                continue;
            }
            let mut w = WindowedTrafficLights::default();
            w.note(place, noted, true);
            for height in [320.0, 720.0, 900.0, 1080.0, 2160.0, 1599.5] {
                let want = Rect::new(
                    place.x,
                    height - (noted - place.max_y()) - place.height,
                    place.width,
                    place.height,
                );
                assert_eq!(w.resting(height), Some(want), "{place:?} {noted} {height}");
            }
        }
    }
}

// MARK: Top row spacing

#[test]
fn top_row_slots_split_gaps() {
    let g = Glyph { image_width: 14.0, ink: [2.0, 12.0] };
    let s = top_row::slots(14.0, 4.0, &[g, g]);
    // Inks 10 wide, 4 apart: centers 7 and 21; each slot reaches the gap's middle (14).
    assert_eq!(s.frames.len(), 2);
    assert_eq!(s.frames[0].x, 0.0);
    assert_eq!(s.frames[0].width, 14.0);
    assert_eq!(s.frames[1].x, 14.0);
    assert_eq!(s.width, 28.0);
    assert_eq!(s.leading_ink, 2.0);
    assert_eq!(top_row::slots(14.0, 4.0, &[]).width, 0.0);
    assert_eq!(top_row::leading_gap(8.0, 2.0, 4.0), 6.0);
    assert_eq!(top_row::leading_gap(8.0, 6.0, 4.0), 4.0);
    let frames = top_row::slot_frames(&s, 0.5, 32.0, 14.0);
    assert_eq!(frames[1], Rect::new(7.0, 9.0, 7.0, 14.0));
}

#[test]
fn top_row_spacing_rounds_to_half_points() {
    let s = top_row::spacing(14.0, 12.0);
    assert_eq!(s.group_gap, 4.0);
    assert_eq!(s.glyph_gap, 6.0);
    assert_eq!(s.arrow_icon_size, 20.0);
    assert_eq!(s.toggle_glyph_point_size, 12.5);
}

// MARK: Fill and pointer

#[test]
fn compensated_fill_composes_to_ground() {
    let ground = Rgb::new(0.5, 0.5, 0.5, 1.0);
    let sheet = Rgb::new(1.0, 1.0, 1.0, 1.0);
    let f = compensated_fill(ground, 0.8, sheet, 0.5);
    assert!((f.alpha - 0.6).abs() < 1e-12);
    let composed = f.alpha * f.red + (1.0 - f.alpha) * 0.5;
    assert!((composed - 0.4).abs() < 1e-12);
    assert_eq!(compensated_fill(ground, 0.4, sheet, 0.5), Rgb::new(0.5, 0.5, 0.5, 0.4));
    assert_eq!(compensated_fill(ground, 0.8, sheet, 1.0).alpha, 0.8);
}

#[test]
fn pointer_move_enters_and_exits() {
    use cmux_design_core::window::diagnostics::Area;
    let area = |id: u64, owner: &str, local: Point| Area {
        id,
        owner: Some(owner.into()),
        live: true,
        hidden: false,
        local: Some(local),
        rect: Rect::new(0.0, 0.0, 10.0, 10.0),
        visible_rect: Rect::new(0.0, 0.0, 10.0, 10.0),
        in_visible_rect: false,
        enter_exit: true,
        mouse_moved: true,
    };
    let inside = Point { x: 5.0, y: 5.0 };
    let outside = Point { x: 50.0, y: 5.0 };
    let before = [area(1, "a", inside)];
    let now = [area(1, "a", outside), area(2, "b", inside)];
    let r = pointer_move(true, &before, &now);
    assert_eq!(r.entered, vec!["b".to_string()]);
    assert_eq!(r.exited, vec!["a".to_string()]);
    assert_eq!(r.inside, vec!["b".to_string()]);
    assert_eq!(r.moved, 1);
    assert_eq!(r.now, vec![2]);
    assert!(pointer_move(false, &before, &now).now.is_empty());
}

#[test]
fn unknown_window_op_is_unknown() {
    assert!(call("window.nope", &json!({})).is_err());
    assert_eq!(
        call(
            "window.frameStripKeyRepeat",
            &json!({"intervalMs": 100.0, "index": 3, "elapsedMs": 225.0})
        )
        .unwrap(),
        json!({"intervalMs": 100, "delayMs": 75.0})
    );
}
