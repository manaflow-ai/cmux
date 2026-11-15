use super::ids::{self, Resolved, WindowIds};
use super::outline::{self, Options};
use super::{diff, guards};
use crate::desktop::{Element, Point, Rect, UiTree};

fn el(id: &str, role: &str, name: &str) -> Element {
    Element { id: id.into(), role: role.into(), name: name.into(), ..Element::default() }
}

fn with(mut e: Element, children: Vec<Element>) -> Element {
    e.children = children;
    e
}

fn ident(mut e: Element, h: u64) -> Element {
    e.identity = Some(h);
    e
}

fn tree(root: Element) -> UiTree {
    UiTree { window_id: "w".into(), root, truncated: false }
}

/// The small id the tree gave the first node named `name`.
fn id_of(t: &UiTree, name: &str) -> u32 {
    fn go(e: &Element, name: &str) -> Option<u32> {
        if e.name == name {
            return e.id.parse().ok();
        }
        e.children.iter().find_map(|c| go(c, name))
    }
    go(&t.root, name).unwrap_or_else(|| panic!("no {name}"))
}

fn form(platform_gen: u32, rows: &[&str]) -> Element {
    let p = |i: usize| format!("{platform_gen}.{i}");
    let list = with(
        el(&p(3), "list", ""),
        rows.iter()
            .enumerate()
            .map(|(i, r)| with(el(&p(10 + i), "row", ""), vec![el(&p(50 + i), "text", r)]))
            .collect(),
    );
    with(
        el(&p(0), "window", "Form"),
        vec![el(&p(1), "text_field", "Name"), el(&p(2), "button", "Save"), list],
    )
}

#[test]
fn ids_are_small_and_stay_the_same_across_walks_with_new_platform_ids() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(form(1, &["Alpha", "Beta"]));
    w.assign(&mut a, false, &mut n);
    assert_eq!(a.root.id, "1");
    let (save, beta) = (id_of(&a, "Save"), id_of(&a, "Beta"));
    // The next walk: every platform id differs (a new generation), nothing moved.
    let mut b = tree(form(2, &["Alpha", "Beta"]));
    w.assign(&mut b, false, &mut n);
    assert_eq!(id_of(&b, "Save"), save);
    assert_eq!(id_of(&b, "Beta"), beta);
    assert_eq!(w.resolve(save), Resolved::Current(w.entry(save).unwrap().clone()));
    assert_eq!(w.entry(save).unwrap().platform_id, "2.2", "the latest walk's own id");
}

#[test]
fn a_row_inserted_above_keeps_each_rows_id_with_its_text() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(form(1, &["Alpha", "Beta"]));
    w.assign(&mut a, false, &mut n);
    let row_of = |t: &UiTree, text: &str| -> String {
        let list = &t.root.children[2];
        list.children.iter().find(|r| r.children[0].name == text).unwrap().id.clone()
    };
    let (alpha_row, beta_row) = (row_of(&a, "Alpha"), row_of(&a, "Beta"));
    let mut b = tree(form(2, &["New", "Alpha", "Beta"]));
    w.assign(&mut b, false, &mut n);
    // Positional matching would have handed Alpha's id to the new first row.
    assert_eq!(row_of(&b, "Alpha"), alpha_row);
    assert_eq!(row_of(&b, "Beta"), beta_row);
    let new_row: u32 = row_of(&b, "New").parse().unwrap();
    assert!(new_row > alpha_row.parse().unwrap(), "new elements get new ids");
}

#[test]
fn platform_identity_keeps_an_id_through_a_rename() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let root = |name: &str, gen_: u32| {
        with(
            el(&format!("{gen_}.0"), "window", "W"),
            vec![ident(el(&format!("{gen_}.1"), "button", name), 77)],
        )
    };
    let mut a = tree(root("Play", 1));
    w.assign(&mut a, false, &mut n);
    let play = id_of(&a, "Play");
    let mut b = tree(root("Pause", 2));
    w.assign(&mut b, false, &mut n);
    assert_eq!(id_of(&b, "Pause"), play);
}

#[test]
fn ids_are_never_reused_and_a_gone_id_says_what_it_was() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(form(1, &["Alpha"]));
    w.assign(&mut a, false, &mut n);
    let save = id_of(&a, "Save");
    let mut b = tree(with(el("2.0", "window", "Form"), vec![el("2.1", "text_field", "Name")]));
    w.assign(&mut b, false, &mut n);
    assert_eq!(w.resolve(save), Resolved::Gone("button \"Save\"".into()));
    let mut c = tree(form(3, &["Alpha"]));
    w.assign(&mut c, false, &mut n);
    assert_ne!(id_of(&c, "Save"), save, "a returning element is new");
    assert_eq!(w.resolve(9999), Resolved::Unknown);
}

