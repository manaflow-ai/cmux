//! Parity tests for `tokens::layout`: the attention settings, the list scroll rule (with a port of
//! `ListViewportReference`, the rule that reads every row, for a seeded equality sweep), the chrome
//! enums and rules, and the workspace row layouts. Expected values are worked by hand from Swift.

use cmux_design_core::ops::{OpError, call};
use cmux_design_core::tokens::layout::attention::*;
use cmux_design_core::tokens::layout::chrome::*;
use cmux_design_core::tokens::layout::rows::*;
use cmux_design_core::tokens::layout::viewport::*;
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

fn op(name: &str, request: Value) -> Value {
    call(&format!("tokens.{name}"), &request).unwrap()
}

// MARK: attention

#[test]
fn attention_defaults_match_swift() {
    // AttentionDefaultTests, AttentionThemedFlashTests, AgentTurnRingTests, NeedsYouGlowTests.
    let s = AttentionSettings::default();
    assert_eq!(s.style, AttentionStyle::Steady);
    assert!(s.shows_on_sidebar && s.shows_on_tab);
    assert_eq!(s.terminal_ring, FocusRingStyle::Glow);
    assert_eq!(s.agent_chat_ring, FocusRingStyle::None);
    assert_eq!(s.color, None);
    assert_eq!((s.blink_count, s.agent_chat_blink_count), (2, 1));
    assert_eq!(s.ring_style, FocusRingStyle::Glow);
    assert_eq!(s.width, 2.0);
    assert_eq!(s.duration, 3.0);
    assert!(s.persists && s.flashes_on_read && s.flashes_on_typing);
    assert_eq!(s.mark, AttentionMarkLook::Badge);
    assert!(s.moves_to_top && !s.moves_to_top_on_agent_finish);
    assert!(s.rings(false) && !s.rings(true));
    assert!(s.draws_any_ring(), "the unread glow is on by default");
    for style in [AttentionStyle::Steady, AttentionStyle::Blink, AttentionStyle::Pulse] {
        assert!(AttentionStyle::ALL.contains(&style));
    }
    assert_eq!(BLINK_RANGE, (1, 10));
    assert_eq!(DURATION_RANGE, (0.3, 30.0));
}

#[test]
fn an_agent_chat_draws_its_own_look_and_count() {
    let mut s = AttentionSettings { agent_chat_ring: FocusRingStyle::Ring, ..Default::default() };
    let chat = s.surface(true);
    let terminal = s.surface(false);
    assert!(chat.ring_style == FocusRingStyle::Ring && chat.blink_count == 1);
    assert!(terminal.ring_style == FocusRingStyle::Glow && terminal.blink_count == 2);
    // FocusRingEarnedTests: terminals off, chats on still rings somewhere; both off, none.
    s.terminal_ring = FocusRingStyle::None;
    assert!(s.draws_any_ring() && !s.rings(false) && s.rings(true));
    s.agent_chat_ring = FocusRingStyle::None;
    assert!(!s.draws_any_ring());
    // Style none: nothing rings whatever the looks.
    let none = AttentionSettings { style: AttentionStyle::None, ..Default::default() };
    assert!(!none.draws_any_ring() && !none.rings(false) && !none.draws_ring());
}

#[test]
fn moves_to_top_on_agent_finish() {
    // NotificationMoveToTopOnAgentFinishTests.
    let defaults = AttentionSettings::default();
    assert!(defaults.moves_to_top_for(true) && defaults.moves_to_top_for(false));
    let off = AttentionSettings { moves_to_top: false, ..Default::default() };
    assert!(!off.moves_to_top_for(true) && !off.moves_to_top_for(false));
    let finish_only = AttentionSettings {
        moves_to_top: false,
        moves_to_top_on_agent_finish: true,
        ..Default::default()
    };
    assert!(finish_only.moves_to_top_for(true) && !finish_only.moves_to_top_for(false));
}

