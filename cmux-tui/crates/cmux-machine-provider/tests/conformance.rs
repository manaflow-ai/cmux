use cmux_machine_provider::conformance::{
    Profile, Run, Status, Step, StepSpec, fill, green, import_journey, run_profile, table,
};
use std::collections::BTreeMap;

fn spec(run: &str, expect: Option<&str>, timeout_s: u64) -> StepSpec {
    StepSpec { run: run.into(), expect: expect.map(Into::into), timeout_s }
}

fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

fn scratch(name: &str) -> std::path::PathBuf {
    let dir = std::env::temp_dir().join(format!("conformance-{name}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn status(run: &Run, step: Step) -> Status {
    run.steps.iter().find(|s| s.step == step).unwrap().status
}

#[test]
fn fill_refuses_a_placeholder_with_no_value() {
    let v = values(&[("machine", "big-red")]);
    assert_eq!(fill("ssh {machine} true", &v).unwrap(), "ssh big-red true");
    assert!(fill("ssh {host} true", &v).unwrap_err().contains("--set host="));
    assert!(fill("echo {machine", &v).is_err());
}

#[test]
fn a_profile_runs_every_step_and_marks_the_missing_ones_not_applicable() {
    let mut steps = BTreeMap::new();
    steps.insert(Step::Attach, spec("echo attached {tag}", Some("attached t1"), 10));
    steps.insert(Step::Connect, spec("echo hello", None, 10));
    steps.insert(Step::AgentTurn, spec("echo PONG", Some("PONG"), 10));
    steps.insert(Step::Detach, spec("echo bye", None, 10));
    let profile = Profile { provider: "own:test".into(), about: String::new(), steps };
    let run = run_profile(&profile, &values(&[("tag", "t1")]), 1, &scratch("all"));
    assert_eq!(status(&run, Step::Attach), Status::Pass);
    assert_eq!(status(&run, Step::AgentTurn), Status::Pass);
    assert_eq!(status(&run, Step::Pause), Status::NotApplicable);
    assert_eq!(status(&run, Step::Resume), Status::NotApplicable);
    assert_eq!(status(&run, Step::Detach), Status::Pass);
    assert!(green(std::slice::from_ref(&run)));
    let text = table(&[run]);
    assert!(text.contains("| pause | n/a |"), "{text}");
    assert!(text.contains("| agent turn | 1/1 |"), "{text}");
}

#[test]
fn a_failed_step_skips_the_rest_but_detach_still_runs() {
    let dir = scratch("fail");
    let marker = dir.join("detached");
    let mut steps = BTreeMap::new();
    steps.insert(Step::Attach, spec("echo ok", None, 10));
    steps.insert(Step::Connect, spec("echo nope; exit 3", None, 10));
    steps.insert(Step::AgentTurn, spec("echo PONG", None, 10));
    steps.insert(Step::Detach, spec(&format!("touch {}", marker.display()), None, 10));
    let profile = Profile { provider: "own:test".into(), about: String::new(), steps };
    let run = run_profile(&profile, &BTreeMap::new(), 1, &dir);
    assert_eq!(status(&run, Step::Connect), Status::Fail);
    let detail = &run.steps.iter().find(|s| s.step == Step::Connect).unwrap().detail;
    assert!(detail.contains("nope"), "{detail}");
    assert_eq!(status(&run, Step::AgentTurn), Status::Skipped);
    assert_eq!(status(&run, Step::Detach), Status::Pass);
    assert!(marker.exists(), "detach must run after a failure");
    assert!(!green(&[run]));
}

#[test]
fn exit_zero_without_the_expected_text_fails() {
    let mut steps = BTreeMap::new();
    steps.insert(Step::AgentTurn, spec("echo something else", Some("PONG"), 10));
    let profile = Profile { provider: "own:test".into(), about: String::new(), steps };
    let run = run_profile(&profile, &BTreeMap::new(), 1, &scratch("expect"));
    assert_eq!(status(&run, Step::AgentTurn), Status::Fail);
}

#[test]
fn a_step_past_its_timeout_fails_and_is_ended() {
    let mut steps = BTreeMap::new();
    steps.insert(Step::Attach, spec("sleep 30", None, 1));
    let profile = Profile { provider: "own:test".into(), about: String::new(), steps };
    let started = std::time::Instant::now();
    let run = run_profile(&profile, &BTreeMap::new(), 1, &scratch("timeout"));
    assert!(started.elapsed() < std::time::Duration::from_secs(10));
    assert_eq!(status(&run, Step::Attach), Status::Fail);
    assert!(run.steps[0].detail.contains("timed out"), "{}", run.steps[0].detail);
}

#[test]
fn a_cloud_journey_maps_onto_the_six_steps() {
    let journey = serde_json::json!({
        "backend": "freestyle",
        "steps": [
            {"step": "create machine", "status": "pass", "ms": 900.4, "detail": ""},
            {"step": "running (status)", "status": "pass", "ms": 100.2, "detail": ""},
            {"step": "first exec", "status": "pass", "ms": 50, "detail": ""},
            {"step": "send chat", "status": "pass", "ms": 30, "detail": ""},
            {"step": "reply", "status": "pass", "ms": 2000, "detail": ""},
            {"step": "connect (carrier dial)", "status": "pass", "ms": 400, "detail": ""},
            {"step": "pause", "status": "fail", "ms": 5000, "detail": "409 busy"},
            {"step": "resume", "status": "skip", "ms": 0, "detail": "after pause failed"},
            {"step": "delete", "status": "pass", "ms": 700, "detail": ""}
        ]
    });
    let run = import_journey("freestyle:staging", &journey).unwrap();
    let ms = |step| run.steps.iter().find(|s| s.step == step).unwrap().ms;
    assert_eq!(status(&run, Step::Attach), Status::Pass);
    assert_eq!(ms(Step::Attach), 1001);
    assert_eq!(ms(Step::AgentTurn), 2030);
    assert_eq!(status(&run, Step::Pause), Status::Fail);
    assert_eq!(status(&run, Step::Resume), Status::Skipped);
    assert_eq!(status(&run, Step::Detach), Status::Pass);
    assert!(table(std::slice::from_ref(&run)).contains("409 busy"));
    assert!(!green(&[run]));
}

#[test]
fn a_journey_missing_a_step_says_which() {
    let journey =
        serde_json::json!({"steps": [{"step": "create machine", "status": "pass", "ms": 1}]});
    let run = import_journey("freestyle:staging", &journey).unwrap();
    assert_eq!(status(&run, Step::Attach), Status::Skipped);
    assert!(run.steps[0].detail.contains("running (status)"));
}

#[test]
fn the_shipped_profiles_parse() {
    let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("conformance");
    let mut seen = 0;
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().is_some_and(|e| e == "json") {
            let profile = Profile::load(&path).unwrap();
            assert!(profile.steps.contains_key(&Step::Detach), "{}: no detach", path.display());
            seen += 1;
        }
    }
    assert!(seen >= 1);
}
