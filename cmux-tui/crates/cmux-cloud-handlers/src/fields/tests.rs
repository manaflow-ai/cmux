//! The cases of the Swift tests these fields came from (CloudNewMachineTests, CloudIdlePauseTests,
//! CloudMachineCostTests, CloudListMachinesTests, CloudTerminalTests, CloudMachineConfigTests).

use super::*;

fn machine(value: Value) -> Machine {
    serde_json::from_value(value).unwrap()
}

fn lane_request() -> NewMachine {
    NewMachine {
        name: Some("lane-vm-3".into()),
        size: Some("medium".into()),
        memory_mb: Some(8192),
        persistent: true,
        bootstrap_path: Some("/tmp/lane-vm-bootstrap".into()),
        bootstrap_kind: BootstrapKind::Lane,
        ..NewMachine::default()
    }
}

#[test]
fn machine_fields_name_the_target_over_extra() {
    let fields = machine_fields("vm-1", object(json!({"name": "box", "machine_id": "other"})));
    assert_eq!(
        Value::Object(fields),
        json!({"name": "box", "machine_id": "vm-1", "target": "machine:vm-1"})
    );
    assert_eq!(
        Value::Object(deletion_pending("vm-1")),
        json!({"machine_id": "vm-1", "target": "machine:vm-1", "pending": true, "status": "deleting"})
    );
}

#[test]
fn a_paused_terminal_pending_says_it_resumes() {
    assert_eq!(
        Value::Object(terminal_pending("vm-1", true)),
        json!({"machine_id": "vm-1", "resuming": true})
    );
    assert_eq!(Value::Object(terminal_pending("vm-1", false)), json!({"machine_id": "vm-1"}));
    assert_eq!(
        Value::Object(terminal_fields("7", Some("term_1"))),
        json!({"surface_id": "7", "terminal_id": "term_1"})
    );
    assert_eq!(Value::Object(terminal_fields("7", None)), json!({"surface_id": "7"}));
}

#[test]
fn the_answer_says_persistent_only_when_the_server_stored_off() {
    let request = NewMachine {
        name: Some("lane-vm-1".into()),
        size: Some("medium".into()),
        memory_mb: Some(8192),
        persistent: true,
        ..NewMachine::default()
    };
    let stored = machine(
        json!({"id": "vm-1", "status": "running", "idlePauseMinutes": 0, "ipv4": "10.0.0.7"}),
    );
    let fields = new_machine(&request, Some(&stored));
    assert_eq!(fields["persistent"], json!(true));
    assert_eq!(fields["idle_pause_minutes"], json!(0));
    assert_eq!(fields["cpu"], json!(4));
    assert_eq!(fields["memory_mb"], json!(8192));
    assert_eq!(fields["address"], json!("10.0.0.7"));
    assert_eq!(fields["name"], json!("lane-vm-1"));
    let not_stored = machine(json!({"id": "vm-2", "status": "running", "idlePauseMinutes": 30}));
    assert_eq!(new_machine(&request, Some(&not_stored))["persistent"], json!(false));
    let pending = new_machine(&request, None);
    assert!(!pending.contains_key("persistent"), "no machine yet: nothing stored to report");
    assert_eq!(pending["persistent_requested"], json!(true));
    assert_eq!(pending["memory_mb"], json!(8192));
}

#[test]
fn a_create_size_says_the_vcpus_the_server_ladder_gives() {
    let request = NewMachine {
        size: Some("xlarge".into()),
        memory_mb: Some(24_576),
        ..NewMachine::default()
    };
    assert_eq!(
        new_machine(&request, None)["cpu"],
        json!(12),
        "24 GiB is the 12 vCPU row, not resize's 16"
    );
    let server = machine(
        json!({"id": "vm-1", "sizeName": "large", "cpu": 8, "memoryMb": 16384, "displayName": "box"}),
    );
    let fields = new_machine(&NewMachine::default(), Some(&server));
    assert_eq!(
        (fields["size"].clone(), fields["cpu"].clone(), fields["name"].clone()),
        (json!("large"), json!(8), json!("box"))
    );
}

#[test]
fn a_lane_answer_names_the_registry_command() {
    let made = machine(
        json!({"id": "vm-3", "status": "running", "ipv4": "10.0.0.9", "idlePauseMinutes": 0}),
    );
    let answer = enrollment(&lane_request(), &made);
    assert_eq!(
        answer["registry_command"],
        json!("tools/lane-vm-enroll lane-vm-3 vm-3 --address 10.0.0.9 --apply")
    );
    assert_eq!(answer["pending"], json!(["fleet-registry"]));
    assert!(
        !answer.contains_key("enroll_command"),
        "no enroll-machine: the carrier reaches the machine"
    );
    assert!(!enrollment(&NewMachine::default(), &made).contains_key("registry_command"));
}

