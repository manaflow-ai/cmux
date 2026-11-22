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
