use std::collections::HashSet;

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
fn a_renamed_element_with_the_same_identity_gets_a_new_id() {
    // Identity alone proves nothing (a freed reference is reused): a button
    // whose label changed is new, and its old id is reported gone.
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let root = |name: &str, gen_: u32| {
        with(
            el(&format!("{gen_}.0"), "window", "W"),
            vec![ident(el(&format!("{gen_}.1"), "button", name), 77)],
        )
    };
    let mut a = tree(root("Cancel", 1));
    w.assign(&mut a, false, &mut n);
    let cancel = id_of(&a, "Cancel");
    let mut b = tree(root("Delete", 2));
    w.assign(&mut b, false, &mut n);
    assert_ne!(id_of(&b, "Delete"), cancel);
    assert_eq!(w.resolve(cancel), Resolved::Gone("button \"Cancel\"".into()));
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
fn typing_is_refused_when_focus_is_on_a_native_checkbox_and_names_the_fields() {
    let mut field = el("2", "text_field", "Name");
    let mut boxed = el("3", "checkbox", "OK");
    boxed.focused = true;
    let root = with(el("1", "window", "W"), vec![field.clone(), boxed.clone()]);
    let r = guards::typing_without_target("7", &root, false).unwrap();
    assert_eq!(r.code, "focus_not_on_text");
    assert!(
        r.message.contains("[3] checkbox \"OK\"") && r.message.contains("[2] text field \"Name\""),
        "{}",
        r.message
    );
    boxed.focused = false;
    // No reported focus is let through (a background window often reports none).
    let root = with(el("1", "window", "W"), vec![field.clone(), boxed.clone()]);
    assert!(guards::typing_without_target("7", &root, false).is_none());
    let canvas = with(el("1", "window", "W"), vec![el("2", "canvas", "")]);
    assert!(guards::typing_without_target("7", &canvas, false).is_none());
    field.focused = true;
    let root = with(el("1", "window", "W"), vec![field, boxed]);
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
    let at = |x, y| guards::pixel_click("5", &frame, &root, false, Point { x, y }, true);
    assert_eq!(at(300.0, 110.0).unwrap().code, "title_bar");
    assert!(at(114.0, 110.0).is_none(), "the close button is a control");
    assert!(at(200.0, 160.0).is_none());
    assert_eq!(at(50.0, 160.0).unwrap().code, "point_outside_window");
    assert!(
        guards::pixel_click("5", &frame, &root, true, Point { x: 300.0, y: 110.0 }, true).is_none(),
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
    // Z is new; X and Y either keep their own ids or get new ones (their
    // place among unnamed fields changed), never another one's.
    let (z, x2, y2) = (&b.root.children[0].id, &b.root.children[1].id, &b.root.children[2].id);
    assert!(z != &x && z != &y, "Z took {z}");
    assert!(x2 == &x || x2 != &y, "X took Y's id");
    assert!(y2 == &y || y2 != &x, "Y took X's id");
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
    r.assign("w1", &mut a, false, None);
    r.assign("w2", &mut b, false, None);
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

fn row(id: &str, text: &str, h: u64) -> Element {
    ident(with(el(id, "row", ""), vec![el(&format!("{id}t"), "text", text)]), h)
}

fn rows(g: u32, texts: &[(&str, u64)]) -> UiTree {
    tree(with(
        el(&format!("{g}.0"), "window", "W"),
        vec![with(
            ident(el(&format!("{g}.1"), "table", ""), 1000),
            texts.iter().enumerate().map(|(i, (t, h))| row(&format!("{g}.r{i}"), t, *h)).collect(),
        )],
    ))
}

#[test]
fn a_recycled_row_keeps_its_id_only_through_a_time_or_count_change() {
    let cases = [
        ("Ada, 2 min ago", "Ada, 3 min ago", true),
        ("Inbox (4)", "Inbox (5)", true),
        ("Lunch 12:05 PM", "Lunch 12:06 PM", true),
        ("IMG_0001", "IMG_0002", false),
        ("#1234", "#5678", false),
        ("12", "13", false),
        ("Ada", "Bob", false),
    ];
    for (before, after, keeps) in cases {
        let mut w = WindowIds::default();
        let mut n = 0u32;
        let mut a = rows(1, &[(before, 7)]);
        w.assign(&mut a, false, &mut n);
        let mut b = rows(2, &[(after, 7)]);
        w.assign(&mut b, false, &mut n);
        let (x, y) = (&a.root.children[0].children[0].id, &b.root.children[0].children[0].id);
        assert_eq!(x == y, keeps, "{before:?} -> {after:?}");
    }
}

#[test]
fn a_time_drift_keeps_an_id_only_at_the_same_place() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = rows(1, &[("Ada, 2 min ago", 7), ("Bob, 9 min ago", 8)]);
    w.assign(&mut a, false, &mut n);
    // The view of Ada's row is reused one place down, ticking: not the same row.
    let mut b = rows(2, &[("Cy, 1 min ago", 9), ("Ada, 3 min ago", 7)]);
    w.assign(&mut b, false, &mut n);
    assert_ne!(b.root.children[0].children[1].id, a.root.children[0].children[0].id);
}

#[test]
fn a_rebuilt_menu_item_or_sheet_button_at_a_reused_address_is_new() {
    // Open Recent rebuilt: the first item's reference now names another file.
    let menu = |g: u32, title: &str| {
        tree(with(
            el(&format!("{g}.0"), "window", "W"),
            vec![with(
                ident(el(&format!("{g}.1"), "menu", "Open Recent"), 5),
                vec![ident(el(&format!("{g}.2"), "menu_item", title), 6)],
            )],
        ))
    };
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = menu(1, "a.txt");
    w.assign(&mut a, false, &mut n);
    let mut b = menu(2, "b.txt");
    w.assign(&mut b, false, &mut n);
    assert_ne!(id_of(&a, "a.txt"), id_of(&b, "b.txt"));
    // A new sheet whose button lands at a dead button's address.
    let sheet = |g: u32, button: &str| {
        tree(with(
            el(&format!("{g}.0"), "window", "W"),
            vec![with(
                ident(el(&format!("{g}.1"), "sheet", ""), 30),
                vec![ident(el(&format!("{g}.2"), "button", button), 31)],
            )],
        ))
    };
    let mut c = sheet(3, "Don't Save");
    w.assign(&mut c, false, &mut n);
    let mut d = sheet(4, "Delete");
    w.assign(&mut d, false, &mut n);
    assert_ne!(id_of(&c, "Don't Save"), id_of(&d, "Delete"));
}

#[test]
fn an_identifier_needs_the_label_when_it_is_not_unique_or_the_role_is_recycled() {
    let with_id = |e: Element, id: &str| Element { identifier: id.into(), ..e };
    // Two buttons share an identifier; they swap places.
    let two = |g: u32, first: &str, second: &str| {
        tree(with(
            el(&format!("{g}.0"), "window", "W"),
            vec![
                with_id(el(&format!("{g}.1"), "button", first), "action"),
                with_id(el(&format!("{g}.2"), "button", second), "action"),
            ],
        ))
    };
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = two(1, "Keep", "Erase");
    w.assign(&mut a, false, &mut n);
    let mut b = two(2, "Erase", "Keep");
    w.assign(&mut b, false, &mut n);
    assert_eq!(id_of(&a, "Keep"), id_of(&b, "Keep"));
    assert_eq!(id_of(&a, "Erase"), id_of(&b, "Erase"));
    // A recycled row with an identifier and new text is a new row.
    let one = |g: u32, text: &str| {
        tree(with(
            el(&format!("{g}.0"), "window", "W"),
            vec![with_id(row(&format!("{g}.1"), text, u64::from(g)), "cell-view")],
        ))
    };
    let mut c = one(1, "IMG_0001");
    w.assign(&mut c, false, &mut n);
    let mut d = one(2, "IMG_0002");
    w.assign(&mut d, false, &mut n);
    assert_ne!(c.root.children[0].id, d.root.children[0].id);
}

#[test]
fn without_identity_an_unnamed_element_is_never_matched_by_place_alone() {
    // Windows before RuntimeId, SwiftUI: no identity repeats.
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(with(el("1.0", "window", "W"), vec![el("1.1", "text_field", "")]));
    w.assign(&mut a, false, &mut n);
    let mut b = tree(with(el("2.0", "window", "W"), vec![el("2.1", "text_field", "")]));
    w.assign(&mut b, false, &mut n);
    assert_ne!(a.root.children[0].id, b.root.children[0].id);
    // An unnamed container holding the same labeled elements keeps its id,
    // so its children keep theirs.
    let pane = |g: u32| {
        tree(with(
            el(&format!("{g}.0"), "window", "W"),
            vec![with(
                el(&format!("{g}.1"), "group", ""),
                vec![el(&format!("{g}.2"), "button", "OK"), el(&format!("{g}.3"), "text", "Sure?")],
            )],
        ))
    };
    let mut c = pane(3);
    w.assign(&mut c, false, &mut n);
    let mut d = pane(4);
    w.assign(&mut d, false, &mut n);
    assert_eq!(c.root.children[0].id, d.root.children[0].id);
    assert_eq!(id_of(&c, "OK"), id_of(&d, "OK"));
}

#[test]
fn a_running_registry_starts_its_ids_at_a_random_thousand() {
    // Without a state directory, ids start at a per-process epoch.
    let mut r = ids::Registry::new(None);
    let mut t = tree(el("1.0", "window", "W"));
    r.assign("w", &mut t, false, None);
    let first: u32 = t.root.id.parse().unwrap();
    assert!(first > 100_000, "{first}");
}

#[test]
fn ids_a_cut_walk_did_not_reach_are_gone_after_a_few_walks() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(form(1, &["Alpha"]));
    w.assign(&mut a, false, &mut n);
    let save = id_of(&a, "Save");
    for g in 2..(ids::CARRY_WALKS as u32 + 4) {
        let mut cut = tree(with(el(&format!("{g}.0"), "window", "Form"), vec![]));
        cut.truncated = true;
        w.assign(&mut cut, false, &mut n);
    }
    assert!(matches!(w.resolve(save), Resolved::Gone(_)), "{:?}", w.resolve(save));
}

#[test]
fn time_drift_reads_times_and_counts_only() {
    assert!(ids::time_drift("2 min ago", "10 min ago"));
    assert!(ids::time_drift("Sent 3h", "Sent 4h"));
    assert!(!ids::time_drift("Report 2024", "Report 2025"));
    assert!(!ids::time_drift("v1.2", "v1.3"));
}

#[test]
fn typing_with_focus_on_a_button_or_in_web_content_goes_through() {
    let field = el("2", "text_field", "Name");
    let mut button = el("3", "button", "Send");
    button.focused = true;
    let root = with(el("1", "window", "W"), vec![field.clone(), button]);
    assert!(guards::typing_without_target("7", &root, false).is_none());
    let mut boxed = el("3", "checkbox", "Remember");
    boxed.focused = true;
    let root = with(el("1", "window", "W"), vec![field.clone(), boxed.clone()]);
    assert_eq!(guards::typing_without_target("7", &root, false).unwrap().code, "focus_not_on_text");
    let web = with(el("4", "web_area", "Page"), vec![boxed]);
    let root = with(el("1", "window", "W"), vec![field, web]);
    assert!(guards::typing_without_target("7", &root, false).is_none());
}

#[test]
fn the_title_bar_guard_needs_a_real_title_bar() {
    let frame = Rect { x: 100.0, y: 100.0, width: 400.0, height: 300.0 };
    let body = framed(el("3", "text_field", "Name"), 120.0, 150.0, 200.0, 22.0);
    // No close, minimize or zoom button in the top strip: full screen, hidden
    // or custom-drawn title bar.
    let bare = framed(with(el("1", "window", "W"), vec![body.clone()]), 100.0, 100.0, 400.0, 300.0);
    assert!(
        guards::pixel_click("5", &frame, &bare, false, Point { x: 300.0, y: 110.0 }, true)
            .is_none()
    );
    let mut close = framed(el("2", "close_button", ""), 108.0, 104.0, 14.0, 14.0);
    close.actions = vec!["press".into()];
    let real = framed(with(el("1", "window", "W"), vec![close, body]), 100.0, 100.0, 400.0, 300.0);
    assert_eq!(
        guards::pixel_click("5", &frame, &real, false, Point { x: 300.0, y: 110.0 }, true)
            .unwrap()
            .code,
        "title_bar"
    );
    // A desktop that draws no title bars (Wayland) never refuses.
    assert!(
        guards::pixel_click("5", &frame, &real, false, Point { x: 300.0, y: 110.0 }, false)
            .is_none()
    );
}

#[test]
fn an_element_read_anew_with_a_new_id_is_said_once_not_as_removed_and_added() {
    let opts = Options::default();
    let before = with(el("1", "window", "W"), vec![el("8", "close_button", "")]);
    let after = with(el("1", "window", "W"), vec![el("9", "close_button", "")]);
    let (a, b) = (outline::build(&before, false, &opts), outline::build(&after, false, &opts));
    let c = diff::compute(&a, &b, &opts);
    assert_eq!(diff::render(&a, &b, &c, &opts).unwrap(), "~ [9] close button (new id; was [8])");
}

/// The ids two walks give the elements named `name` (first match each).
fn twice(a: Element, b: Element) -> (UiTree, UiTree) {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let (mut x, mut y) = (tree(a), tree(b));
    w.assign(&mut x, false, &mut n);
    w.assign(&mut y, false, &mut n);
    (x, y)
}

#[test]
fn a_recycled_rows_delete_button_never_keeps_its_id_under_another_file() {
    // AppKit reuses the row view (same identity) and its button for another
    // file: the "Delete" of a.txt must not become the "Delete" of b.txt.
    let row = |g: u32, file: &str| {
        with(
            el(&format!("{g}.0"), "window", "Files"),
            vec![with(
                ident(el(&format!("{g}.1"), "table", ""), 1),
                vec![with(
                    ident(el(&format!("{g}.2"), "row", ""), 7),
                    vec![
                        el(&format!("{g}.3"), "text", file),
                        ident(el(&format!("{g}.4"), "button", "Delete"), 50),
                    ],
                )],
            )],
        )
    };
    let (a, b) = twice(row(1, "a.txt"), row(2, "b.txt"));
    assert_ne!(id_of(&a, "Delete"), id_of(&b, "Delete"));
}

#[test]
fn a_feed_card_rerendered_with_another_post_is_new() {
    // Unlabeled cards sharing "Like" and "Share": only the post tells them
    // apart, so a card now showing another post is another card.
    let feed = |g: u32, posts: &[&str]| {
        with(
            el(&format!("{g}.0"), "window", "Feed"),
            posts
                .iter()
                .enumerate()
                .map(|(i, p)| {
                    with(
                        el(&format!("{g}.c{i}"), "group", ""),
                        vec![
                            el(&format!("{g}.t{i}"), "text", p),
                            el(&format!("{g}.l{i}"), "button", "Like"),
                            el(&format!("{g}.s{i}"), "button", "Share"),
                        ],
                    )
                })
                .collect(),
        )
    };
    let (a, b) = twice(feed(1, &["Post A", "Post B"]), feed(2, &["Post C", "Post B"]));
    assert_ne!(a.root.children[0].id, b.root.children[0].id, "card 1 shows another post");
    assert_ne!(
        a.root.children[0].children[1].id, b.root.children[0].children[1].id,
        "its Like too"
    );
    assert_eq!(a.root.children[1].id, b.root.children[1].id, "card 2 is the same card");
}

#[test]
fn repeated_identical_siblings_lose_their_ids_when_one_is_removed() {
    let list = |g: u32, k: usize| {
        with(
            el(&format!("{g}.0"), "window", "W"),
            (0..k).map(|i| el(&format!("{g}.{i}"), "button", "Remove")).collect(),
        )
    };
    let (a, b) = twice(list(1, 3), list(2, 2));
    let old: Vec<&String> = a.root.children.iter().map(|c| &c.id).collect();
    for c in &b.root.children {
        assert!(
            !old.contains(&&c.id),
            "{} kept an id though which one was removed is unknown",
            c.id
        );
    }
}

#[test]
fn a_renamed_button_with_a_fixed_identifier_and_an_insert_is_new() {
    let with_id = |e: Element, id: &str| Element { identifier: id.into(), ..e };
    let a = with(el("1.0", "window", "W"), vec![with_id(el("1.1", "button", "Save"), "primary")]);
    let b = with(
        el("2.0", "window", "W"),
        vec![
            el("2.9", "text", "Unsaved changes"),
            with_id(el("2.1", "button", "Delete"), "primary"),
        ],
    );
    let (x, y) = twice(a, b);
    assert_ne!(id_of(&x, "Save"), id_of(&y, "Delete"));
}

#[test]
fn ids_given_out_before_a_restart_are_never_given_out_again() {
    let dir = std::env::temp_dir().join(format!(
        "cu-ids-{}-{:?}",
        std::process::id(),
        std::thread::current().id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    fn all(e: &Element, out: &mut Vec<u32>) {
        out.push(e.id.parse().unwrap());
        e.children.iter().for_each(|c| all(c, out));
    }
    // Twenty restarts of the worker, each walking the window once: no id is
    // ever given out twice (a model may still hold one from before).
    let mut seen: HashSet<u32> = HashSet::new();
    for g in 1..=20u32 {
        let mut r = ids::Registry::new(Some(&dir));
        let mut t = tree(form(g, &["Alpha", "Beta"]));
        r.assign("w", &mut t, false, None);
        let mut ids = Vec::new();
        all(&t.root, &mut ids);
        for id in ids {
            assert!(seen.insert(id), "id {id} given out again after restart {g}");
        }
    }
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn a_window_id_reused_by_another_process_starts_its_ids_over() {
    let mut r = ids::Registry::default();
    let mut a = tree(form(1, &["Alpha"]));
    r.assign("w", &mut a, false, Some(10));
    let save = id_of(&a, "Save");
    let mut b = tree(form(2, &["Alpha"]));
    r.assign("w", &mut b, false, Some(11));
    assert_ne!(id_of(&b, "Save"), save);
    assert_eq!(r.window("w").unwrap().resolve(save), Resolved::Unknown);
}

#[test]
fn a_fingerprint_names_what_differs() {
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(form(1, &["Alpha"]));
    w.assign(&mut a, false, &mut n);
    let save = id_of(&a, "Save");
    let fp = w.fingerprint(save).unwrap();
    assert_eq!(fp.difference(&fp), None);
    let mut other = fp.clone();
    other.label = "Delete".into();
    assert!(fp.difference(&other).unwrap().contains("\"Delete\""));
}

/// A Notes-like list: a window, a scroll area 100 high at y 50, a focused
/// table whose rows are 20 high from `top` (every cell focused, as AppKit
/// reports a focused table's cells), each row a cell with the row's text,
/// and a scroll bar.
fn long_list(top: f64, rows: usize) -> Element {
    let mut table = framed(el("3", "table", "Notes"), 0.0, top, 200.0, 20.0 * rows as f64);
    table.focused = true;
    table.children = (0..rows)
        .map(|i| {
            let y = top + 20.0 * i as f64;
            let mut cell = framed(el(&format!("{}", 200 + i), "cell", ""), 0.0, y, 200.0, 20.0);
            cell.focused = true;
            cell.actions = vec!["show_menu".into(), "pin".into()];
            cell.children = vec![framed(
                el(&format!("{}", 400 + i), "text", &format!("Note {i}")),
                0.0,
                y,
                100.0,
                20.0,
            )];
            let mut row = framed(el(&format!("{}", 100 + i), "table_row", ""), 0.0, y, 200.0, 20.0);
            row.actions = vec!["pin".into()];
            row.children = vec![cell];
            row
        })
        .collect();
    let bar = with(
        el("4", "scroll_bar", ""),
        vec![el("5", "value_indicator", ""), el("6", "increment_arrow", ""), el("7", "button", "")],
    );
    let mut area = framed(el("2", "scroll_area", ""), 0.0, 50.0, 200.0, 100.0);
    area.actions =
        vec!["scroll_up_by_page".into(), "scroll_down_by_page".into(), "show_menu".into()];
    area.children = vec![table, bar];
    let mut file = el("11", "menu_bar_item", "File");
    file.actions = vec!["cancel".into(), "pick".into()];
    let mut bar = with(el("10", "menu_bar", ""), vec![file]);
    bar.actions = vec!["cancel".into()];
    with(framed(el("1", "window", "Notes"), 0.0, 0.0, 200.0, 200.0), vec![area, bar])
}

#[test]
fn rows_scrolled_out_of_view_are_counted_on_their_container_not_listed() {
    let o = outline::build(&long_list(50.0, 40), false, &Options::default());
    let text = outline::render(&o, &Options::default());
    // Five rows fit in the 100-high area; the other 35 are a count.
    assert_eq!(
        text,
        "[1] window \"Notes\"\n  [2] scroll area\n    [3] table \"Notes\" focused (out of view: 35 below)\n      [100] table row actions: pin\n        [400] text \"Note 0\"\n      [101] table row actions: pin\n        [401] text \"Note 1\"\n      [102] table row actions: pin\n        [402] text \"Note 2\"\n      [103] table row actions: pin\n        [403] text \"Note 3\"\n      [104] table row actions: pin\n        [404] text \"Note 4\"\n  [10] menu bar (click a menu's id to list its items)\n    [11] menu bar item \"File\"\nFocus: [3] table \"Notes\""
    );
    assert!(o.clipped.contains(&139) && o.clipped.contains(&439), "the hidden rows are known");
    // full: true lists them.
    let all = Options { offscreen: true, ..Options::default() };
    let text = outline::render(&outline::build(&long_list(50.0, 40), false, &all), &all);
    assert!(text.contains("[139] table row") && !text.contains("out of view"), "{text}");
}

#[test]
fn a_scroll_shows_the_rows_that_came_into_view_and_removes_nothing() {
    let opts = Options::default();
    let before = outline::build(&long_list(50.0, 40), false, &opts);
    // Scrolled by three rows: rows 0-2 above, 3-7 in view.
    let after = outline::build(&long_list(-10.0, 40), false, &opts);
    let c = diff::compute(&before, &after, &opts);
    assert!(c.removed.is_empty(), "scrolled away is not removed: {c:?}");
    let text = diff::render(&before, &after, &c, &opts).unwrap();
    assert!(text.contains("+ [105] table row actions: pin (in [3])"), "{text}");
    assert!(
        text.contains("~ [3] table \"Notes\" focused (out of view: 3 above, 32 below) (was: out of view: 35 below)"),
        "{text}"
    );
    assert!(!text.contains("- ["), "{text}");
    // The same scroll position again: nothing to say.
    let again = outline::build(&long_list(-10.0, 40), false, &opts);
    assert!(diff::compute(&after, &again, &opts).is_empty());
}

#[test]
fn only_the_element_with_keyboard_focus_is_marked_focused() {
    // AppKit marks every cell of a focused table focused: the focus is the
    // table, not the last cell.
    let o = outline::build(&long_list(50.0, 3), false, &Options::default());
    let text = outline::render(&o, &Options::default());
    assert_eq!(text.matches(" focused").count(), 1, "{text}");
    assert!(text.ends_with("Focus: [3] table \"Notes\""), "{text}");
    // A cell of an unfocused table that alone has focus is the focus.
    let mut root = long_list(50.0, 3);
    root.children[0].children[0].focused = false;
    for row in &mut root.children[0].children[0].children {
        row.children[0].focused = false;
    }
    root.children[0].children[0].children[1].children[0].focused = true;
    let text =
        outline::render(&outline::build(&root, false, &Options::default()), &Options::default());
    assert!(text.ends_with("Focus: [201] cell"), "{text}");
    assert!(text.contains("[201] cell focused actions: pin"), "the focused cell is shown: {text}");
}

#[test]
fn what_says_nothing_to_act_on_is_left_out() {
    let text = outline::render(
        &outline::build(&long_list(50.0, 2), false, &Options::default()),
        &Options::default(),
    );
    // A cell that only repeats its row, a scroll bar's parts, the context
    // menu and page scrolls every element has, a menu's cancel and pick.
    assert!(!text.contains("cell"), "{text}");
    assert!(!text.contains("scroll bar") && !text.contains("arrow"), "{text}");
    assert!(!text.contains("show_menu") && !text.contains("by_page"), "{text}");
    assert!(!text.contains("cancel") && !text.contains("pick"), "{text}");
    // An empty row (a separator) and a tab's favicon go; a tab says on/off.
    let mut tab = el("21", "tab_button", "CUEV Page");
    tab.value = "1".into();
    tab.children = vec![el("22", "image", "safari")];
    let mut sep = el("23", "outline_row", "");
    sep.children = vec![el("24", "cell", "")];
    let root = with(
        el("20", "window", "W"),
        vec![tab, sep, with(el("25", "outline_row", ""), vec![el("26", "button", "Wi-Fi")])],
    );
    let text =
        outline::render(&outline::build(&root, false, &Options::default()), &Options::default());
    assert_eq!(
        text,
        "[20] window \"W\"\n  [21] tab button \"CUEV Page\" = on\n  [25] outline row\n    [26] button \"Wi-Fi\"\nFocus: no element of this window has keyboard focus"
    );
}

#[test]
fn a_table_column_made_anew_each_read_keeps_its_id_by_its_identifier() {
    // Finder and Notes give their table columns new elements every read (no
    // identity): the column's identifier names it.
    let cols = |g: u32| {
        with(
            el(&format!("{g}.0"), "window", "Finder"),
            vec![with(
                el(&format!("{g}.1"), "table", "files"),
                ["name", "dateModified"]
                    .iter()
                    .enumerate()
                    .map(|(i, id)| Element {
                        identifier: (*id).into(),
                        ..el(&format!("{g}.{}", 2 + i), "column", "")
                    })
                    .collect(),
            )],
        )
    };
    let mut w = WindowIds::default();
    let mut n = 0u32;
    let mut a = tree(cols(1));
    w.assign(&mut a, false, &mut n);
    let mut b = tree(cols(2));
    w.assign(&mut b, false, &mut n);
    assert_eq!(a.root.children[0].children[0].id, b.root.children[0].children[0].id);
    assert_eq!(a.root.children[0].children[1].id, b.root.children[0].children[1].id);
}
