use super::*;

const MINIMAL: &str = r#"
name = "tiny"
summary = "a pause"
spec = "idle,stream_kbps=64,stream_seconds=4"
headless = true

[[event]]
kind = "pause"
at_ms = 1000
ms = 1000

[[check]]
metric = "resume_catch_up_ms"
max = 100

[sim]
ui = ["TerminalScrollBench"]
"#;

#[test]
fn parses_a_minimal_scenario() {
    let scenario = Scenario::parse(MINIMAL).unwrap();
    assert_eq!(scenario.name, "tiny");
    assert_eq!((scenario.cols, scenario.rows, scenario.frame_bytes), (44, 40, 65536));
    assert_eq!(scenario.events, vec![Event::Pause { at_ms: 1000, ms: 1000 }]);
    assert_eq!(scenario.checks[0].stat, Stat::Max);
    assert_eq!(scenario.checks[0].max, Some(100.0));
    assert_eq!(
        scenario.sim_args(),
        "test ui=TerminalScrollBench duress=idle,stream_kbps=64,stream_seconds=4"
    );
}

#[test]
fn rejects_what_would_run_wrong() {
    let bad = |from: &str, to: &str| Scenario::parse(&MINIMAL.replace(from, to)).unwrap_err();
    assert!(bad("ms = 1000\n", "ms = 1000\nspeed = 2\n").contains("speed"));
    assert!(bad("kind = \"pause\"", "kind = \"warp\"").contains("warp"));
    assert!(bad("spec = \"idle,", "spec = \"idel,").contains("idle, duress, heavy"));
    assert!(bad("max = 100", "").contains("max or min"));
    assert!(bad("headless = true", "headless = false").contains("headless_reason"));
    assert!(bad("name = \"tiny\"", "name = \"Tiny\"").contains("lowercase"));
    assert!(bad("ui = [\"TerminalScrollBench\"]", "ui = []").contains("kit test (only)"));
    assert!(
        bad("headless = true", "headless = true\nknown_failing = \" \"").contains("known_failing")
    );
    // A path reset on a link with no address change and no stall_ms of its own.
    let reset = MINIMAL.replace(
        "kind = \"pause\"\nat_ms = 1000\nms = 1000",
        "kind = \"path_reset\"\nevery_ms = [1000, 2000]",
    );
    assert!(Scenario::parse(&reset).unwrap_err().contains("stall_ms"));
    let handoff = reset.replace("stream_seconds=4", "stream_seconds=4,link=5g-lte-handoff");
    assert!(Scenario::parse(&handoff).is_ok());
}

#[test]
fn a_known_failing_scenario_says_which_bug_in_its_line() {
    let plain = Scenario::parse(MINIMAL).unwrap();
    assert_eq!(plain.known_failing, None);
    let text = MINIMAL.replace("headless = true", "headless = true\nknown_failing = \"#1 open\"");
    let scenario = Scenario::parse(&text).unwrap();
    let json = report_json(&scenario, 1, None, &Metrics::default(), &[], 0.0);
    assert_eq!(json["known_failing"], "#1 open");
    assert_eq!(
        report_json(&plain, 1, None, &Metrics::default(), &[], 0.0)["known_failing"],
        Value::Null
    );
}

#[test]
fn sim_only_scenarios_carry_a_reason_and_nothing_to_run() {
    let text = r#"
name = "list-only"
summary = "Swift list"
spec = "duress"
headless = false
headless_reason = "the list is SwiftUI"
[sim]
ui = ["WorkspaceListBench"]
duress = "heavy"
"#;
    let scenario = Scenario::parse(text).unwrap();
    assert_eq!(scenario.sim_args(), "test ui=WorkspaceListBench duress=heavy");
    let with_check = format!("{text}\n[[check]]\nmetric = \"x\"\nmax = 1\n");
    assert!(Scenario::parse(&with_check).unwrap_err().contains("no events or checks"));
}

#[test]
fn pause_holds_deliveries_to_the_resume() {
    let mut times = vec![500.0, 1000.0, 1500.0, 1999.0, 2000.0, 2500.0];
    let mark = apply_pause(&mut times, 1000, 1000);
    assert_eq!(times, vec![500.0, 2000.0, 2000.0, 2000.0, 2000.0, 2500.0]);
    assert_eq!((mark.from_ms, mark.target_ms), (2000.0, 2000.0));
}

#[test]
fn resets_are_seeded_and_inside_their_ranges() {
    let draw =
        |seed| reset_times([60_000, 100_000], [1000, 3000], 0, 400_000.0, &mut Rng::new(seed));
    let resets = draw(7);
    assert_eq!(resets, draw(7));
    assert!((4..=6).contains(&resets.len()), "{resets:?}");
    let mut last = 0.0;
    for (at, stall) in &resets {
        assert!((60_000.0..=100_000.0).contains(&(at - last)), "{resets:?}");
        assert!((1000.0..=3000.0).contains(stall));
        last = *at;
    }
    let mut times = vec![0.0, 10_000.0, 10_500.0, 12_100.0, 12_200.0];
    let mark = apply_reset(&mut times, 10_000.0, 2000.0, 100.0);
    assert_eq!(times, vec![0.0, 12_100.0, 12_100.0, 12_100.0, 12_200.0]);
    assert_eq!((mark.from_ms, mark.burst_ms), (10_000.0, 12_100.0));
}