#[test]
fn menu_bar_ids_are_carried_through_a_walk_without_menus() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let menus = |g: u32| {
        with(
            el(&format!("{g}.9"), "menu_bar", ""),
            vec![with(
                el(&format!("{g}.10"), "menu_bar_item", "File"),
                vec![with(
                    el(&format!("{g}.11"), "menu", ""),
                    vec![el(&format!("{g}.12"), "menu_item", "Save As…")],
                )],
            )],
        )
    };
    let mut a = tree(with(el("1.0", "window", "W"), vec![el("1.1", "button", "OK"), menus(1)]));
    w.assign(&mut a, true, &mut n);
    let save_as = id_of(&a, "Save As…");
    let mut b = tree(with(el("2.0", "window", "W"), vec![el("2.1", "button", "OK")]));
    w.assign(&mut b, false, &mut n);
    assert!(matches!(w.resolve(save_as), Resolved::Carried(_)), "kept, but its platform id is old");
    let mut c = tree(with(el("3.0", "window", "W"), vec![el("3.1", "button", "OK"), menus(3)]));
    w.assign(&mut c, true, &mut n);
    assert_eq!(id_of(&c, "Save As…"), save_as);
    assert!(matches!(w.resolve(save_as), Resolved::Current(e) if e.platform_id == "3.12"));
}

#[test]
fn ids_parse_plain_and_bracketed_numbers_only() {
    assert_eq!(ids::parse("17"), Some(17));
    assert_eq!(ids::parse(" [17] "), Some(17));
    assert_eq!(ids::parse("12.3"), None);
    assert_eq!(ids::parse(":1.42|/org/a11y/1"), None);
    assert_eq!(ids::parse("e1"), None);
    assert_eq!(ids::parse("0"), None);
}

fn sample() -> Element {
    let mut name = el("2", "text_field", "To");
    name.value = "ada@example.com".into();
    name.focused = true;
    let mut send = el("3", "button", "Send");
    send.disabled = true;
    let mut bcc = el("4", "checkbox", "Bcc");
    bcc.value = "0".into();
    let mut save = el("9", "menu_item", "Save As…");
    save.shortcut = "cmd+shift+s".into();
    with(
        el("1", "window", "Compose"),
        vec![
            with(el("5", "group", ""), vec![name, send]),
            with(el("6", "button", "Close"), vec![el("7", "text", "Close")]),
            bcc,
            with(
                el("10", "menu_bar", ""),
                vec![with(
                    el("11", "menu_bar_item", "File"),
                    vec![with(el("12", "menu", ""), vec![save])],
                )],
            ),
        ],
    )
}

#[test]
fn the_outline_folds_layout_and_repeated_labels_and_marks_focus() {
    let o = outline::build(&sample(), false, &Options::default());
    let text = outline::render(&o, &Options::default());
    assert_eq!(
        text,
        "[1] window \"Compose\"\n  [2] text field \"To\" = \"ada@example.com\" focused\n  [3] button \"Send\" disabled\n  [6] button \"Close\"\n  [4] checkbox \"Bcc\" = off\n  [10] menu bar (click a menu's id to list its items)\n    [11] menu bar item \"File\"\nFocus: [2] text field \"To\""
    );
    let all = outline::render(
        &outline::build(&sample(), false, &Options { menus: true, ..Options::default() }),
        &Options { menus: true, ..Options::default() },
    );
    assert!(all.contains("[9] menu item \"Save As…\" cmd+shift+s"), "{all}");
}

#[test]
fn the_outline_is_smaller_than_the_json() {
    let o = outline::build(&sample(), false, &Options::default());
    let text = outline::render(&o, &Options::default());
    let json = serde_json::to_string(&sample()).unwrap();
    assert!(text.len() * 2 < json.len(), "{} vs {}", text.len(), json.len());
}

