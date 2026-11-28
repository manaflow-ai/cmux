use super::*;

/// p0 p1 pinned, then t2 t3 t4 t5.
fn order() -> Vec<String> {
    ["p0", "p1", "t2", "t3", "t4", "t5"].map(String::from).to_vec()
}

fn set(ids: &[&str]) -> BTreeSet<String> {
    ids.iter().map(|id| id.to_string()).collect()
}

/// Clicks like the strip does: the returned tab becomes active.
fn click(selection: &mut MultiSelection, active: &mut String, id: &str, kind: Click) {
    if let Some(next) = selection.click(id, kind, &order(), Some(active)) {
        *active = next;
    }
}

#[test]
fn cmd_click_adds_a_tab_and_makes_it_active() {
    let (mut selection, mut active) = (MultiSelection::default(), "t2".to_string());
    click(&mut selection, &mut active, "t4", Click::Toggle);
    assert_eq!(active, "t4");
    assert_eq!(selection.ids, set(&["t2", "t4"]));
}

#[test]
fn cmd_click_takes_a_tab_out_and_the_nearest_selected_tab_becomes_active() {
    let (mut selection, mut active) = (MultiSelection::default(), "t2".to_string());
    click(&mut selection, &mut active, "t3", Click::Toggle);
    click(&mut selection, &mut active, "t5", Click::Toggle);
    assert_eq!(selection.ids, set(&["t2", "t3", "t5"]));
    // t5 is active; nothing selected after it, so the one before (t3).
    click(&mut selection, &mut active, "t5", Click::Toggle);
    assert_eq!(active, "t3");
    assert_eq!(selection.anchor.as_deref(), Some("t3"));
    // A selected tab that is not active leaves without a switch; one left is no selection.
    click(&mut selection, &mut active, "t2", Click::Toggle);
    assert_eq!(active, "t3");
    assert!(selection.ids.is_empty());
}

#[test]
fn cmd_click_on_the_only_selected_tab_keeps_it() {
    let mut selection = MultiSelection::default();
    assert_eq!(selection.click("t2", Click::Toggle, &order(), Some("t2")), None);
    assert!(selection.ids.is_empty());
}

#[test]
fn shift_click_selects_the_range_from_the_anchor_and_keeps_the_anchor() {
    let (mut selection, mut active) = (MultiSelection::default(), "t2".to_string());
    click(&mut selection, &mut active, "t5", Click::Range);
    assert_eq!(active, "t5");
    assert_eq!(selection.ids, set(&["t2", "t3", "t4", "t5"]));
    click(&mut selection, &mut active, "t3", Click::Range);
    assert_eq!(selection.ids, set(&["t2", "t3"]));
    assert_eq!(selection.anchor.as_deref(), Some("t2"));
}

#[test]
fn cmd_shift_click_adds_the_range() {
    let (mut selection, mut active) = (MultiSelection::default(), "p0".to_string());
    click(&mut selection, &mut active, "t5", Click::Toggle);
    click(&mut selection, &mut active, "t3", Click::AddRange);
    assert_eq!(selection.ids, set(&["p0", "t3", "t4", "t5"]));
}

#[test]
fn a_range_to_a_tab_not_in_the_strip_does_nothing() {
    let mut selection = MultiSelection::default();
    assert_eq!(selection.click("gone", Click::Range, &order(), Some("t2")), None);
    assert_eq!(selection, MultiSelection::default());
}

#[test]
fn a_plain_click_ends_the_selection() {
    let (mut selection, mut active) = (MultiSelection::default(), "t2".to_string());
    click(&mut selection, &mut active, "t4", Click::Toggle);
    click(&mut selection, &mut active, "t5", Click::Plain);
    assert_eq!(active, "t5");
    assert!(selection.ids.is_empty());
    assert_eq!(selection.anchor.as_deref(), Some("t5"));
}

#[test]
fn closes_and_activations_follow() {
    let (mut selection, mut active) = (MultiSelection::default(), "t2".to_string());
    click(&mut selection, &mut active, "t4", Click::Range);
    selection.follow(&["t2", "t3", "t5"].map(String::from));
    assert_eq!(selection.ids, set(&["t2", "t3"]));
    assert_eq!(selection.anchor.as_deref(), Some("t2"));
    selection.activated(Some("t3"));
    assert_eq!(selection.ids, set(&["t2", "t3"]));
    selection.activated(Some("t5"));
    assert!(selection.ids.is_empty());
    selection.follow(&["t5".to_string()]);
    assert_eq!(selection.anchor, None);
}

#[test]
fn a_move_keeps_order_and_sections() {
    let none = BTreeSet::new();
    let order: Vec<String> = ["A", "b", "c", "D", "E", "f"].map(String::from).to_vec();
    assert_eq!(moving(&order, &none, &set(&["A", "D", "E"]), 1), ["b", "A", "D", "E", "c", "f"]);
    let order: Vec<String> = ["p0", "P1", "t2", "T3", "t4", "T5"].map(String::from).to_vec();
    let pinned = set(&["p0", "P1"]);
    // P1 stays among the pinned tabs, T3 and T5 go to the start of the unpinned ones.
    assert_eq!(
        moving(&order, &pinned, &set(&["P1", "T3", "T5"]), 0),
        ["P1", "p0", "T3", "T5", "t2", "t4"]
    );
    assert_eq!(
        moving(&order, &pinned, &set(&["P1", "T3"]), 99),
        ["p0", "P1", "t2", "t4", "T5", "T3"]
    );
}

#[test]
fn steps_walk_a_drop_to_its_order() {
    let target: Vec<String> = ["t4", "t2", "x", "t5", "t3"].map(String::from).to_vec();
    let mut current = order();
    let mut moves = 0;
    while let Some(step) = next_step(&current, &target) {
        let from = current.iter().position(|tab| *tab == step.id).unwrap();
        let tab = current.remove(from);
        current.insert(step.index, tab);
        moves += 1;
        assert!(moves <= 6);
    }
    let shared: Vec<&String> = current.iter().filter(|tab| target.contains(tab)).collect();
    assert_eq!(shared, ["t4", "t2", "t5", "t3"]);
}
