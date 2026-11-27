//! The headless route (direct.rs): the same start answered by the cmux API instead of the app,
//! old (app verbs) against new (direct) on one request.

use std::collections::VecDeque;

use serde_json::{Value, json};

use super::super::direct::{Cloud, DirectRunner, Route, Row, start_program};
use super::*;

/// A fake cmux API: its machines, the calls asked, and the exec answers in order.
struct FakeCloud {
    rows: Vec<Row>,
    asked: Vec<String>,
    execs: VecDeque<Result<Value, Value>>,
    commands: Vec<String>,
}

fn row(id: &str, name: &str, status: &str, host: Option<&str>) -> Row {
    Row {
        id: id.into(),
        name: Some(name.into()),
        status: status.into(),
        host: host.map(Into::into),
        created_at: None,
        running_since: None,
        size: None,
    }
}

impl Cloud for FakeCloud {
    fn list(&mut self) -> Result<Vec<Row>, Value> {
        self.asked.push("list".into());
        Ok(self.rows.clone())
    }
    fn get(&mut self, machine: &str) -> Result<Row, Value> {
        self.asked.push(format!("get {machine}"));
        self.rows
            .iter()
            .find(|r| r.id == machine)
            .cloned()
            .ok_or_else(|| json!({"code": "cloud.machine.not_found", "message": "gone"}))
    }
    fn create(&mut self, name: &str, key: &str, provider: Option<&str>) -> Result<Row, Value> {
        self.asked.push(format!("create {name} {key} {}", provider.unwrap_or("default")));
        let made = row("vm-new", name, "provisioning", None);
        self.rows.push(row("vm-new", name, "running", Some("h-new")));
        Ok(made)
    }
    fn start(&mut self, machine: &str, key: &str) -> Result<Row, Value> {
        self.asked.push(format!("start {machine} {key}"));
        let r = self.rows.iter_mut().find(|r| r.id == machine).ok_or_else(gone)?;
        if r.status != "paused" {
            return Err(json!({"code": "cloud.machine.not_paused", "message": "not paused"}));
        }
        r.status = "running".into();
        r.host = Some("h-1".into());
        Ok(r.clone())
    }
    fn pause(&mut self, machine: &str, key: &str) -> Result<Row, Value> {
        self.asked.push(format!("pause {machine} {key}"));
        let r = self.rows.iter_mut().find(|r| r.id == machine).ok_or_else(gone)?;
        if r.status != "running" {
            return Err(json!({"code": "cloud.machine.not_running", "message": "not running"}));
        }
        r.status = "paused".into();
        r.host = None;
        Ok(r.clone())
    }
    fn delete(&mut self, machine: &str, key: &str) -> Result<(), Value> {
        self.asked.push(format!("delete {machine} {key}"));
        self.rows.retain(|r| r.id != machine);
        Ok(())
    }
    fn exec(&mut self, machine: &str, command: &str, _timeout_ms: u64) -> Result<Value, Value> {
        self.asked.push(format!("exec {machine}"));
        self.commands.push(command.to_owned());
        self.execs.pop_front().expect("an exec answer")
    }
    fn team(&self) -> Option<String> {
        Some("team_1".into())
    }
    fn new_key(&mut self) -> String {
        "key-0123456789abcdef".into()
    }
}

fn gone() -> Value {
    json!({"code": "cloud.machine.not_found", "message": "gone"})
}

fn fake(rows: Vec<Row>) -> FakeCloud {
    FakeCloud { rows, asked: Vec::new(), execs: VecDeque::new(), commands: Vec::new() }
}

/// One app verb on the direct route: its answer (`result`) or its error.
fn verb(cloud: &mut FakeCloud, words: &[&str]) -> (Result<Value, Value>, Vec<Vec<String>>) {
    let mut inner = Fake::new(vec![]);
    let args: Vec<String> = words.iter().map(|w| (*w).to_owned()).collect();
    let ran = DirectRunner { inner: &mut inner, cloud }.cmux(&args);
    (super::super::step_result(&ran), inner.ran)
}

fn out(stdout: &str) -> Result<Value, Value> {
    Ok(json!({"exit_code": 0, "stdout": stdout, "stderr": ""}))
}

const SEND: &str = "@@history\n{\"turns\":[]}\n@@send\nd\n@@exit 0\n";

