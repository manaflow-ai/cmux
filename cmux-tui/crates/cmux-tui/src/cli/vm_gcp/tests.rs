use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn provider_is_taken_out_wherever_it_is_typed_before_the_command() {
    assert_eq!(
        take_provider(&args(&["pause", "dev", "--provider", "gcp"])),
        (args(&["pause", "dev"]), Some("gcp".to_owned()))
    );
    assert_eq!(
        take_provider(&args(&["ls", "--provider=all"])),
        (args(&["ls"]), Some("all".to_owned()))
    );
    // After `--` it is the guest command's word.
    assert_eq!(
        take_provider(&args(&["exec", "dev", "--", "x", "--provider", "gcp"])),
        (args(&["exec", "dev", "--", "x", "--provider", "gcp"]), None)
    );
}

#[test]
fn provider_names() {
    assert_eq!(provider_of("gcp"), Some(Provider::Gcp));
    assert_eq!(provider_of("gce"), Some(Provider::Gcp));
    assert_eq!(provider_of("freestyle"), Some(Provider::Freestyle));
    assert_eq!(provider_of("all"), Some(Provider::All));
    assert_eq!(provider_of("aws"), None);
}

#[test]
fn freestyle_provider_gives_the_command_back_without_it() {
    let route =
        run_if_requested(&args(&["--json", "vm", "pause", "dev", "--provider", "freestyle"]));
    assert_eq!(route, Some(Route::Args(args(&["--json", "vm", "pause", "dev"]))));
}

#[test]
fn commands_without_a_provider_are_left_alone() {
    assert_eq!(run_if_requested(&args(&["vm", "pause", "dev"])), None);
    assert_eq!(run_if_requested(&args(&["workspace", "new"])), None);
    assert_eq!(run_if_requested(&args(&["machine", "new", "--provider", "gcp"])), None);
}

#[test]
fn parse_splits_flags_switches_positionals_and_the_command() {
    let words = parse(&args(&[
        "new",
        "--name",
        "a",
        "--size=small",
        "--label",
        "pool=lanes",
        "--label",
        "x=y",
        "--no-wait",
    ]))
    .unwrap();
    assert_eq!(words.verb, "new");
    assert_eq!(words.flag("--name"), Some("a"));
    assert_eq!(words.flag("--size"), Some("small"));
    assert_eq!(words.flags.get("--label").unwrap(), &args(&["pool=lanes", "x=y"]));
    assert!(words.has("--no-wait"));
    let words = parse(&args(&["exec", "gcp:us-west1-b/a", "--", "uname", "-a"])).unwrap();
    assert_eq!(words.positional, args(&["gcp:us-west1-b/a"]));
    assert_eq!(words.command, args(&["uname", "-a"]));
    assert!(parse(&args(&["new", "--zone"])).is_err());
}

#[test]
fn selectors_name_the_zone_when_they_carry_one() {
    assert_eq!(selector("gcp:us-west1-b/dev"), (Some("us-west1-b"), "dev"));
    assert_eq!(selector("us-west1-b/dev"), (Some("us-west1-b"), "dev"));
    assert_eq!(selector("dev"), (None, "dev"));
}

#[test]
fn gce_statuses_map_to_the_interface_states() {
    assert_eq!(state("RUNNING"), "running");
    assert_eq!(state("SUSPENDED"), "paused");
    assert_eq!(state("SUSPENDING"), "pausing");
    assert_eq!(state("TERMINATED"), "stopped");
    assert_eq!(state("STAGING"), "starting");
    assert_eq!(state("WHATEVER"), "unknown");
}

#[test]
fn names_follow_gce_rules() {
    assert!(valid_name("cmux-vm-1a2b3c4d"));
    assert!(!valid_name("Dev"));
    assert!(!valid_name("1dev"));
    assert!(!valid_name("dev-"));
    assert!(!valid_name(""));
    assert!(!valid_name(&"a".repeat(64)));
    assert!(valid_name(&fresh_name()));
    let fork = fork_name(&"b".repeat(60));
    assert!(valid_name(&fork), "{fork}");
}