#[test]
fn attention_ops() {
    let d = op("layout_attention_defaults", json!({}));
    assert_eq!(d["style"], "steady");
    assert_eq!(d["agentChatRing"], "none");
    assert_eq!(d["color"], Value::Null);
    let chat = op(
        "layout_attention_surface",
        json!({"settings": {"agentChatRing": "ring"}, "agentChat": true}),
    );
    assert_eq!(chat["ringStyle"], "ring");
    assert_eq!(chat["blinkCount"], 1);
    let rules = op(
        "layout_attention_rules",
        json!({"settings": {"movesToTop": false, "movesToTopOnAgentFinish": true}, "finishedTurn": true}),
    );
    assert_eq!(
        rules,
        json!({"drawsRing": true, "drawsAnyRing": true, "ringsTerminal": true, "ringsAgentChat": false, "movesToTop": true})
    );
    assert_eq!(
        op("layout_attention_ranges", json!({})),
        json!({"blink": [1, 10], "duration": [0.3, 30.0]})
    );
    let mark: AttentionMark = serde_json::from_value(json!({"generation": 7})).unwrap();
    assert_eq!(mark, AttentionMark::new(7));
}

// MARK: chrome

#[test]
fn notice_timing_is_ten_seconds() {
    assert_eq!(CONNECTION_QUIET_MS, 10_000);
    assert_eq!(op("layout_notice_timing", json!({})), json!({"connectionQuietMs": 10_000}));
}

#[test]
fn strip_band_holds_on_the_pages_side() {
    use TabBarOrder::*;
    use TabBarPosition as S;
    use ToolbarPosition as T;
    assert!(holds_strip_band(T::Top, S::Top, BelowToolbar));
    assert!(!holds_strip_band(T::Top, S::Top, AboveToolbar));
    assert!(holds_strip_band(T::Bottom, S::Bottom, AboveToolbar));
    assert!(!holds_strip_band(T::Bottom, S::Bottom, BelowToolbar));
    for order in [AboveToolbar, BelowToolbar] {
        assert!(!holds_strip_band(T::Top, S::Bottom, order));
        assert!(!holds_strip_band(T::Bottom, S::Top, order));
    }
    assert_eq!(
        op("layout_strip_band", json!({"toolbar": "top", "strip": "top", "order": "belowToolbar"})),
        json!({"holds": true})
    );
}

#[test]
fn agent_badges_from_switches() {
    // SidebarAgentPillTests.
    let sw = |pairs: &[(&str, bool)]| {
        pairs.iter().map(|(k, v)| (k.to_string(), *v)).collect::<HashMap<_, _>>()
    };
    use AgentBadgesExperiment::*;
    assert_eq!(AgentBadgesExperiment::from_switches(&sw(&[])), Off);
    assert_eq!(AgentBadgesExperiment::from_switches(&sw(&[("agentBadgesBeam", true)])), Off);
    assert_eq!(AgentBadgesExperiment::from_switches(&sw(&[("agentBadges", true)])), Pills);
    assert_eq!(
        AgentBadgesExperiment::from_switches(&sw(&[
            ("agentBadges", true),
            ("agentBadgesBeam", false)
        ])),
        Pills
    );
    assert_eq!(
        AgentBadgesExperiment::from_switches(&sw(&[
            ("agentBadges", true),
            ("agentBadgesBeam", true)
        ])),
        Beam
    );
    assert!(!Off.shows_pills() && Pills.shows_pills() && Beam.shows_pills());
    assert!(!Off.shows_beam() && !Pills.shows_beam() && Beam.shows_beam());
    assert_eq!(
        op(
            "layout_agent_badges",
            json!({"switches": {"agentBadges": true, "agentBadgesBeam": true}})
        ),
        json!({"experiment": "beam", "showsPills": true, "showsBeam": true})
    );
    assert_eq!(op("layout_agent_badges", json!({}))["experiment"], "off");
}

#[test]
fn nav_row_defaults_and_wire() {
    let row: SidebarNavRow = serde_json::from_value(json!({"action": "workspace.new"})).unwrap();
    assert_eq!(row, SidebarNavRow::new("workspace.new"));
    assert_eq!(row.title, None);
}

