use super::*;

fn page(url: &str, machine: &str) -> ClosedItem {
    ClosedItem {
        kind: ItemKind::Tab,
        tabs: vec![ClosedTab {
            kind: "browser".into(),
            url: Some(url.into()),
            ..ClosedTab::default()
        }],
        machine: machine.into(),
        ..ClosedItem::default()
    }
}

fn terminal() -> ClosedItem {
    ClosedItem {
        kind: ItemKind::Tab,
        tabs: vec![ClosedTab { kind: "terminal".into(), ..ClosedTab::default() }],
        ..ClosedItem::default()
    }
}

#[test]
fn only_one_browser_tab_on_a_real_address_is_a_page() {
    assert_eq!(page_key(&page("https://a.test", "m")), Some(("m", "https://a.test")));
    assert_eq!(page_key(&page("about:blank", "m")), None);
    assert_eq!(page_key(&page("", "m")), None);
    assert_eq!(page_key(&terminal()), None);
    assert_eq!(page_key(&ClosedItem { grouped: true, ..page("https://a.test", "m") }), None);
    let mut two = page("https://a.test", "m");
    two.tabs.push(two.tabs[0].clone());
    assert_eq!(page_key(&two), None);
    let mut internal = page("https://a.test", "m");
    internal.tabs[0].page = true;
    assert_eq!(page_key(&internal), None);
}

#[test]
fn a_page_closed_again_lists_once_at_its_newest_close() {
    let items = vec![
        page("https://a.test", "m"),
        terminal(),
        page("https://a.test", "m"),
        page("https://a.test", "n"),
        terminal(),
    ];
    assert_eq!(newest_once(&items), vec![0, 1, 3, 4]);
    assert_eq!(closes(2, &items), vec![0, 2]);
    assert_eq!(closes(1, &items), vec![1]);
}

fn facts(workspace_window: Option<&str>) -> OwnerFacts {
    OwnerFacts {
        kind: ItemKind::Tab,
        workspace_window: workspace_window.map(str::to_owned),
        ..OwnerFacts::default()
    }
}

#[test]
fn the_window_record_decides_on_this_mac_for_a_known_window() {
    let recorded = |open| OwnerFacts {
        local: true,
        recorded_window: Some("w1".into()),
        recorded_open: Some(open),
        ..facts(Some("w2"))
    };
    assert_eq!(owner(&recorded(true), Some("w1")), Owner::Window);
    assert_eq!(owner(&recorded(true), Some("w3")), Owner::OtherWindow);
    assert_eq!(owner(&recorded(false), Some("w3")), Owner::None);
    let unknown = OwnerFacts { recorded_open: None, ..recorded(true) };
    assert_eq!(owner(&unknown, Some("w2")), Owner::Window);
    let remote = OwnerFacts { local: false, ..recorded(true) };
    assert_eq!(owner(&remote, Some("w2")), Owner::Window);
}

#[test]
fn a_window_item_of_an_unknown_window_belongs_to_another_and_a_workspace_to_its_window() {
    assert_eq!(
        owner(&OwnerFacts { kind: ItemKind::Window, ..facts(None) }, Some("w")),
        Owner::OtherWindow
    );
    assert_eq!(owner(&facts(None), Some("w")), Owner::None);
    assert_eq!(owner(&facts(Some("w")), Some("w")), Owner::Window);
    assert_eq!(owner(&facts(Some("v")), Some("w")), Owner::OtherWindow);
    assert_eq!(owner(&facts(Some("v")), None), Owner::OtherWindow);
}

#[test]
fn cmd_shift_t_takes_this_window_first_then_one_no_window_owns() {
    let entries = vec![facts(Some("v")), facts(None), facts(Some("w"))];
    assert_eq!(newest(&entries, Some("w")), Some(2));
    assert_eq!(newest(&entries, Some("x")), Some(1));
    assert_eq!(newest(&entries[..1], Some("x")), None);
}

fn tabs(list: &[(&str, usize)]) -> Vec<ExpectedTab> {
    list.iter().map(|(id, index)| ExpectedTab { id: (*id).into(), index: *index }).collect()
}

fn item(id: &str, pane: &str, count: usize) -> RecordedItem {
    RecordedItem { id: id.into(), kind: ItemKind::Tab, pane: Some(pane.into()), tabs: count }
}

#[test]
fn a_gesture_settles_once_its_items_hold_every_tab() {
    let mut state = UndoState::default();
    let announced = expect(&mut state, 1, tabs(&[("b", 3), ("a", 1)]), vec!["p".into()], true);
    assert_eq!(announced, Announced::Waiting { dropped: vec![] });
    assert_eq!(state.expected[0].tabs[0].id, "a");
    let first = record(&mut state, &[item("i1", "p", 1), item("x", "other", 1)]);
    assert_eq!(first.matched, vec![true, false]);
    assert!(first.settled.is_empty());
    let second = record(&mut state, &[item("i2", "p", 0)]);
    assert_eq!(
        second.settled,
        vec![Settled { token: 1, items: vec!["i1".into(), "i2".into()], tabs: 2, shows: true }]
    );
    assert!(state.expected.is_empty());
}

#[test]
fn an_idle_close_settles_without_its_toast_and_a_screen_item_never_matches() {
    let mut state = UndoState::default();
    expect(&mut state, 7, tabs(&[("a", 0)]), vec!["p".into()], false);
    let screen = RecordedItem { kind: ItemKind::Screen, ..item("s", "p", 1) };
    assert_eq!(record(&mut state, &[screen]).matched, vec![false]);
    assert!(!record(&mut state, &[item("i", "p", 1)]).settled[0].shows);
}

#[test]
fn a_repeated_close_and_an_empty_one_add_nothing_and_the_oldest_goes_past_the_limit() {
    let mut state = UndoState::default();
    assert_eq!(expect(&mut state, 0, vec![], vec![], true), Announced::Empty);
    expect(&mut state, 1, tabs(&[("a", 0)]), vec!["p".into()], true);
    assert_eq!(
        expect(&mut state, 2, tabs(&[("a", 0), ("b", 1)]), vec!["p".into()], true),
        Announced::Repeated
    );
    for token in 2..=EXPECTED_LIMIT as u64 {
        expect(&mut state, token, tabs(&[(&format!("t{token}"), 0)]), vec!["p".into()], true);
    }
    let over = expect(&mut state, 99, tabs(&[("z", 0)]), vec!["p".into()], true);
    assert_eq!(over, Announced::Waiting { dropped: vec![1] });
    assert_eq!(state.expected.len(), EXPECTED_LIMIT);
}

#[test]
fn a_close_joins_the_toast_its_window_shows_else_waits_for_the_rate_limit() {
    assert_eq!(toast_show(2, Some(3), false), ToastShow::Join { tabs: 5 });
    assert_eq!(toast_show(1, None, true), ToastShow::New { tabs: 1 });
    assert_eq!(toast_show(1, None, false), ToastShow::Drop);
}
