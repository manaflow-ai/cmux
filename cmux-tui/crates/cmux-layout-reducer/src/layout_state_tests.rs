//! Mirrors `EndedValuesTests`, `DividerInsertPlanTests` and the `LayoutModel` focus, apply and
//! reject rules; the app's intent handler is the caller between [`EndedValues::send`] and
//! [`end_sending`].

use super::*;
use crate::screen_layout::{Edge, Row};

fn column(id: &str, width: f64, pane: &str) -> Column {
    Column { id: id.into(), width, root: Node::leaf(pane), dock: None, rows: Vec::new() }
}

fn screen(id: &str, layout: Layout) -> Screen {
    Screen {
        id: id.into(),
        name: id.into(),
        layout,
        zoomed: false,
        presented: false,
        hidden_dividers: BTreeSet::new(),
        floating: Vec::new(),
    }
}

fn strip(widths: [f64; 3]) -> Vec<Screen> {
    let columns = vec![
        column("c0", widths[0], "p0"),
        column("c1", widths[1], "p1"),
        column("c2", widths[2], "p2"),
    ];
    vec![screen("s", Layout::Columns(columns))]
}

fn model() -> Model {
    Model::new(strip([0.5, 0.5, 0.5]), Some("s".into()), Some("p0".into()))
}

fn widths(model: &Model) -> Vec<f64> {
    model.screens[0].layout.columns().iter().map(|column| column.width).collect()
}

fn ended(values: &[(&str, f64)], transaction: &str) -> EndedValues {
    EndedValues {
        values: values
            .iter()
            .map(|(column, width)| DragValue::Width { column: (*column).into(), width: *width })
            .collect(),
        transaction: transaction.into(),
    }
}