#[test]
fn enum_raw_values_match_swift() {
    let e = op("layout_enums", json!({}));
    assert_eq!(e["AttentionStyle"], json!(["none", "steady", "pulse", "blink"]));
    assert_eq!(e["AttentionMarkLook"], json!(["badge", "glow"]));
    assert_eq!(e["FocusRingStyle"], json!(["ring", "glow", "none"]));
    assert_eq!(e["TabShellIconTheme"], json!(["default", "machine"]));
    assert_eq!(e["TerminalCellBackgrounds"], json!(["opaque", "window", "tint", "tintWindow"]));
    assert_eq!(e["ToolbarPosition"], json!(["top", "bottom"]));
    assert_eq!(e["TabBarPosition"], json!(["top", "bottom"]));
    assert_eq!(e["TabBarOrder"], json!(["aboveToolbar", "belowToolbar"]));
    assert_eq!(e["AgentBadgesExperiment"], json!(["off", "pills", "beam"]));
    assert_eq!(
        e["WorkspaceRowElement"],
        json!([
            "icon",
            "directory",
            "branch",
            "process",
            "agentStatus",
            "tabCount",
            "ports",
            "lastActivity",
            "pullRequest",
            "progress",
            "working",
            "log",
            "notification"
        ])
    );
    assert_eq!(e["WorkspaceRowKind"], json!(["terminal", "agent", "browser", "mixed"]));
    assert_eq!(e["WorkspaceRowStatusPlacement"], json!(["trailing", "leading"]));
    assert_eq!(TabShellIconTheme::from_raw("machine"), Some(TabShellIconTheme::Machine));
    assert_eq!(
        TerminalCellBackgrounds::from_raw("tintWindow"),
        Some(TerminalCellBackgrounds::TintWindow)
    );
    assert_eq!(WorkspaceRowStatusPlacement::from_raw("middle"), None);
    assert_eq!(serde_json::to_value(TabShellIconTheme::Default).unwrap(), json!("default"));
}

// MARK: rows

#[test]
fn second_line_elements() {
    assert_eq!(
        op("layout_row_second_line", json!({})),
        json!([
            "notification",
            "directory",
            "branch",
            "process",
            "agentStatus",
            "ports",
            "lastActivity"
        ])
    );
    let second: HashSet<_> = WorkspaceRowElement::SECOND_LINE.into_iter().collect();
    for &e in WorkspaceRowElement::ALL {
        assert_eq!(e.is_second_line(), second.contains(&e), "{e:?}");
    }
    assert!(
        !WorkspaceRowElement::Icon.is_second_line() && !WorkspaceRowElement::Log.is_second_line()
    );
    assert_eq!(
        op("layout_row_element", json!({"element": "branch"})),
        json!({"isSecondLine": true})
    );
    assert_eq!(
        op("layout_row_element", json!({"element": "working"})),
        json!({"isSecondLine": false})
    );
}

fn row_layout(custom: bool, lines: &[&[&str]]) -> WorkspaceRowLayout {
    WorkspaceRowLayout {
        custom,
        lines: lines.iter().map(|l| l.iter().map(|s| s.to_string()).collect()).collect(),
        slots: Slots { icon: false, working: false, progress: false },
    }
}

#[test]
fn row_layout_for_takes_agent_then_kind_and_only_custom() {
    // WorkspaceRowLayoutSettingsTests' reads of `layout(for:agent:)`.
    let mut layouts = WorkspaceRowLayouts::default();
    let mut agent = KindLayouts {
        fallback: Some(row_layout(true, &[&["name"], &["directory"]])),
        ..Default::default()
    };
    agent.agents.insert("codex".into(), row_layout(true, &[&["name"], &["log"]]));
    agent.agents.insert("plain".into(), row_layout(false, &[&["name"]]));
    layouts.kinds.insert(WorkspaceRowKind::Agent, agent);
    layouts.kinds.insert(
        WorkspaceRowKind::Terminal,
        KindLayouts {
            fallback: Some(row_layout(true, &[&["name", "branch"]])),
            ..Default::default()
        },
    );
    layouts.kinds.insert(
        WorkspaceRowKind::Browser,
        KindLayouts { fallback: Some(row_layout(false, &[&["name"]])), ..Default::default() },
    );
    let lines = |k, a: Option<&str>| layouts.layout(k, a).map(|l| l.lines.clone());
    let strs = |v: &[&[&str]]| Some(row_layout(true, v).lines);
    assert_eq!(lines(WorkspaceRowKind::Agent, Some("codex")), strs(&[&["name"], &["log"]]));
    assert_eq!(lines(WorkspaceRowKind::Agent, Some("claude")), strs(&[&["name"], &["directory"]]));
    assert_eq!(lines(WorkspaceRowKind::Agent, None), strs(&[&["name"], &["directory"]]));
    // An agent's own layout that is not custom is nil, not the fallback.
    assert_eq!(lines(WorkspaceRowKind::Agent, Some("plain")), None);
    assert_eq!(lines(WorkspaceRowKind::Terminal, None), strs(&[&["name", "branch"]]));
    assert_eq!(lines(WorkspaceRowKind::Browser, None), None);
    assert_eq!(lines(WorkspaceRowKind::Mixed, None), None);

    let request = json!({
        "layouts": serde_json::to_value(&layouts).unwrap(),
        "kind": "agent",
        "agent": "codex",
    });
    let got = op("layout_row_layout_for", request);
    assert_eq!(got["lines"], json!([["name"], ["log"]]));
    assert_eq!(got["slots"], json!({"icon": false, "working": false, "progress": false}));
    assert_eq!(op("layout_row_layout_for", json!({"kind": "mixed"})), Value::Null);
}

