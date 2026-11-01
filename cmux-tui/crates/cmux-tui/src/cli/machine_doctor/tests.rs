use serde_json::json;

use super::*;

const ORIGIN: &str = "https://platform.example";

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|w| (*w).to_owned()).collect()
}

fn entry(heartbeat_ago_ms: u64, now: u64) -> Value {
    json!({
        "machineId": "m_1",
        "label": "lane-vm-3",
        "lastHeartbeat": now - heartbeat_ago_ms,
        "revoked": false,
        "meshPeerId": "inst_1",
    })
}

fn state<'a>(steps: &'a [JoinStep], name: &str) -> &'a JoinStep {
    steps.iter().find(|s| s.step == name).unwrap_or_else(|| panic!("no {name} in {steps:?}"))
}

fn names(steps: &[JoinStep]) -> Vec<&str> {
    steps.iter().map(|s| s.step).collect()
}

#[test]
fn doctor_with_no_machine_is_this_machine_and_other_flags_are_the_apps() {
    let here = parse(&strings(&["machine", "doctor"])).unwrap().unwrap();
    assert_eq!(here.machine, None);
    assert!(!here.fix);
    let remote = parse(&strings(&[
        "machine",
        "doctor",
        "lane-vm-3",
        "--fix",
        "--platform=https://p.example",
    ]))
    .unwrap()
    .unwrap();
    assert_eq!(remote.machine.as_deref(), Some("lane-vm-3"));
    assert!(remote.fix);
    assert_eq!(remote.auth.platform.as_deref(), Some("https://p.example"));
    assert!(parse(&strings(&["machine", "doctor", "mini-7", "--harness", "claude"])).is_none());
    assert!(parse(&strings(&["machine", "doctor", "a", "b"])).is_none());
    assert!(parse(&strings(&["machine", "add"])).is_none());
    assert!(parse(&strings(&["machine", "doctor", "--platform"])).unwrap().is_err());
}

#[test]
fn a_healthy_joined_machine_is_all_ok() {
    let now = machine_join::now_ms();
    let checked = remote_steps(
        ORIGIN,
        "lane-vm-3",
        Some(Ok(vec![entry(5_000, now)])),
        Some(Ok(vec!["inst_0".into(), "inst_1".into()])),
        now,
    );
    assert_eq!(names(&checked), ["signed-in", "platform", "listed", "heartbeat", "mesh"]);
    assert!(checked.iter().all(|s| s.state == StepState::Ok), "{checked:?}");
    assert_eq!(state(&checked, "listed").detail, "listed as m_1");
}

#[test]
fn no_sign_in_and_a_refused_sign_in_fail_signed_in() {
    for list in [None, Some(Err(CallError::Status { status: 401, code: "auth.unauthenticated" }))] {
        let checked = remote_steps(ORIGIN, "lane-vm-3", list, None, 0);
        let signed_in = state(&checked, "signed-in");
        assert_eq!(signed_in.state, StepState::Fail);
        assert_eq!(signed_in.fix.as_deref(), Some("Sign in in cmux, or pass --cloud-token-file"));
        for later in ["platform", "listed", "heartbeat", "mesh"] {
            assert_eq!(state(&checked, later).state, StepState::Skip, "{later}");
        }
    }
}

#[test]
fn a_platform_with_joining_off_points_at_development() {
    let off = Some(Err(CallError::Status { status: 404, code: "machine.not_found" }));
    let checked = remote_steps(ORIGIN, "lane-vm-3", off, None, 0);
    let platform = state(&checked, "platform");
    assert_eq!(platform.state, StepState::Fail);
    assert_eq!(platform.detail, "joining is off on https://platform.example");
    assert_eq!(
        platform.fix.as_deref(),
        Some(
            "Point at development: --platform https://cmux-platform-development.debussy.workers.dev"
        )
    );
    let down = Some(Err(CallError::Unreachable("connection refused".into())));
    let checked = remote_steps(ORIGIN, "lane-vm-3", down, None, 0);
    assert_eq!(
        state(&checked, "platform").detail,
        "https://platform.example did not list the machines (no answer)"
    );
}

#[test]
fn an_unlisted_or_revoked_machine_fails_listed_with_the_machine_add_fix() {
    let now = machine_join::now_ms();
    let mut revoked = entry(5_000, now);
    revoked["revoked"] = json!(true);
    for (entries, detail) in [
        (vec![], "no joined machine has that id or name (cmux machine list shows them)"),
        (vec![revoked], "lane-vm-3 is revoked"),
    ] {
        let checked = remote_steps(ORIGIN, "lane-vm-3", Some(Ok(entries)), None, now);
        let listed = state(&checked, "listed");
        assert_eq!(listed.state, StepState::Fail);
        assert_eq!(listed.detail, detail);
        assert_eq!(
            listed.fix.as_deref(),
            Some("Not joined (or revoked): cmux machine add --name lane-vm-3")
        );
        assert_eq!(state(&checked, "heartbeat").state, StepState::Skip);
    }
}