/// Old against new: the app route and the direct route answer one start with the same chat.
#[test]
fn the_direct_route_answers_the_start_the_app_route_answers() {
    let asked = request(&["--prompt", "x", "--name", "dev"]);
    let mut app = Fake::new(vec![
        ok(
            json!({"account": {"signed_in": true}, "machines": [{"title": "dev", "machine_id": "vm-1"}]}),
        ),
        ok(
            json!({"machine_id": "vm-1", "machine_name": "dev", "session_id": "sess-1", "host": "h-1"}),
        ),
        exec_out(SEND),
    ]);
    let Outcome::Done(old) = run(&mut app, &asked) else { panic!("{:?}", app.ran) };

    let mut inner = Fake::new(vec![]);
    let mut cloud = FakeCloud {
        rows: vec![row("vm-1", "dev", "paused", None)],
        asked: Vec::new(),
        execs: VecDeque::from([out("@@session sess-1\n"), out(SEND)]),
        commands: Vec::new(),
    };
    let new = run(&mut DirectRunner { inner: &mut inner, cloud: &mut cloud }, &asked);
    let Outcome::Done(new) = new else { panic!("{new:?} {:?}", cloud.asked) };
    for key in ["machine_id", "machine_name", "session_id", "target", "sent", "follow_up", "agent"]
    {
        assert_eq!(old[key], new[key], "{key}");
    }
    assert_eq!(new["sent"], true);
    assert!(inner.ran.is_empty(), "no app verb reached the app: {:?}", inner.ran);
    // The paused machine of that name was started, not a second one made.
    assert!(cloud.asked.iter().any(|a| a.starts_with("start vm-1")), "{:?}", cloud.asked);
    assert!(!cloud.asked.iter().any(|a| a.starts_with("create")), "{:?}", cloud.asked);
    assert!(cloud.commands[0].contains("acp new --machine local --name"), "{}", cloud.commands[0]);
    assert!(
        cloud.commands[1].contains("acp send --no-wait") && cloud.commands[1].contains("sess-1"),
        "{}",
        cloud.commands[1]
    );
}

#[test]
fn a_name_no_machine_has_is_made_once_and_waited_on() {
    let asked = request(&["--name", "lane-x"]);
    let mut inner = Fake::new(vec![]);
    let mut cloud = FakeCloud {
        rows: vec![],
        asked: Vec::new(),
        // No prompt: the start, then the read of the chat's folder.
        execs: VecDeque::from([out("@@session None\n"), out("@@cwd\n")]),
        commands: Vec::new(),
    };
    let done = run(&mut DirectRunner { inner: &mut inner, cloud: &mut cloud }, &asked);
    let Outcome::Done(answer) = done else { panic!("{done:?}") };
    assert_eq!(answer["machine_id"], "vm-new");
    // A session that answered no id is the name it was started with.
    assert!(answer["session_id"].as_str().unwrap().starts_with("chat-"), "{answer}");
    assert_eq!(cloud.asked.iter().filter(|a| a.starts_with("create lane-x")).count(), 1);
    // The fake says nothing of a claim: the answer says so rather than guessing.
    assert_eq!(answer["machine_origin"], json!({"from": "unknown"}), "{answer}");
}

#[test]
fn a_provider_is_forwarded_when_direct_route_creates_machine() {
    let asked = request(&["--name", "lane-gcp", "--provider", "gcp"]);
    let mut inner = Fake::new(vec![]);
    let mut cloud = FakeCloud {
        rows: vec![],
        asked: Vec::new(),
        execs: VecDeque::from([out("@@session None\n"), out("@@cwd\n")]),
        commands: Vec::new(),
    };
    let done = run(&mut DirectRunner { inner: &mut inner, cloud: &mut cloud }, &asked);
    assert!(matches!(done, Outcome::Done(_)), "{done:?}");
    assert!(cloud.asked.iter().any(|call| call.ends_with(" gcp")), "{:?}", cloud.asked);
}

#[test]
fn an_existing_machine_answers_that_it_existed() {
    let asked = request(&["--name", "dev"]);
    let mut inner = Fake::new(vec![]);
    let mut cloud = FakeCloud {
        rows: vec![row("vm-1", "dev", "running", Some("h-1"))],
        asked: Vec::new(),
        execs: VecDeque::from([out("@@session s\n"), out("@@cwd\n")]),
        commands: Vec::new(),
    };
    let done = run(&mut DirectRunner { inner: &mut inner, cloud: &mut cloud }, &asked);
    let Outcome::Done(answer) = done else { panic!("{done:?}") };
    assert_eq!(
        answer["machine_origin"],
        json!({"from": "existing", "status_before": "running"}),
        "{answer}"
    );
}