// MARK: viewport

fn frame(viewport: f64, content: f64) -> Frame {
    Frame { viewport, content }
}

#[test]
fn clamp_and_max_offset() {
    let f = frame(100.0, 400.0);
    assert_eq!(f.max_offset(), 300.0);
    assert_eq!(f.clamp(-5.0), 0.0);
    assert_eq!(f.clamp(350.0), 300.0);
    assert_eq!(f.clamp(120.0), 120.0);
    assert_eq!(frame(100.0, 50.0).max_offset(), 0.0);
    assert_eq!(frame(100.0, 50.0).clamp(30.0), 0.0);
    assert_eq!(
        op("layout_viewport_clamp", json!({"viewport": 100, "content": 400, "offset": 350})),
        json!({"offset": 300.0, "maxOffset": 300.0})
    );
}

#[test]
fn full_visibility_with_padding_and_epsilon() {
    let f = frame(100.0, 400.0);
    let item = Item::new("a".to_string(), 20.0, 20.0);
    assert!(f.is_fully_visible(&item, 0.0, 0.0));
    assert!(!f.is_fully_visible(&item, 30.0, 0.0));
    // Within epsilon of the edge.
    assert!(f.is_fully_visible(&item, 20.005, 0.0));
    assert!(!f.is_fully_visible(&item, 20.02, 0.0));
    // Padding past the content's start does not exist.
    assert!(f.is_fully_visible(&Item::new("b".to_string(), 0.0, 20.0), 0.0, 8.0));
    assert!(!f.is_fully_visible(&Item::new("c".to_string(), 10.0, 20.0), 5.0, 8.0));
    // An item at least as long as the viewport covers it.
    let tall = Item::new("t".to_string(), 50.0, 150.0);
    assert!(f.is_fully_visible(&tall, 60.0, 0.0));
    assert!(!f.is_fully_visible(&tall, 300.0, 0.0));
    assert_eq!(
        op(
            "layout_viewport_is_fully_visible",
            json!({"viewport": 100, "content": 400, "offset": 0, "padding": 0, "item": {"id": "a", "start": 20, "length": 20}})
        ),
        json!({"visible": true})
    );
    assert!(matches!(
        call(
            "tokens.layout_viewport_reveal",
            &json!({"viewport": 100, "content": 400, "offset": 0})
        ),
        Err(OpError::Invalid(_))
    ));
}

#[test]
fn reveal_aligns_the_nearer_edge() {
    let f = frame(100.0, 400.0);
    // Below the view: toLeading 142, toTrailing 78; the trailing edge is nearer.
    assert_eq!(f.reveal(&Item::new("x".to_string(), 150.0, 20.0), 0.0, 8.0), 78.0);
    // Above: toLeading 2, toTrailing -62 from 100: 98 against 162.
    assert_eq!(f.reveal(&Item::new("x".to_string(), 10.0, 20.0), 100.0, 8.0), 2.0);
    // Shown: unchanged (clamped first).
    assert_eq!(f.reveal(&Item::new("x".to_string(), 10.0, 20.0), -4.0, 0.0), 0.0);
    // Taller than the viewport: its leading edge.
    assert_eq!(f.reveal(&Item::new("x".to_string(), 50.0, 150.0), 300.0, 0.0), 50.0);
    // Tall with padding (90 + 16 >= 100): centred, start - 5.
    assert_eq!(f.reveal(&Item::new("x".to_string(), 200.0, 90.0), 0.0, 8.0), 195.0);
    assert_eq!(
        op(
            "layout_viewport_reveal",
            json!({"viewport": 100, "content": 400, "offset": 0, "padding": 8, "item": {"id": "x", "start": 150, "length": 20}})
        ),
        json!({"offset": 78.0})
    );
}