#[test]
fn a_diff_shows_added_changed_removed_and_focus() {
    let before = sample();
    let mut after = sample();
    // The field lost focus and its text changed, Send is enabled, Close went,
    // and a sheet opened.
    after.children[0].children[0].value = "ada@example.org".into();
    after.children[0].children[0].focused = false;
    after.children[0].children[1].disabled = false;
    after.children.remove(1);
    let mut sheet = with(el("20", "sheet", "Send this message?"), vec![el("21", "button", "Send")]);
    sheet.children[0].focused = true;
    after.children.push(sheet);
    let opts = Options::default();
    let (a, b) = (outline::build(&before, false, &opts), outline::build(&after, false, &opts));
    let c = diff::compute(&a, &b, &opts);
    let text = diff::render(&a, &b, &c, &opts).unwrap();
    assert_eq!(
        text,
        "+ [20] sheet \"Send this message?\" (in [1])\n+   [21] button \"Send\" focused\n~ [2] text field \"To\" = \"ada@example.org\" (was: = \"ada@example.com\", focused)\n~ [3] button \"Send\" (was: disabled)\n- [6] button \"Close\"\nFocus now: [21] button \"Send\""
    );
    let same = diff::compute(&a, &a, &opts);
    assert!(same.is_empty() && diff::render(&a, &a, &same, &opts).is_none());
}

#[test]
fn a_long_value_change_is_shown_around_where_it_changed() {
    let long: String = "x".repeat(1000);
    let (o, n) = diff::around_change(&format!("{long} end"), &format!("{long} the end"));
    assert!(n.starts_with('\u{2026}') && n.ends_with(" the end"), "{n}");
    assert!(o.ends_with(" end") && o.chars().count() < 60, "{o}");
}

#[test]
fn ranges_compress_ids() {
    assert_eq!(diff::ranges(&mut [9, 4, 5, 6, 12, 7]), "4-7, 9, 12");
}

fn framed(mut e: Element, x: f64, y: f64, w: f64, h: f64) -> Element {
    e.frame = Some(Rect { x, y, width: w, height: h });
    e
}

#[test]
fn typing_is_refused_when_focus_is_on_a_button_or_nowhere_with_fields_around() {
    let mut field = el("2", "text_field", "Name");
    let mut button = el("3", "button", "OK");
    button.focused = true;
    let root = with(el("1", "window", "W"), vec![field.clone(), button.clone()]);
    let r = guards::typing_without_target("7", &root, false).unwrap();
    assert_eq!(r.code, "focus_not_on_text");
    assert!(
        r.message.contains("[3] button \"OK\"") && r.message.contains("[2] text field \"Name\""),
        "{}",
        r.message
    );
    button.focused = false;
    let root = with(el("1", "window", "W"), vec![field.clone(), button.clone()]);
    // No reported focus is let through (a background window often reports none).
    assert!(guards::typing_without_target("7", &root, false).is_none());
    // A window with no text fields (a canvas, a terminal) is let through.
    let canvas = with(el("1", "window", "W"), vec![el("2", "canvas", "")]);
    assert!(guards::typing_without_target("7", &canvas, false).is_none());
    field.focused = true;
    let root = with(el("1", "window", "W"), vec![field, button]);
    assert!(guards::typing_without_target("7", &root, false).is_none());
    // A focused list takes type-select.
    let mut list = el("2", "list", "");
    list.focused = true;
    let root = with(el("1", "window", "W"), vec![list, el("3", "search_field", "Search")]);
    assert!(guards::typing_without_target("7", &root, false).is_none());
}

#[test]
fn pixel_clicks_on_a_bare_title_bar_or_outside_are_refused() {
    let frame = Rect { x: 100.0, y: 100.0, width: 400.0, height: 300.0 };
    let mut close = framed(el("2", "close_button", ""), 108.0, 104.0, 14.0, 14.0);
    close.actions = vec!["press".into()];
    let root = framed(
        with(
            el("1", "window", "W"),
            vec![close, framed(el("3", "text_field", "Name"), 120.0, 150.0, 200.0, 22.0)],
        ),
        100.0,
        100.0,
        400.0,
        300.0,
    );
    let at = |x, y| guards::pixel_click("5", &frame, &root, false, Point { x, y });
    assert_eq!(at(300.0, 110.0).unwrap().code, "title_bar");
    assert!(at(114.0, 110.0).is_none(), "the close button is a control");
    assert!(at(200.0, 160.0).is_none());
    assert_eq!(at(50.0, 160.0).unwrap().code, "point_outside_window");
    assert!(
        guards::pixel_click("5", &frame, &root, true, Point { x: 300.0, y: 110.0 }).is_none(),
        "truncated: can't tell"
    );
}