#[test]
fn a_persistent_machine_the_server_still_pauses_says_how_to_finish() {
    let made = machine(json!({"id": "vm-3", "idlePauseMinutes": 30}));
    assert_eq!(
        enrollment(&lane_request(), &made)["pending"],
        json!([
            "idle-pause: cmux cloud set-idle-pause --target machine:vm-3 --minutes off",
            "fleet-registry"
        ])
    );
}

#[test]
fn the_created_answer_carries_bootstrap_repo_and_machine_config() {
    let made: Created = serde_json::from_value(json!({
        "machine": {"id": "vm-3", "title": "lane-vm-3", "status": "running", "idlePauseMinutes": 0},
        "workspaceId": "ws-1", "scriptKind": "lane",
        "bootstrap": {"status": "started", "statusFile": "/b/status.json", "log": "/b/log"},
        "machineConfig": {"status": "failed", "reason": "bad toml", "statusFile": "/c/status.json", "log": "/c/log"},
    }))
    .unwrap();
    let request = NewMachine {
        repo: Some(crate::repo::parse("manaflow-ai/cmux").unwrap()),
        machine_config_path: Some("/Users/me/m.toml".into()),
        ..lane_request()
    };
    let fields = created(&request, &made);
    assert_eq!(fields["machine_id"], json!("vm-3"));
    assert_eq!(fields["workspace_id"], json!("ws-1"));
    assert_eq!(fields["target"], json!("machine:vm-3"));
    let check = "cmux cloud file-read --target machine:vm-3 --path /b/status.json";
    assert_eq!(
        fields["bootstrap"],
        json!({"status": "started", "kind": "lane", "log": "/b/log", "status_file": "/b/status.json", "check": check})
    );
    assert_eq!(
        fields["repo"],
        json!({"spec": "manaflow-ai/cmux", "url": "https://github.com/manaflow-ai/cmux.git", "dir": "~/work/cmux", "check": check})
    );
    assert_eq!(
        fields["machine_config"],
        json!({"status": "failed", "reason": "bad toml", "status_file": "/c/status.json", "log": "/c/log",
               "check": "cmux cloud file-read --target machine:vm-3 --path /c/status.json"})
    );
    assert_eq!(
        fields["enrollment"]["registry_command"],
        json!("tools/lane-vm-enroll lane-vm-3 vm-3 --apply")
    );
}

#[test]
fn a_create_with_no_script_says_none() {
    let made: Created = serde_json::from_value(json!({
        "machine": {"id": "vm-4", "title": "t", "status": "running"},
        // A config outcome the request never asked for is not answered.
        "machineConfig": {"status": "applied", "statusFile": "/c/status.json", "log": "/c/log"},
    }))
    .unwrap();
    let request =
        NewMachine { repo: Some(crate::repo::parse("a/b").unwrap()), ..NewMachine::default() };
    let fields = created(&request, &made);
    assert_eq!(fields["bootstrap"], json!({"status": "none"}));
    assert_eq!(fields["repo"]["check"], json!("none"));
    assert_eq!(fields["repo"]["url"], json!("https://github.com/a/b.git"));
    assert!(!fields.contains_key("machine_config"));
    assert!(!created(&NewMachine::default(), &made).contains_key("repo"));
}

#[test]
fn a_template_is_named_after_the_machine_and_the_time() {
    assert_eq!(
        template_name("vm-0123456789abcdef", 1_700_000_000),
        "template-vm-012345678-1700000000"
    );
    assert_eq!(template_name("vm-1", 5), "template-vm-1-5");
}

#[test]
fn the_handoff_names_the_attach_and_inspect_verbs() {
    assert_eq!(
        handoff("box", "vm-1", "", "running"),
        "box (vm-1)\nprovider: ?\nstatus: running\nattach: cmux cloud new-terminal-on-machine --target machine:vm-1\ninspect: cmux cloud machine-status --target machine:vm-1"
    );
}

fn idle() -> IdlePause {
    serde_json::from_value(json!({"minutes": 30, "lastCheckedAt": 1_700_000_000_000_i64, "idleSince": 1_699_998_000_000_i64,
        "lastApiActivityAt": 1_699_999_000_000_i64, "privateAddressKnown": true,
        "lastDecision": {"at": 1_700_000_000_000_i64, "outcome": "idle", "reason": "idle",
                         "run": {"checked": 8, "elapsedMs": 120}}}))
    .unwrap()
}

#[test]
fn idle_pause_diagnostics_nest_as_the_record_has_them() {
    let fields = idle_pause_fields(&idle());
    assert_eq!(fields["minutes"], json!(30));
    assert_eq!(fields["private_address_known"], json!(true));
    assert_eq!(fields["last_checked_at"], json!(1_700_000_000_000_i64));
    assert_eq!(fields["last_decision"]["run"], json!({"checked": 8, "elapsed_ms": 120}));
    let none = idle_pause_fields(&IdlePause::default());
    assert_eq!(none["last_decision"], Value::Null);
    assert_eq!(none["idle_since"], Value::Null);
}

