use super::*;

fn plan(focused: &str, neighbors: Neighbors) -> Plan {
    Plan {
        order: vec!["a".into(), "b".into(), "c".into()],
        focused: focused.into(),
        neighbors,
        ..Plan::default()
    }
}

#[test]
fn each_pane_shows_its_number_and_the_move_that_reaches_it() {
    let mut plan = plan(
        "b",
        Neighbors { left: Some("a".into()), right: Some("c".into()), ..Neighbors::default() },
    );
    plan.labels = [("focusLeft", "⌃⌘H"), ("focusRight", "⌃⌘L")]
        .map(|(k, v)| (k.to_owned(), v.to_owned()))
        .into();
    plan.pane_number_labels = (1..=9).map(|d| (d.to_string(), format!("⌃⌘{d}"))).collect();
    let chips = chips(&plan);
    assert_eq!(chips.iter().map(|c| c.pane.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
    assert_eq!(
        chips.iter().map(|c| c.text.as_str()).collect::<Vec<_>>(),
        ["⌃⌘1 ⌃⌘H", "⌃⌘2", "⌃⌘3 ⌃⌘L"]
    );
}

#[test]
fn unbound_moves_show_no_chip_and_next_previous_follow_the_binding() {
    // Only Focus Next Pane is bound (to a rebound key); no numbers, no directions.
    let mut plan = plan("c", Neighbors { left: Some("b".into()), ..Neighbors::default() });
    plan.labels = [("focusNextPane".to_owned(), "⌃⌥]".to_owned())].into();
    let chips = chips(&plan);
    assert_eq!(
        chips,
        [Chip { pane: "a".into(), text: "⌃⌥]".into() }],
        "next pane after the last wraps to the first"
    );
}

#[test]
fn the_ninth_digit_is_the_last_pane() {
    let plan = Plan {
        order: (0..12).map(|i| format!("p{i}")).collect(),
        focused: "p0".into(),
        pane_number_labels: (1..=9).map(|d| (d.to_string(), d.to_string())).collect(),
        ..Plan::default()
    };
    let chips = chips(&plan);
    assert_eq!(chips.len(), 9);
    assert_eq!(chips.last().unwrap(), &Chip { pane: "p11".into(), text: "9".into() });
    assert!(keeps_hints_up("focusPaneByNumber") && keeps_hints_up("focusUp"));
    assert!(!keeps_hints_up("newTab"));
}