#[test]
fn an_element_scrolled_out_of_view_is_refused_unless_pressable() {
    let row = framed(el("9", "cell", "Row 80"), 10.0, 2000.0, 100.0, 20.0);
    let clips = [
        (0, Rect { x: 0.0, y: 0.0, width: 500.0, height: 500.0 }),
        (4, Rect { x: 0.0, y: 50.0, width: 500.0, height: 400.0 }),
    ];
    let r = guards::offscreen(&row, &clips, false).unwrap();
    assert_eq!(r.code, "element_offscreen");
    assert!(r.message.contains("scroll [4]"), "{}", r.message);
    assert!(
        guards::offscreen(&row, &clips, true).unwrap().message.contains("scroll_to_visible on [9]")
    );
    let mut pressable = row;
    pressable.actions = vec!["press".into()];
    assert!(guards::offscreen(&pressable, &clips, false).is_none());
    let visible = framed(el("9", "cell", "Row 3"), 10.0, 100.0, 100.0, 20.0);
    assert!(guards::offscreen(&visible, &clips, false).is_none());
}

#[test]
fn disabled_and_non_text_targets_are_refused() {
    let mut b = el("3", "button", "Send");
    assert!(guards::disabled(&b).is_none());
    b.disabled = true;
    assert_eq!(guards::disabled(&b).unwrap().code, "element_disabled");
    assert_eq!(guards::typing_into(&b).unwrap().code, "not_a_text_field");
    assert!(guards::typing_into(&el("2", "text_area", "")).is_none());
}

#[test]
fn an_unnamed_element_inserted_above_never_takes_an_id_that_is_still_there() {
    // Two unnamed fields with platform identities; a third is inserted first.
    let field = |id: &str, h: u64| ident(el(id, "text_field", ""), h);
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(with(el("1.0", "window", "W"), vec![field("1.1", 11), field("1.2", 12)]));
    w.assign(&mut a, false, &mut n);
    let (x, y) = (a.root.children[0].id.clone(), a.root.children[1].id.clone());
    let mut b = tree(with(
        el("2.0", "window", "W"),
        vec![field("2.9", 99), field("2.1", 11), field("2.2", 12)],
    ));
    w.assign(&mut b, false, &mut n);
    assert_eq!(b.root.children[1].id, x, "X keeps its id");
    assert_eq!(b.root.children[2].id, y, "Y keeps its id");
    assert_ne!(b.root.children[0].id, x);
    assert_ne!(b.root.children[0].id, y);
}

#[test]
fn a_recycled_row_with_other_text_is_a_new_row() {
    let row = |id: &str, text: &str| {
        ident(with(el(id, "row", ""), vec![el(&format!("{id}t"), "text", text)]), 7)
    };
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(with(el("1.0", "window", "W"), vec![row("1.1", "Alpha")]));
    w.assign(&mut a, false, &mut n);
    let alpha = a.root.children[0].id.clone();
    // The same AppKit view now shows another row (same hash, other text).
    let mut b = tree(with(el("2.0", "window", "W"), vec![row("2.1", "Omega")]));
    w.assign(&mut b, false, &mut n);
    assert_ne!(b.root.children[0].id, alpha);
}

#[test]
fn ids_are_unique_across_windows_and_say_whose_they_are() {
    let mut r = ids::Registry::default();
    let mut a = tree(form(1, &["Alpha"]));
    let mut b = tree(form(1, &["Alpha"]));
    r.assign("w1", &mut a, false);
    r.assign("w2", &mut b, false);
    let save_a = id_of(&a, "Save");
    assert_ne!(save_a, id_of(&b, "Save"));
    assert_eq!(r.window("w2").unwrap().resolve(save_a), Resolved::Unknown);
    assert_eq!(r.owner(save_a), Some("w1"));
}

#[test]
fn a_walk_cut_at_the_limit_keeps_the_ids_it_did_not_reach() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(form(1, &["Alpha", "Beta"]));
    w.assign(&mut a, false, &mut n);
    let beta = id_of(&a, "Beta");
    let mut cut = tree(with(el("2.0", "window", "Form"), vec![el("2.1", "text_field", "Name")]));
    cut.truncated = true;
    w.assign(&mut cut, false, &mut n);
    assert!(matches!(w.resolve(beta), Resolved::Carried(_)), "not buried");
}

