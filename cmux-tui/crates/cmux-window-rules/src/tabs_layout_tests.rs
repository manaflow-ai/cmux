use serde_json::Value;

use super::vertical::{self, List, Rect, RowKind};
use super::*;

fn metrics() -> Metrics {
    Metrics {
        max_tab_width: 240.0,
        min_inactive_tab_width: 74.0,
        min_active_tab_width: 74.0,
        pinned_tab_width: 36.0,
        compact_tab_width: 180.0,
        pinned_group_gap: 10.0,
        chrome_min_inactive_width: 32.0,
        close_min_contents_width: 56.0,
        title_min_visible_width: 20.0,
        content_leading_inset: 8.0,
        content_trailing_inset: 6.0,
        icon_size: 16.0,
        close_button_size: 14.0,
        icon_title_spacing: 6.0,
        title_close_spacing: 8.0,
        status_mark_placement: StatusMarkPlacement::MirrorIcon,
    }
}

/// The crowded strip of the hover tests: tabs shrink to 32 points.
fn narrow() -> Metrics {
    Metrics { min_inactive_tab_width: 32.0, ..metrics() }
}

fn tab(id: &str) -> Item {
    Item { id: id.into(), ..Item::default() }
}

fn pinned(id: &str) -> Item {
    Item { pinned: true, ..tab(id) }
}

fn tabs(count: usize) -> Vec<Item> {
    (0..count).map(|index| tab(&format!("t{index}"))).collect()
}

fn state() -> TabState {
    TabState::default()
}

// MARK: Layout

/// A row kind: its name, items, style, closing-mode width and Full Width Tab.
type RowKindCase = (&'static str, Vec<Item>, Style, Option<f64>, Option<&'static str>);

#[test]
fn resized_equals_a_full_layout_for_every_row_kind() {
    let m = metrics();
    let member = |id: &str, group: &str| Item { group: Some(group.into()), ..tab(id) };
    let chip = |width: f64| Item {
        id: "chip".into(),
        group: Some("g".into()),
        fixed_width: Some(width),
        group_chip: true,
        ..Item::default()
    };
    let mut pinned_and_unpinned = tabs(8);
    for item in &mut pinned_and_unpinned[..3] {
        item.pinned = true;
    }
    let mut group_with_chip = vec![pinned("p0"), chip(57.5)];
    group_with_chip.extend(["t1", "t2", "t3"].map(|id| member(id, "g")));
    group_with_chip.extend(["t4", "t5", "t6"].map(tab));
    let mut collapsed_group = vec![chip(40.0)];
    collapsed_group
        .extend(["t0", "t1", "t2"].map(|id| Item { collapsed: true, ..member(id, "g") }));
    collapsed_group.extend(["t3", "t4", "t5"].map(tab));
    let mut full_width = tabs(5);
    full_width[0].pinned = true;
    let only_pinned: Vec<Item> = (0..4).map(|index| pinned(&format!("p{index}"))).collect();
    let rows: Vec<RowKindCase> = vec![
        ("noTabs", vec![], Style::Chrome, None, None),
        ("oneTab", tabs(1), Style::Chrome, None, None),
        ("threeTabs", tabs(3), Style::Chrome, None, None),
        ("twelveTabs", tabs(12), Style::Chrome, None, None),
        ("pinnedAndUnpinned", pinned_and_unpinned, Style::Chrome, None, None),
        ("onlyPinned", only_pinned, Style::Chrome, None, None),
        ("groupWithChip", group_with_chip, Style::Chrome, None, None),
        ("collapsedGroup", collapsed_group, Style::Chrome, None, None),
        ("compact", tabs(6), Style::Compact, None, None),
        ("closingMode", tabs(6), Style::Chrome, Some(413.0), None),
        ("fullWidthTab", full_width, Style::Chrome, None, Some("t2")),
    ];
    let mut widths: Vec<f64> = (0..=2133).map(|step| step as f64 * 0.75).collect();
    widths.extend((0..=120).map(|step| 1600.0 - step as f64 * 13.25).filter(|width| *width >= 0.0));
    widths.extend([640.0, 3.0, 1200.5, 0.0]);
    for (name, items, style, closing, full) in rows {
        let mut result = layout(&items, 800.0, style, &m, closing, full);
        for &width in &widths {
            result = resized(&result, width, style, &m, closing);
            assert_eq!(
                result,
                layout(&items, width, style, &m, closing, full),
                "{name} at {width}"
            );
        }
    }
}