/// Rows `ids` in order, 20 pt each, in a 100 pt viewport (ListViewportFocusedVisibleTests.list).
fn list(ids: &[i64]) -> ListViewport<i64> {
    let items =
        ids.iter().enumerate().map(|(i, &id)| Item::new(id, i as f64 * 20.0, 20.0)).collect();
    ListViewport::new(items, 100.0, ids.len() as f64 * 20.0)
}

fn range(a: i64, b: i64) -> Vec<i64> {
    (a..=b).collect()
}

#[test]
fn a_focused_row_moved_by_another_client_scrolls_into_view() {
    let old = list(&range(1, 20));
    let mut ids = range(2, 20);
    ids.push(1);
    let new = list(&ids);
    let offset = new.settle(&old, 0.0, Some(&1), Some(&1), 0.0, false, None);
    let row = new.item(&1).unwrap().clone();
    assert!(new.is_fully_visible(&row, offset, 0.0), "out of view at {offset}");
}

#[test]
fn a_focused_row_moved_while_scrolled_away_scrolls_into_view() {
    let old = list(&range(1, 20));
    let mut ids = vec![2, 1];
    ids.extend(range(3, 20));
    let new = list(&ids);
    let offset = new.settle(&old, old.max_offset(), Some(&1), Some(&1), 0.0, false, None);
    let row = new.item(&1).unwrap().clone();
    assert!(new.is_fully_visible(&row, offset, 0.0));
}

#[test]
fn a_focused_row_pushed_out_by_a_row_arriving_above_scrolls_into_view() {
    let old = list(&range(1, 20));
    let mut ids = vec![1, 2, 99];
    ids.extend(range(3, 20));
    let new = list(&ids);
    let offset = new.settle(&old, 0.0, Some(&5), Some(&5), 0.0, false, None);
    let row = new.item(&5).unwrap().clone();
    assert!(new.is_fully_visible(&row, offset, 0.0));
    // By hand: row 1 anchors at 0; row 5 now spans 100...120: toTrailing 20 is nearer.
    assert_eq!(offset, 20.0);
}

#[test]
fn a_user_who_scrolled_away_keeps_the_view_through_an_unrelated_close() {
    let old = list(&range(1, 20));
    let ids: Vec<i64> = range(1, 20).into_iter().filter(|&i| i != 15).collect();
    let new = list(&ids);
    let offset = new.settle(&old, 200.0, Some(&1), Some(&1), 0.0, false, None);
    assert!(offset > 100.0, "an unrelated close scrolled back: {offset}");
    // By hand: the anchor is row 11 (200...220), unmoved: the offset stays.
    assert_eq!(offset, 200.0);
}

#[test]
fn a_close_beside_the_focused_row_is_no_move() {
    let old = list(&range(1, 6));
    let new = list(&[1, 2, 4, 5, 6]);
    assert!(!old.moved_by_itself(&2, &new));
    assert!(!old.moved_by_itself(&4, &new));
    assert!(old.moved_by_itself(&1, &list(&[2, 3, 1, 4, 5, 6])));
    // An id missing from either list never moved by itself.
    assert!(!old.moved_by_itself(&3, &new));
}

#[test]
fn anchor_keeps_what_the_user_sees_when_a_row_above_closes() {
    let old = list(&range(1, 20));
    let ids: Vec<i64> = range(1, 20).into_iter().filter(|&i| i != 2).collect();
    let new = list(&ids);
    // At 40 the rows in view are 3...7; row 3 keeps row 1 before it.
    let anchor = old.anchor(40.0, &new).unwrap();
    assert_eq!((anchor.id, anchor.start), (3, 40.0));
    assert_eq!(new.anchored(&old, 40.0), 20.0);
    // A row in view that moved by itself is skipped for one that stayed.
    let moved = list(&[1, 2, 4, 5, 3, 6, 7, 8, 9, 10]);
    let a = list(&range(1, 10)).anchor(40.0, &moved).unwrap();
    assert_eq!(a.id, 4);
}

