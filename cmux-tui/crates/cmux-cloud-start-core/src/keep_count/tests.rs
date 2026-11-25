use super::*;

fn facts(plan: Option<&str>, kept: u32, on: bool, hours: Option<f64>) -> Facts {
    Facts { plan: plan.map(str::to_owned), kept, on, hours_used: hours }
}

#[test]
fn every_plan_counts_as_rfd_0135s_table_says() {
    let table = [
        (Plan::Trial, 1, 10, Window::Week),
        (Plan::Intro, 3, 100, Window::Month),
        (Plan::Plus, 3, 100, Window::Month),
        (Plan::Pro, 5, 1_000, Window::Month),
        (Plan::Agents20, 20, 4_000, Window::Month),
        (Plan::Max, 50, 10_000, Window::Month),
    ];
    for (plan, slots, hours, window) in table {
        assert_eq!(plan.allowance(), Allowance { slots, hours, window }, "{plan:?}");
    }
}

#[test]
fn grant_ids_and_wire_names_both_name_a_plan() {
    for (id, plan) in [
        ("next_taste", Plan::Trial),
        ("next_intro", Plan::Intro),
        ("next_plus", Plan::Plus),
        ("go", Plan::Plus),
        ("next_pro", Plan::Pro),
        ("team", Plan::Pro),
        ("next_max", Plan::Max),
        ("agents20", Plan::Agents20),
    ] {
        assert_eq!(count(&facts(Some(id), 0, false, None)).plan, Some(plan), "{id}");
    }
    assert_eq!(count(&facts(Some("free"), 0, false, None)).plan, None);
}

#[test]
fn with_no_plan_turning_it_on_starts_the_taste() {
    let c = count(&facts(None, 0, false, None));
    assert_eq!((c.slots, c.hours), (0, None));
    assert_eq!(c.next, Next::StartsTrial { slots: 1, hours: 10 });
}

#[test]
fn two_of_three_kept_and_another_keeps_the_third() {
    let c = count(&facts(Some("next_plus"), 2, false, Some(41.7)));
    assert_eq!((c.kept, c.slots, c.hours_used, c.hours), (2, 3, Some(41), Some(100)));
    assert_eq!(c.next, Next::Keeps { after: 3 });
    assert!(!c.hours_low);
}

#[test]
fn three_of_three_kept_another_is_full_and_this_one_frees_its_slot() {
    assert_eq!(count(&facts(Some("plus"), 3, false, Some(41.0))).next, Next::Full);
    assert_eq!(count(&facts(Some("plus"), 3, true, Some(41.0))).next, Next::Frees { after: 2 });
    // A plan that shrank under its kept chats is still full, never a negative room.
    assert_eq!(count(&facts(Some("plus"), 5, false, None)).next, Next::Full);
}

#[test]
fn spent_hours_come_before_the_count_and_80_percent_is_low() {
    let spent = count(&facts(Some("next_plus"), 1, false, Some(100.0)));
    assert_eq!(spent.next, Next::HoursUsedUp);
    assert!(spent.hours_low);
    assert!(count(&facts(Some("next_plus"), 1, false, Some(80.0))).hours_low);
    assert!(!count(&facts(Some("next_plus"), 1, false, Some(79.9))).hours_low);
    // Turning a kept chat off is always allowed, hours or not.
    assert_eq!(
        count(&facts(Some("next_plus"), 1, true, Some(120.0))).next,
        Next::Frees { after: 0 }
    );
}

#[test]
fn unread_or_bad_hours_show_no_hours_used() {
    for hours in [None, Some(f64::NAN), Some(f64::INFINITY)] {
        let c = count(&facts(Some("next_pro"), 1, false, hours));
        assert_eq!(c.hours_used, None);
        assert_eq!(c.next, Next::Keeps { after: 2 });
    }
    assert_eq!(count(&facts(Some("next_pro"), 0, false, Some(-3.0))).hours_used, Some(0));
}

#[test]
fn the_wire_shape_is_camel_case_with_a_tagged_next() {
    let value =
        serde_json::to_value(count(&facts(Some("next_plus"), 2, false, Some(41.0)))).unwrap();
    assert_eq!(
        value,
        serde_json::json!({
            "plan": "plus", "kept": 2, "slots": 3, "hoursUsed": 41, "hours": 100,
            "window": "month", "hoursLow": false, "next": {"do": "keeps", "after": 3}
        })
    );
}