#[test]
fn a_selection_never_changes_a_crowded_strip() {
    let m = Metrics { min_inactive_tab_width: 32.0, min_active_tab_width: 72.0, ..metrics() };
    let mut items = tabs(30);
    let plain = layout(&items, 1200.0, Style::Chrome, &m, None, None);
    let widths: Vec<f64> = plain.slots.iter().map(|slot| slot.width).collect();
    let (low, high) = widths.iter().fold((f64::MAX, f64::MIN), |(l, h), w| (l.min(*w), h.max(*w)));
    assert!(high - low <= 1.0, "{widths:?}");
    assert!(widths.iter().all(|width| *width < m.min_active_tab_width));
    items[7].selected = true;
    assert_eq!(layout(&items, 1200.0, Style::Chrome, &m, None, None), plain);
}

#[test]
fn pinned_tabs_are_thin_and_gapped() {
    let m = metrics();
    let result =
        layout(&[pinned("p0"), pinned("p1"), tab("a")], 800.0, Style::Chrome, &m, None, None);
    assert!(result.slots[..2].iter().all(|slot| slot.width == m.pinned_tab_width));
    assert_eq!(result.slots[2].x, 2.0 * m.pinned_tab_width + m.pinned_group_gap);
}

#[test]
fn row_share_tiers() {
    let m = metrics();
    assert_eq!(row_share(0, 500.0, Style::Chrome, &m), Share::None);
    assert_eq!(row_share(3, 10.0, Style::Compact, &m), Share::Each { width: 180.0 });
    assert_eq!(row_share(2, 1000.0, Style::Chrome, &m), Share::Each { width: 240.0 });
    assert_eq!(row_share(1, 100.7, Style::Chrome, &m), Share::Alone { width: 100.0 });
    assert_eq!(row_share(1, 20.0, Style::Chrome, &m), Share::Alone { width: 74.0 });
    assert_eq!(row_share(3, 301.0, Style::Chrome, &m), Share::Split { base: 100.0, extra: 1 });
    assert_eq!(row_share(5, 100.0, Style::Chrome, &m), Share::Each { width: 74.0 });
    assert_eq!(distribute(10.0, 3), vec![4.0, 3.0, 3.0]);
    assert_eq!(split(f64::INFINITY, 3), (0.0, 0));
}

#[test]
fn closing_mode_keeps_the_neighbor_under_the_pointer() {
    let m = metrics();
    let result = layout(&[pinned("p"), tab("a"), tab("b")], 2000.0, Style::Chrome, &m, None, None);
    // The only pinned tab goes, and the gap with it.
    assert_eq!(closing_mode_width("p", &result, None), Some(480.0));
    assert_eq!(closing_mode_width("a", &result, Some(300.0)), Some(286.0));
    assert_eq!(closing_mode_width("b", &result, Some(300.0)), Some(300.0));
    assert_eq!(closing_mode_width("missing", &result, None), None);
}

#[test]
fn a_drop_gap_lands_before_a_foreign_chip() {
    let chip =
        Item { id: "chip".into(), group: Some("g".into()), group_chip: true, ..Item::default() };
    let member = Item { group: Some("g".into()), ..tab("b") };
    let items = vec![tab("a"), chip, member];
    let mut outside = items.clone();
    insert_placeholder(&mut outside, tab("gap"), 1);
    assert_eq!(outside[1].id, "gap");
    let mut inside = items;
    insert_placeholder(&mut inside, Item { group: Some("g".into()), ..tab("gap") }, 1);
    assert_eq!(inside[2].id, "gap");
}

// MARK: Reorder and scroll

