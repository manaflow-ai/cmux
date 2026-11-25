use super::*;

fn words(line: &str) -> Vec<String> {
    line.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn spill_options_leave_the_rest_to_remote_exec() {
    let parsed =
        parse_spill_args(&words("box --timings --state-dir /s -- cargo test --here")).unwrap();
    assert_eq!(parsed.force, Override::None);
    assert!(parsed.timings);
    assert_eq!(parsed.exec.connect, words("box --state-dir /s"));
    // Words after `--` are the command's, even ones that look like spill options.
    assert_eq!(parsed.exec.argv, words("cargo test --here"));
}

#[test]
fn here_and_to_override_and_to_names_the_route() {
    let here = parse_spill_args(&words("box --here -- make")).unwrap();
    assert_eq!(here.force, Override::Here);
    let to = parse_spill_args(&words("--to other --carrier -- make")).unwrap();
    assert_eq!(to.force, Override::To("other".into()));
    assert_eq!(to.exec.connect, words("other --carrier"));
    assert!(parse_spill_args(&words("--here --to x -- make")).is_err());
    assert!(parse_spill_args(&words("box --to x -- make")).is_err());
    assert!(parse_spill_args(&words("--to -- make")).is_err());
}

#[test]
fn the_place_is_named_by_its_route_or_machine() {
    assert_eq!(place_name(&words("--state-dir /s ws://h/v1/link --carrier")), "ws://h/v1/link");
    assert_eq!(place_name(&words("--via-machine cloud-a")), "cloud-a");
}

#[test]
fn the_timings_line_carries_spill_start_ms_and_the_reason_as_data() {
    let decision = Decision {
        placement: Placement::There("box".into()),
        reason: Reason::OverBudget { level: Level::Warning, over: vec!["ram".into()] },
    };
    let mut phases = Map::new();
    phases.insert("connect".into(), json!(3));
    let line = timings_line(&decision, Some(42), phases, json!(7), 50, None);
    assert_eq!(line["spill_start_ms"], 42);
    assert_eq!(line["placement"], json!({"at": "there", "place": "box"}));
    assert_eq!(line["reason"]["code"], "over_budget");
    assert_eq!(line["phases"]["connect"], 3);
    assert_eq!(line["exit"], 7);
    let here = Decision { placement: Placement::Here, reason: Reason::AskedHere };
    assert!(timings_line(&here, None, Map::new(), json!(0), 1, None)["spill_start_ms"].is_null());
}

#[test]
fn no_route_or_route_cloud_is_the_cloud_place() {
    assert!(spill_cloud::is_cloud(&[], None));
    assert!(spill_cloud::is_cloud(&words("cloud"), Some("cloud")));
    assert!(spill_cloud::is_cloud(&words("cloud:build"), Some("cloud:build")));
    assert!(!spill_cloud::is_cloud(&words("box"), Some("box")));
    // `--via-machine` with no ROUTE is still that machine, not the Cloud one.
    assert!(!spill_cloud::is_cloud(&words("--via-machine mac"), None));
    let to = parse_spill_args(&words("--to cloud -- make")).unwrap();
    assert_eq!(to.force, Override::To("cloud".into()));
    assert_eq!(to.exec.connect, words("cloud"));
}

fn row(id: &str, status: &str, daemon: &str) -> Value {
    json!({"id": id, "title": format!("{id}-title"), "team": "team_a", "status": status, "daemon": daemon})
}

#[test]
fn the_cloud_machine_is_the_connected_one_then_the_running_one() {
    use spill_cloud::{Miss, pick};
    let rows = vec![
        row("vm-gone", "destroyed", "connected"),
        row("vm-run", "running", "disconnected"),
        row("vm-live", "running", "connected"),
    ];
    let chosen = pick(Some(&rows), None).unwrap();
    assert_eq!(chosen.id, "vm-live");
    assert_eq!(chosen.title, "vm-live-title");
    assert_eq!(chosen.team.as_deref(), Some("team_a"));
    assert_eq!(pick(Some(&rows[..2]), None).unwrap().id, "vm-run");
    assert_eq!(pick(Some(&rows), Some("cloud:vm-run")).unwrap().id, "vm-run");
    assert_eq!(pick(Some(&rows), Some("cloud:vm-run-title")).unwrap().id, "vm-run");
    // A destroyed machine is never picked, even by name.
    assert_eq!(pick(Some(&rows), Some("cloud:vm-gone")), Err(Miss::NotFound("vm-gone".into())));
}

#[test]
fn each_cloud_miss_names_the_one_step_that_enables_spilling() {
    use spill_cloud::{Miss, pick, token_miss};
    assert_eq!(pick(None, None), Err(Miss::NoApp));
    assert_eq!(pick(Some(&[]), None), Err(Miss::NoMachine));
    assert_eq!(pick(Some(&[row("vm-gone", "destroyed", "")]), None), Err(Miss::NoMachine));
    let asleep = pick(Some(&[row("vm-nap", "paused", "disconnected")]), None).unwrap_err();
    assert_eq!(asleep, Miss::Asleep("vm-nap".into()));
    assert_eq!(asleep.step(), "start your Cloud machine: cmux vm resume vm-nap");
    assert_eq!(Miss::NoMachine.step(), "make a Cloud machine: cmux vm new");
    assert_eq!(token_miss("not_signed_in"), Miss::NotSignedIn);
    assert_eq!(token_miss("app.unreachable"), Miss::NoApp);
    assert_eq!(Miss::NoApp.step(), "open the cmux app and sign in");
    assert_eq!(Miss::NotSignedIn.step(), "sign in to cmux in the app");
}
