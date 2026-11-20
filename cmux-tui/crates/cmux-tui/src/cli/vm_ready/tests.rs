//! `cmux vm new … --wait`: the words it sends, and the waits it does for a person.

use std::collections::VecDeque;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::cloud_start_chat::{Ran, Runner};
use super::{CONFIG_STATUS, DEFAULT_TIMEOUT, NewWait, new_and_wait, parse};

fn strings(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

/// Answers each step in turn by its verb (`cloud VERB`), and counts time by its pauses.
pub(crate) struct Fake {
    pub(crate) answers: Vec<(&'static str, VecDeque<Value>)>,
    pub(crate) ran: Vec<Vec<String>>,
    pub(crate) start: Instant,
    pub(crate) waited: Duration,
}

impl Fake {
    pub(crate) fn new(answers: Vec<(&'static str, Vec<Value>)>) -> Self {
        Self {
            answers: answers.into_iter().map(|(verb, list)| (verb, list.into())).collect(),
            ran: Vec::new(),
            start: Instant::now(),
            waited: Duration::ZERO,
        }
    }

    pub(crate) fn verbs(&self) -> Vec<String> {
        self.ran.iter().map(|words| words.get(1).cloned().unwrap_or_default()).collect()
    }
}

impl Runner for Fake {
    fn cmux(&mut self, args: &[String]) -> Ran {
        self.ran.push(args.to_vec());
        let verb = args.get(1).cloned().unwrap_or_default();
        let Some((_, list)) = self.answers.iter_mut().find(|(name, _)| *name == verb) else {
            return Ran {
                code: 1,
                stdout: String::new(),
                stderr: format!("unexpected step {verb}"),
            };
        };
        // The last answer repeats: a wait reads it until something changes.
        let answer = if list.len() > 1 { list.pop_front() } else { list.front().cloned() };
        match answer {
            Some(Value::Object(error)) if error.contains_key("code") => {
                Ran { code: 1, stdout: String::new(), stderr: Value::Object(error).to_string() }
            }
            Some(result) => Ran {
                code: 0,
                stdout: json!({"ok": true, "result": result}).to_string(),
                stderr: String::new(),
            },
            None => Ran { code: 1, stdout: String::new(), stderr: "no answer".into() },
        }
    }
    fn pause(&mut self, duration: Duration) {
        self.waited += duration;
    }
    fn now(&mut self) -> Instant {
        self.start + self.waited
    }
    fn fresh_name(&mut self) -> String {
        "chat-0000000000000000".into()
    }
}

pub(crate) fn row(id: &str, title: &str, status: &str) -> Value {
    json!({"machine_id": id, "title": title, "status": status})
}

pub(crate) fn listed(rows: &[Value]) -> Value {
    json!({"machines": rows})
}

pub(crate) fn config(state: &str) -> Value {
    json!({"path": CONFIG_STATUS, "text": json!({"state": state, "secrets": {"missing": ["API_KEY"]}}).to_string()})
}

#[test]
fn without_wait_it_is_not_this_command() {
    assert_eq!(parse(&strings(&["--name", "dev"]), || unreachable!()), None);
    // A `--wait` after `--` belongs to something else.
    assert_eq!(parse(&strings(&["--name", "dev", "--", "--wait"]), || unreachable!()), None);
}

#[test]
fn wait_and_timeout_are_taken_out_and_a_name_is_made_when_none_is_given() {
    let parsed =
        parse(&strings(&["--wait", "--machine-config", "a.toml", "--timeout", "60"]), || {
            "vm-abc".into()
        });
    assert_eq!(
        parsed,
        Some(Ok(NewWait {
            create: strings(&["--machine-config", "a.toml", "--name", "vm-abc"]),
            timeout: Duration::from_secs(60),
            name: "vm-abc".into(),
            configured: true,
        }))
    );
    let named = parse(&strings(&["--name=dev", "--wait", "--persistent"]), || unreachable!());
    assert_eq!(
        named,
        Some(Ok(NewWait {
            create: strings(&["--name=dev", "--persistent"]),
            timeout: DEFAULT_TIMEOUT,
            name: "dev".into(),
            configured: false,
        }))
    );
    assert!(matches!(
        parse(&strings(&["--wait", "--timeout", "soon"]), || "x".into()),
        Some(Err(_))
    ));
}

#[test]
fn a_configured_vm_is_ready_once_running_applied_and_its_secrets_delivered() {
    let request = parse(
        &strings(&["--name", "dev", "--machine-config", "m.toml", "--wait"]),
        || unreachable!(),
    )
    .unwrap()
    .unwrap();
    let mut fake = Fake::new(vec![
        ("new-machine", vec![json!({"pending": true, "status": "creating"})]),
        (
            "list-machines",
            vec![
                listed(&[]),
                listed(&[row("vm-1", "dev", "provisioning")]),
                listed(&[row("vm-1", "dev", "running")]),
            ],
        ),
        (
            "file-read",
            vec![
                json!({"code": "cloud.file_not_found", "message": "no file"}),
                config("running"),
                config("done"),
            ],
        ),
        (
            "deliver-secrets",
            vec![
                json!({"status": "delivering"}),
                json!({"status": "delivered", "delivered": ["API_KEY"], "missing": []}),
            ],
        ),
    ]);
    let answer = new_and_wait(&mut fake, &request).unwrap();
    assert_eq!(answer["machine_id"], "vm-1");
    assert_eq!(answer["target"], "vm:vm-1");
    assert_eq!(answer["machine_config"]["state"], "done");
    assert_eq!(answer["secrets"]["delivered"], json!(["API_KEY"]));
    assert_eq!(
        answer["next"]["start_agent"],
        "cmux vm start-session --target vm:vm-1 --agent claude"
    );
    assert_eq!(
        fake.ran[0],
        strings(&["cloud", "new-machine", "--name", "dev", "--machine-config", "m.toml", "--json"])
    );
    assert_eq!(
        fake.verbs(),
        strings(&[
            "new-machine",
            "list-machines",
            "list-machines",
            "list-machines",
            "file-read",
            "file-read",
            "file-read",
            "deliver-secrets",
            "deliver-secrets",
        ])
    );
    assert_eq!(
        fake.ran[4],
        strings(&[
            "cloud",
            "file-read",
            "--target",
            "machine:vm-1",
            "--path",
            CONFIG_STATUS,
            "--json"
        ])
    );
}

#[test]
fn a_vm_with_no_config_is_ready_once_running() {
    let request = parse(&strings(&["--wait"]), || "vm-made".into()).unwrap().unwrap();
    let mut fake = Fake::new(vec![
        ("new-machine", vec![json!({"machine_id": "vm-2", "status": "provisioning"})]),
        ("list-machines", vec![listed(&[row("vm-2", "vm-made", "running")])]),
    ]);
    let answer = new_and_wait(&mut fake, &request).unwrap();
    assert_eq!(answer["machine_id"], "vm-2");
    assert!(answer.get("machine_config").is_none());
    assert_eq!(fake.verbs(), strings(&["new-machine", "list-machines"]));
}

#[test]
fn a_failed_setup_stops_with_its_status_and_log() {
    let request = parse(&strings(&["--name", "dev", "--repo", "o/r", "--wait"]), || unreachable!())
        .unwrap()
        .unwrap();
    let mut fake = Fake::new(vec![
        ("new-machine", vec![json!({"machine_id": "vm-3"})]),
        ("list-machines", vec![listed(&[row("vm-3", "dev", "running")])]),
        ("file-read", vec![config("failed")]),
    ]);
    let error = new_and_wait(&mut fake, &request).unwrap_err();
    assert_eq!(error["code"], "vm.config_failed");
    assert_eq!(error["details"]["log"], "/home/cmux/.cmux/machine-config/setup.log");
    assert!(!fake.verbs().contains(&"deliver-secrets".to_owned()));
}

#[test]
fn the_wait_ends_at_its_timeout_and_says_what_to_check() {
    let request =
        parse(&strings(&["--name", "dev", "--wait", "--timeout", "30"]), || unreachable!())
            .unwrap()
            .unwrap();
    let mut fake = Fake::new(vec![
        ("new-machine", vec![json!({"pending": true})]),
        ("list-machines", vec![listed(&[row("vm-4", "dev", "provisioning")])]),
    ]);
    let error = new_and_wait(&mut fake, &request).unwrap_err();
    assert_eq!(error["code"], "vm.wait_timeout");
    assert_eq!(error["details"]["next"], "cmux vm ls");
    assert!(fake.waited >= Duration::from_secs(30));
}

#[test]
fn a_create_refusal_is_the_answer() {
    let request = parse(&strings(&["--wait"]), || "vm-x".into()).unwrap().unwrap();
    let mut fake = Fake::new(vec![(
        "new-machine",
        vec![
            json!({"code": "cloud.quota.exceeded", "message": "this plan allows 5 active machines"}),
        ],
    )]);
    let error = new_and_wait(&mut fake, &request).unwrap_err();
    assert_eq!(error["code"], "cloud.quota.exceeded");
    assert_eq!(fake.verbs(), strings(&["new-machine"]));
}