#[test]
fn insertion_index_takes_the_nearest_edge_first_on_a_tie() {
    assert_eq!(insertion_index(0.0, 0.0, &[100.0, 100.0]), 0);
    assert_eq!(insertion_index(149.0, 0.0, &[100.0, 100.0]), 1);
    assert_eq!(insertion_index(150.0, 0.0, &[100.0, 100.0]), 1);
    assert_eq!(insertion_index(500.0, 0.0, &[100.0, 100.0]), 2);
}

#[test]
fn reveal_scrolls_the_least_and_skips_the_band() {
    let slot = Slot { id: "s".into(), x: 900.0, width: 100.0, ..Slot::default() };
    assert_eq!(offset_revealing(&slot, 0.0, 2000.0, 500.0, 12.0, 0.0), 512.0);
    let pinned = Slot { pinned: true, ..slot.clone() };
    assert_eq!(offset_revealing(&pinned, 40.0, 2000.0, 500.0, 12.0, 80.0), 40.0);
    let early = Slot { x: 100.0, ..slot };
    assert_eq!(offset_revealing(&early, 300.0, 2000.0, 500.0, 12.0, 80.0), 8.0);
    assert_eq!(faded_edges(-20.0, 1000.0, 500.0), FadedEdges { leading: false, trailing: true });
    assert_eq!(faded_edges(500.0, 1000.0, 500.0), FadedEdges { leading: true, trailing: false });
}

#[test]
fn the_pinned_band_holds_still_while_it_leaves_room() {
    let m = metrics();
    let result = layout(&[pinned("p"), tab("a"), tab("b")], 400.0, Style::Chrome, &m, None, None);
    let mapping = ScrollMapping::new(&result, 400.0, 100.0, 30.0);
    assert_eq!(mapping.band, 46.0);
    assert_eq!(mapping.view_x(10.0, true), 10.0);
    assert_eq!(mapping.view_x(100.0, false), 70.0);
    assert!(!mapping.shows_unpinned(45.0));
    assert_eq!(ScrollMapping::new(&result, 120.0, 100.0, 30.0).band, 0.0);
}

// MARK: Chrome visibility

#[test]
fn pinned_tabs_show_only_their_centered_icon() {
    let m = narrow();
    for hovered in [false, true] {
        for closable in [false, true] {
            let form = Visibility::resolve(
                36.0,
                TabState { pinned: true, hovered, closable, ..state() },
                Style::Chrome,
                &m,
            );
            assert_eq!(form, Visibility::new(true, false, false, true));
        }
    }
}

#[test]
fn a_crowded_hovered_tab_trades_its_icon_for_a_centered_close() {
    let m = narrow();
    let form = Visibility::resolve(32.0, TabState { hovered: true, ..state() }, Style::Chrome, &m);
    assert!(form.shows_close && !form.shows_icon && form.centers_content);
    assert_eq!(form.close_button_origin_x(32.0, &m), Some(9.0));
    let unclosable = Visibility::resolve(
        32.0,
        TabState { hovered: true, closable: false, ..state() },
        Style::Chrome,
        &m,
    );
    assert!(unclosable.shows_icon && !unclosable.shows_close);
}

#[test]
fn a_roomy_hovered_tab_shows_icon_title_and_close() {
    let m = narrow();
    let form = Visibility::resolve(200.0, TabState { hovered: true, ..state() }, Style::Chrome, &m);
    assert_eq!(form, Visibility::new(true, true, true, false));
    assert_eq!(form.close_button_origin_x(200.0, &m), Some(180.0));
}

#[test]
fn a_narrow_selected_tab_keeps_its_close_at_rest() {
    let m = narrow();
    let form = Visibility::resolve(60.0, TabState { selected: true, ..state() }, Style::Chrome, &m);
    assert!(form.shows_close);
    // Contents of 60 with a 56 minimum: roomy, so the x waits for the hover (Helium's parity).
    let roomy =
        Visibility::resolve(74.0, TabState { selected: true, ..state() }, Style::Chrome, &m);
    assert!(!roomy.shows_close && roomy.shows_title);
}

#[test]
fn too_narrow_hides_everything() {
    let form = Visibility::resolve(20.0, state(), Style::Chrome, &narrow());
    assert_eq!(form, Visibility::HIDDEN);
    assert!(form.is_hidden());
}

