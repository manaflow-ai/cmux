use super::*;

fn ids(names: &[&str]) -> Vec<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

fn set(names: &[&str]) -> BTreeSet<String> {
    names.iter().map(|name| (*name).to_owned()).collect()
}

#[test]
fn a_sight_keeps_the_newer_time() {
    let mut ledger = Ledger::default();
    ledger.saw("w", 100.0);
    ledger.saw("w", 50.0);
    assert_eq!(ledger.seen["w"], 100.0);
    ledger.saw("w", 150.0);
    assert_eq!(ledger.seen["w"], 150.0);
}

#[test]
fn keep_drops_gone_workspaces_and_items() {
    let mut ledger = Ledger::default();
    ledger.saw("a", 1.0);
    ledger.saw("b", 1.0);
    ledger.auto_archived = set(&["x", "y"]);
    ledger.keep(&set(&["a"]), &set(&["y", "z"]));
    assert_eq!(ledger.seen.keys().cloned().collect::<Vec<_>>(), ids(&["a"]));
    assert_eq!(ledger.auto_archived, set(&["y"]));
}

#[test]
fn a_pass_archives_suggests_or_waits_by_style() {
    assert_eq!(pass(Style::Quiet, 7.0, 2, None, 0.0).action, Action::Archive);
    assert_eq!(pass(Style::Groups, 7.0, 2, None, 0.0).action, Action::Archive);
    assert_eq!(pass(Style::Suggest, 7.0, 2, None, 0.0).action, Action::Suggest);
    assert_eq!(pass(Style::Manual, 7.0, 2, None, 0.0).action, Action::None);
    assert_eq!(pass(Style::Off, 7.0, 2, None, 0.0).action, Action::None);
    assert_eq!(pass(Style::Quiet, 7.0, 0, None, 0.0).action, Action::None);
}

#[test]
fn the_next_pass_is_never_sooner_than_a_second() {
    assert_eq!(pass(Style::Suggest, 7.0, 0, Some(10.0), 20.0).recheck_after, Some(1.0));
    assert_eq!(pass(Style::Suggest, 7.0, 0, Some(100.0), 20.0).recheck_after, Some(80.0));
    assert_eq!(pass(Style::Suggest, 7.0, 0, None, 20.0).recheck_after, None);
}

#[test]
fn the_card_days_round_half_away_from_zero() {
    assert_eq!(pass(Style::Suggest, 2.5, 1, None, 0.0).days, 3);
    assert_eq!(pass(Style::Suggest, 2.49, 1, None, 0.0).days, 2);
    assert_eq!(pass(Style::Suggest, f64::NAN, 1, None, 0.0).days, 0);
}

#[test]
fn a_plan_records_first_sights_and_prunes_unless_snoozed() {
    let mut ledger = Ledger::default();
    ledger.saw("gone", 1.0);
    let (after, dirty) =
        planned(ledger.clone(), &ids(&["new"]), false, &set(&["new"]), &set(&[]), 9.0);
    assert!(dirty);
    assert_eq!(after.seen.keys().cloned().collect::<Vec<_>>(), ids(&["new"]));
    let (after, dirty) = planned(ledger, &[], true, &set(&[]), &set(&[]), 9.0);
    assert!(!dirty);
    assert!(after.seen.contains_key("gone"));
}

#[test]
fn the_card_lists_five_names_and_counts_the_rest() {
    let titles = ids(&["a", "b", "c", "d", "e", "f", "g"]);
    assert_eq!(card(&titles), (ids(&["a", "b", "c", "d", "e"]), Some(2)));
    assert_eq!(card(&titles[..5]), (ids(&["a", "b", "c", "d", "e"]), None));
}

#[test]
fn a_shown_auto_archived_item_comes_back_only_while_archived() {
    let ledger = archived(Ledger::default(), &ids(&["i1", "i2"]));
    let rows = vec![
        Shown { workspace: "w1".into(), item: Some("i1".into()), archived: true },
        Shown { workspace: "w2".into(), item: Some("i2".into()), archived: false },
        Shown { workspace: "w3".into(), item: Some("other".into()), archived: true },
        Shown { workspace: "w4".into(), item: None, archived: true },
    ];
    let (after, back, dirty) = shown(ledger, &rows, 5.0);
    assert_eq!(back, ids(&["i1"]));
    assert!(dirty);
    assert_eq!(after.seen.len(), 4);
}

#[test]
fn nothing_comes_back_when_nothing_is_auto_archived() {
    let rows = vec![Shown { workspace: "w".into(), item: Some("i".into()), archived: true }];
    let (_, back, _) = shown(Ledger::default(), &rows, 1.0);
    assert!(back.is_empty());
    let (_, _, dirty) = shown(Ledger::default(), &[], 1.0);
    assert!(!dirty);
}

#[test]
fn a_restore_forgets_the_items_and_sees_their_workspaces() {
    let ledger = archived(Ledger::default(), &ids(&["i1", "i2"]));
    let after = restored(ledger, &ids(&["i1"]), &ids(&["w1"]), 7.0);
    assert_eq!(after.auto_archived, set(&["i2"]));
    assert_eq!(after.seen["w1"], 7.0);
}

#[test]
fn not_now_snoozes_a_day() {
    let (after, recheck) = snoozed(Ledger::default(), 10.0);
    assert_eq!(after.snoozed_until, Some(10.0 + SNOOZE));
    assert_eq!(recheck, SNOOZE);
}

#[test]
fn the_cards_archive_takes_only_what_is_still_due() {
    assert_eq!(still_due(&ids(&["a", "b", "c"]), &ids(&["c", "a"])), ids(&["a", "c"]));
}

#[test]
fn the_ledger_round_trips_in_the_apps_keys() {
    let value = serde_json::json!({"seen": {"w": 1.0}, "autoArchived": ["i"], "snoozedUntil": 3.0});
    let ledger: Ledger = serde_json::from_value(value.clone()).expect("ledger");
    assert_eq!(serde_json::to_value(&ledger).expect("json"), value);
}