#[test]
fn a_reused_machine_records_its_uptime_age_and_size() {
    let now = 1_800_000_000_000;
    let mut vm = row("vm-1", "dev", "running", Some("h-1"));
    vm.created_at = Some(now - 7_200_000);
    vm.running_since = Some(now - 600_000);
    vm.size = Some(json!({"cpu": 2, "memory_mb": 4096, "disk_mb": 20480}));
    assert_eq!(
        vm.reused(now),
        json!({"from": "existing", "status_before": "running", "uptime_s": 600, "age_s": 7200,
            "size": {"cpu": 2, "memory_mb": 4096, "disk_mb": 20480}})
    );
    // A paused machine has no uptime (it is resumed for the start); a clock behind the
    // platform's records no negative age.
    vm.status = "paused".into();
    assert_eq!(vm.reused(now)["uptime_s"], Value::Null);
    assert_eq!(vm.reused(now - 10_000_000)["age_s"], Value::Null);
}

#[test]
fn spare_origin_reads_the_create_answer_claim() {
    use super::super::direct::spare_origin;
    let spare = json!({"machine": {}, "spare_path": "running", "spare_fallback": null,
        "claim": {"path": "running", "fallback": null, "ms": 412}});
    assert_eq!(spare_origin(&spare), json!({"from": "spare", "path": "running", "claim_ms": 412}));
    let resumed = json!({"claim": {"path": "resumed", "fallback": null, "ms": 1900}});
    assert_eq!(spare_origin(&resumed)["from"], "spare");
    let fresh = json!({"spare_fallback": "no_spare", "claim": {"path": "created", "fallback": "no_spare", "ms": 30}});
    assert_eq!(
        spare_origin(&fresh),
        json!({"from": "fresh", "path": "created", "fallback": "no_spare", "claim_ms": 30})
    );
    // An answer with no claim (a replay, a caller the platform hands no spare).
    assert_eq!(spare_origin(&json!({"machine": {}})), json!({"from": "unknown"}));
}

#[test]
fn a_failed_agent_start_names_the_machine_and_what_it_said() {
    let asked = request(&["--prompt", "x", "--name", "dev"]);
    let mut inner = Fake::new(vec![]);
    let mut cloud = FakeCloud {
        rows: vec![row("vm-1", "dev", "running", Some("h-1"))],
        asked: Vec::new(),
        execs: VecDeque::from([out("no harness claude\n@@exit 1\n")]),
        commands: Vec::new(),
    };
    let done = run(&mut DirectRunner { inner: &mut inner, cloud: &mut cloud }, &asked);
    let Outcome::Failed { error, .. } = done else { panic!("{done:?}") };
    let text = error.to_string();
    assert!(text.contains("vm-1") && text.contains("no harness claude"), "{text}");
}

#[test]
fn the_route_is_direct_only_with_a_credential_and_no_app_named() {
    let global =
        |app: Option<&str>| GlobalArgs { app_socket: app.map(Into::into), ..GlobalArgs::default() };
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| (*v).to_owned())
    };
    let token: &[(&str, &str)] = &[("CMUX_CLOUD_ACCESS_TOKEN", "t")];
    assert_eq!(Route::choose(&global(None), env(token)), Route::Direct);
    assert_eq!(Route::choose(&global(Some("/s")), env(token)), Route::App);
    assert_eq!(Route::choose(&global(None), env(&[])), Route::App, "signed-out stays the app's");
}

#[test]
fn a_launch_credential_goes_to_session_new_never_to_argv_words() {
    let with =
        start_program("s1", "claude", None, Some("/w"), Some(("K".into(), "sk-secret".into())));
    assert!(with.contains("session/new") && with.contains("python3 -I -"), "{with}");
    let plain = start_program("s1", "codex", Some("gpt-5.5"), Some("/a b"), None);
    assert!(plain.contains("-m codex/gpt-5.5") && plain.contains("--cwd '/a b'"), "{plain}");
}