#[test]
fn a_hovered_status_yields_to_the_close() {
    let m = narrow();
    let titled = Visibility::resolve(
        200.0,
        TabState { hovered: true, has_status: true, ..state() },
        Style::Chrome,
        &m,
    );
    assert!(titled.close_replaces_status && titled.shows_title && titled.shows_icon);
    let untitled = Visibility::resolve(
        40.0,
        TabState { hovered: true, has_status: true, ..state() },
        Style::Chrome,
        &m,
    );
    assert!(untitled.close_replaces_status && !untitled.shows_icon && untitled.centers_content);
    assert_eq!(untitled.close_button_origin_x(40.0, &m), Some(13.0));
    // A resting close already sits beside the status.
    let resting = Visibility::resolve(
        60.0,
        TabState { selected: true, hovered: true, has_status: true, ..state() },
        Style::Chrome,
        &m,
    );
    assert!(resting.shows_close && !resting.close_replaces_status);
    // A hidden tab has no x to yield to.
    let hidden = Visibility::resolve(
        10.0,
        TabState { hovered: true, has_status: true, ..state() },
        Style::Chrome,
        &m,
    );
    assert!(!hidden.close_replaces_status);
}

#[test]
fn hovering_a_narrow_selected_tab_changes_nothing() {
    let m = narrow();
    let widths = [40.0, 50.0, 60.0, 68.0];
    let rest = TabState { selected: true, ..state() };
    let hovered = TabState { hovered: true, ..rest };
    for width in widths {
        assert_eq!(
            Visibility::resolve(width, rest, Style::Chrome, &m),
            Visibility::resolve(width, hovered, Style::Chrome, &m)
        );
    }
    let start = Visibility::resolve(40.0, rest, Style::Chrome, &m);
    assert_eq!(
        Visibility::path(&widths, start, rest, Style::Chrome, &m),
        Visibility::path(&widths, start, hovered, Style::Chrome, &m)
    );
}

#[test]
fn an_unclosable_tab_never_shows_a_close() {
    let m = narrow();
    let tab = TabState { selected: true, hovered: true, closable: false, ..state() };
    let form = Visibility::resolve(220.0, tab, Style::Chrome, &m);
    assert!(!form.shows_close && form.shows_title);
    let start = Visibility::resolve(120.0, tab, Style::Chrome, &m);
    assert!(
        Visibility::path(&[120.0, 180.0, 220.0], start, tab, Style::Chrome, &m)
            .iter()
            .all(|form| !form.shows_close)
    );
}

#[test]
fn a_width_path_changes_each_part_once() {
    let m = narrow();
    let tab = TabState { hovered: true, ..state() };
    let widths = [200.0, 30.0, 120.0, 40.0, 60.0];
    let start = Visibility::resolve(200.0, tab, Style::Chrome, &m);
    let forms = Visibility::path(&widths, start, tab, Style::Chrome, &m);
    // The x can still wait where a kept icon leaves it no room; the icon and the title flip once.
    for part in [|f: &Visibility| f.shows_icon, |f: &Visibility| f.shows_title] {
        let flips = forms.windows(2).filter(|pair| part(&pair[0]) != part(&pair[1])).count()
            + usize::from(part(&start) != part(&forms[0]));
        assert!(flips <= 1, "{forms:?}");
    }
    assert_eq!(forms.last(), Some(&Visibility::resolve(60.0, tab, Style::Chrome, &m)));
    assert!(Visibility::path(&[], start, tab, Style::Chrome, &m).is_empty());
}

#[test]
fn mirror_all_puts_the_close_in_the_status_slot() {
    let m = Metrics { status_mark_placement: StatusMarkPlacement::MirrorAll, ..narrow() };
    let form = Visibility::resolve(200.0, TabState { hovered: true, ..state() }, Style::Chrome, &m);
    // The icon's center mirrored: 200 - 8 - 8 = 184; the x's own center is 187.
    assert_eq!(form.close_button_origin_x(200.0, &m), Some(177.0));
    assert_eq!(m.status_slot_mid_x(200.0, StatusMarkPlacement::CloseSlot), 187.0);
}

