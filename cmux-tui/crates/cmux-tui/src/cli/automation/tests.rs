use super::*;

fn args(words: &[&str]) -> Args {
    Args::parse(&words.iter().map(|s| s.to_string()).collect::<Vec<_>>(), SPEC_VALUED, SPEC_FLAGS)
        .ok()
        .unwrap()
}

#[test]
fn schedules_parse_to_triggers() {
    let now = 1_793_350_800;
    let t = |w: &[&str]| parse_trigger(&args(w), now).ok().flatten();
    assert_eq!(
        t(&["--daily", "09:30", "--tz", "UTC"]),
        Some(Trigger::Cron { expr: "30 9 * * *".into(), tz: "UTC".into() })
    );
    assert_eq!(
        t(&["--weekdays=8:05", "--tz", "UTC"]),
        Some(Trigger::Cron { expr: "5 8 * * 1-5".into(), tz: "UTC".into() })
    );
    assert_eq!(
        t(&["--weekly", "fri 17:00", "--tz", "UTC"]),
        Some(Trigger::Cron { expr: "0 17 * * 5".into(), tz: "UTC".into() })
    );
    assert_eq!(t(&["--every", "30m"]), Some(Trigger::Every { seconds: 1_800, anchor: now }));
    assert_eq!(t(&["--in", "2h"]), Some(Trigger::At { at: now + 7_200 }));
    assert_eq!(
        t(&["--at", "2026-10-30 10:00", "--tz", "UTC"]),
        Some(Trigger::At { at: now + 3_600 })
    );
    assert_eq!(
        t(&["--at", "08:00", "--tz", "UTC"]),
        Some(Trigger::At { at: now + 23 * 3_600 }),
        "a past clock time means tomorrow"
    );
    assert_eq!(t(&["--manual"]), Some(Trigger::Manual));
    assert_eq!(t(&["--hourly", "--tz", "UTC"]), Some(Trigger::preset_hourly(Zone::Utc)));
    assert_eq!(t(&[]), None);
}

#[test]
fn the_runner_finds_what_the_installing_shell_finds_and_homebrew() {
    assert_eq!(
        runner_path(Some("/Users/me/.cargo/bin:/usr/bin:/bin")),
        "/Users/me/.cargo/bin:/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin"
    );
    assert_eq!(runner_path(None), "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin");
}

#[test]
fn when_names_an_event_with_its_own_debounce_and_guardrails() {
    let t = |w: &[&str]| parse_trigger(&args(w), 0);
    assert_eq!(
        t(&["--when", "pr-opened"]).ok().flatten(),
        Some(Trigger::Event { event: "pr-opened".into(), debounce_seconds: 5 })
    );
    assert_eq!(
        t(&["--when=agent-idle", "--debounce", "10s"]).ok().flatten(),
        Some(Trigger::Event { event: "agent-idle".into(), debounce_seconds: 10 })
    );
    for bad in [&["--when", "agent-busy"][..], &["--when", "pr-opened", "--daily", "9:00"]] {
        let Err(Failure::Usage(why)) = t(bad) else { panic!("{bad:?} is a usage error") };
        assert!(!why.is_empty(), "{bad:?}");
    }
    let Err(Failure::Usage(why)) = t(&["--when", "agent-busy"]) else { unreachable!() };
    assert!(why.contains("agent-idle, agent-needs-input, pr-opened"), "{why}");
    assert!(why.contains("cmux automation events"), "{why}");
    // A new automation on an event gets that event's guardrails; flags win.
    let idle = Trigger::Event { event: "agent-idle".into(), debounce_seconds: 5 };
    let defaults = triggers::guard_defaults(&idle);
    assert_eq!(defaults, Some((60, Some(48))));
    let gate = triggers::gate(&args(&[]), Gate::default(), defaults).ok().unwrap();
    assert_eq!((gate.cooldown_seconds, gate.max_runs_per_day), (60, Some(48)));
    let gate = triggers::gate(&args(&["--max-runs", "0"]), Gate::default(), defaults).ok().unwrap();
    assert_eq!(gate.max_runs_per_day, None);
    assert_eq!(triggers::guard_defaults(&Trigger::Manual), None);
    assert_eq!(describe_trigger(&idle), "When an agent goes idle");
}

#[test]
fn bad_schedules_are_usage_errors() {
    let now = 0;
    for w in [
        &["--daily", "25:00"][..],
        &["--every", "30s"],
        &["--daily", "9:00", "--hourly"],
        &["--cron", "* * *"],
        &["--tz", "Europe/Paris", "--daily", "9:00"],
        &["--weekly", "someday 9:00"],
    ] {
        assert!(parse_trigger(&args(w), now).is_err(), "{w:?}");
    }
}

#[test]
fn durations() {
    assert_eq!(parse_duration("90").ok(), Some(90));
    assert_eq!(parse_duration("45m").ok(), Some(2_700));
    assert_eq!(parse_duration("1d").ok(), Some(86_400));
    assert!(parse_duration("soon").is_err());
}

#[test]
fn target_is_taken_out_of_the_words_in_both_forms() {
    let words = |w: &[&str]| w.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    let taken = |w: &[&str]| take_target(&words(w)).ok();
    assert_eq!(taken(&["list"]), Some((false, words(&["list"]))));
    assert_eq!(
        taken(&["list", "--target", "cloud", "--json"]),
        Some((true, words(&["list", "--json"])))
    );
    assert_eq!(taken(&["--target=cloud", "list"]), Some((true, words(&["list"]))));
    assert_eq!(taken(&["list", "--target", "this-mac"]), Some((false, words(&["list"]))));
    assert!(matches!(take_target(&words(&["list", "--target"])), Err(Failure::Usage(_))));
    assert!(matches!(take_target(&words(&["--target", "mars"])), Err(Failure::Usage(_))));
}