#[test]
fn pause_resume_and_kill_answer_from_the_cmux_api_with_no_app() {
    let mut cloud = fake(vec![row("vm-1", "dev", "running", Some("h-1"))]);
    let (paused, app) = verb(&mut cloud, &["cloud", "pause-machine", "--target", "machine:vm-1"]);
    let paused = paused.unwrap();
    assert_eq!(paused["machine_id"], "vm-1");
    assert_eq!(paused["machine_name"], "dev");
    assert_eq!(paused["status"], "paused");
    assert_eq!(paused["route"], "direct");
    assert!(app.is_empty(), "no app verb: {app:?}");

    // `vm:ID`, the spelling cloud_help prints, names the same machine.
    let (resumed, app) = verb(&mut cloud, &["cloud", "resume-machine", "--target", "vm:vm-1"]);
    assert_eq!(resumed.unwrap()["status"], "running");
    assert!(app.is_empty(), "no app verb: {app:?}");

    let (killed, app) =
        verb(&mut cloud, &["cloud", "kill-machine", "--target", "vm-1", "--yes", "--json"]);
    let killed = killed.unwrap();
    assert_eq!(killed["machine_id"], "vm-1");
    assert_eq!(killed["deleted"], true);
    assert!(app.is_empty(), "no app verb: {app:?}");
    assert!(cloud.rows.is_empty());
    assert_eq!(
        cloud.asked,
        [
            "pause vm-1 key-0123456789abcdef",
            "start vm-1 key-0123456789abcdef",
            "delete vm-1 key-0123456789abcdef"
        ]
    );
}

#[test]
fn pausing_a_paused_machine_or_resuming_a_running_one_answers_its_state() {
    let mut cloud = fake(vec![row("vm-1", "dev", "paused", None)]);
    let (paused, _) = verb(&mut cloud, &["cloud", "pause-machine", "--target", "machine:vm-1"]);
    assert_eq!(paused.unwrap()["status"], "paused");
    let mut cloud = fake(vec![row("vm-2", "b", "running", Some("h"))]);
    let (resumed, _) = verb(&mut cloud, &["cloud", "resume-machine", "--target", "machine:vm-2"]);
    assert_eq!(resumed.unwrap()["status"], "running");
}

#[test]
fn kill_needs_yes_and_every_verb_needs_a_target() {
    let mut cloud = fake(vec![row("vm-1", "dev", "running", Some("h-1"))]);
    let (refused, _) = verb(&mut cloud, &["cloud", "kill-machine", "--target", "machine:vm-1"]);
    let refused = refused.unwrap_err();
    assert_eq!(refused["code"], "usage.invalid");
    assert!(refused["message"].as_str().unwrap().contains("--yes"), "{refused}");
    assert_eq!(cloud.rows.len(), 1, "nothing deleted without --yes");
    for name in ["pause-machine", "resume-machine", "kill-machine"] {
        let (refused, _) = verb(&mut cloud, &["cloud", name, "--yes"]);
        assert_eq!(refused.unwrap_err()["code"], "usage.invalid", "{name}");
        let (refused, _) = verb(&mut cloud, &["cloud", name, "--target", "ws:main", "--yes"]);
        assert_eq!(refused.unwrap_err()["code"], "usage.invalid", "{name}");
    }
    assert!(cloud.asked.is_empty(), "{:?}", cloud.asked);
}

#[test]
fn a_missing_machine_is_refused_with_the_apis_code() {
    let mut cloud = fake(vec![]);
    let (refused, _) = verb(&mut cloud, &["cloud", "pause-machine", "--target", "machine:vm-9"]);
    assert_eq!(refused.unwrap_err()["code"], "cloud.machine.not_found");
}

/// A message to a chat already on a machine (`cmux chat send SESSION`) execs through the cmux API.
#[test]
fn a_message_to_an_existing_chat_runs_with_no_app() {
    let asked = request(&["--prompt", "next step", "--target", "machine:vm-1"]);
    let mut inner = Fake::new(vec![]);
    let mut cloud = fake(vec![row("vm-1", "dev", "running", Some("h-1"))]);
    cloud.execs = VecDeque::from([out(SEND)]);
    let sent = send_to(
        &mut DirectRunner { inner: &mut inner, cloud: &mut cloud },
        &asked,
        "vm-1",
        "sess-1",
    );
    let Outcome::Done(answer) = sent else { panic!("{sent:?} {:?}", cloud.asked) };
    assert_eq!(answer["sent"], true, "{answer}");
    assert!(inner.ran.is_empty(), "no app verb reached the app: {:?}", inner.ran);
    assert!(cloud.commands[0].contains("sess-1"), "{}", cloud.commands[0]);
}