#[test]
fn a_stale_heartbeat_and_a_missing_mesh_daemon_fail_with_the_joined_end_fix() {
    let now = machine_join::now_ms();
    let checked = remote_steps(
        ORIGIN,
        "lane-vm-3",
        Some(Ok(vec![entry(10 * 60_000, now)])),
        Some(Ok(vec!["inst_0".into()])),
        now,
    );
    let heartbeat = state(&checked, "heartbeat");
    assert_eq!(heartbeat.state, StepState::Fail);
    assert_eq!(heartbeat.detail, "last heartbeat 10 min ago");
    let fix = "Run cmux machine doctor (or acpmux host doctor --here) on lane-vm-3";
    assert_eq!(heartbeat.fix.as_deref(), Some(fix));
    let mesh = state(&checked, "mesh");
    assert_eq!(mesh.state, StepState::Fail);
    assert_eq!(mesh.fix.as_deref(), Some(fix));
    let mut never = entry(0, now);
    never["lastHeartbeat"] = Value::Null;
    let checked = remote_steps(ORIGIN, "lane-vm-3", Some(Ok(vec![never])), None, now);
    assert_eq!(state(&checked, "heartbeat").detail, "no heartbeat yet");
}

#[test]
fn the_mesh_step_degrades_without_a_mesh_id_or_a_mesh() {
    let now = machine_join::now_ms();
    let mut no_peer = entry(5_000, now);
    no_peer.as_object_mut().unwrap().remove("meshPeerId");
    let checked = remote_steps(ORIGIN, "m_1", Some(Ok(vec![no_peer])), None, now);
    assert_eq!(state(&checked, "mesh").state, StepState::Skip);
    let off = Some(Err(CallError::Status { status: 404, code: "" }));
    let checked = remote_steps(ORIGIN, "m_1", Some(Ok(vec![entry(5_000, now)])), off, now);
    let mesh = state(&checked, "mesh");
    assert_eq!(mesh.state, StepState::Fail, "a mesh that is off fails the check");
    assert_eq!(
        mesh.fix.as_deref(),
        Some("Run cmux machine doctor (or acpmux host doctor --here) on lane-vm-3")
    );
    let (text, ok) = doctor::render("lane-vm-3", "joined machine", &checked, Print::Lines);
    assert!(!ok);
    let lines: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(lines.last().unwrap()["report"]["ok"], false);
    let down = Some(Err(CallError::Unreachable("connect refused".into())));
    let checked = remote_steps(ORIGIN, "m_1", Some(Ok(vec![entry(5_000, now)])), down, now);
    assert_eq!(state(&checked, "mesh").state, StepState::Fail);
}

#[test]
fn an_unread_joined_list_is_named_when_the_ssh_check_runs_instead() {
    assert_eq!(unread(Some(&Ok(vec![]))), None);
    assert!(unread(None).unwrap().starts_with("not signed in"));
    let off = Err(CallError::Status { status: 404, code: "" });
    assert!(unread(Some(&off)).unwrap().contains("isn't available"));
    let denied = Err(CallError::Status { status: 401, code: "" });
    assert_eq!(unread(Some(&denied)).unwrap(), "the platform answered 401");
    let down = Err(CallError::Unreachable("tcp".into()));
    assert_eq!(unread(Some(&down)).unwrap(), "the platform did not answer");
    let note = fallback_note(OutputMode::Human, "build-box", Some(&down)).unwrap();
    assert_eq!(
        note,
        "cmux machine doctor: build-box was checked as an ssh machine; joined machines were not \
         checked (the platform did not answer)"
    );
    assert!(fallback_note(OutputMode::Json, "build-box", None).is_some());
    assert_eq!(fallback_note(OutputMode::Quiet, "build-box", None), None, "quiet prints nothing");
    assert_eq!(fallback_note(OutputMode::Human, "build-box", Some(&Ok(vec![]))), None);
}

#[test]
fn fixes_name_the_listed_machine_and_never_echo_a_secret_key() {
    let now = machine_join::now_ms();
    let mut revoked = entry(5_000, now);
    revoked["revoked"] = json!(true);
    let checked = remote_steps(ORIGIN, "m_1", Some(Ok(vec![revoked])), None, now);
    assert_eq!(
        state(&checked, "listed").fix.as_deref(),
        Some("Not joined (or revoked): cmux machine add --name lane-vm-3")
    );
    for key in ["cmj_0123456789abcdefghij", "cmm_secret", "a b; rm -rf ~", "x\u{1b}[2J"] {
        let checked = remote_steps(ORIGIN, key, Some(Ok(vec![])), None, now);
        let text = format!("{checked:?}");
        assert!(
            !text.contains("cmj_") && !text.contains("cmm_") && !text.contains("rm -rf"),
            "{text}"
        );
        assert_eq!(
            state(&checked, "listed").fix.as_deref(),
            Some("Not joined (or revoked): cmux machine add --name NAME")
        );
    }
}