#[test]
fn a_row_carries_what_the_scaler_reads() {
    let instance = json!({
        "name": "dev",
        "zone": "https://www.googleapis.com/compute/v1/projects/p/zones/us-west1-b",
        "machineType": "https://www.googleapis.com/compute/v1/projects/p/zones/us-west1-b/machineTypes/e2-standard-4",
        "status": "SUSPENDED",
        "creationTimestamp": "2026-11-20T01:00:00.000-08:00",
        "labels": {"cmux-vm": "true", "pool": "lanes"},
        "networkInterfaces": [{"networkIP": "10.0.0.2", "accessConfigs": [{"natIP": "34.1.2.3"}]}],
    });
    let row = row(&instance);
    assert_eq!(row["provider"], "gcp");
    assert_eq!(row["id"], "gcp:us-west1-b/dev");
    assert_eq!(row["state"], "paused");
    assert_eq!(row["provider_state"], "SUSPENDED");
    assert_eq!(row["zone"], "us-west1-b");
    assert_eq!(row["machine_type"], "e2-standard-4");
    assert_eq!(row["labels"]["pool"], "lanes");
    assert_eq!(row["internal_ip"], "10.0.0.2");
    assert_eq!(row["external_ip"], "34.1.2.3");
}

#[test]
fn freestyle_rows_come_from_the_app_and_the_vm_api_lists() {
    let app = json!({"result": {
        "machines": [{"machine_id": "m1", "title": "dev", "status": "running", "created_at": "2026-11-19T00:00:00Z"}],
        "creating": [{"name": "new-one", "status": "creating"}],
    }});
    let rows = freestyle_rows(&app);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0]["id"], "vm:m1");
    assert_eq!(rows[0]["name"], "dev");
    assert_eq!(rows[0]["state"], "running");
    assert_eq!(rows[1]["state"], "starting");
    let api =
        json!({"items": [{"id": "vm_1", "state": "paused", "createdAt": "2026-11-19T00:00:00Z"}]});
    let rows = freestyle_rows(&api);
    assert_eq!(rows[0]["provider"], "freestyle");
    assert_eq!(rows[0]["name"], "vm_1");
    assert_eq!(rows[0]["state"], "paused");
}

#[test]
fn the_table_lists_both_providers() {
    let rows = vec![
        json!({"name": "dev", "provider": "freestyle", "id": "vm:m1", "state": "running", "created_at": "2026-11-19T00:00:00Z"}),
        json!({"name": "gpu", "provider": "gcp", "id": "gcp:us-west1-b/gpu", "state": "paused", "created_at": "2026-11-20T01:00:00.000-08:00"}),
    ];
    let table = table(&rows);
    let lines: Vec<&str> = table.lines().collect();
    assert!(lines[0].starts_with("NAME"));
    assert!(lines[1].contains("freestyle") && lines[1].contains("2026-11-19"));
    assert!(lines[2].contains("gcp:us-west1-b/gpu") && lines[2].contains("paused"));
    assert!(super::table(&[]).starts_with("No VMs"));
}

#[test]
fn insert_body_takes_size_labels_and_startup_script() {
    let words = parse(&args(&["new", "--size", "small", "--label", "pool=lanes"])).unwrap();
    let body =
        insert_body("p", "us-west1-b", "dev", &words, Some("#!/bin/sh\n".to_owned())).unwrap();
    assert_eq!(body["machineType"], "zones/us-west1-b/machineTypes/e2-standard-2");
    assert_eq!(body["labels"]["cmux-vm"], "true");
    assert_eq!(body["labels"]["pool"], "lanes");
    assert_eq!(body["metadata"]["items"][0]["key"], "startup-script");
    assert_eq!(body["disks"][0]["initializeParams"]["diskSizeGb"], "50");
    let words = parse(&args(&["new", "--size", "huge"])).unwrap();
    assert!(insert_body("p", "z", "dev", &words, None).is_err());
    let words = parse(&args(&["new", "--label", "nolabel"])).unwrap();
    assert!(insert_body("p", "z", "dev", &words, None).is_err());
    let words =
        parse(&args(&["new", "--machine-type", "c4d-standard-8", "--size", "small"])).unwrap();
    let body = insert_body("p", "z", "dev", &words, None).unwrap();
    assert_eq!(body["machineType"], "zones/z/machineTypes/c4d-standard-8");
}

#[test]
fn shell_line_quotes_what_the_shell_would_split() {
    assert_eq!(shell_line(&args(&["uname", "-a"])), "uname -a");
    assert_eq!(shell_line(&args(&["echo", "a b", "it's"])), "echo 'a b' 'it'\\''s'");
    assert_eq!(shell_line(&args(&[""])), "''");
}

#[test]
fn gcloud_config_reads_project_and_zone() {
    let config = GcloudConfig::parse(
        "[core]\naccount = leo@cmux.com\nproject = manaflow-437420\n\n[compute]\nzone = us-west1-b\n",
    );
    assert_eq!(config.get("core", "project").as_deref(), Some("manaflow-437420"));
    assert_eq!(config.get("compute", "zone").as_deref(), Some("us-west1-b"));
    assert_eq!(config.get("compute", "region"), None);
}