#[test]
fn machine_status_prints_why_the_machine_failed_and_its_idle_pause() {
    let status: Status = serde_json::from_value(json!({
        "machineId": "vm-failed", "title": "box", "status": "failed", "state": "failed",
        "failure": {"code": "cloud.provider.unavailable", "message": "VM API: HTTP 503"},
    }))
    .unwrap();
    let fields = status_fields(&status);
    assert_eq!(
        fields["error"],
        json!({"code": "cloud.provider.unavailable", "message": "VM API: HTTP 503"})
    );
    assert_eq!(fields["desktop"], json!(false));
    assert!(describe(&status).contains("error: cloud.provider.unavailable: VM API: HTTP 503"));
    let healthy = Status { idle_pause: Some(idle()), ..Status::default() };
    assert!(!status_fields(&healthy).contains_key("error"));
    let text = describe(&healthy);
    assert!(text.contains("idle pause: 30 minutes"));
    assert!(text.contains(
        "idle pause decision: idle (idle) at 1700000000000; run checked=8, elapsed_ms=120"
    ));
    assert!(
        describe(&Status { idle_pause: Some(IdlePause::default()), ..Status::default() })
            .contains("idle pause decision: null")
    );
}

#[test]
fn machine_status_text_rounds_like_the_app() {
    let status: Status = serde_json::from_value(json!({
        "machineId": "vm-1", "title": "box", "status": "running", "state": "running", "cpus": 4, "cpuPercent": 12.6,
        "memoryUsedMb": 1023.5, "memoryTotalMb": 8192.0, "diskUsedMb": 1.0, "diskTotalMb": 2.0, "ipv4": "10.0.0.7",
        "cost": {"usage": "$0.59 so far"},
    }))
    .unwrap();
    assert_eq!(
        describe(&status),
        "box (vm-1)\nstate: running, status: running\ncpus: 4, 13%\nmemory: 1024 / 8192 MB\ndisk: 1 / 2 MB\naddress: 10.0.0.7\n$0.59 so far"
    );
    let fields = status_fields(&status);
    assert_eq!(fields["cpu_percent"], json!(12.6));
    assert_eq!(fields["address"], json!("10.0.0.7"));
}

#[test]
fn machine_status_fields_carry_the_cost() {
    let cost = Cost {
        hourly_rate_usd: Some(0.2645),
        running_since: Some(1_700_000_000.5),
        estimated_cost_usd: Some(0.590_710_9),
        usage: None,
    };
    let fields = cost_fields(&cost);
    assert_eq!(fields["hourly_rate_usd"], json!(0.2645));
    assert_eq!(fields["running_since"], json!("2023-11-14T22:13:20Z"));
    assert_eq!(fields["estimated_cost_usd"], json!(0.5907));
    let paused = cost_fields(&Cost { hourly_rate_usd: Some(0.2645), ..Cost::default() });
    assert!(!paused.contains_key("running_since") && !paused.contains_key("estimated_cost_usd"));
}

#[test]
fn a_list_not_loaded_has_no_machines_but_keeps_creations() {
    let list: MachineList = serde_json::from_value(json!({
        "loaded": false, "signedIn": true,
        "machines": [{"machineId": "vm-1", "title": "box", "status": "running"}],
        "creating": [{"creationId": "c-1", "name": "lane-vm-1"}, {"creationId": "c-2", "failed": "plan cap"}],
    }))
    .unwrap();
    let fields = machine_list(&list);
    assert_eq!(fields["machines"], json!([]));
    assert_eq!(fields["count"], json!(0));
    assert_eq!(
        fields["creating"],
        json!([{"creation_id": "c-1", "name": "lane-vm-1", "status": "creating"},
               {"creation_id": "c-2", "name": null, "status": "failed", "reason": "plan cap"}])
    );
    assert_eq!(fields["account"], json!({"signed_in": true}));
}

#[test]
fn a_loaded_list_names_each_machine_its_target_and_owner() {
    let list: MachineList = serde_json::from_value(json!({
        "loaded": true, "team": true, "signedIn": true,
        "machines": [{"machineId": "vm-1", "title": "box", "status": "paused", "createdBy": "u-1", "createdAt": 1_700_000_000.0,
                      "failure": {"code": "c", "message": "m"}},
                     {"machineId": "vm-2", "title": "two", "status": "running"}],
    }))
    .unwrap();
    let fields = machine_list(&list);
    assert_eq!(fields["count"], json!(2));
    assert_eq!(
        fields["machines"][0],
        json!({"machine_id": "vm-1", "target": "machine:vm-1", "title": "box", "status": "paused", "owner": "team",
               "created_by": "u-1", "created_at": "2023-11-14T22:13:20Z", "error": {"code": "c", "message": "m"}})
    );
    assert_eq!(fields["machines"][1]["created_at"], Value::Null);
    assert_eq!(fields["machines"][1]["error"], Value::Null);
}
