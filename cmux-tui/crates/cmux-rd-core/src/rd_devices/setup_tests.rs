//! Ported from `MacScreenDeviceSetupTests.swift`.
use super::*;
use serde_json::json;

fn both() -> BTreeSet<Verb> {
    [Verb::Setup, Verb::Start].into()
}

#[test]
fn reads_each_step_state() {
    for (word, state) in [
        ("ok", StepState::Ok),
        ("changed", StepState::Changed),
        ("warn", StepState::Warn),
        ("fail", StepState::Fail),
        ("skip", StepState::Skip),
    ] {
        let line = format!(
            r#"{{"device":"studio-mac","step":"launch","state":"{word}","detail":"opened cmux NIGHTLY","fix":""}}"#
        );
        let mut step = Step::new("studio-mac", "launch", state);
        step.detail = "opened cmux NIGHTLY".into();
        assert_eq!(Line::parse(&line), Some(Line::Step(step)));
    }
}

#[test]
fn an_unknown_state_reads_as_a_warning_never_a_pass() {
    let Some(Line::Step(step)) =
        Line::parse(r#"{"device":"m","step":"app","state":"exploded","detail":"d"}"#)
    else {
        panic!("not a step")
    };
    assert_eq!(step.state, StepState::Warn);
    assert_eq!(step.fix, None);
}

#[test]
fn reads_the_fix_of_a_failed_step() {
    let line = r#"{"device":"m","step":"reach","state":"fail","detail":"ssh refused","fix":"Turn on Remote Login on m."}"#;
    let Some(Line::Step(step)) = Line::parse(line) else { panic!("not a step") };
    assert_eq!(step.fix.as_deref(), Some("Turn on Remote Login on m."));
}

#[test]
fn reads_the_summary_line() {
    let line = r#"{"device":"studio-mac","summary":"started","changed":["launch"]}"#;
    assert_eq!(
        Line::parse(line),
        Some(Line::Summary(Summary {
            device: "studio-mac".into(),
            summary: "started".into(),
            changed: vec!["launch".into()]
        }))
    );
}

#[test]
fn skips_what_is_not_a_line() {
    for text in ["", "   ", "starting…", "{not json", r#"{"other":"shape"}"#, "[1,2]"] {
        assert_eq!(Line::parse(text), None, "{text}");
    }
}

#[test]
fn reads_a_step_event_and_the_reply_from_the_daemon() {
    let event = json!({"event": "device-setup-step", "device": "studio-mac", "step": "launch", "state": "changed", "detail": "opened"});
    let mut step = Step::new("studio-mac", "launch", StepState::Changed);
    step.detail = "opened".into();
    assert_eq!(Line::of_value(&event), Some(Line::Step(step)));
    let reply = json!({"device": "studio-mac", "summary": "started", "changed": ["launch"]});
    assert!(matches!(Line::of_value(&reply), Some(Line::Summary(s)) if s.changed == ["launch"]));
    assert_eq!(Line::of_value(&json!({"ok": true})), None);
}

#[test]
fn an_unknown_command_is_an_older_daemon() {
    for message in [
        "unknown variant `device-setup`, expected one of …",
        "unknown command: device-setup",
        "Unknown cmd device-setup",
    ] {
        assert!(is_unknown_command(message), "{message}");
    }
    assert!(!is_unknown_command("no route to studio-mac"));
}

#[test]
fn an_offline_mac_shows_start() {
    let row = SetupRow::make(true, false, Some(&both()), None);
    assert!(row.shows_start && row.shows_setup && row.can_run(Verb::Start));
}

#[test]
fn an_online_mac_shows_set_up_but_not_start() {
    let row = SetupRow::make(true, true, Some(&both()), None);
    assert!(!row.shows_start && row.shows_setup);
}

#[test]
fn an_unknown_verb_hides_its_button() {
    assert_eq!(SetupRow::make(true, false, Some(&BTreeSet::new()), None), SetupRow::default());
    let only_setup = SetupRow::make(true, false, Some(&[Verb::Setup].into()), None);
    assert!(!only_setup.shows_start && only_setup.shows_setup);
    assert_eq!(SetupRow::make(true, false, None, None), SetupRow::default());
}

#[test]
fn a_phone_shows_no_button() {
    assert_eq!(SetupRow::make(false, false, Some(&both()), None), SetupRow::default());
}

#[test]
fn a_running_start_keeps_its_button_disabled_while_the_mac_comes_online() {
    let row = SetupRow::make(true, true, Some(&both()), Some(Run::new(Verb::Start)));
    assert!(row.shows_start && !row.can_run(Verb::Start) && !row.can_run(Verb::Setup));
}

#[test]
fn a_run_ends_by_its_exit_and_steps() {
    let mut run = Run::new(Verb::Start);
    run.take(Line::Step(Step::new("m", "reach", StepState::Ok)));
    run.take(Line::Step(Step::new("m", "launch", StepState::Changed)));
    run.end(None);
    assert_eq!(run.phase, Phase::Succeeded);

    let mut failed = Run::new(Verb::Setup);
    failed.take(Line::Step(Step::new("m", "reach", StepState::Fail)));
    failed.end(Some(RunStop {
        unknown_command: false,
        message: "device-setup: reach failed".into(),
    }));
    assert_eq!(failed.phase, Phase::Failed(String::new()));

    let mut stopped = Run::new(Verb::Start);
    stopped.end(Some(RunStop { unknown_command: false, message: "no route to m".into() }));
    assert_eq!(stopped.phase, Phase::Failed("no route to m".into()));

    let mut too_old = Run::new(Verb::Start);
    too_old.end(Some(RunStop { unknown_command: true, message: "unknown variant".into() }));
    assert_eq!(too_old.phase, Phase::NeedsNewerCmux);
}

#[test]
fn a_step_that_reports_again_replaces_its_line() {
    let mut run = Run::new(Verb::Setup);
    run.take(Line::Step(Step::new("m", "app", StepState::Warn)));
    run.take(Line::Step(Step::new("m", "app", StepState::Changed)));
    assert_eq!(run.steps.iter().map(|s| s.state).collect::<Vec<_>>(), [StepState::Changed]);
}

#[test]
fn start_runs_and_refreshes_on_success() {
    let mut setup = Setup::default();
    setup.set_runner(true);
    assert!(setup.row("d1", true, false).shows_start);
    assert!(setup.run(Verb::Start, "d1"));
    assert!(!setup.run(Verb::Setup, "d1"), "one run per device at a time");
    setup.line("d1", Line::Step(Step::new("studio-mac", "reach", StepState::Ok)));
    setup.line("d1", Line::Step(Step::new("studio-mac", "launch", StepState::Changed)));
    setup.line(
        "d1",
        Line::Summary(Summary {
            device: "studio-mac".into(),
            summary: "started".into(),
            changed: vec!["launch".into()],
        }),
    );
    let ended = setup.end("d1", None).unwrap();
    assert_eq!(ended, Ended { phase: Phase::Succeeded, succeeded: true });
    let run = &setup.runs["d1"];
    assert_eq!(run.steps.iter().map(|s| s.step.as_str()).collect::<Vec<_>>(), ["reach", "launch"]);
    assert_eq!(run.summary.as_ref().unwrap().changed, ["launch"]);
    assert!(setup.dismiss("d1") && !setup.runs.contains_key("d1"));
}

#[test]
fn a_daemon_that_refuses_the_command_hides_the_buttons() {
    let mut setup = Setup::default();
    setup.set_runner(true);
    setup.run(Verb::Start, "d1");
    let ended =
        setup.end("d1", Some(RunStop { unknown_command: true, message: "unknown variant".into() }));
    assert_eq!(ended.unwrap().phase, Phase::NeedsNewerCmux);
    assert!(!setup.row("d1", true, false).shows_start);
    assert!(!setup.row("d1", true, false).shows_setup);
    assert!(!setup.row("d2", true, true).shows_setup);
}

#[test]
fn a_host_that_blocks_this_mac_offers_no_set_up() {
    let row = SetupRow::make(true, false, Some(&both()), None);
    let blocked = row.clone().blocking(false);
    assert!(!blocked.shows_setup && blocked.shows_start);
    assert_eq!(row.clone().blocking(true), row);
}

#[test]
fn no_daemon_shows_no_button() {
    let mut setup = Setup::default();
    assert_eq!(setup.row("d1", true, false), SetupRow::default());
    assert!(!setup.run(Verb::Start, "d1"));
    setup.set_runner(true);
    assert!(setup.row("d1", true, false).shows_start);
}