// MARK: Vertical list

fn vtab(id: &str, pinned: bool, group: Option<&str>) -> vertical::Tab {
    vertical::Tab { id: id.into(), pinned, group: group.map(Into::into) }
}

fn model() -> (Vec<vertical::Tab>, Vec<vertical::Group>) {
    let tabs = vec![
        vtab("p1", true, None),
        vtab("p2", true, None),
        vtab("a", false, None),
        vtab("w1", false, Some("work")),
        vtab("w2", false, Some("work")),
        vtab("l1", false, Some("later")),
        vtab("b", false, None),
    ];
    let groups = vec![
        vertical::Group { id: "work".into(), collapsed: false },
        vertical::Group { id: "later".into(), collapsed: true },
    ];
    (tabs, groups)
}

fn list<'a>(
    tabs: &'a [vertical::Tab],
    groups: &'a [vertical::Group],
    icons_only: bool,
) -> List<'a> {
    List { tabs, groups, icons_only, width: 240.0, metrics: vertical::Metrics::default() }
}

#[test]
fn vertical_rows_follow_the_model() {
    let (tabs, groups) = model();
    let list = list(&tabs, &groups, false);
    let layout = list.layout(true);
    let kinds: Vec<RowKind> = layout.rows.iter().map(|row| row.kind.clone()).collect();
    assert_eq!(
        kinds,
        vec![
            RowKind::Pinned("p1".into()),
            RowKind::Pinned("p2".into()),
            RowKind::Separator,
            RowKind::Tab("a".into()),
            RowKind::GroupHeader("work".into()),
            RowKind::Tab("w1".into()),
            RowKind::Tab("w2".into()),
            RowKind::GroupHeader("later".into()),
            RowKind::Tab("b".into()),
            RowKind::NewTab,
        ]
    );
    assert_eq!(layout.pinned_columns, 6);
    assert_eq!(layout.group_lines.len(), 1);
    assert_eq!(
        layout.group_panes.iter().map(|pane| pane.group.as_str()).collect::<Vec<_>>(),
        ["work", "later"]
    );
    let work = layout
        .rows
        .iter()
        .find(|row| row.kind == RowKind::GroupHeader("work".into()))
        .unwrap()
        .frame;
    let w2 = list.frame_of(&layout, "w2").unwrap();
    assert_eq!(layout.group_panes[0].frame, Rect::new(6.0, work.y, 228.0, w2.max_y() - work.y));
    assert_eq!(w2.x, 14.0);
    assert_eq!(list.frame_of(&layout, "l1"), None);
}

#[test]
fn vertical_drop_slots() {
    let (tabs, groups) = model();
    let list = list(&tabs, &groups, false);
    let layout = list.layout(true);
    let at = |id: RowKind, fraction: f64| {
        let frame = layout.rows.iter().find(|row| row.kind == id).unwrap().frame;
        let slot = list.slot_at(&layout, 20.0, frame.y + frame.height * fraction, false);
        (slot.index, slot.group)
    };
    let work = Some("work".to_string());
    assert_eq!(at(RowKind::Tab("a".into()), 0.25), (2, None));
    assert_eq!(at(RowKind::GroupHeader("work".into()), 0.25), (3, None));
    assert_eq!(at(RowKind::GroupHeader("work".into()), 0.75), (3, work.clone()));
    assert_eq!(at(RowKind::Tab("w1".into()), 0.75), (4, work.clone()));
    assert_eq!(at(RowKind::Tab("w2".into()), 0.75), (5, work));
    assert_eq!(at(RowKind::GroupHeader("later".into()), 0.25), (5, None));
    assert_eq!(at(RowKind::GroupHeader("later".into()), 0.75), (6, None));
    assert_eq!(list.slot_at(&layout, 20.0, layout.content_height + 50.0, false).index, 7);
    assert_eq!(list.slot_at(&layout, 200.0, 20.0, true).index, 2);
    assert_eq!(list.slot_at(&layout, 7.0, 20.0, true).index, 0);
}

