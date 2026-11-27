//! The decision table of [`decide`]: every row of the module docs' rules.

use super::*;

fn argv(words: &str) -> Vec<String> {
    words.split_whitespace().map(str::to_owned).collect()
}

fn over() -> Option<HereBudget> {
    Some(HereBudget { level: Level::Critical, over: vec!["load1 9.0 >= 8 (8 cores)".into()] })
}

fn at(level: Level) -> Option<HereBudget> {
    Some(HereBudget { level, over: Vec::new() })
}

fn room(place: &str, headroom: Headroom) -> Room {
    Room { place: place.into(), headroom }
}

fn inputs<'a>(
    work: Work<'a>,
    asked: Asked,
    here: Option<HereBudget>,
    setting: &'a Setting,
    force: Override,
) -> Inputs<'a> {
    Inputs { work, asked, here, setting, force }
}

/// Places that must never be read: the host is not over, or an override decided.
fn unread() -> Vec<Room> {
    panic!("places read when the decision did not need them")
}

#[test]
fn an_override_wins_whatever_the_budget() {
    let cmd = argv("cargo test");
    let setting = Setting::default();
    let here = decide(
        &inputs(Work::Command(&cmd), Asked::Spill, over(), &setting, Override::Here),
        unread,
    );
    assert_eq!(here, Decision { placement: Placement::Here, reason: Reason::AskedHere });
    let to = Override::To("box".into());
    let there =
        decide(&inputs(Work::Command(&cmd), Asked::Spill, at(Level::Normal), &setting, to), unread);
    assert_eq!(
        there,
        Decision { placement: Placement::There("box".into()), reason: Reason::AskedThere }
    );
}

#[test]
fn auto_off_keeps_work_here_even_over_budget() {
    let cmd = argv("cargo test");
    let setting = Setting::default();
    assert!(!setting.auto, "Auto is off by default");
    let d =
        decide(&inputs(Work::Command(&cmd), Asked::Auto, over(), &setting, Override::None), unread);
    assert_eq!(d.reason, Reason::AutoOff);
    let d = decide(&inputs(Work::Session, Asked::Auto, over(), &setting, Override::None), unread);
    assert_eq!(d.reason, Reason::AutoOff);
}

#[test]
fn auto_on_spills_only_commands_on_the_rule_list() {
    let setting = Setting { auto: true, ..Setting::default() };
    let places = || vec![room("cloud", Headroom::Room)];
    let vim = argv("vim notes.txt");
    let d =
        decide(&inputs(Work::Command(&vim), Asked::Auto, over(), &setting, Override::None), unread);
    assert_eq!(d.reason, Reason::NoRule);
    let build = argv("/usr/bin/make -j8");
    let d = decide(
        &inputs(Work::Command(&build), Asked::Auto, over(), &setting, Override::None),
        places,
    );
    assert_eq!(d.placement, Placement::There("cloud".into()));
    // A session has no rule list: Auto on is enough.
    let d = decide(&inputs(Work::Session, Asked::Auto, over(), &setting, Override::None), places);
    assert!(d.spills());
}

#[test]
fn the_spill_verb_needs_no_setting_or_rule() {
    let setting = Setting::default();
    let cmd = argv("sh -c 'echo hi'");
    let d = decide(
        &inputs(Work::Command(&cmd), Asked::Spill, over(), &setting, Override::None),
        || vec![room("cloud", Headroom::Room)],
    );
    assert_eq!(
        d,
        Decision {
            placement: Placement::There("cloud".into()),
            reason: Reason::OverBudget {
                level: Level::Critical,
                over: vec!["load1 9.0 >= 8 (8 cores)".into()],
            },
        }
    );
}

#[test]
fn within_budget_or_unread_stays_here_and_never_asks_for_places() {
    let setting = Setting::default();
    let cmd = argv("cargo build");
    let d = decide(
        &inputs(Work::Command(&cmd), Asked::Spill, at(Level::Normal), &setting, Override::None),
        unread,
    );
    assert_eq!(d.reason, Reason::WithinBudget { level: Level::Normal });
    let d =
        decide(&inputs(Work::Command(&cmd), Asked::Spill, None, &setting, Override::None), unread);
    assert_eq!(d.reason, Reason::BudgetUnknown);
}