#[test]
fn a_selection_change_is_a_change() {
    let mut before = sample();
    before.children.push(el("30", "row", "Inbox"));
    let mut after = before.clone();
    after.children[4].selected = true;
    let opts = Options::default();
    let (a, b) = (outline::build(&before, false, &opts), outline::build(&after, false, &opts));
    let text = diff::render(&a, &b, &diff::compute(&a, &b, &opts), &opts).unwrap();
    assert_eq!(text, "~ [30] row \"Inbox\" selected (was: not selected)");
}

#[test]
fn elements_read_anew_each_walk_keep_their_ids_by_place_and_label() {
    // SwiftUI gives every read new element references: identities never repeat.
    let side = |g: u32| {
        with(
            el(&format!("{g}.0"), "window", "Settings"),
            vec![ident(el(&format!("{g}.1"), "text", "Sound"), u64::from(g) * 100 + 1)],
        )
    };
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(side(1));
    w.assign(&mut a, false, &mut n);
    let mut b = tree(side(2));
    w.assign(&mut b, false, &mut n);
    assert_eq!(a.root.children[0].id, b.root.children[0].id);
}

#[test]
fn a_container_folded_or_shown_only_by_its_focus_is_no_add_or_remove() {
    let mut group = with(el("13", "group", ""), vec![el("14", "button", "7")]);
    group.focused = true;
    let before = with(el("10", "window", "Calculator"), vec![group.clone()]);
    group.focused = false;
    let after = with(el("10", "window", "Calculator"), vec![group]);
    let opts = Options::default();
    let (a, b) = (outline::build(&before, false, &opts), outline::build(&after, false, &opts));
    let text = diff::render(&a, &b, &diff::compute(&a, &b, &opts), &opts).unwrap();
    assert_eq!(text, "~ [13] group (was: focused)\nFocus now: no element of this window");
}

#[test]
fn an_insertion_into_a_value_cut_at_the_limit_shows_what_was_typed() {
    let doc: String = (1..60).map(|i| format!("line {i} the quick brown fox\n")).collect();
    let cap = |s: String| -> String { s.chars().take(2000).collect() };
    let old = cap(format!("OBS{doc}"));
    let new = cap(format!("OBSHELLO{doc}"));
    let (o, n) = diff::around_change(&old, &new);
    assert!(n.starts_with("OBSHELLOline 1 the quick"), "{n}");
    assert!(o.starts_with("OBSline 1 the quick"), "{o}");
    assert!(n.chars().count() < 60, "{n}");
}

#[test]
fn quotes_drop_direction_marks() {
    assert_eq!(outline::quote("\u{200e}7"), "\"7\"");
}

#[test]
fn menu_shortcuts_read_as_press_key_combos() {
    use outline::menu_shortcut as s;
    assert_eq!(s("S", 0), "cmd+s");
    assert_eq!(s("S", 1), "cmd+shift+s");
    assert_eq!(s("T", 2 | 1), "cmd+alt+shift+t");
    assert_eq!(s("F", 4 | 8), "ctrl+f");
    assert_eq!(s("+", 0), "cmd+plus");
    assert_eq!(s("\u{F704}", 8), "F1");
    assert_eq!(s("\u{F700}", 0), "cmd+Up");
    assert_eq!(s("", 0), "");
}

#[test]
fn an_unnamed_field_put_where_one_was_removed_is_new() {
    let field = |id: &str, h: u64| ident(el(id, "text_field", ""), h);
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(with(el("1.0", "window", "W"), vec![field("1.1", 11)]));
    w.assign(&mut a, false, &mut n);
    let old = a.root.children[0].id.clone();
    let mut b = tree(with(el("2.0", "window", "W"), vec![field("2.1", 99)]));
    w.assign(&mut b, false, &mut n);
    assert_ne!(b.root.children[0].id, old);
}

#[test]
fn a_recycled_row_whose_time_ticks_keeps_its_id() {
    let row = |id: &str, text: &str| {
        ident(with(el(id, "row", ""), vec![el(&format!("{id}t"), "text", text)]), 7)
    };
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(with(el("1.0", "window", "W"), vec![row("1.1", "Ada, 2 min ago")]));
    w.assign(&mut a, false, &mut n);
    let mut b = tree(with(el("2.0", "window", "W"), vec![row("2.1", "Ada, 3 min ago")]));
    w.assign(&mut b, false, &mut n);
    assert_eq!(a.root.children[0].id, b.root.children[0].id);
}