#[test]
fn settle_reveals_a_new_focus_and_uses_its_extent() {
    let old = list(&range(1, 20));
    let new = old.clone();
    // A focus change to row 10 (180...200) reveals with padding 8: toTrailing 108 against toLeading 172.
    assert_eq!(new.settle(&old, 0.0, Some(&1), Some(&10), 8.0, false, None), 108.0);
    // The extent stands in for the row only when focus changed.
    let extent = Item::new(10, 160.0, 40.0);
    assert_eq!(new.settle(&old, 0.0, Some(&1), Some(&10), 0.0, false, Some(&extent)), 100.0);
    // Same focus, out of view, nothing moved and not user moved: stays.
    assert_eq!(new.settle(&old, 0.0, Some(&10), Some(&10), 8.0, false, Some(&extent)), 0.0);
    // userMoved reveals it, with the row, not the extent: 200 + 8 - 100.
    assert_eq!(new.settle(&old, 0.0, Some(&10), Some(&10), 8.0, true, Some(&extent)), 108.0);
    // A row already in view moves nothing, whatever the padding.
    assert_eq!(new.settle(&old, 0.0, Some(&1), Some(&5), 30.0, false, None), 0.0);
    // No new focus: the anchored offset.
    assert_eq!(new.settle(&old, 37.0, Some(&1), None, 8.0, false, None), 37.0);
    // An unknown new focus with no extent: the anchored offset.
    assert_eq!(new.settle(&old, 37.0, Some(&1), Some(&404), 8.0, false, None), 37.0);
}

#[test]
fn viewport_change_ops() {
    let to_wire = |l: &ListViewport<i64>| {
        json!({
            "items": l.items.iter().map(|i| json!({"id": i.id.to_string(), "start": i.start, "length": i.length})).collect::<Vec<_>>(),
            "viewport": l.viewport,
            "content": l.content,
        })
    };
    let old = list(&range(1, 20));
    let ids: Vec<i64> = range(1, 20).into_iter().filter(|&i| i != 2).collect();
    let new = list(&ids);
    let base = json!({"old": to_wire(&old), "new": to_wire(&new), "offset": 40});
    assert_eq!(
        op("layout_viewport_anchor", base.clone()),
        json!({"id": "3", "start": 40.0, "length": 20.0})
    );
    assert_eq!(op("layout_viewport_anchored", base), json!({"offset": 20.0}));
    let mut settle = json!({"old": to_wire(&old), "new": to_wire(&old), "offset": 0, "focused": "1", "newFocus": "10", "padding": 8});
    assert_eq!(op("layout_viewport_settle", settle.clone()), json!({"offset": 108.0}));
    settle["anchored"] = json!(50.0);
    // From the anchored offset given: row 10 (180...200) at 50 is out of view; trailing 108 is nearer.
    assert_eq!(op("layout_viewport_settle", settle), json!({"offset": 108.0}));
    let moved = json!({"old": to_wire(&list(&range(1, 6))), "new": to_wire(&list(&[2, 3, 1, 4, 5, 6])), "id": "1"});
    assert_eq!(op("layout_viewport_moved_by_itself", moved), json!({"moved": true}));
    assert_eq!(call("tokens.layout_nope", &json!({})), Err(OpError::Unknown));
}

// MARK: the reference rule (ListViewportReference.swift, test code there too)

struct Reference {
    items: Vec<Item<i64>>,
    viewport: f64,
    content: f64,
}

type Neighbours = HashMap<i64, (Option<i64>, Option<i64>)>;