#[test]
fn ticks_and_scroll_steps() {
    assert_eq!(ticks(250, 0, None, 1000.0), vec![250.0, 500.0, 750.0]);
    assert_eq!(ticks(250, 100, Some(700), 1000.0), vec![100.0, 350.0, 600.0]);
    assert_eq!(scroll_steps(6, -3, 2), vec![-3, -3, 3, 3, -3, -3]);
}

#[test]
fn judge_reads_the_named_stat() {
    let mut metrics = Metrics::default();
    for value in [1.0, 2.0, 3.0, 4.0, 100.0] {
        metrics.push("frame_ms", "ms", value);
    }
    metrics.count("mismatch", 0.0);
    let check = |metric: &str, stat, max, min| Check { metric: metric.into(), stat, max, min };
    let judged = judge(
        &[
            check("frame_ms", Stat::P50, Some(3.0), None),
            check("frame_ms", Stat::Max, Some(50.0), None),
            check("frame_ms", Stat::N, None, Some(5.0)),
            check("mismatch", Stat::Max, Some(0.0), None),
            check("absent", Stat::Max, Some(1.0), None),
        ],
        &metrics,
    );
    let passes: Vec<bool> = judged.iter().map(|j| j.pass).collect();
    assert_eq!(passes, vec![true, false, true, true, false]);
    assert_eq!(judged[1].value, Some(100.0));
    assert_eq!(judged[4].value, None);
}

#[test]
fn report_is_one_json_line_with_sources() {
    let scenario = Scenario::parse(MINIMAL).unwrap();
    let mut metrics = Metrics::default();
    metrics.push("resume_catch_up_ms", "ms", 40.0);
    let judged = judge(&scenario.checks, &metrics);
    let value = report_json(&scenario, 1, Some("abc"), &metrics, &judged, 12.5);
    let line = value.to_string();
    assert!(!line.contains('\n'));
    assert_eq!(value["verdict"], "pass");
    assert_eq!(value["commit"], "abc");
    assert_eq!(value["metrics"]["resume_catch_up_ms"]["source"], "headless");
    assert_eq!(value["metrics"]["resume_catch_up_ms"]["p95"], 40.0);
    assert_eq!(value["sim"]["source"], "sim");
    assert_eq!(value["sim"]["step"], Value::Null);
}

#[test]
fn every_bundled_scenario_parses() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("scenarios");
    let scenarios = load_dir(&dir).unwrap();
    let names: Vec<&str> = scenarios.iter().map(|s| s.name.as_str()).collect();
    for name in [
        "resume-after-1s",
        "turn-path-reset",
        "tui-scroll-lag",
        "tui-scroll-lag-projection",
        "keyboard-open-close",
        "blank-favicons-previews",
        "theme-wallpaper-mismatch",
    ] {
        assert!(names.contains(&name), "{name} missing from {names:?}");
    }
    assert!(find(&dir, "nope").unwrap_err().contains("resume-after-1s"));
    assert!(list_table(&scenarios).contains("sim-only"));
    // A kit-test sim half runs without duress=, which the sim script allows only beside ui=.
    let resume = find(&dir, "resume-after-1s").unwrap();
    assert_eq!(resume.sim_args(), "test only=CmuxMobileLiveTests/ReconnectChainTimingTests");
}

#[test]
fn new_text_copies_a_scenario_under_a_new_name_keeping_its_comments() {
    let base = MINIMAL
        .replace("[[check]]", "# why this budget\n[[check]]")
        .replace("name = \"tiny\"", "# what it reproduces\nname = \"tiny\"");
    let text =
        new_text(&base, "resume-after-30s", "back after 30 s", "Leo, 2026-11-22", Some(30_000))
            .unwrap();
    let made = Scenario::parse(&text).unwrap();
    assert_eq!(made.name, "resume-after-30s");
    assert_eq!(made.summary, "back after 30 s");
    assert_eq!(made.events, vec![Event::Pause { at_ms: 1000, ms: 30_000 }]);
    assert_eq!(made.checks, Scenario::parse(MINIMAL).unwrap().checks);
    assert!(text.contains("# why this budget"), "{text}");
    assert!(text.contains("# what it reproduces\nname = \"resume-after-30s\""), "{text}");
    assert!(text.contains("Leo, 2026-11-22"), "{text}");
    assert!(text.contains("scenario new resume-after-30s --like tiny"), "{text}");
    // Without --pause-ms the pause stays as it was.
    let same = new_text(&base, "copy", "s", "src", None).unwrap();
    let same = Scenario::parse(&same).unwrap();
    assert_eq!(same.events, vec![Event::Pause { at_ms: 1000, ms: 1000 }]);
}

#[test]
fn new_text_and_pause_ms_refuse_a_scenario_without_a_pause() {
    let no_pause_text =
        MINIMAL.replace("[[event]]\nkind = \"pause\"\nat_ms = 1000\nms = 1000\n", "");
    assert!(
        new_text(&no_pause_text, "x", "s", "src", Some(5000)).unwrap_err().contains("no pause")
    );
    assert!(new_text(MINIMAL, "x", "s", "src", Some(0)).unwrap_err().contains("above 0"));
    let mut tiny = Scenario::parse(MINIMAL).unwrap();
    tiny.set_pause_ms(300_000).unwrap();
    assert_eq!(tiny.events, vec![Event::Pause { at_ms: 1000, ms: 300_000 }]);
    let mut none = Scenario::parse(&no_pause_text).unwrap();
    assert!(none.set_pause_ms(5000).unwrap_err().contains("no pause"));
}