fn columns_of(intent: &Intent) -> Vec<String> {
    match intent {
        Intent::SetColumnWidth { column, phase: Phase::Ended, .. } => vec![column.clone()],
        Intent::SetLayoutSizes { values, .. } => values
            .iter()
            .filter_map(|value| match value {
                SizeValue::Width { column, .. } => Some(column.clone()),
                SizeValue::Ratio { .. } => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

/// `send(in:)` with an app that hears each intent through `handler`.
fn send(
    values: &EndedValues,
    model: &mut Model,
    handler: &mut dyn FnMut(&Intent, &mut Model),
) -> bool {
    match values.send(model, None) {
        SendStart::Done(sent) => sent,
        SendStart::Sending(intent) => {
            if let Some(intent) = intent
                && model.has_handler
            {
                handler(&intent, model);
            }
            end_sending(model)
        }
    }
}

#[test]
fn a_change_sent_from_inside_another_keeps_the_outer_refusal() {
    let mut model = model();
    let outer = ended(&[("c0", 0.55), ("c1", 0.45)], "outer");
    let inner = ended(&[("c2", 0.6)], "inner");
    let mut sent = Vec::new();
    let went = send(&outer, &mut model, &mut |intent, model| {
        sent.push(columns_of(intent));
        if let Intent::SetLayoutSizes { transaction, .. } = intent {
            let mut inner_sent = Vec::new();
            assert!(send(&inner, model, &mut |intent, _| inner_sent.push(columns_of(intent))));
            sent.extend(inner_sent);
            model.reject(transaction);
        }
    });
    assert!(!went, "the outer change said it went after the app refused it");
    assert_eq!(sent, vec![vec!["c0".to_owned(), "c1".into()], vec!["c2".into()]]);
    assert_eq!(widths(&model), vec![0.5, 0.5, 0.6]);
}

#[test]
fn a_refused_change_says_it_did_not_go_and_shows_nothing() {
    let mut model = model();
    let went =
        send(&ended(&[("c0", 0.55), ("c1", 0.45)], "t"), &mut model, &mut |intent, model| {
            if let Intent::SetLayoutSizes { transaction, .. } = intent {
                model.reject(transaction);
            }
        });
    assert!(!went);
    assert_eq!(widths(&model), vec![0.5, 0.5, 0.5]);
}

#[test]
fn a_refusal_of_another_change_leaves_this_one_sent() {
    let mut model = model();
    let went = send(&ended(&[("c0", 0.55), ("c1", 0.45)], "t"), &mut model, &mut |_, model| {
        model.reject("other");
    });
    assert!(went);
    assert_eq!(widths(&model), vec![0.55, 0.45, 0.5]);
}

#[test]
fn with_no_app_the_change_shows_and_counts_as_sent() {
    let mut model = model();
    model.has_handler = false;
    assert!(send(&ended(&[("c0", 0.55), ("c1", 0.45)], "t"), &mut model, &mut |_, _| panic!(
        "no app"
    )));
    assert_eq!(widths(&model), vec![0.55, 0.45, 0.5]);
    assert!(model.replies.unanswered.is_empty());
}

#[test]
fn the_one_intent_carries_the_shown_values_in_order() {
    let mut model = model();
    let mut intents = Vec::new();
    assert!(send(&ended(&[("c1", 0.45), ("c0", 0.55)], "t"), &mut model, &mut |intent, _| intents
        .push(intent.clone())));
    let want = Intent::SetLayoutSizes {
        values: vec![
            SizeValue::Width { column: "c1".into(), any_pane: "p1".into(), width: 0.45 },
            SizeValue::Width { column: "c0".into(), any_pane: "p0".into(), width: 0.55 },
        ],
        transaction: "t".into(),
    };
    assert_eq!(intents, vec![want]);
    assert_eq!(widths(&model), vec![0.55, 0.45, 0.5]);
}

#[test]
fn a_change_of_one_value_goes_as_its_own_command() {
    let mut model = model();
    let mut intents = Vec::new();
    assert!(send(&ended(&[("c0", 0.55)], "t"), &mut model, &mut |intent, _| intents
        .push(intent.clone())));
    let want = Intent::SetColumnWidth {
        column: "c0".into(),
        any_pane: "p0".into(),
        width: 0.55,
        transaction: "t".into(),
        phase: Phase::Ended,
    };
    assert_eq!(intents, vec![want]);
}

#[test]
fn one_reply_settles_a_change_of_two_values() {
    let mut model = model();
    assert!(send(&ended(&[("c0", 0.55), ("c1", 0.45)], "t"), &mut model, &mut |_, _| {}));
    model.apply(strip([0.5, 0.5, 0.5]));
    assert_eq!(
        widths(&model),
        vec![0.55, 0.45, 0.5],
        "a snapshot before the reply took the change back"
    );
    model.settle("t");
    model.apply(strip([0.6, 0.4, 0.5]));
    assert_eq!(widths(&model), vec![0.6, 0.4, 0.5]);
    assert!(model.width_overrides.is_empty());
}

#[test]
fn a_change_sent_inside_one_of_its_own_transaction_keeps_the_refusal() {
    let mut model = model();
    let outer = ended(&[("c0", 0.55), ("c1", 0.45)], "t");
    let inner = ended(&[("c2", 0.6)], "t");
    let mut sent = Vec::new();
    let went = send(&outer, &mut model, &mut |intent, model| {
        sent.push(columns_of(intent));
        if let Intent::SetLayoutSizes { transaction, .. } = intent {
            let mut inner_sent = Vec::new();
            send(&inner, model, &mut |intent, _| inner_sent.push(columns_of(intent)));
            sent.extend(inner_sent);
            model.reject(transaction);
        }
    });
    assert!(!went);
    assert_eq!(sent.len(), 2);
    assert_eq!(widths(&model), vec![0.5, 0.5, 0.5]);
}

#[test]
fn a_value_with_no_target_or_no_handle_sends_nothing() {
    let mut model = model();
    assert_eq!(
        ended(&[("c0", 0.55), ("gone", 0.4)], "t").send(&mut model, None),
        SendStart::Done(false)
    );
    let unsendable = Unsendable { splits: BTreeSet::new(), panes: ["p1".to_owned()].into() };
    assert_eq!(
        ended(&[("c0", 0.55), ("c1", 0.4)], "t").send(&mut model, Some(&unsendable)),
        SendStart::Done(false)
    );
    assert_eq!(widths(&model), vec![0.5, 0.5, 0.5]);
    assert_eq!(ended(&[], "t").send(&mut model, None), SendStart::Done(true));
}

// DividerInsertPlanTests

fn split(id: &str, axis: Axis, a: Node, b: Node, ratio: f64) -> Node {
    Node::split(id, axis, ratio, a, b)
}

#[test]
fn two_panes_split_the_first_and_move_the_divider_to_two_thirds() {
    for axis in [Axis::Horizontal, Axis::Vertical] {
        let tree = split("s", axis, Node::leaf("a"), Node::leaf("b"), 0.5);
        let plan = divider_insert_plan(&tree, "s").unwrap();
        assert_eq!(plan.target, "a");
        assert_eq!(plan.around, None);
        assert_eq!(plan.axis, axis);
        assert_eq!(plan.sizing, vec![RatioChange { split: "s".into(), ratio: 2.0 / 3.0 }]);
    }
}

#[test]
fn a_nested_first_side_is_wrapped_whole() {
    let inner = split("inner", Axis::Vertical, Node::leaf("x"), Node::leaf("y"), 0.5);
    let tree = split("s", Axis::Horizontal, inner, Node::leaf("b"), 0.5);
    let plan = divider_insert_plan(&tree, "s").unwrap();
    assert_eq!(plan.target, "y");
    assert_eq!(plan.around.as_deref(), Some("inner"));
}

#[test]
fn a_divider_in_a_chain_of_three_is_found() {
    let bc = split("bc", Axis::Horizontal, Node::leaf("b"), Node::leaf("c"), 0.5);
    let tree = split("outer", Axis::Horizontal, Node::leaf("a"), bc, 1.0 / 3.0);
    let plan = divider_insert_plan(&tree, "bc").unwrap();
    assert_eq!(plan.target, "b");
    assert_eq!(plan.around, None);
    assert_eq!(divider_insert_plan(&tree, "gone"), None);
}

#[test]
fn the_divider_beside_a_pane_is_the_one_after_it_else_before_it() {
    let bc = split("bc", Axis::Vertical, Node::leaf("b"), Node::leaf("c"), 0.5);
    let tree = split("outer", Axis::Horizontal, Node::leaf("a"), bc, 0.5);
    assert_eq!(divider_beside(&tree, "a").as_deref(), Some("outer"));
    assert_eq!(divider_beside(&tree, "b").as_deref(), Some("bc"));
    assert_eq!(divider_beside(&tree, "c").as_deref(), Some("bc"));
    assert_eq!(divider_beside(&Node::leaf("a"), "a"), None);
}

#[test]
fn the_model_finds_a_plan_on_any_screen_and_a_hidden_divider() {
    let tree = split("s", Axis::Horizontal, Node::leaf("a"), Node::leaf("b"), 0.5);
    let mut other = screen("two", Layout::Splits(tree));
    other.hidden_dividers.insert("s".into());
    let screens = vec![screen("one", Layout::Splits(Node::leaf("z"))), other];
    assert_eq!(screens_divider_insert_plan(&screens, "s").unwrap().target, "a");
    assert_eq!(screens_divider_beside(&screens, "b").as_deref(), Some("s"));
    assert!(divider_hidden(&screens, "s"));
    assert!(!divider_hidden(&screens, "t"));
}

// LayoutModel focus, apply, reject

#[test]
fn a_closed_focused_pane_hands_focus_to_the_pane_before_it() {
    let mut model = model();
    model.focus("p1", false, FocusSource::Keyboard);
    assert!(model.focus_ring_earned);
    let columns = vec![column("c0", 0.5, "p0"), column("c2", 0.5, "p2")];
    model.apply(vec![screen("s", Layout::Columns(columns))]);
    assert_eq!(model.focused_pane.as_deref(), Some("p0"));
    assert!(!model.focus_ring_earned);
    model.apply(vec![screen("s", Layout::Columns(vec![column("c2", 0.5, "p2")]))]);
    assert_eq!(model.focused_pane.as_deref(), Some("p2"), "no pane before it: the one after");
}

#[test]
fn a_gone_active_screen_falls_back_to_the_first() {
    let mut model = model();
    model.apply(vec![screen("t", Layout::Splits(Node::leaf("q")))]);
    assert_eq!(model.active_screen.as_deref(), Some("t"));
    assert_eq!(model.focused_pane.as_deref(), Some("q"));
}

#[test]
fn focus_moves_the_ring_reveals_and_raises() {
    let mut model = model();
    model.screens[0].floating = vec![
        FloatingPane { pane: "f0".into(), frame: Rect::UNIT },
        FloatingPane { pane: "f1".into(), frame: Rect::UNIT },
    ];
    let effects = model.focus("f0", true, FocusSource::Keyboard);
    assert_eq!(
        effects.intents,
        vec![Intent::RaiseFloatingPane { pane: "f0".into() }, Intent::Focus { pane: "f0".into() }]
    );
    assert_eq!(effects.entered.as_deref(), Some("f0"));
    assert_eq!(effects.reveal_on_canvas.as_deref(), Some("s"));
    let pointer = model.focus("f1", false, FocusSource::Pointer);
    assert_eq!(pointer.intents, Vec::new(), "the front pane is not raised");
    assert_eq!(pointer.reveal_on_canvas, None);
    assert!(!model.focus_ring_earned);
    model.focus_ring_earned = true;
    let again = model.focus("f1", true, FocusSource::Scroll);
    assert_eq!(again, FocusEffects::default());
    assert!(!model.focus_ring_earned);
    assert_eq!(model.focus("gone", true, FocusSource::Keyboard), FocusEffects::default());
}

#[test]
fn select_screen_moves_a_focus_not_on_it() {
    let mut screens = strip([0.5, 0.5, 0.5]);
    screens.push(screen("t", Layout::Splits(Node::leaf("q"))));
    let mut model = Model::new(screens, None, None);
    assert_eq!(model.active_screen.as_deref(), Some("s"));
    assert_eq!(model.focused_pane.as_deref(), Some("p0"));
    assert_eq!(model.select_screen("s"), Vec::new());
    assert_eq!(model.select_screen("gone"), Vec::new());
    assert_eq!(model.select_screen("t"), vec![Intent::SelectScreen { screen: "t".into() }]);
    assert_eq!(model.focused_pane.as_deref(), Some("q"));
}

#[test]
fn a_split_ratio_shows_while_dragging_and_sends_at_the_end() {
    let tree = split("s", Axis::Horizontal, Node::leaf("a"), Node::leaf("b"), 0.5);
    let mut model = Model::new(vec![screen("one", Layout::Splits(tree))], None, None);
    assert_eq!(model.set_split_ratio("s", 0.99, "t", Phase::Changed), Vec::new());
    assert_eq!(model.screens[0].layout.ratio_of("s"), Some(0.95));
    let sent = model.set_split_ratio("s", 0.7, "t", Phase::Ended);
    assert_eq!(
        sent,
        vec![Intent::SetSplitRatio {
            split: "s".into(),
            ratio: 0.7,
            transaction: "t".into(),
            phase: Phase::Ended
        }]
    );
    assert_eq!(model.replies.unanswered.get("t"), Some(&1));
    assert!(model.reject("t"));
    assert_eq!(model.screens[0].layout.ratio_of("s"), Some(0.5));
    assert!(!model.reject("t"), "nothing left to drop");
}

#[test]
fn a_confirmed_ended_override_is_dropped_on_the_snapshot() {
    let mut model = model();
    model.set_column_width("c0", 0.6, "t", Phase::Ended);
    model.apply(strip([0.601, 0.5, 0.5]));
    assert!(model.width_overrides.is_empty());
    assert_eq!(widths(&model), vec![0.601, 0.5, 0.5]);
    assert_eq!(model.set_column_width("gone", 0.6, "t", Phase::Ended), Vec::new());
}

#[test]
fn supersede_drops_only_ended_overrides_of_the_set() {
    let mut model = model();
    model.set_column_width("c0", 0.6, "t", Phase::Ended);
    model.set_column_width("c1", 0.6, "u", Phase::Changed);
    model.supersede_sent_widths(&["c0".to_owned(), "c1".into()].into());
    assert_eq!(model.width_overrides.keys().collect::<Vec<_>>(), vec!["c1"]);
    let (shown, intents) = model.cancel_gesture("u");
    assert!(shown);
    assert_eq!(intents, vec![Intent::CancelGesture { transaction: "u".into() }]);
}

#[test]
fn replies_count_down_and_forget_marks_the_sending_refused() {
    let mut replies = TransactionReplies::default();
    replies.await_reply("t");
    replies.await_reply("t");
    assert!(!replies.answered("t"));
    assert!(replies.answered("t"));
    assert!(replies.answered("never"));
    replies.begin_sending("t");
    replies.begin_sending("u");
    replies.forget("t");
    assert!(!replies.end_sending());
    assert!(replies.end_sending());
    assert!(!replies.end_sending());
}

// ScreenLayout and LayoutScreen

#[test]
fn structure_ignores_sizes_but_not_docks_or_rows() {
    let a = Layout::Columns(vec![column("c0", 0.5, "p0")]);
    let b = Layout::Columns(vec![column("c0", 0.9, "p0")]);
    assert!(has_same_structure(&a, &b));
    let dock = Dock {
        edge: Edge::Left,
        mode: Default::default(),
        role: None,
        is_pinned: false,
        allows_tabs: false,
    };
    let docked = setting_dock(&b, Some(&dock), "c0");
    assert!(!has_same_structure(&a, &docked));
    assert!(!has_same_structure(&a, &Layout::Splits(Node::leaf("p0"))));
    let row = |id: &str, pane: &str| Row { id: id.into(), height: 500, root: Node::leaf(pane) };
    let mut rows = column("c0", 0.5, "p0");
    rows.rows = vec![row("r0", "p0"), row("r1", "p1")];
    let rowed = Layout::Columns(vec![rows]);
    let taller = setting_row_heights(
        &rowed,
        &[RowHeight { row: "r1".into(), height: 300 }, RowHeight { row: "r1".into(), height: 700 }],
        "c0",
    );
    assert_eq!(taller.columns()[0].rows[1].height, 700);
    assert_eq!(taller.columns()[0].rows[0].height, 500);
    assert!(has_same_structure(&rowed, &taller));
    assert!(!has_same_structure(&a, &rowed));
}

#[test]
fn docking_a_column_undocks_the_other_on_that_edge() {
    let dock = Dock {
        edge: Edge::Left,
        mode: Default::default(),
        role: None,
        is_pinned: false,
        allows_tabs: false,
    };
    let layout = Layout::Columns(vec![column("c0", 0.5, "p0"), column("c1", 0.5, "p1")]);
    let first = setting_dock(&layout, Some(&dock), "c0");
    let second = setting_dock(&first, Some(&dock), "c1");
    assert_eq!(second.columns()[0].dock, None);
    assert_eq!(second.columns()[1].dock, Some(dock));
    assert_eq!(setting_dock(&second, None, "c1").columns()[1].dock, None);
}

#[test]
fn a_split_screen_has_one_implicit_column() {
    let one = screen("one", Layout::Splits(Node::leaf("a")));
    let implicit = one.column_containing("a").unwrap();
    assert_eq!(implicit.id, "implicit:one");
    assert_eq!(implicit.width, 1.0);
    assert_eq!(one.column_by_id("implicit:one"), Some(implicit));
    assert_eq!(one.column_containing("b"), None);
    assert!(!one.in_agent_chat_dock("a"));
}

#[test]
fn tree_with_split_finds_the_row_tree() {
    let mut rows = column("c0", 0.5, "p0");
    let tree = split("s", Axis::Vertical, Node::leaf("p1"), Node::leaf("p2"), 0.5);
    rows.rows = vec![
        Row { id: "r0".into(), height: 500, root: Node::leaf("p0") },
        Row { id: "r1".into(), height: 500, root: tree.clone() },
    ];
    let layout = Layout::Columns(vec![rows]);
    assert_eq!(tree_with_split(&layout, "s"), Some(&tree));
    assert_eq!(tree_with_split(&layout, "gone"), None);
}

// Floating panes

#[test]
fn a_floating_frame_clamps_its_size_then_its_corner() {
    assert_eq!(floating_clamped(Rect::new(0.95, -0.2, 0.05, 2.0)), Rect::new(0.85, 0.0, 0.15, 1.0));
    assert_eq!(floating_clamped(Rect::new(0.5, 0.5, -0.3, 0.2)), Rect::new(0.2, 0.5, 0.3, 0.2));
}

#[test]
fn a_floating_rect_snaps_to_the_pixel_grid() {
    let rect = floating_rect(Rect::new(0.1, 0.1, 0.5, 0.5), 101.0, 51.0, 2.0);
    assert_eq!(rect, Rect::new(10.0, 5.0, 50.5, 25.5));
    let card = Rect::new(10.0, 20.0, 100.0, 80.0);
    assert_eq!(floating_pane_rect(card), Rect::new(15.0, 34.0, 90.0, 61.0));
    assert_eq!(floating_card_rect(floating_pane_rect(card)), card);
    assert_eq!(floating_pane_rect(Rect::new(0.0, 0.0, 4.0, 4.0)), Rect::new(5.0, 14.0, 0.0, 0.0));
    assert_eq!(floating_fractions(card, 200.0, 160.0), Rect::new(0.05, 0.125, 0.5, 0.5));
    assert_eq!(floating_fractions(card, 0.0, 160.0), Rect::UNIT);
}

// Layout cache

#[test]
fn the_cache_tree_is_the_strip_as_one_horizontal_split() {
    let model = Model::new(strip([0.5, 0.25, 0.25]), None, None);
    let node = cache_node(&model, &BTreeMap::new()).unwrap();
    assert_eq!(node["axis"], "h");
    assert_eq!(node["fractions"], json!([0.5, 0.25, 0.25]));
    assert_eq!(
        node["children"][0]["frame"],
        json!({"x": 0.0, "y": 0.0, "width": 0.0, "height": 0.0})
    );
    let live = cache_live(&model, None, 1.0).unwrap();
    assert_eq!(live["panes"], json!(["p0", "p1", "p2"]));
    assert_eq!(live["root"]["children"].as_array().unwrap().len(), 3);
    let none = Model::new(strip([0.0, -1.0, 0.0]), None, None);
    assert_eq!(cache_node(&none, &BTreeMap::new()), None);
}

#[test]
fn the_drift_mark_names_the_moves() {
    let cached = json!({"type": "leaf", "pane_id": "p0", "kind": "other"});
    assert_eq!(cache_drift(&cached, Some((0, 0))).as_deref(), Some("layout_cache.exact"));
    assert_eq!(
        cache_drift(&cached, Some((2, 1))).as_deref(),
        Some("layout_cache.drift.moved_2.transitions_1")
    );
    assert_eq!(cache_drift(&cached, None), None);
    assert_eq!(cache_drift(&json!({"type": "leaf", "pane_id": ""}), Some((0, 0))), None);
}