impl Reference {
    fn from(l: &ListViewport<i64>) -> Self {
        Reference { items: l.items.clone(), viewport: l.viewport, content: l.content }
    }
    fn frame(&self) -> Frame {
        Frame { viewport: self.viewport, content: self.content }
    }
    fn item(&self, id: i64) -> Option<&Item<i64>> {
        self.items.iter().find(|i| i.id == id)
    }
    fn neighbours(order: &[i64]) -> Neighbours {
        let mut result = HashMap::new();
        for (index, &id) in order.iter().enumerate() {
            let prev = if index > 0 { Some(order[index - 1]) } else { None };
            let next = order.get(index + 1).copied();
            result.insert(id, (prev, next));
        }
        result
    }
    fn anchor(&self, offset: f64, next: &Reference) -> Option<Item<i64>> {
        let visible = |i: &Item<i64>| {
            i.end() > offset + EPSILON && i.start < offset + self.viewport - EPSILON
        };
        let new_ids: HashSet<i64> = next.items.iter().map(|i| i.id).collect();
        if !self.items.iter().any(|i| visible(i) && new_ids.contains(&i.id)) {
            return None;
        }
        let old_ids: HashSet<i64> = self.items.iter().map(|i| i.id).collect();
        let before = Self::neighbours(
            &self.items.iter().map(|i| i.id).filter(|i| new_ids.contains(i)).collect::<Vec<_>>(),
        );
        let after = Self::neighbours(
            &next.items.iter().map(|i| i.id).filter(|i| old_ids.contains(i)).collect::<Vec<_>>(),
        );
        let mut first = None;
        for item in self.items.iter().filter(|i| visible(i) && new_ids.contains(&i.id)) {
            if first.is_none() {
                first = Some(item.clone());
            }
            let (Some(old), Some(new)) = (before.get(&item.id), after.get(&item.id)) else {
                continue;
            };
            if old.0 == new.0 || old.1 == new.1 {
                return Some(item.clone());
            }
        }
        first
    }
    fn anchored(&self, old: &Reference, offset: f64) -> f64 {
        let mut next = offset;
        if let Some(anchor) = old.anchor(offset, self)
            && let Some(moved) = self.item(anchor.id)
        {
            next += moved.start - anchor.start;
        }
        self.frame().clamp(next)
    }
    #[allow(clippy::too_many_arguments)]
    fn settle(
        &self,
        old: &Reference,
        offset: f64,
        focused: Option<i64>,
        new_focus: Option<i64>,
        padding: f64,
        user_moved: bool,
        extent: Option<&Item<i64>>,
    ) -> f64 {
        let next = self.anchored(old, offset);
        let Some(nf) = new_focus else { return next };
        let target = if Some(nf) != focused { extent.cloned() } else { None }
            .or_else(|| self.item(nf).cloned());
        let Some(target) = target else { return next };
        let was_visible =
            old.item(nf).map(|i| old.frame().is_fully_visible(i, offset, 0.0)).unwrap_or(false);
        if !(Some(nf) != focused || user_moved || was_visible || old.moved_by_itself(nf, self)) {
            return next;
        }
        if self.frame().is_fully_visible(&target, next, 0.0) {
            return next;
        }
        self.frame().reveal(&target, next, padding)
    }
    fn moved_by_itself(&self, id: i64, next: &Reference) -> bool {
        let old_ids: HashSet<i64> = self.items.iter().map(|i| i.id).collect();
        let new_ids: HashSet<i64> = next.items.iter().map(|i| i.id).collect();
        if !old_ids.contains(&id) || !new_ids.contains(&id) {
            return false;
        }
        let before = Self::neighbours(
            &self.items.iter().map(|i| i.id).filter(|i| new_ids.contains(i)).collect::<Vec<_>>(),
        );
        let after = Self::neighbours(
            &next.items.iter().map(|i| i.id).filter(|i| old_ids.contains(i)).collect::<Vec<_>>(),
        );
        let (Some(b), Some(a)) = (before.get(&id), after.get(&id)) else { return false };
        b.0 != a.0 && b.1 != a.1
    }
}

/// A seeded xorshift, for the equality sweep.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn int(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next() % (hi - lo + 1)
    }
    fn chance(&mut self, p: f64) -> bool {
        (self.next() % 10_000) as f64 / 10_000.0 < p
    }
}

/// Rows of mixed heights packed by place, for `ids`.
fn packed(ids: &[i64], viewport: f64) -> ListViewport<i64> {
    let mut start = 0.0;
    let items = ids
        .iter()
        .map(|&id| {
            let length = [20.0, 28.0, 44.0][(id.unsigned_abs() % 3) as usize];
            let item = Item::new(id, start, length);
            start += length + 2.0;
            item
        })
        .collect();
    ListViewport::new(items, viewport, f64::max(start, viewport))
}

