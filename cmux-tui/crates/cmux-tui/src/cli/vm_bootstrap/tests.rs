//! Headless `cmux vm new`: the create words it makes, and a fake VM driving the bootstrap plan.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use super::*;

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

#[derive(Debug, PartialEq, Eq)]
enum Call {
    Write { path: String, bytes: Vec<u8>, mode: u32 },
    Exec(String),
}

/// A VM that answers each exec with the next queued answer (`started` once the queue is empty).
#[derive(Default)]
struct FakeGuest {
    calls: Vec<Call>,
    answers: VecDeque<Result<ExecAnswer, String>>,
    pauses: u32,
}

fn said(stdout: &str) -> Result<ExecAnswer, String> {
    Ok(ExecAnswer { exit_code: 0, stdout: stdout.to_owned(), stderr: String::new() })
}

impl Guest for FakeGuest {
    fn write(&mut self, path: &str, bytes: &[u8], mode: u32) -> Result<(), String> {
        self.calls.push(Call::Write { path: path.to_owned(), bytes: bytes.to_vec(), mode });
        Ok(())
    }

    fn exec(&mut self, command: &str) -> Result<ExecAnswer, String> {
        self.calls.push(Call::Exec(command.to_owned()));
        self.answers.pop_front().unwrap_or_else(|| said("started\n"))
    }

    fn pause(&mut self, _: Duration) {
        self.pauses += 1;
    }
}

#[test]
fn size_and_persistent_become_vm_api_create_words() {
    let parsed =
        parse(&words(&["--name", "lane-1", "--size", "large", "--persistent"]), "/h").unwrap();
    assert_eq!(
        parsed.create,
        words(&[
            "--name",
            "lane-1",
            "--vcpus",
            "8",
            "--memory-mib",
            "16384",
            "--idle-timeout",
            "-1"
        ])
    );
    assert!(!parsed.runs_after_create());
    assert_eq!(parsed.name.as_deref(), Some("lane-1"));
    assert!(parse(&words(&["--size", "huge"]), "/h").is_err());
    assert!(parse(&words(&["--persistent", "--idle-timeout", "60"]), "/h").is_err());
    // VM API words pass through untouched.
    let plain = parse(&words(&["--snapshot", "snap_1", "--public-egress"]), "/h").unwrap();
    assert_eq!(plain.create, words(&["--snapshot", "snap_1", "--public-egress"]));
}

#[test]
fn a_lane_bootstrap_needs_its_script_and_a_name() {
    let parsed = parse(
        &words(&[
            "--name=lane-2",
            "--bootstrap",
            "lane",
            "--bootstrap-script",
            "~/b.sh",
            "--machine-config",
            "m.toml",
            "--wait",
            "--timeout",
            "90",
        ]),
        "/home/me",
    )
    .unwrap();
    assert_eq!(parsed.bootstrap, Some((Kind::Lane, PathBuf::from("/home/me/b.sh"))));
    assert_eq!(parsed.machine_config, Some(PathBuf::from("m.toml")));
    assert!(parsed.wait && parsed.runs_after_create());
    assert_eq!(parsed.timeout, Duration::from_secs(90));
    assert_eq!(parsed.create, words(&["--name=lane-2"]));
    assert!(parse(&words(&["--bootstrap", "lane", "--name", "x"]), "/h").is_err());
    assert!(parse(&words(&["--bootstrap", "lane", "--bootstrap-script", "b"]), "/h").is_err());
    assert!(parse(&words(&["--bootstrap", "other", "--bootstrap-script", "b"]), "/h").is_err());
    assert!(parse(&words(&["--repo", "o/n"]), "/h").is_err());
    let plain = parse(&words(&["--bootstrap-script", "b.sh"]), "/h").unwrap();
    assert_eq!(plain.bootstrap, Some((Kind::Plain, PathBuf::from("b.sh"))));
}

/// The fake VM gets `start_plan`'s writes and execs in its order, the script as the payload, and
/// the start's last line decides the outcome.
#[test]
fn a_start_makes_the_plans_writes_and_execs_in_order() {
    let plan = machine_bootstrap::start_plan(&StartRequest {
        kind: Kind::Lane,
        name: Some("lane-3".into()),
        repo: None,
        start_id: "ab12".into(),
    });
    let mut guest = FakeGuest::default();
    guest.answers.push_back(said(""));
    guest.answers.push_back(said("started\n"));
    let outcome = run_plan(&mut guest, &plan, Some(b"#!/bin/sh\necho lane\n"), None);
    assert_eq!(outcome, Outcome { status: "started".into(), reason: None });
    assert_eq!(guest.calls.len(), plan.steps.len());
    for (call, step) in guest.calls.iter().zip(&plan.steps) {
        match (call, step) {
            (Call::Exec(ran), Step::Exec { command, .. }) => assert_eq!(ran, command),
            (Call::Write { path, bytes, mode }, Step::Write { path: p, mode: m, text, .. }) => {
                assert_eq!((path, mode), (p, m));
                let want = text.as_deref().map_or(&b"#!/bin/sh\necho lane\n"[..], str::as_bytes);
                assert_eq!(bytes, want);
            }
            other => panic!("call and step differ: {other:?}"),
        }
    }
    let env = guest.calls.iter().find_map(|call| match call {
        Call::Write { path, bytes, .. } if path.ends_with("/env") => Some(bytes.clone()),
        _ => None,
    });
    assert!(String::from_utf8(env.unwrap()).unwrap().contains("LANE_VM_NAME='lane-3'"));

    // A failed prepare stops the plan there with its words.
    let mut failing = FakeGuest::default();
    failing.answers.push_back(Ok(ExecAnswer {
        exit_code: 1,
        stdout: String::new(),
        stderr: "no sudo".into(),
    }));
    let outcome = run_plan(&mut failing, &plan, Some(b"x"), None);
    assert_eq!(outcome.status, "failed");
    assert_eq!(outcome.reason.as_deref(), Some("no sudo"));
    assert_eq!(failing.calls.len(), 1);
}

