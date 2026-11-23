use super::*;

#[test]
fn nine_is_the_last_and_clamp_takes_the_last_past_the_end() {
    assert_eq!(ordinal(1, 3, PastEnd::Clamp), Some(0));
    assert_eq!(ordinal(3, 3, PastEnd::Clamp), Some(2));
    assert_eq!(ordinal(5, 3, PastEnd::Clamp), Some(2));
    assert_eq!(ordinal(9, 12, PastEnd::Clamp), Some(11));
    assert_eq!(ordinal(10, 12, PastEnd::Clamp), Some(11));
}

#[test]
fn refuse_picks_nothing_past_the_end_but_nine_is_still_the_last() {
    assert_eq!(ordinal(2, 3, PastEnd::Refuse), Some(1));
    assert_eq!(ordinal(4, 3, PastEnd::Refuse), None);
    assert_eq!(ordinal(9, 3, PastEnd::Refuse), Some(2));
    assert_eq!(ordinal(10, 12, PastEnd::Refuse), Some(9));
}

#[test]
fn no_item_and_numbers_below_one_pick_nothing() {
    assert_eq!(ordinal(1, 0, PastEnd::Clamp), None);
    assert_eq!(ordinal(9, 0, PastEnd::Refuse), None);
    assert_eq!(ordinal(0, 3, PastEnd::Clamp), None);
    assert_eq!(ordinal(-4, 3, PastEnd::Refuse), None);
}

#[test]
fn step_wraps_around_both_ends() {
    assert_eq!(step(2, 1, 3), Some(0));
    assert_eq!(step(0, -1, 3), Some(2));
    assert_eq!(step(1, 7, 3), Some(2));
    assert_eq!(step(0, -7, 3), Some(2));
    assert_eq!(step(0, 1, 0), None);
}

fn named_list() -> Vec<Named> {
    vec![
        Named { id: "p1".into(), folded: "work".into() },
        Named { id: "work".into(), folded: "home".into() },
        Named { id: "p3".into(), folded: "work".into() },
    ]
}

#[test]
fn an_id_wins_over_a_name_then_the_first_folded_name() {
    assert_eq!(named("work", "work", &named_list()), Some(1));
    assert_eq!(named("Work", "work", &named_list()), Some(0));
    assert_eq!(named("p3", "p3", &named_list()), Some(2));
    assert_eq!(named("Nope", "nope", &named_list()), None);
}

#[test]
fn the_explicit_target_is_the_first_of_a_wanted_kind() {
    let tab = Some(TargetRef { kind: "tab".into(), id: "t".into() });
    let window = Some(TargetRef { kind: "window".into(), id: "w".into() });
    let kinds = vec!["tab".to_owned(), "pane".to_owned()];
    assert_eq!(explicit(&[window.clone(), None, tab.clone()], &kinds), Some(2));
    assert_eq!(explicit(&[tab, window.clone()], &kinds), Some(0));
    assert_eq!(explicit(&[window, None], &kinds), None);
}

#[test]
fn a_tab_list_is_trimmed_without_empty_entries() {
    assert_eq!(tab_ids(" a, b ,,\tc ,"), vec!["a", "b", "c"]);
    assert!(tab_ids(" , ").is_empty());
    assert_eq!(trim_spaces(" x\n"), "x\n");
}

#[test]
fn tabs_act_together_only_in_one_pane() {
    assert_eq!(one_pane(&[]), Err(TabsRefusal::NoTab));
    assert_eq!(one_pane(&["p".into(), "p".into()]), Ok(()));
    assert_eq!(one_pane(&["p".into(), "q".into()]), Err(TabsRefusal::TabsInDifferentPanes));
}

#[test]
fn a_thrown_failure_refuses_not_found_first_then_quietly() {
    assert_eq!(refusal(Failure { not_found: true, quiet: true }), Refusal::NotFound);
    assert_eq!(refusal(Failure { not_found: false, quiet: true }), Refusal::Quiet);
    assert_eq!(refusal(Failure::default()), Refusal::Shown);
}
