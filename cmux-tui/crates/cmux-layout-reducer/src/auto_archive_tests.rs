//! Ported from cmux-next macOS `AutoArchivePlannerTests.swift` and the
//! snooze case of `AutoArchiveCoordinator.plan`: which idle workspaces the
//! planner offers under each style, what always keeps a workspace, how a
//! group's rule wins over the days, and when the next pass is due.

use super::*;
use serde_json::json;

const NOW: f64 = 1_800_000_000.0;

#[derive(Default)]
struct Ws {
    idle_days: Option<f64>,
    groups: Vec<&'static str>,
    pinned: bool,
    archived: bool,
    shown: bool,
    running: bool,
    attention: bool,
}

fn ws(idle_days: Option<f64>) -> Ws {
    Ws { idle_days, ..Ws::default() }
}

impl Ws {
    fn groups(mut self, groups: &[&'static str]) -> Self {
        self.groups = groups.to_vec();
        self
    }

    fn candidate(&self) -> Candidate {
        Candidate {
            last_active: self.idle_days.map(|days| NOW - days * DAY),
            seen: None,
            groups: self.groups.iter().map(|g| g.to_string()).collect(),
            pinned: self.pinned,
            archived: self.archived,
            shown: self.shown,
            running: self.running,
            needs_attention: self.attention,
        }
    }
}

fn request(list: &[Ws], style: Style, days: f64, rules: Value, trigger: Trigger) -> Request {
    Request {
        candidates: list.iter().map(Ws::candidate).collect(),
        rules: serde_json::from_value(rules).unwrap(),
        policy: Policy { style, idle_days: days },
        trigger,
        now: NOW,
        snoozed_until: None,
    }
}

/// The names of the due workspaces, `names` naming `list` in order.
fn due(
    list: &[Ws],
    names: &[&str],
    style: Style,
    days: f64,
    rules: Value,
    trigger: Trigger,
) -> Vec<String> {
    plan(&request(list, style, days, rules, trigger))
        .due
        .iter()
        .map(|&i| names[i].to_string())
        .collect()
}

#[test]
fn suggest_and_quiet_offer_workspaces_idle_past_the_days_idlest_first() {
    let list = [ws(Some(1.0)), ws(Some(4.0)), ws(Some(30.0))];
    let names = ["fresh", "old", "older"];
    let bg = Trigger::Background;
    assert_eq!(due(&list, &names, Style::Suggest, 3.0, json!({}), bg), ["older", "old"]);
    assert_eq!(due(&list, &names, Style::Quiet, 3.0, json!({}), bg), ["older", "old"]);
    assert_eq!(due(&list, &names, Style::Quiet, 10.0, json!({}), bg), ["older"]);
}

#[test]
fn off_and_manual_never_run_in_the_background_but_the_sweep_does() {
    let list = [ws(Some(9.0))];
    let names = ["old"];
    assert!(due(&list, &names, Style::Off, 3.0, json!({}), Trigger::Background).is_empty());
    assert!(due(&list, &names, Style::Manual, 3.0, json!({}), Trigger::Background).is_empty());
    assert_eq!(due(&list, &names, Style::Manual, 3.0, json!({}), Trigger::Sweep), ["old"]);
    assert_eq!(due(&list, &names, Style::Off, 3.0, json!({}), Trigger::Sweep), ["old"]);
}

#[test]
fn something_always_keeps_a_workspace() {
    let cases = [
        ("pinned", Ws { pinned: true, ..ws(Some(40.0)) }),
        ("archived", Ws { archived: true, ..ws(Some(40.0)) }),
        ("shown", Ws { shown: true, ..ws(Some(40.0)) }),
        ("running", Ws { running: true, ..ws(Some(40.0)) }),
        ("attention", Ws { attention: true, ..ws(Some(40.0)) }),
        ("never seen", ws(None)),
    ];
    for (reason, candidate) in cases {
        let list = [candidate];
        for trigger in [Trigger::Background, Trigger::Sweep] {
            assert!(
                due(&list, &["w"], Style::Quiet, 3.0, json!({}), trigger).is_empty(),
                "{reason} must keep it ({trigger:?})"
            );
        }
    }
}

#[test]
fn the_nearest_group_with_a_rule_wins() {
    let rules = json!({"g_outer": 24, "g_keep": "never"});
    let list = [
        ws(Some(2.0)).groups(&["g_inner", "g_outer"]),
        ws(Some(90.0)).groups(&["g_keep", "g_outer"]),
        ws(Some(2.0)),
    ];
    let names = ["inOuter", "kept", "loose"];
    assert_eq!(
        due(&list, &names, Style::Quiet, 3.0, rules.clone(), Trigger::Background),
        ["inOuter"]
    );
    // The person's sweep still honors Never.
    assert_eq!(due(&list, &names, Style::Manual, 3.0, rules, Trigger::Sweep), ["inOuter"]);
}

#[test]
fn the_groups_style_archives_only_where_a_group_set_a_rule() {
    let rules = json!({"g_ci": 12});
    let list = [ws(Some(1.0)).groups(&["g_ci"]), ws(Some(50.0)), ws(Some(50.0)).groups(&["g_x"])];
    let names = ["ci", "loose", "other"];
    assert_eq!(due(&list, &names, Style::Groups, 3.0, rules.clone(), Trigger::Background), ["ci"]);
    assert_eq!(
        due(&list, &names, Style::Groups, 3.0, rules, Trigger::Sweep),
        ["loose", "other", "ci"]
    );
}

#[test]
fn off_ignores_group_rules_in_the_background() {
    let list = [ws(Some(1.0)).groups(&["g_ci"])];
    assert!(
        due(&list, &["ci"], Style::Off, 3.0, json!({"g_ci": 1}), Trigger::Background).is_empty()
    );
}

#[test]
fn a_rule_the_document_would_refuse_is_no_rule() {
    // 0 hours, a fraction, a boolean and an unknown word all fall back to the days.
    for bad in [json!(0), json!(1.5), json!(true), json!("soon"), json!(87_601)] {
        let list = [ws(Some(4.0)).groups(&["g"])];
        let rules = json!({ "g": bad });
        assert_eq!(
            due(&list, &["w"], Style::Quiet, 3.0, rules, Trigger::Background),
            ["w"],
            "{bad}"
        );
    }
    assert_eq!(rule_idle_seconds(AutoArchiveRule::AfterHours(24)), Some(86_400.0));
    assert_eq!(rule_idle_seconds(AutoArchiveRule::Never), None);
}

#[test]
fn the_next_check_is_the_soonest_deadline_and_never_sooner_than_a_minute() {
    let list = [ws(Some(1.0)), ws(Some(2.5)), Ws { pinned: true, ..ws(Some(2.9)) }];
    let result = plan(&request(&list, Style::Quiet, 3.0, json!({}), Trigger::Background));
    assert!(result.due.is_empty());
    assert_eq!(result.next_check, Some(NOW + 0.5 * DAY));

    let almost = [ws(Some(3.0 - 1.0 / DAY))];
    let soon = plan(&request(&almost, Style::Quiet, 3.0, json!({}), Trigger::Background));
    assert_eq!(soon.next_check, Some(NOW + MINIMUM_RECHECK));

    let none = plan(&request(&[], Style::Quiet, 3.0, json!({}), Trigger::Background));
    assert_eq!(none.next_check, None);
}

#[test]
fn the_ledger_sight_counts_as_use_and_a_new_workspace_is_never_idle_on_arrival() {
    let mut req = request(
        &[ws(Some(10.0)), ws(None), ws(None)],
        Style::Quiet,
        3.0,
        json!({}),
        Trigger::Background,
    );
    // Shown an hour ago on this Mac: the newer of the two wins.
    req.candidates[0].seen = Some(NOW - 3600.0);
    // Never active, but seen four days ago.
    req.candidates[1].seen = Some(NOW - 4.0 * DAY);
    let result = plan(&req);
    assert_eq!(result.due, [1]);
    assert_eq!(result.first_sight, [2]);
    assert_eq!(result.next_check, Some(NOW - 3600.0 + 3.0 * DAY));
}

#[test]
fn a_snoozed_suggestion_waits_for_the_snooze_and_only_in_the_background() {
    let list = [ws(Some(9.0)), ws(Some(2.0))];
    let mut req = request(&list, Style::Suggest, 3.0, json!({}), Trigger::Background);
    req.snoozed_until = Some(NOW + 600.0);
    let snoozed = plan(&req);
    assert!(snoozed.due.is_empty() && snoozed.snoozed);
    // The later of the next deadline and the snooze's end.
    assert_eq!(snoozed.next_check, Some(NOW + DAY));
    req.snoozed_until = Some(NOW + 2.0 * DAY);
    assert_eq!(plan(&req).next_check, Some(NOW + 2.0 * DAY));

    // Over: the card may show again.
    req.snoozed_until = Some(NOW - 1.0);
    assert_eq!(plan(&req).due, [0]);
    // The person's sweep ignores it, and so does every other style.
    req.snoozed_until = Some(NOW + 600.0);
    req.trigger = Trigger::Sweep;
    assert_eq!(plan(&req).due, [0]);
    req.trigger = Trigger::Background;
    req.policy.style = Style::Quiet;
    assert!(!plan(&req).snoozed);
    // Snoozed with nothing pending: look again when it ends.
    let mut empty = request(&[], Style::Suggest, 3.0, json!({}), Trigger::Background);
    empty.snoozed_until = Some(NOW + 600.0);
    assert_eq!(plan(&empty).next_check, Some(NOW + 600.0));
    // A snooze ending within the minute still waits the minute.
    empty.snoozed_until = Some(NOW + 1.0);
    assert_eq!(plan(&empty).next_check, Some(NOW + MINIMUM_RECHECK));
}

#[test]
fn the_wire_reads_the_app_request() {
    let req: Request = serde_json::from_value(json!({
        "candidates": [{"last_active": NOW - 5.0 * DAY, "groups": ["g"]}, {}],
        "rules": {"g": "never"},
        "policy": {"style": "quiet", "idle_days": 3},
        "trigger": "sweep",
        "now": NOW,
    }))
    .unwrap();
    let result = plan(&req);
    assert!(result.due.is_empty());
    assert_eq!(result.first_sight, [1]);
    let reply = serde_json::to_value(&result).unwrap();
    assert_eq!(
        reply,
        json!({"due": [], "next_check": NOW + 3.0 * DAY, "first_sight": [1], "snoozed": false})
    );
}

#[test]
fn a_first_sight_is_never_due_but_its_deadline_schedules_the_next_check() {
    // The only candidate is new: without its deadline no pass would come back for it.
    let result = plan(&request(&[ws(None)], Style::Quiet, 3.0, json!({}), Trigger::Background));
    assert!(result.due.is_empty());
    assert_eq!(result.first_sight, [0]);
    assert_eq!(result.next_check, Some(NOW + 3.0 * DAY));
    // Even with no idle time at all, arrival is not idleness.
    let zero = plan(&request(&[ws(None)], Style::Quiet, 0.0, json!({}), Trigger::Sweep));
    assert!(zero.due.is_empty());
    assert_eq!(zero.next_check, Some(NOW + MINIMUM_RECHECK));
}