#[test]
fn the_wait_reads_until_the_run_ends() {
    let mut guest = FakeGuest::default();
    guest.answers.push_back(said("cmux-wait held 100\n"));
    guest.answers.push_back(Err("timed out".into()));
    guest
        .answers
        .push_back(said("cmux-wait free 120\n{\"state\":\"done\",\"exit_code\":0,\"at\":119}\n"));
    let far = Instant::now() + Duration::from_secs(3600);
    assert_eq!(wait_run(&mut guest, far), Run::Finished { repo_path: None });
    assert_eq!(guest.calls.len(), 3);
    assert!(guest.calls.iter().all(|call| *call == Call::Exec(machine_bootstrap::wait_command())));

    let mut failed = FakeGuest::default();
    failed.answers.push_back(said(
        "cmux-wait free 120\n{\"state\":\"failed\",\"exit_code\":7,\"step\":\"script\",\"at\":119}\n",
    ));
    assert_eq!(wait_run(&mut failed, far), Run::ScriptFailed { exit_code: 7 });

    let mut gone = FakeGuest::default();
    for _ in 0..3 {
        gone.answers.push_back(Err("unreachable".into()));
    }
    assert_eq!(wait_run(&mut gone, far), Run::Unreachable { error: "unreachable".into() });
}

/// `set_up` starts the bootstrap, applies the machine config, then waits for both.
#[test]
fn set_up_starts_applies_and_waits() {
    let mut guest = FakeGuest::default();
    // Bootstrap: prepare, start.
    guest.answers.push_back(said(""));
    guest.answers.push_back(said("started\n"));
    // Machine config: prepare, start.
    guest.answers.push_back(said(""));
    guest.answers.push_back(said("started\n"));
    // The run's end, then the config's status (not yet, then done).
    guest.answers.push_back(said("cmux-wait free 5\n{\"state\":\"done\",\"exit_code\":0}\n"));
    guest.answers.push_back(said("{\"state\":\"running\"}"));
    guest.answers.push_back(said("{\"state\":\"done\",\"config_sha\":\"x\"}"));
    let setup = Setup {
        bootstrap: Some((Kind::Lane, b"#!/bin/sh\n".to_vec())),
        machine_config: Some(b"version = 1\n".to_vec()),
        wait: true,
        timeout: Duration::from_secs(600),
        name: Some("lane-4".into()),
    };
    let (answer, ok) = set_up(&mut guest, &setup);
    assert!(ok, "{answer}");
    assert_eq!(answer.pointer("/bootstrap/status"), Some(&json!("started")));
    assert_eq!(answer.pointer("/bootstrap/run/run"), Some(&json!("finished")));
    assert_eq!(answer.pointer("/machine_config/status"), Some(&json!("started")));
    assert_eq!(answer.pointer("/machine_config/state/state"), Some(&json!("done")));
    assert_eq!(guest.pauses, 1);
    let config_upload = guest.calls.iter().any(|call| {
        matches!(call, Call::Write { path, bytes, .. }
            if path.ends_with(".toml") && bytes == b"version = 1\n")
    });
    assert!(config_upload);
    assert!(human("vm_1", &answer).contains("Bootstrap: started; run finished"));

    // A failed start ends unwell, and its run is not waited for.
    let mut failing = FakeGuest::default();
    failing.answers.push_back(Ok(ExecAnswer {
        exit_code: 1,
        stdout: String::new(),
        stderr: "x".into(),
    }));
    let only = Setup { machine_config: None, ..setup };
    let (answer, ok) = set_up(&mut failing, &only);
    assert!(!ok);
    assert_eq!(answer.pointer("/bootstrap/status"), Some(&json!("failed")));
    assert_eq!(failing.calls.len(), 1);
}

#[test]
fn globals_come_from_the_plan() {
    let plan =
        words(&["--json", "--team", "t1", "--base-url=https://x", "create", "--", "--team", "no"]);
    assert_eq!(global_value(&plan, "--team").as_deref(), Some("t1"));
    assert_eq!(global_value(&plan, "--base-url").as_deref(), Some("https://x"));
    assert_eq!(global_value(&plan, "--config"), None);
}