#[test]
fn the_rule_of_the_rows_in_view_equals_the_rule_of_every_row() {
    // SidebarViewportRuleEqualityTests, over plain lists.
    let (mut anchors, mut shifts, mut reveals) = (0, 0, 0);
    for seed in 1..=600u64 {
        let mut r = Rng(seed.wrapping_mul(0x9E37_79B9_7F4A_7C15) | 1);
        let count = r.int(1, 120) as i64;
        let ids: Vec<i64> = (0..count).collect();
        let mut changed = ids.clone();
        match r.int(0, 5) {
            0 if !changed.is_empty() => {
                let i = r.int(0, changed.len() as u64 - 1) as usize;
                changed.remove(i);
            }
            1 => {
                let i = r.int(0, changed.len() as u64) as usize;
                changed.insert(i, 1000 + seed as i64);
            }
            2 if !changed.is_empty() => {
                let moved = changed.remove(r.int(0, changed.len() as u64 - 1) as usize);
                let i = r.int(0, changed.len() as u64) as usize;
                changed.insert(i, moved);
            }
            3 => {
                for _ in 0..r.int(2, 12) {
                    if changed.len() > 1 {
                        let i = r.int(0, changed.len() as u64 - 1) as usize;
                        changed.remove(i);
                    }
                }
                for k in 0..r.int(0, 6) {
                    let i = r.int(0, changed.len() as u64) as usize;
                    changed.insert(i, 2000 + k as i64);
                }
            }
            4 => {
                for i in (1..changed.len()).rev() {
                    let j = r.int(0, i as u64) as usize;
                    changed.swap(i, j);
                }
            }
            _ => changed = (0..r.int(1, 80) as i64).map(|i| 5000 + i).collect(),
        }
        for _ in 0..6 {
            let height = r.int(60, 900) as f64;
            let old = packed(&ids, height);
            let new = packed(&changed, height);
            let (before, after) = (Reference::from(&old), Reference::from(&new));
            let top = f64::max(0.0, old.content - height);
            let offset = if r.chance(0.2) {
                if r.chance(0.5) { 0.0 } else { top }
            } else {
                (r.int(0, 1000) as f64 / 1000.0 * top).round()
            };
            let anchor = before.anchor(offset, &after);
            assert_eq!(old.anchor(offset, &new), anchor, "anchor: seed {seed}, offset {offset}");
            let anchored = after.anchored(&before, offset);
            assert_eq!(new.anchored(&old, offset), anchored, "anchored: seed {seed}");
            let focused = if ids.is_empty() || r.chance(0.1) {
                None
            } else {
                Some(ids[r.int(0, ids.len() as u64 - 1) as usize])
            };
            let new_focus = if r.chance(0.5) {
                focused
            } else if changed.is_empty() || r.chance(0.1) {
                None
            } else {
                Some(changed[r.int(0, changed.len() as u64 - 1) as usize])
            };
            let user_moved = r.chance(0.2);
            let extent = new_focus.and_then(|f| {
                if r.chance(0.5) {
                    new.item(&f)
                        .map(|i| Item::new(f, f64::max(0.0, i.start - 30.0), i.length + 30.0))
                } else {
                    None
                }
            });
            let settled =
                after.settle(&before, offset, focused, new_focus, 8.0, user_moved, extent.as_ref());
            let change = old.change(&new);
            assert_eq!(
                change.settle(
                    offset,
                    None,
                    focused.as_ref(),
                    new_focus.as_ref(),
                    8.0,
                    user_moved,
                    extent.as_ref()
                ),
                settled,
                "settle: seed {seed}"
            );
            assert_eq!(
                change.settle(
                    offset,
                    Some(anchored),
                    focused.as_ref(),
                    new_focus.as_ref(),
                    8.0,
                    user_moved,
                    extent.as_ref()
                ),
                settled,
                "settle from the anchored offset: seed {seed}"
            );
            for id in focused.into_iter().chain(new_focus).chain(ids.iter().take(3).copied()) {
                assert_eq!(
                    old.moved_by_itself(&id, &new),
                    before.moved_by_itself(id, &after),
                    "moved {id}: seed {seed}"
                );
            }
            anchors += anchor.is_some() as u32;
            shifts += (anchored != offset) as u32;
            reveals += (settled != anchored) as u32;
        }
    }
    assert!(
        anchors > 500 && shifts > 100 && reveals > 100,
        "{anchors} anchors, {shifts} shifts, {reveals} reveals"
    );
}