#[test]
fn vertical_icons_only_stacks_one_column() {
    let (tabs, groups) = model();
    let list = List { width: 44.0, ..list(&tabs, &groups, true) };
    let layout = list.layout(false);
    assert_eq!(layout.pinned_columns, 1);
    let p2 = list.frame_of(&layout, "p2").unwrap();
    assert_eq!((p2.x, p2.y), (6.0, 42.0));
    let header =
        layout.rows.iter().find(|row| row.kind == RowKind::GroupHeader("work".into())).unwrap();
    assert_eq!(header.frame.height, 8.0);
    assert_eq!(list.frame_of(&layout, "w1").unwrap().x, 6.0);
    assert_eq!(layout.group_lines[0].frame.x, 1.0);
}

#[test]
fn vertical_row_at_skips_the_separator() {
    let (tabs, groups) = model();
    let list = list(&tabs, &groups, false);
    let layout = list.layout(true);
    let separator = layout.rows.iter().find(|row| row.kind == RowKind::Separator).unwrap().frame;
    assert!(list.row_at(&layout, 20.0, separator.mid_y()).is_none());
    let a = list.frame_of(&layout, "a").unwrap();
    assert_eq!(
        list.row_at(&layout, 1.0, a.mid_y()).map(|row| row.kind.clone()),
        Some(RowKind::Tab("a".into()))
    );
    assert!(list.row_at(&layout, 240.0, a.mid_y()).is_none());
    assert!(list.row_at(&layout, 5.0, 10.0).is_none());
}

#[test]
fn an_empty_list_is_its_padding() {
    let list = List {
        tabs: &[],
        groups: &[],
        icons_only: false,
        width: 240.0,
        metrics: vertical::Metrics::default(),
    };
    let layout = list.layout(false);
    assert_eq!(layout.content_height, 12.0);
    let slot = list.slot_at(&layout, 0.0, 0.0, false);
    assert_eq!((slot.index, slot.indicator), (0, Rect::new(6.0, 6.0, 228.0, 2.0)));
    assert_eq!(list.slot_at(&layout, 0.0, 0.0, true).indicator, Rect::ZERO);
}

// MARK: Vectors

/// Equal within a small epsilon; a key the transliteration leaves out is null or false here.
fn same(actual: &Value, expected: &Value) -> bool {
    match (actual, expected) {
        (Value::Number(a), Value::Number(e)) => {
            (a.as_f64().unwrap() - e.as_f64().unwrap()).abs() < 1e-9
        }
        (Value::Array(a), Value::Array(e)) => {
            a.len() == e.len() && a.iter().zip(e).all(|(a, e)| same(a, e))
        }
        (Value::Object(a), Value::Object(e)) => {
            e.iter().all(|(key, e)| a.get(key).is_some_and(|a| same(a, e)))
                && a.iter().all(|(key, a)| {
                    e.contains_key(key) || matches!(a, Value::Null | Value::Bool(false))
                })
        }
        _ => actual == expected,
    }
}

#[test]
fn the_apps_vectors_hold() {
    let file: Value =
        serde_json::from_str(include_str!("../../../../schemas/tab-layout-rules/vectors.json"))
            .unwrap();
    let cases = file["cases"].as_array().unwrap();
    assert!(cases.len() > 300, "{} cases", cases.len());
    for case in cases {
        let op = case["op"].as_str().unwrap();
        assert!(wire::handles(op), "{op}");
        let request = serde_json::to_vec(&case["input"]).unwrap();
        let actual =
            wire::respond(op, &request).unwrap_or_else(|| panic!("{} refused", case["name"]));
        assert!(
            same(&actual, &case["expected"]),
            "{}: {actual} != {}",
            case["name"],
            case["expected"]
        );
    }
}

#[test]
fn unknown_ops_and_bad_requests_get_no_answer() {
    assert!(wire::respond("tab_layout_nope", b"{}").is_none());
    assert!(wire::respond("tab_layout_layout", b"{\"items\": 3}").is_none());
    assert!(!wire::handles("tab_groups_order"));
}
