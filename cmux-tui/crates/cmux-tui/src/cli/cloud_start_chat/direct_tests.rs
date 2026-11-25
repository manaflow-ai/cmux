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
    fn create(&mut self, name: &str, key: &str) -> Result<Row, Value> {
        self.asked.push(format!("create {name} {key}"));
        let made = row("vm-new", name, "provisioning", None);
        self.rows.push(row("vm-new", name, "running", Some("h-new")));
        Ok(made)
    }
    fn start(&mut self, machine: &str, key: &str) -> Result<Row, Value> {
        self.asked.push(format!("start {machine} {key}"));
        let r = self.rows.iter_mut().find(|r| r.id == machine).unwrap();
        r.status = "running".into();
        r.host = Some("h-1".into());
        Ok(r.clone())
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