#[test]
fn the_warning_level_is_the_trigger() {
    let setting = Setting::default();
    let cmd = argv("cargo build");
    let d = decide(
        &inputs(Work::Command(&cmd), Asked::Spill, at(Level::Warning), &setting, Override::None),
        || vec![room("cloud", Headroom::Room)],
    );
    assert!(d.spills());
}

#[test]
fn unknown_stale_or_full_places_are_never_room() {
    let setting = Setting::default();
    let cmd = argv("cargo build");
    let places = vec![
        room("a", Headroom::Unknown),
        room("b", Headroom::Stale),
        room("c", Headroom::Full(vec!["load1 4.0 >= 2 (2 cores)".into()])),
    ];
    let d = decide(
        &inputs(Work::Command(&cmd), Asked::Spill, over(), &setting, Override::None),
        || places.clone(),
    );
    assert_eq!(d.placement, Placement::Here);
    let Reason::NoRoom { places: seen, .. } = &d.reason else { panic!("{d:?}") };
    assert_eq!(seen, &places);
    let line = d.reason.to_string();
    assert!(line.contains("no other machine has room"), "{line}");
    assert!(line.contains("a room unknown"), "{line}");
    // No places at all.
    let d = decide(
        &inputs(Work::Command(&cmd), Asked::Spill, over(), &setting, Override::None),
        Vec::new,
    );
    assert!(d.reason.to_string().ends_with("no other machine is available"), "{}", d.reason);
}

#[test]
fn the_first_place_with_room_is_taken() {
    let setting = Setting::default();
    let cmd = argv("cargo build");
    let d = decide(
        &inputs(Work::Command(&cmd), Asked::Spill, over(), &setting, Override::None),
        || vec![room("a", Headroom::Unknown), room("b", Headroom::Room), room("c", Headroom::Room)],
    );
    assert_eq!(d.placement, Placement::There("b".into()));
}

#[test]
fn rules_match_leading_words_and_the_program_by_file_name() {
    assert!(matches_rule("cargo test", &argv("cargo test -p x")));
    assert!(matches_rule("make", &argv("/usr/bin/make")));
    assert!(!matches_rule("cargo test", &argv("cargo")));
    assert!(!matches_rule("cargo test", &argv("cargo run")));
    assert!(!matches_rule("", &argv("make")));
    assert!(!matches_rule("make", &argv("/usr/bin/cmake")));
}

#[test]
fn the_decision_serializes_its_reason_as_data() {
    let d = Decision {
        placement: Placement::There("cloud".into()),
        reason: Reason::OverBudget { level: Level::Warning, over: vec!["x".into()] },
    };
    assert_eq!(
        serde_json::to_value(&d).unwrap(),
        serde_json::json!({
            "placement": {"at": "there", "place": "cloud"},
            "reason": {"code": "over_budget", "level": "warning", "over": ["x"]},
        })
    );
}

#[test]
fn a_linux_probe_reads_as_room_full_or_unknown() {
    let probe = |load: &str| {
        format!(
            "@nproc\n8\n@loadavg\n{load} 1.0 1.0 1/100 42\n@meminfo\nMemTotal: 1000 kB\n\
             MemAvailable: 600 kB\n@psi\nsome avg10=0.00 avg60=0.00 avg300=0.00 total=0\n"
        )
    };
    assert_eq!(linux_headroom(&probe("1.5")), Headroom::Room);
    let Headroom::Full(over) = linux_headroom(&probe("12.0")) else { panic!() };
    assert!(over[0].starts_with("load1 12.0 >= 8"), "{over:?}");
    assert_eq!(linux_headroom("@nproc\n\n@loadavg\n1 1 1\n"), Headroom::Unknown);
    assert_eq!(linux_headroom("sh: nproc: not found"), Headroom::Unknown);
}
